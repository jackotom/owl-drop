# Verification scope

The macOS application has been compiled on Apple Silicon with Swift 6.3.3 in Swift 5 language mode. Local code-signature integrity and application launch were checked.

The focused receiver check covers successful HTTP upload and exact saved bytes, collision preservation, quarantine metadata, rejected path traversal, invalid session links, invalid Host/Origin headers, duplicate Content-Length, rejected chunked encoding, aborted-upload cleanup and stop state.

```sh
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path build/module-cache Sources/LANReceiver.swift Tests/LANReceiverChecks.swift -o build/lan-receiver-checks
build/lan-receiver-checks
```

The check listens only on loopback and writes temporary fixture files, which it removes on exit. Run where local TCP listeners are permitted.

GUI checks covered file selection, opening the system AirDrop sheet, discovery of a nearby device, and returning from cancellation. The sheet's completion callback is not treated as proof of delivery to another device.

Browser checks covered a generic file upload and two-image upload from the dedicated photo input (`image/*`, multiple selection). Saved files matched the originals byte-for-byte. The page is served locally by the Mac app; the public GitHub Pages website does not handle uploaded files.

Not yet verified: physical Android gallery/camera behavior across browsers, physical iPhone AirDrop delivery, the oldest supported macOS version, full 2 GiB uploads, and concurrent transfers from multiple phones. No throughput benchmark or notarization claim is made.
