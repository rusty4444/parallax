// Compiles together with ../ParallaxApple.swift against the real FlutterMacOS
// framework. No engine, Dart mocks, or access to NSPasteboard.general required.
import Cocoa
import FlutterMacOS
import ImageIO
import UniformTypeIdentifiers

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private final class TestMessenger: NSObject, FlutterBinaryMessenger {
    private var handlers: [String: FlutterBinaryMessageHandler] = [:]
    private var connections: [Int64: String] = [:]
    private var nextConnection: Int64 = 0

    func send(onChannel channel: String, message: Data?) {}
    func send(onChannel channel: String, message: Data?, binaryReply: FlutterBinaryReply?) {
        binaryReply?(nil)
    }
    func setMessageHandlerOnChannel(
        _ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?
    ) -> FlutterBinaryMessengerConnection {
        handlers[channel] = handler
        nextConnection += 1
        connections[nextConnection] = channel
        return nextConnection
    }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
        if let channel = connections.removeValue(forKey: connection) {
            handlers.removeValue(forKey: channel)
        }
    }

    func beginInvocation(_ method: String = "readImage", reply: @escaping FlutterBinaryReply) throws {
        guard let handler = handlers["parallax/clipboard"] else {
            throw TestFailure(description: "parallax/clipboard is not registered")
        }
        let call = FlutterMethodCall(methodName: method, arguments: nil)
        handler(FlutterStandardMethodCodec.sharedInstance().encode(call), reply)
    }

    /// Round-trip real StandardMethodCodec bytes through the registered handler.
    /// A nil binary reply is NotImplemented; a success(null) envelope is not.
    func invoke(_ method: String = "readImage", arguments: Any? = nil) throws -> Data? {
        guard let handler = handlers["parallax/clipboard"] else {
            throw TestFailure(description: "parallax/clipboard is not registered")
        }
        let codec = FlutterStandardMethodCodec.sharedInstance()
        var replies = 0
        var envelope: Data?
        var repliedOnMain = false
        handler(codec.encode(FlutterMethodCall(methodName: method, arguments: arguments))) { reply in
            replies += 1
            envelope = reply
            repliedOnMain = Thread.isMainThread
        }
        let deadline = Date().addingTimeInterval(30)
        while replies == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        try require(replies == 1, "expected one bounded reply, received \(replies)")
        try require(repliedOnMain, "channel reply was not on the main thread")
        return envelope
    }

    func readImage() throws -> Any? {
        guard let envelope = try invoke() else {
            throw TestFailure(description: "readImage returned NotImplemented")
        }
        return FlutterStandardMethodCodec.sharedInstance().decodeEnvelope(envelope)
    }
}

private func raster(width: Int = 3, height: Int = 2, noise: Bool = false) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    var random: UInt32 = 0x12345678
    for pixel in 0..<(width * height) {
        for component in 0..<3 {
            random ^= random << 13
            random ^= random >> 17
            random ^= random << 5
            bytes[pixel * 4 + component] = noise ? UInt8(truncatingIfNeeded: random) : [255, 0, 0][component]
        }
        bytes[pixel * 4 + 3] = 255
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw TestFailure(description: "could not generate synthetic raster") }
    return image
}

private func encode(_ image: CGImage, as type: UTType = .png, frames: Int = 1) throws -> Data {
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, frames, nil)
    else { throw TestFailure(description: "could not create \(type.identifier) encoder") }
    for _ in 0..<frames {
        CGImageDestinationAddImage(destination, image, nil)
    }
    try require(CGImageDestinationFinalize(destination), "fixture encoder failed")
    return bytes as Data
}

