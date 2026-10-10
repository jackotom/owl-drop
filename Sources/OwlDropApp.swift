import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

final class TransferModel: NSObject, ObservableObject, NSSharingServiceDelegate {
    @Published var files: [URL] = []
    @Published var message = "选择文件后，在系统窗口中选择你的 iPhone。"
    @Published var sharing = false
    private var service: NSSharingService?

    func add(_ urls: [URL]) {
        guard !sharing else { return }
        var rejected = 0
        for url in urls {
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
                rejected += 1
                continue
            }
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            if !files.contains(file) { files.append(file) }
        }
        message = rejected > 0 ? "有 \(rejected) 个项目无法读取，请重新选择。" : "已选择 \(files.count) 个项目，准备发送。"
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "添加"
        panel.begin { [weak self] response in
            if response == .OK { self?.add(panel.urls) }
        }
    }

    func send() {
        guard !files.isEmpty, !sharing else { return }
        guard files.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else {
            message = "文件已移动或无法读取，请移除后重新添加。"
            return
        }
        guard let next = NSSharingService(named: .sendViaAirDrop), next.canPerform(withItems: files) else {
            message = "系统暂时无法使用隔空投送。请检查 Wi-Fi、蓝牙和接收设备。"
            return
        }
        service = next
        next.delegate = self
        sharing = true
        message = "在系统隔空投送窗口中选择设备；可随时取消。"
        next.perform(withItems: files)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        sharing = false
        service = nil
        // AirDrop also reports didShareItems after cancelling on macOS 26.
        message = "隔空投送窗口已关闭，是否收到请以接收设备为准。"
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        sharing = false
        service = nil
        let failure = error as NSError
        message = failure.code == NSUserCancelledError ? "已取消发送，文件仍保留在列表中。" : "发送未完成：\(error.localizedDescription)"
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        NSApp.keyWindow
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let receiver = LANReceiver()
    static let transfer = TransferModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Self.receiver.stop() }
    func application(_ application: NSApplication, open urls: [URL]) { Self.transfer.add(urls) }
}

@main
struct OwlDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Owl Drop") {
            MainView(transfer: AppDelegate.transfer, receiver: AppDelegate.receiver)
                .frame(minWidth: 760, minHeight: 620)
        }
        .defaultSize(width: 830, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加文件…") { AppDelegate.transfer.choose() }.keyboardShortcut("o")
            }
        }
    }
}

struct MainView: View {
    @ObservedObject var transfer: TransferModel
    @ObservedObject var receiver: LANReceiver
    @State private var tab = 0
    @State private var targeted = false
    @State private var notice: String?
    private let accent = Color(red: 0.29, green: 0.30, blue: 0.78)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 13) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Owl Drop").font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("文件，就在设备之间。").foregroundStyle(.secondary)
                }
                Spacer()
                if receiver.isRunning {
                    Label("局域网接收中", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Picker("传输方向", selection: $tab) {
                Text("发送到 iPhone").tag(0)
                Text("接收文件 · iPhone / 安卓").tag(1)
            }.pickerStyle(.segmented)
            if tab == 0 { sender } else { ScrollView { receiving }.scrollIndicators(.hidden) }
            Spacer(minLength: 0)
            HStack {
                Image(systemName: "network")
                Text("iPhone 用隔空投送 · 安卓用同一局域网")
                Spacer()
                Text("v0.1.0").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).padding(.top, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .alert("Owl Drop", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private var sender: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "paperplane.circle.fill").font(.system(size: 54)).foregroundStyle(accent)
                Text("拖入文件，送到 iPhone").font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("照片、视频、文档，也可以一次选择多个文件。").foregroundStyle(.secondary)
                Button("选择文件…") { transfer.choose() }.controlSize(.large).disabled(transfer.sharing)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
            .background(accent.opacity(targeted ? 0.12 : 0.045), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(targeted ? 0.8 : 0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .dropDestination(for: URL.self) { urls, _ in
                guard !transfer.sharing else { return false }
                transfer.add(urls)
                return !urls.isEmpty
            } isTargeted: { targeted = $0 }
            if !transfer.files.isEmpty {
                HStack {
                    Text("待发送 · \(transfer.files.count) 项").font(.headline)
                    Spacer()
                    Button("清空") { transfer.files.removeAll(); transfer.message = "已清空待发送列表。" }
                        .buttonStyle(.borderless).disabled(transfer.sharing)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(transfer.files, id: \.self) { file in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 28, height: 28)
                                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { transfer.files.removeAll { $0 == file } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).disabled(transfer.sharing).accessibilityLabel("移除 \(file.lastPathComponent)")
                            }.padding(9).background(.background, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }.frame(maxHeight: 130)
            }
            HStack(alignment: .center, spacing: 20) {
                Text(transfer.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { transfer.send() } label: { Label("隔空投送…", systemImage: "airplayaudio") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(transfer.files.isEmpty || transfer.sharing)
            }
            Text("找不到 iPhone？打开手机的 Wi-Fi 和蓝牙，并在隔空投送设置中允许接收。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var receiving: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("从 iPhone 接收").font(.headline)
                    Text("在手机分享菜单选择「隔空投送」，再选这台 Mac。\n接收确认和文件保存由系统处理。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("打开隔空投送") { openAirDrop() }.controlSize(.large)
            }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("安卓传到 Mac").font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("连同一 Wi-Fi · 扫码 · 浏览器选择文件上传").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(receiver.isRunning ? "关闭接收" : "开启局域网接收") {
                        if receiver.isRunning { receiver.stop() } else { receiver.start() }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                if let url = receiver.url, receiver.isRunning {
                    HStack(alignment: .center, spacing: 24) {
                        if let qr = qrImage(url.absoluteString) {
                            Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 154, height: 154)
                                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("用手机相机扫描此二维码打开上传页面")
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("用手机相机扫码").font(.headline)
                            Text("也可以把地址复制到手机浏览器。\niPhone、平板和电脑浏览器同样可用。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                notice = "上传地址已复制。关闭接收后，这个地址会失效。"
                            } label: { Label("复制上传地址", systemImage: "doc.on.doc") }
                            Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(receiver.status).font(.callout).foregroundStyle(receiver.isRunning ? .primary : .secondary)
                Text("仅在可信局域网开启。持有二维码的人可上传；传输使用局域网 HTTP，不经云端。单文件最多 2 GB。关闭窗口会退出并停止接收。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Label("保存到 下载 / Owl Drop", systemImage: "folder").font(.caption)
                    Spacer()
                    Button("打开接收文件夹") { openFolder(receiver.directory) }
                }
            }.padding(20).background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            if !receiver.received.isEmpty {
                HStack {
                    Text("最近收到 \(receiver.received.count) 个文件").font(.headline)
                    Spacer()
                    if let latest = receiver.received.first {
                        Button("显示最新文件") { NSWorkspace.shared.activateFileViewerSelecting([latest.url]) }
                    }
                }
            }
        }
    }

    private func openAirDrop() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { DispatchQueue.main.async { notice = "无法打开隔空投送：\(error.localizedDescription)" } }
        }
    }

    private func openFolder(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(url) { notice = "无法打开接收文件夹。" }
        } catch { notice = "无法打开接收文件夹：\(error.localizedDescription)" }
    }

    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
