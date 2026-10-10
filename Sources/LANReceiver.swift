import Foundation
import Combine
import Network
import Darwin

struct ReceivedFile: Identifiable {
    let id = UUID()
    let url: URL
    let date: Date
    let size: Int64
}

final class LANReceiver: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var url: URL?
    @Published private(set) var status = "开启后，用安卓浏览器扫码传文件"
    @Published private(set) var received: [ReceivedFile] = []
    let directory: URL

    private let bindHost: String?
    private let queue = DispatchQueue(label: "app.owldrop.receiver")
    private var listener: NWListener?
    private var clients: [UUID: UploadConnection] = [:]

    init(directory: URL? = nil, bindHost: String? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Owl Drop", isDirectory: true)
        self.bindHost = bindHost
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            guard let host = self.bindHost ?? Self.localIPv4() else {
                self.publish(running: false, url: nil, status: "未找到局域网 IPv4，请连接 Wi-Fi 后重试")
                return
            }
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port,
                              let url = URL(string: "http://\(host):\(port.rawValue)/\(token)/") else { return }
                        self.publish(running: true, url: url, status: "等待安卓传入 · 文件保存在下载文件夹")
                    case .failed(let error):
                        self.shutdown()
                        self.publish(running: false, url: nil, status: "接收服务失败：\(error.localizedDescription)")
                    case .waiting(let error):
                        self.shutdown()
                        self.publish(running: false, url: nil, status: "网络暂不可用：\(error.localizedDescription)")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self, weak listener] connection in
                    guard let self, let listener, self.listener === listener,
                          let port = listener.port, self.clients.count < 4 else { connection.cancel(); return }
                    let client = UploadConnection(connection: connection, queue: self.queue, directory: self.directory,
                                                  authority: "\(host):\(port.rawValue)", token: token)
                    self.clients[client.id] = client
                    client.finished = { [weak self, weak client] file, error in
                        guard let self, let client else { return }
                        self.clients.removeValue(forKey: client.id)
                        guard self.listener === listener else { return }
                        if let file {
                            DispatchQueue.main.async {
                                self.received.insert(file, at: 0)
                                self.received = Array(self.received.prefix(20))
                                self.status = "已收到：\(file.url.lastPathComponent)"
                            }
                        } else if let error {
                            DispatchQueue.main.async { self.status = error }
                        }
                    }
                    client.start()
                }
                listener.start(queue: self.queue)
            } catch {
                self.shutdown()
                self.publish(running: false, url: nil, status: "无法开启接收：\(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.sync {
            shutdown()
        }
        publish(running: false, url: nil, status: "接收已关闭，原二维码已失效")
    }

    private func shutdown() {
        listener?.cancel()
        listener = nil
        let active = Array(clients.values)
        clients.removeAll()
        for client in active { client.cancel() }
    }

    private func publish(running: Bool, url: URL?, status: String) {
        DispatchQueue.main.async {
            self.isRunning = running
            self.url = url
            self.status = status
        }
    }

    private static func localIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var current = head
        var candidates: [(String, String)] = []
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let item = interface.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (item.ifa_flags & UInt32(IFF_UP)) != 0,
                  (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            guard inet_ntop(AF_INET, &ipv4, &bytes, socklen_t(bytes.count)) != nil else { continue }
            let host = String(cString: bytes)
            let parts = host.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4,
                  parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168) else { continue }
            candidates.append((name, host))
        }
        return candidates.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }.first?.1
    }
}

