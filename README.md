# Owl Drop

本机原生 macOS 文件传输应用，支持 Apple Silicon / macOS 13 及以上。无需安装运行时或第三方依赖。

[项目网页](https://jackotom.github.io/owl-drop/) · [下载 v0.1.0 预览版](https://github.com/jackotom/owl-drop/releases/tag/v0.1.0)

下载 `Owl-Drop-0.1.0-macOS-arm64.zip`，解压后将 `Owl Drop.app` 拖入「应用程序」。安装包仅支持 Apple Silicon；当前只有 ad-hoc 本地签名，尚未进行 Developer ID 签名或 Apple 公证，其他 Mac 可能阻止直接打开。可审查源码后自行构建。

## 使用

### Mac 发送到 iPhone

拖入文件，或点击「选择文件」，再点「隔空投送…」。在系统窗口选择 iPhone，按手机提示接收。

### iPhone 发送到 Mac

切换「接收文件」，点击「打开隔空投送」。在 iPhone 分享菜单选择隔空投送和本机。接收确认、联系人限制、文件保存由 macOS 处理，应用不绕过这些设置。照片等内容也可走下面的浏览器上传。

### 安卓发送到 Mac

1. 手机和 Mac 连接同一个可信局域网。
2. 在应用的「接收文件」中点击「开启局域网接收」。
3. 手机相机扫码，用浏览器打开上传页面；点「选择图片」从相册多选照片，或点「选择文件」选视频和文档，再点击「开始上传」。不需要安卓 App。
4. 上传成功的文件在 `~/Downloads/Owl Drop`，重名文件不会覆盖已有文件。
5. 传完点击「关闭接收」。关闭应用窗口会退出并停止接收；旧二维码失效。

无需安卓客户端、账号或云服务。浏览器路径仅负责手机向 Mac 上传，未实现 Mac 向安卓发送。单文件上限 2 GB。最近接收记录只保留当前进程内的最近 20 条，不扫描用户下载目录。

局域网上传使用 HTTP，内容没有应用层加密；仅应在可信网络开启。临时随机地址是本次会话的上传凭证，持有人在开启期间可以上传。不要公开二维码或地址。接收服务不提供文件下载、目录列举或删除功能，不修改防火墙。

若手机打不开：检查两端网络、访客网络的设备隔离，以及 macOS 是否允许 Owl Drop 的局域网/传入连接。换网络后关闭再开启接收。

## 构建

安装支持 Swift 5.7 或更高版本的 Xcode / 命令行工具后，在本目录运行 `bash build.sh`，产物为 `build/Owl Drop.app`。不需要 Homebrew、RTK 或第三方运行时。

构建脚本使用 ad-hoc 签名。Release 提供可下载的预览包，不代表已完成 Apple 公证或 App Store 审核。

## 与 omdrop-owl 的关系

研究参考：https://github.com/t4t5/omdrop-owl

上游是 Linux AWDL 无线后端，需要 monitor interface、Linux 网卡驱动和 root helper。当前 macOS 实现没有复制或移植其代码，没有加载 Linux 驱动；根据用户选择使用 macOS 的公开隔空投送接口，并独立实现局域网浏览器接收。

Apple API：https://developer.apple.com/documentation/appkit/nssharingservice/name/sendviaairdrop

## 验证

公开验证范围与检查命令见 [docs/testing.md](docs/testing.md)。本机编译、浏览器传输和系统分享窗口验证，与 iPhone/安卓实体设备实传分别记录。

## 授权

当前仓库公开可见，尚未指定开源许可证。公开可见不代表授予 MIT 或其他开源授权。
