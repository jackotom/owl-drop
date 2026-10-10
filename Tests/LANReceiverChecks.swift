import Foundation
import Darwin

@main
enum LANReceiverChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func connect(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        require(result == 0, "connect failed")
        return fd
    }

    static func send(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                require(count > 0, "write failed")
                offset += count
            }
        }
    }

    static func request(_ base: URL, method: String = "POST", path: String? = nil, body: Data = Data("hello".utf8), extra: String = "", host: String? = nil) -> String {
        let fd = connect(UInt16(base.port!))
        defer { close(fd) }
        let target = path ?? URLComponents(url: base, resolvingAgainstBaseURL: false)!.percentEncodedPath + "upload?name=hello.txt"
        let header = "\(method) \(target) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(base.port!)")\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
        send(fd, Data(header.utf8) + body)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: response, as: UTF8.self)
    }

    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owl-receiver-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiver = LANReceiver(directory: directory, bindHost: "127.0.0.1")
        receiver.start()
        for _ in 0..<500 where receiver.url == nil { pump(0.01) }
        guard let base = receiver.url else { fatalError("server did not start: \(receiver.status)") }
        let prefix = URLComponents(url: base, resolvingAgainstBaseURL: false)!.percentEncodedPath
        require(request(base, method: "GET", path: prefix, body: Data()).contains("200 OK"), "mobile page")
        require(request(base).contains("201 Created"), "valid upload")
        require(try! Data(contentsOf: directory.appendingPathComponent("hello.txt")) == Data("hello".utf8), "file content")
        require(request(base, body: Data("second".utf8)).contains("201 Created"), "duplicate upload")
        require(try! Data(contentsOf: directory.appendingPathComponent("hello.txt")) == Data("hello".utf8), "must not overwrite")
        require(try! Data(contentsOf: directory.appendingPathComponent("hello (2).txt")) == Data("second".utf8), "collision suffix")
        let quarantine = directory.appendingPathComponent("hello.txt").path.withCString { getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) }
        require(quarantine > 0, "quarantine attribute missing")
        require(request(base, path: prefix + "upload?name=..%2Fescape").contains("400 Bad Request"), "path traversal")
        require(request(base, path: "/wrong/upload?name=bad.txt").contains("403 Forbidden"), "wrong token")
        require(request(base, extra: "Origin: https://evil.example\r\n").contains("403 Forbidden"), "cross-site origin")
        require(request(base, host: "evil.example").contains("403 Forbidden"), "wrong host")
        require(request(base, extra: "Content-Length: 5\r\n").contains("400 Bad Request"), "duplicate length")
        require(request(base, extra: "Transfer-Encoding: chunked\r\n").contains("400 Bad Request"), "chunked unsupported")
        let fd = connect(UInt16(base.port!))
        send(fd, Data("POST \(prefix)upload?name=partial.txt HTTP/1.1\r\nHost: 127.0.0.1:\(base.port!)\r\nContent-Length: 2000\r\n\r\npartial".utf8))
        pump(0.1)
        close(fd)
        pump(0.15)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        require(files.sorted() == ["hello (2).txt", "hello.txt"], "disconnected upload must remove temporary file")
        require(receiver.received.count == 2, "published received list")
        receiver.stop()
        pump(0.1)
        require(!receiver.isRunning && receiver.url == nil, "stop state")
        print("PASS: page, upload bytes, collision preservation, quarantine, path/token/Origin/Host rejection, malformed headers, disconnect cleanup, stop state")
    }
}