private final class UploadConnection {
    let id = UUID()
    var finished: ((ReceivedFile?, String?) -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let directory: URL
    private let authority: String
    private let prefix: String
    private var header = Data()
    private var parsed = false
    private var remaining: Int64 = 0
    private var size: Int64 = 0
    private var filename = ""
    private var fd: Int32 = -1
    private var temporary: URL?
    private var timer: DispatchSourceTimer?
    private var done = false
    private var responding = false
    private var completedFile: ReceivedFile?
    private var failure: String?

    init(connection: NWConnection, queue: DispatchQueue, directory: URL, authority: String, token: String) {
        self.connection = connection
        self.queue = queue
        self.directory = directory
        self.authority = authority
        self.prefix = "/\(token)/"
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.cancel() }
        timer.schedule(deadline: .now() + 30)
        timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
        }
        connection.start(queue: queue)
        readNext()
    }

    func cancel() {
        guard !done else { return }
        done = true
        timer?.cancel()
        timer = nil
        if fd >= 0 { close(fd); fd = -1 }
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        connection.cancel()
        finished?(completedFile, failure)
        finished = nil
    }

    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.done, !self.responding else { return }
            self.timer?.schedule(deadline: .now() + 30)
            if let data, !data.isEmpty { self.consume(data) }
            guard !self.done, !self.responding else { return }
            if complete || error != nil { self.cancel() } else { self.readNext() }
        }
    }

    private func consume(_ data: Data) {
        if !parsed {
            header.append(data)
            guard let boundary = header.range(of: Data("\r\n\r\n".utf8)) else {
                if header.count > 16384 { respond(431, "请求头过大") }
                return
            }
            guard boundary.upperBound <= 16384 else { respond(431, "请求头过大"); return }
            let body = Data(header[boundary.upperBound...])
            let raw = Data(header[..<boundary.lowerBound])
            header.removeAll(keepingCapacity: false)
            guard parse(raw) else { return }
            parsed = true
            writeBody(body)
        } else { writeBody(data) }
    }

    private func parse(_ raw: Data) -> Bool {
        guard let text = String(data: raw, encoding: .utf8), !text.contains("\0") else { respond(400, "请求头无效"); return false }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1", request[1].hasPrefix("/"), !request[1].hasPrefix("//") else {
            respond(400, "请求格式无效"); return false
        }
        var fields: [String: String] = [:]
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(400, "请求头无效"); return false }
            let key = String(line[..<colon])
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }) else { respond(400, "请求头无效"); return false }
            let lower = key.lowercased()
            guard fields[lower] == nil else { respond(400, "不支持重复请求头"); return false }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { respond(400, "请求头无效"); return false }
            fields[lower] = value
        }
        guard fields["host"] == authority,
              fields["origin"] == nil || fields["origin"] == "http://\(authority)",
              fields["sec-fetch-site"] == nil || ["same-origin", "none"].contains(fields["sec-fetch-site"]!) else {
            respond(403, "来源未获允许"); return false
        }
        guard fields["transfer-encoding"] == nil, fields["expect"] == nil else { respond(400, "不支持此传输方式"); return false }
        guard let parts = URLComponents(string: String(request[1])), parts.scheme == nil, parts.host == nil,
              parts.fragment == nil, parts.percentEncodedPath.hasPrefix(prefix) else { respond(403, "接收链接无效或已失效"); return false }
        if request[0] == "GET", parts.percentEncodedPath == prefix, parts.query == nil {
            guard fields["content-length"] == nil || fields["content-length"] == "0" else { respond(400, "页面请求不应包含正文"); return false }
            respond(200, Self.page, html: true)
            return false
        }
        guard request[0] == "POST", parts.percentEncodedPath == prefix + "upload" else { respond(404, "没有此接口"); return false }
        guard let length = fields["content-length"], !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int64(length) else {
            respond(400, "缺少有效文件大小"); return false
        }
        guard count <= 2 * 1024 * 1024 * 1024 else { respond(413, "单个文件不能超过 2 GB"); return false }
        guard let items = parts.queryItems, items.count == 1, items[0].name == "name", let name = items[0].value,
              !name.isEmpty, name.utf8.count <= 200, !name.hasPrefix("."),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            respond(400, "文件名无效，请更名后重试"); return false
        }
        filename = name
        size = count
        remaining = count
        let temp = directory.appendingPathComponent(".owl-upload-\(UUID().uuidString)")
        fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { failDisk("无法创建文件，请检查下载文件夹权限或剩余空间"); return false }
        temporary = temp
        return true
    }

    private func writeBody(_ data: Data) {
        guard Int64(data.count) <= remaining else { respond(400, "文件长度与声明不一致"); return }
        let success = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard success else { failDisk("写入失败，请检查磁盘空间与文件夹权限"); return }
        remaining -= Int64(data.count)
        if remaining == 0 { commit() }
    }

    private func commit() {
        let quarantine = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));Owl Drop;"
        let quarantined = quarantine.withCString { fsetxattr(fd, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        guard quarantined == 0 else { failDisk("无法设置 macOS 文件安全标记，本次接收已取消"); return }
        guard fsync(fd) == 0 else { failDisk("磁盘同步失败，本次接收已取消"); return }
        let closeResult = close(fd)
        fd = -1
        guard closeResult == 0, let temporary else { failDisk("关闭文件失败，本次接收已取消"); return }
        let sourceName = filename as NSString
        let ext = sourceName.pathExtension
        let stem = ext.isEmpty ? filename : sourceName.deletingPathExtension
        for number in 1...10000 {
            let name = number == 1 ? filename : "\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
            let destination = directory.appendingPathComponent(name)
            // link publishes the completed inode atomically and never replaces an existing file.
            if link(temporary.path, destination.path) == 0 {
                completedFile = ReceivedFile(url: destination, date: Date(), size: size)
                respond(201, "已保存：\(name)")
                return
            }
            if errno != EEXIST { failDisk("无法保存文件，请检查磁盘格式和文件夹权限"); return }
        }
        failDisk("同名文件过多，请更名后重试")
    }

    private func failDisk(_ message: String) {
        failure = message
        respond(500, message)
    }

    private func respond(_ code: Int, _ message: String, html: Bool = false) {
        guard !responding, !done else { return }
        responding = true
        let descriptions = [200: "OK", 201: "Created", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error"]
        let body = html ? Data(message.utf8) : (try! JSONSerialization.data(withJSONObject: ["message": message]))
        let headers = "HTTP/1.1 \(code) \(descriptions[code] ?? "Error")\r\nContent-Type: \(html ? "text/html" : "application/json"); charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.cancel() })
    }

    private static let page = #"""
    <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Owl Drop · 发到 Mac</title>
    <style>
    *{box-sizing:border-box}body{margin:0;background:#f5f5fa;color:#24243b;font-family:system-ui,-apple-system,sans-serif;padding:28px 22px}
    main{max-width:460px;margin:4vh auto}small{letter-spacing:.14em;color:#4a4cc7;font-weight:700}h1{font-size:38px;letter-spacing:-.04em;margin:18px 0 12px}
    p{line-height:1.7;color:#62647a}.card{margin-top:24px;padding:22px;background:#fff;border:1px solid #dedfea;border-radius:24px}
    .choices{display:grid;grid-template-columns:1fr 1fr;gap:12px}button{cursor:pointer;padding:16px 10px;border:1px solid transparent;border-radius:14px;font:600 16px system-ui}
    .pick{background:#f0f0fc;color:#3d3eb0;border-color:#ddddf2;min-height:82px}.pick span{display:block;font-size:12px;font-weight:400;margin-top:7px;color:#62647a}
    #upload{width:100%;margin-top:22px;background:#4a4cc7;color:#fff}button:disabled{opacity:.45;cursor:default}button:focus-visible{outline:3px solid #8587e7;outline-offset:3px}
    progress{width:100%;height:10px;margin-top:22px;accent-color:#4a4cc7}#status{white-space:pre-wrap;word-break:break-word;font-size:14px}footer{font-size:12px;color:#62647a;margin-top:24px;line-height:1.7}
    </style>
    <main><small>OWL DROP / 局域网直传</small><h1>把照片，传到 Mac。</h1><p>从相册选好图片，点一下上传。<br>也能发送视频和文档，不用安装 App。</p>
    <div class="card"><div class="choices">
    <button class="pick" id="pickPhotos" type="button">选择图片<span>相册图片 · 支持多选</span></button>
    <button class="pick" id="pickFiles" type="button">选择文件<span>视频、文档等</span></button></div>
    <input id="photos" type="file" accept="image/*" multiple hidden><input id="files" type="file" multiple hidden>
    <button id="upload" disabled>开始上传</button><progress id="progress" max="100" value="0" aria-label="上传进度"></progress>
    <p id="status" role="status" aria-live="polite">先选择图片或文件，每个最多 2 GB。</p></div>
    <footer>保持页面开启，文件保存到 Mac 的「下载 / Owl Drop」。<br>手机与 Mac 需连接同一 Wi-Fi。链接仅本次接收有效。<br>局域网 HTTP 传输不加密，请在可信网络中使用。</footer></main>
    <script>
    const files=document.getElementById('files'),photos=document.getElementById('photos'),button=document.getElementById('upload'),status=document.getElementById('status'),progress=document.getElementById('progress');
    const pickPhotos=document.getElementById('pickPhotos'),pickFiles=document.getElementById('pickFiles');let selected=[];
    pickPhotos.onclick=()=>{photos.value='';photos.click()};pickFiles.onclick=()=>{files.value='';files.click()};
    function select(list){if(!list.length)return;selected=Array.from(list);button.disabled=false;button.textContent='开始上传';status.textContent='已选 '+selected.length+' 项，点击开始上传\n'+selected.map(f=>f.name).join('\n');progress.value=0}
    files.onchange=()=>select(files.files);photos.onchange=()=>select(photos.files);
    button.onclick=async()=>{
      button.disabled=true;pickPhotos.disabled=true;pickFiles.disabled=true;files.disabled=true;photos.disabled=true;
      let good=0,bad=0;const results=[];
      for(let i=0;i<selected.length;i++){
        const f=selected[i];progress.value=0;status.textContent='正在上传 '+(i+1)+' / '+selected.length+'：'+f.name;
        try{
          if(f.size>2147483648)throw Error('超过 2 GB');
          const saved=await new Promise((resolve,reject)=>{
            const x=new XMLHttpRequest();x.open('POST','upload?name='+encodeURIComponent(f.name));x.timeout=1800000;x.setRequestHeader('Content-Type','application/octet-stream');
            x.upload.onprogress=e=>{if(e.lengthComputable)progress.value=e.loaded/e.total*100};
            x.onload=()=>{let msg='服务器返回 '+x.status;try{msg=JSON.parse(x.responseText).message}catch{}x.status===201?resolve(msg):reject(Error(msg))};
            x.onerror=()=>reject(Error('网络中断，请检查 Mac 接收是否仍开启；重试前查看 Mac 是否已收到'));
            x.ontimeout=()=>reject(Error('上传超时；重试前查看 Mac 是否已收到'));x.send(f)
          });good++;results.push('✓ '+saved)
        }catch(e){bad++;results.push('✕ '+f.name+'：'+e.message)}
      }
      progress.value=bad?0:100;status.textContent='完成：'+good+' 个成功'+(bad?'，'+bad+' 个失败':'')+'\n'+results.join('\n');
      files.disabled=false;photos.disabled=false;pickPhotos.disabled=false;pickFiles.disabled=false;button.disabled=false;button.textContent='再次上传所选文件'
    };
    </script></html>
    """#
}