private func expectPNG(_ value: Any?, width: Int = 3, height: Int = 2) throws {
    guard let typed = value as? FlutterStandardTypedData else {
        throw TestFailure(description: "expected bare FlutterStandardTypedData / Dart Uint8List, got \(String(describing: value))")
    }
    try require(typed.type == .uInt8, "expected UInt8 typed data")
    try require(typed.data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "reply is not PNG")
    try require(typed.data.count <= ParallaxClipboardImage.maxEncodedBytes, "output exceeded byte cap")
    guard let source = CGImageSourceCreateWithData(typed.data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw TestFailure(description: "reply PNG cannot be decoded") }
    try require(CGImageSourceGetType(source) as String? == UTType.png.identifier, "MIME must be image/png")
    try require(image.width == width && image.height == height, "image dimensions changed")
    // Read canonical sRGB pixels directly. NSBitmapImageRep.colorAt returns a
    // calibrated NSColor whose subsequent sRGB conversion changes the fixture.
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(
            data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let sample = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        else { throw TestFailure(description: "cannot read output pixel") }
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    try require(pixel[0] > 230 && pixel[1] < 26 && pixel[2] < 26,
                "synthetic red pixel was not preserved: \(pixel)")
}

@main
private enum ClipboardImageTests {
    static func main() {
        do { try run() }
        catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        try require(Thread.isMainThread, "test harness must start on the main thread")
        let board = NSPasteboard(name: NSPasteboard.Name("net.samrussell.parallax.clipboard-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let messenger = TestMessenger()
        var boardReads = 0
        weak var weakHandler: ParallaxClipboardImage?
        let channel: FlutterMethodChannel = {
            let handler = ParallaxClipboardImage(pasteboard: {
                boardReads += 1
                return board
            })
            weakHandler = handler
            return handler.register(messenger: messenger)
        }()
        defer { channel.setMethodCallHandler(nil) }
        let image = try raster()
        let png = try encode(image)
        var passed = 0

        func test(_ name: String, _ body: () throws -> Void) throws {
            try autoreleasepool { try body() }
            passed += 1
            print("PASS \(name)")
            fflush(stdout)
        }
        func replace(_ data: Data, type: NSPasteboard.PasteboardType) throws {
            board.clearContents()
            try require(board.setData(data, forType: type), "named pasteboard write failed")
        }
        func expectNil() throws {
            let result = try messenger.readImage()
            try require(result == nil || result is NSNull, "expected success(null), got \(String(describing: result))")
        }

        try test("registration retains handler; unknown method does not access pasteboard") {
            try require(weakHandler != nil, "registered handler was released")
            try require(boardReads == 0, "registration accessed pasteboard")
            let unknownReply = try messenger.invoke("unknown", arguments: ["path": "https://example.invalid/no.png"])
            try require(unknownReply == nil, "unknown method must return FlutterMethodNotImplemented")
            try require(boardReads == 0, "unknown method accessed pasteboard")
        }
        try test("empty named pasteboard returns success(null)") {
            board.clearContents()
            try expectNil()
        }
        try test("plain text returns null and remains unchanged") {
            board.clearContents()
            board.setString("keep this text", forType: .string)
            let changeCount = board.changeCount
            try expectNil()
            try require(board.string(forType: .string) == "keep this text", "text changed")
            try require(board.changeCount == changeCount, "paste mutated clipboard")
        }
        try test("PNG crosses real Flutter codec as Uint8List and stays on pasteboard") {
            try replace(png, type: .png)
            let changeCount = board.changeCount
            try expectPNG(messenger.readImage())
            try require(board.data(forType: .png) == png, "PNG clipboard data changed")
            try require(board.changeCount == changeCount, "paste mutated clipboard")
        }
        try test("single-flight snapshot survives clipboard change and does not queue repeats") {
            try replace(png, type: .png)
            let readsBefore = boardReads
            var firstEnvelope: Data?
            var firstReplies = 0
            try messenger.beginInvocation { envelope in
                firstReplies += 1
                firstEnvelope = envelope
            }
            board.clearContents()
            board.setString("new contents", forType: .string)
            try expectNil() // Busy: no second snapshot or background decode.
            try require(boardReads == readsBefore + 1, "repeat read another clipboard snapshot")
            let deadline = Date().addingTimeInterval(30)
            while firstReplies == 0 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            try require(firstReplies == 1, "initial snapshot did not complete exactly once")
            guard let firstEnvelope = firstEnvelope else {
                throw TestFailure(description: "initial snapshot returned NotImplemented")
            }
            try expectPNG(FlutterStandardMethodCodec.sharedInstance().decodeEnvelope(firstEnvelope))
            try require(board.string(forType: .string) == "new contents", "late decode changed pasteboard")
            try replace(png, type: .png)
            try expectPNG(messenger.readImage()) // Single-flight slot was released.
        }
        try test("TIFF is normalized to PNG") {
            try replace(encode(image, as: .tiff), type: .tiff)
            try expectPNG(messenger.readImage())
        }
        try test("JPEG is normalized to PNG") {
            try replace(encode(image, as: .jpeg), type: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            try expectPNG(messenger.readImage())
        }
        for type in [UTType.bmp, .heic] {
            try test("\(type.identifier) is normalized to PNG") {
                try replace(encode(image, as: type), type: NSPasteboard.PasteboardType(type.identifier))
                try expectPNG(messenger.readImage())
            }
        }
        try test("unadvertised inline format disguised as PNG is rejected") {
            let jpeg2000 = UTType(filenameExtension: "jp2")!
            let data = try encode(image, as: jpeg2000)
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            try require(CGImageSourceGetType(source) as String? == jpeg2000.identifier,
                        "fixture did not encode JPEG 2000")
            try replace(data, type: .png)
            try expectNil()
        }
        try test("high-bit-depth input is rejected before decode") {
            let samples = [UInt16](repeating: .max, count: 6)
            let bytes = samples.withUnsafeBytes { Data($0) }
            let provider = CGDataProvider(data: bytes as CFData)!
            let highDepth = CGImage(
                width: 3, height: 2, bitsPerComponent: 16, bitsPerPixel: 16,
                bytesPerRow: 6, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .byteOrder16Little,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let data = try encode(highDepth)
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
            try require(properties[kCGImagePropertyDepth] as? Int == 16, "fixture lost its 16-bit depth")
            try replace(data, type: .png)
            try expectNil()
        }
        try test("animated GIF returns one PNG frame") {
            try replace(encode(image, as: .gif, frames: 2), type: NSPasteboard.PasteboardType(UTType.gif.identifier))
            let result = try messenger.readImage()
            try expectPNG(result)
            let bytes = (result as! FlutterStandardTypedData).data
            let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
            try require(CGImageSourceGetCount(source) == 1, "returned animation")
        }
        try test("PNG preferred to TIFF; accompanying text remains unchanged") {
            try replace(png, type: .png)
            board.setData(try encode(raster(width: 1, height: 1), as: .tiff), forType: .tiff)
            board.setString("caption", forType: .string)
            try expectPNG(messenger.readImage())
            try require(board.string(forType: .string) == "caption", "accompanying text changed")
        }
        try test("malformed and empty inline images return null for text fallback") {
            for invalid in [Data(), Data("not an image".utf8), Data(png.prefix(24))] {
                try replace(invalid, type: .png)
                board.setString("fallback text", forType: .string)
                try expectNil()
                try require(board.string(forType: .string) == "fallback text", "fallback text changed")
            }
        }
        try test("file URL to valid owned PNG is not opened") {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!, isDirectory: true)
            let file = root.appendingPathComponent("clipboard-url-fixture-\(UUID().uuidString).png")
            try png.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            board.clearContents()
            board.setString(file.absoluteString, forType: .fileURL)
            try expectNil()
        }
        try test("remote URLs, file promises and path text are not image sources") {
            for type in [NSPasteboard.PasteboardType.URL, .fileURL,
                         NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"), .string] {
                board.clearContents()
                board.setString("https://example.invalid/image.png", forType: type)
                try expectNil()
            }
        }
        try test("encoded input exactly at byte cap is accepted") {
            var padded = png
            padded.append(Data(repeating: 0, count: ParallaxClipboardImage.maxEncodedBytes - padded.count))
            try replace(padded, type: .png)
            try expectPNG(messenger.readImage())
        }
        try test("encoded input one byte above cap is rejected") {
            var padded = png
            padded.append(Data(repeating: 0, count: ParallaxClipboardImage.maxEncodedBytes + 1 - padded.count))
            try replace(padded, type: .png)
            try expectNil()
        }
        try test("maximum edge is accepted") {
            try replace(encode(raster(width: ParallaxClipboardImage.maxDimension, height: 1)), type: .png)
            try expectPNG(messenger.readImage(), width: ParallaxClipboardImage.maxDimension, height: 1)
        }
        try test("one pixel over either edge limit is rejected before decode") {
            for (width, height) in [(ParallaxClipboardImage.maxDimension + 1, 1), (1, ParallaxClipboardImage.maxDimension + 1)] {
                try replace(encode(raster(width: width, height: height)), type: .png)
                try expectNil()
            }
        }
        try test("pixel budget exact boundary is accepted") {
            try replace(encode(raster(width: 4096, height: 4096)), type: .png)
            try expectPNG(messenger.readImage(), width: 4096, height: 4096)
        }
        try test("pixel budget excess with individually allowed edges is rejected") {
            try replace(encode(raster(width: 4096, height: 4097)), type: .png)
            try expectNil()
        }
        try test("PNG output above byte cap is rejected independently of input cap") {
            let jpeg = try encode(raster(width: 3000, height: 3000, noise: true), as: .jpeg)
            try require(jpeg.count < ParallaxClipboardImage.maxEncodedBytes, "fixture exceeds input budget")
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let uncappedPNG = try encode(decoded)
            try require(uncappedPNG.count > ParallaxClipboardImage.maxEncodedBytes, "fixture does not isolate output budget")
            try replace(jpeg, type: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            try expectNil()
        }
        print("\(passed) native clipboard tests passed; isolated named pasteboard only; general clipboard never accessed.")
    }
}
