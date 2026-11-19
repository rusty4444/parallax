// Parallax native Apple layer (iOS + macOS).
//
// One shared implementation for the MethodChannels the Dart app already
// speaks on Android (see android/app/src/main/kotlin/net/samrussell/parallax):
//
//   parallax/video            probe / compress / sampleFrames / delete
//   parallax/permissions      check / request (camera + microphone)
//   parallax/secure_window    setSecure (app-switcher cover / screen capture)
//   parallax/platform_intents takePending / discard, native -> Dart "pending"
//
// Registered from each Runner's AppDelegate via ParallaxAppleChannels.
// Channel results are always delivered on the main thread; video and file
// work runs on utility queues and never blocks the main thread.

import Foundation
import AVFoundation
import AudioToolbox

#if os(iOS)
import UIKit
import Flutter
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

// MARK: - Small shared helpers

/// Thread-safe box used to bridge async AVFoundation loads onto the video
/// utility queue without touching the main thread.
private final class ParallaxLoaded<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ newValue: T?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func parallaxClamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
    return min(max(value, lower), upper)
}

private func parallaxCachesDirectory() -> URL {
    let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
    return urls.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
}

/// A display/file name without path separators or control characters
/// (mirrors SharedIntentStore.sanitise on Android).
private func parallaxSanitiseName(_ raw: String?) -> String {
    var name = raw ?? ""
    name = name.split(separator: "/").last.map(String.init) ?? name
    name = name.split(separator: "\\").last.map(String.init) ?? name
    name = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f })
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    while name.hasPrefix(".") { name.removeFirst() }
    if name.isEmpty { return "shared-file" }
    return name.count > 120 ? String(name.suffix(120)) : name
}

/// `type/subtype`, lower-cased, or application/octet-stream. Dart validates
/// again; this only keeps obviously broken values out of the payload.
private func parallaxSanitiseMime(_ raw: String?) -> String {
    guard let raw = raw else { return "application/octet-stream" }
    let mime = raw.split(separator: ";").first.map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let parts = mime.split(separator: "/")
    if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
        !mime.contains(" "), mime.count <= 127 {
        return mime
    }
    return "application/octet-stream"
}

/// JPEG-encodes a CGImage on either platform.
private func parallaxJpegData(_ image: CGImage, quality: Double) -> Data? {
    #if os(iOS)
    return UIImage(cgImage: image).jpegData(compressionQuality: quality)
    #elseif os(macOS)
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    #endif
}

// MARK: - Video tools (parallax/video)

/// AVFoundation port of VideoTools.kt: probe = display size, duration and a
/// JPEG poster frame; compress = H.264/AAC MP4 re-encode with the short side
/// capped; sampleFrames = evenly spaced JPEGs from the opening seconds.
final class ParallaxVideoTools {
    private let ioQueue = DispatchQueue(label: "net.samrussell.parallax.video", qos: .utility)
    private let workDirectory = parallaxCachesDirectory()
        .appendingPathComponent("video_tools", isDirectory: true)
    /// Outputs from an earlier process are never still in use; clear once.
    private static var cleanedWorkDirectory = false
    private static let thumbnailLongSide: CGFloat = 800

    init() {
        if !ParallaxVideoTools.cleanedWorkDirectory {
            ParallaxVideoTools.cleanedWorkDirectory = true
            let dir = workDirectory
            ioQueue.async {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    // MARK: Channel entry points (called on the main thread)

    func probe(path: String, result: @escaping FlutterResult) {
        ioQueue.async { [weak self] in
            let info = self?.probeSync(path: path)
            DispatchQueue.main.async { result(info) }
        }
    }

    func sampleFrames(
        path: String,
        maxEdge: Int,
        maxFrames: Int,
        maxDurationMs: Int,
        result: @escaping FlutterResult
    ) {
        ioQueue.async { [weak self] in
            let sample = self?.sampleFramesSync(
                path: path, maxEdge: maxEdge, maxFrames: maxFrames, maxDurationMs: maxDurationMs)
            DispatchQueue.main.async { result(sample) }
        }
    }

    func compress(path: String, shortSide: Int, bitrate: Int, result: @escaping FlutterResult) {
        ioQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "COMPRESS_FAILED", message: "Tools released", details: nil))
                }
                return
            }
            do {
                let output = try self.compressSync(path: path, shortSide: shortSide, bitrate: bitrate)
                DispatchQueue.main.async { result(output) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "COMPRESS_FAILED",
                        message: error.localizedDescription,
                        details: nil))
                }
            }
        }
    }

    func delete(path: String, result: @escaping FlutterResult) {
        ioQueue.async { [weak self] in
            if let self = self {
                self.deleteOwned(path: path)
            }
            DispatchQueue.main.async { result(nil) }
        }
    }

    // MARK: Async AVFoundation loading (bridged onto the utility queue)

    private func loadAsset<T>(_ asset: AVAsset, _ property: AVAsyncProperty<AVAsset, T>) -> T? {
        let box = ParallaxLoaded<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            box.set(try? await asset.load(property))
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()
    }

    private func loadTrack<T>(_ track: AVAssetTrack, _ property: AVAsyncProperty<AVAssetTrack, T>) -> T? {
        let box = ParallaxLoaded<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            box.set(try? await track.load(property))
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()
    }

    /// Display-oriented size: applies preferredTransform (swaps for 90/270).
    private func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> (width: Int, height: Int) {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return (max(1, Int(abs(rect.width).rounded())), max(1, Int(abs(rect.height).rounded())))
    }

    private func videoTrack(of asset: AVAsset) -> AVAssetTrack? {
        guard let tracks = loadAsset(asset, .tracks) else { return nil }
        return tracks.first { $0.mediaType == .video }
    }

    // MARK: probe

    private func probeSync(path: String) -> [String: Any]? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = videoTrack(of: asset),
            let naturalSize = loadTrack(track, .naturalSize),
            let transform = loadTrack(track, .preferredTransform),
            naturalSize.width > 0, naturalSize.height > 0
        else { return nil }
        let size = displaySize(naturalSize: naturalSize, transform: transform)
        var durationMs: Int? = nil
        if let duration = loadAsset(asset, .duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 {
                durationMs = Int((seconds * 1000).rounded())
            }
        }

        var thumbnail: Data? = nil
        var thumbWidth: Int? = nil
        var thumbHeight: Int? = nil
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: ParallaxVideoTools.thumbnailLongSide,
            height: ParallaxVideoTools.thumbnailLongSide)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let frame = try? generator.copyCGImage(at: CMTime.zero, actualTime: nil),
            let data = parallaxJpegData(frame, quality: 0.8) {
            thumbnail = data
            thumbWidth = frame.width
            thumbHeight = frame.height
        }

        var info: [String: Any] = [
            "width": size.width,
            "height": size.height,
            "durationMs": durationMs as Any,
        ]
        if let thumbnail = thumbnail, let thumbWidth = thumbWidth, let thumbHeight = thumbHeight {
            info["thumbnail"] = FlutterStandardTypedData(bytes: thumbnail)
            info["thumbnailWidth"] = thumbWidth
            info["thumbnailHeight"] = thumbHeight
        }
        return info
    }

    // MARK: sampleFrames

    private func sampleFramesSync(
        path: String,
        maxEdge: Int,
        maxFrames: Int,
        maxDurationMs: Int
    ) -> [String: Any]? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard videoTrack(of: asset) != nil else { return nil }
        var durationMs = 0
        if let duration = loadAsset(asset, .duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                durationMs = Int((seconds * 1000).rounded())
            }
        }

        // Same cadence as Android: ~4 frames per second of sampled window.
        let clipMs = min(durationMs, maxDurationMs)
        let count: Int
        if clipMs <= 0 {
            count = 1
        } else if clipMs < 400 {
            count = 2
        } else {
            count = parallaxClamp(clipMs / 250, 4, maxFrames)
        }
        let stepMs = clipMs > 0 ? Double(clipMs) / Double(count) : 200.0
        let delayMs = parallaxClamp(Int(stepMs.rounded()), 80, 500)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [Data] = []
        let started = Date()
        for i in 0..<count {
            // Stop early if decoding is slow; a preview only needs a few frames.
            if frames.count >= 2 && Date().timeIntervalSince(started) > 3.5 { break }
            let atMs: Int
            if durationMs > 0 {
                atMs = parallaxClamp(Int(((Double(i) + 0.25) * stepMs).rounded()), 0, max(0, durationMs - 1))
            } else {
                atMs = 0
            }
            let time = CMTimeMake(value: Int64(atMs), timescale: 1000)
            if let frame = try? generator.copyCGImage(at: time, actualTime: nil),
                let data = parallaxJpegData(frame, quality: 0.85) {
                frames.append(data)
            }
        }
        if frames.isEmpty { return nil }
        // A static clip produces identical frames; send one.
        if frames.count > 1 && frames.allSatisfy({ $0 == frames[0] }) {
            frames = [frames[0]]
        }
        return [
            "frames": frames.map { FlutterStandardTypedData(bytes: $0) },
            "delayMs": delayMs,
        ]
    }

    // MARK: compress

    private struct CompressionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func compressSync(path: String, shortSide: Int, bitrate: Int) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let output = workDirectory.appendingPathComponent("\(UUID().uuidString).mp4")

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = videoTrack(of: asset),
            let naturalSize = loadTrack(track, .naturalSize),
            let transform = loadTrack(track, .preferredTransform),
            naturalSize.width > 0, naturalSize.height > 0
        else {
            throw CompressionError(message: "Can't read the video track")
        }
        guard let duration = loadAsset(asset, .duration),
            CMTimeGetSeconds(duration).isFinite, CMTimeGetSeconds(duration) > 0
        else {
            throw CompressionError(message: "Can't read the video duration")
        }
        let tracks = loadAsset(asset, .tracks) ?? []
        let audioTrack = tracks.first { $0.mediaType == .audio }

        // Scale so the short side is at most shortSide (never upscale). The
        // short side is orientation-independent, so compute it on the raw
        // size; the writer keeps the source orientation via transform below.
        let cappedSide = max(2, shortSide)
        let scale = min(1.0, CGFloat(cappedSide) / min(naturalSize.width, naturalSize.height))
        var outWidth = Int((naturalSize.width * scale).rounded())
        var outHeight = Int((naturalSize.height * scale).rounded())
        outWidth = max(2, outWidth - outWidth % 2)
        outHeight = max(2, outHeight - outHeight % 2)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput? = nil
        if let audioTrack = audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1, bitrate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // Keep the source rotation so the output plays display-oriented,
        // exactly like the Media3 Transformer output on Android.
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw CompressionError(message: "Can't add the video encoder input")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput? = nil
        if audioOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioOutput = nil
            }
        }

        guard writer.startWriting() else {
            throw CompressionError(message: writer.error?.localizedDescription ?? "Can't start writing")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw CompressionError(message: reader.error?.localizedDescription ?? "Can't start reading")
        }

        // Pump both inputs on a dedicated serial queue; this utility queue
        // waits for them below (never the main thread).
        let pumpQueue = DispatchQueue(label: "net.samrussell.parallax.video.pump")
        let group = DispatchGroup()

        func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderTrackOutput) {
            group.enter()
            input.requestMediaDataWhenReady(on: pumpQueue) {
                while input.isReadyForMoreMediaData {
                    if reader.status != .reading || writer.status != .writing {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if let sample = output.copyNextSampleBuffer() {
                        if !input.append(sample) {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    } else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        pump(videoInput, videoOutput)
        if let audioInput = audioInput, let audioOutput = audioOutput {
            pump(audioInput, audioOutput)
        }
        // Bounded wait: a failed reader/writer normally drains the pumps via
        // the status checks above, but never let a stuck encode hang Dart.
        if group.wait(timeout: .now() + 600) == .timedOut {
            reader.cancelReading()
            writer.cancelWriting()
            try? fileManager.removeItem(at: output)
            throw CompressionError(message: "Compression timed out")
        }

        if reader.status == .failed {
            writer.cancelWriting()
            try? fileManager.removeItem(at: output)
            throw CompressionError(message: reader.error?.localizedDescription ?? "Reading failed")
        }
        if writer.status == .failed {
            reader.cancelReading()
            try? fileManager.removeItem(at: output)
            throw CompressionError(message: writer.error?.localizedDescription ?? "Writing failed")
        }
        // finishWriting() is async on modern SDKs; bridge it onto this
        // utility queue the same way as the property loads above.
        let finishSemaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            await writer.finishWriting()
            finishSemaphore.signal()
        }
        finishSemaphore.wait()
        reader.cancelReading()
        if writer.status != .completed {
            try? fileManager.removeItem(at: output)
            throw CompressionError(message: writer.error?.localizedDescription ?? "Writing did not complete")
        }
        return output.path
    }

    // MARK: delete

    /// Deletes only files inside the work directory.
    private func deleteOwned(path: String) {
        let root = workDirectory.resolvingSymlinksInPath().standardizedFileURL
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - Permissions (parallax/permissions)

/// Minimal runtime-permission bridge matching MainActivity.kt: Android
/// permission names map to AVCaptureDevice media types; anything else is
/// reported as not granted.
final class ParallaxPermissions {
    private func mediaType(for permission: String) -> AVMediaType? {
        switch permission {
        case "android.permission.CAMERA": return .video
        case "android.permission.RECORD_AUDIO": return .audio
        default: return nil
        }
    }

    private func isGranted(_ permission: String) -> Bool {
        guard let type = mediaType(for: permission) else { return false }
        return AVCaptureDevice.authorizationStatus(for: type) == .authorized
    }

    private func grantedMap(_ permissions: [String]) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for permission in permissions {
            map[permission] = isGranted(permission)
        }
        return map
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let permissions = args["permissions"] as? [String],
            !permissions.isEmpty
        else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing permissions", details: nil))
            return
        }
        switch call.method {
        case "check":
            result(grantedMap(permissions))
        case "request":
            let missing = permissions.filter { !isGranted($0) && mediaType(for: $0) != nil }
            if missing.isEmpty {
                result(grantedMap(permissions))
                return
            }
            let group = DispatchGroup()
            for permission in missing {
                guard let type = mediaType(for: permission) else { continue }
                group.enter()
                AVCaptureDevice.requestAccess(for: type) { _ in
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                result(self?.grantedMap(permissions) ?? [:])
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - Secure window (parallax/secure_window)

#if os(iOS)
/// iOS cannot block screenshots while active (platform limit, no private
/// API). While a lease is held, an opaque overlay covers the app whenever it
/// becomes inactive so the app-switcher snapshot never shows protected
/// content; it is removed as soon as the app is active again.
final class ParallaxSecureWindow {
    private var enabled = false
    private var overlay: UIWindow?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let cover: (Notification) -> Void = { [weak self] _ in self?.showOverlay() }
        let uncover: (Notification) -> Void = { [weak self] _ in self?.hideOverlay() }
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main, using: cover))
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: cover))
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: uncover))
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setSecure(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            if UIApplication.shared.applicationState != .active {
                showOverlay()
            }
        } else {
            hideOverlay()
        }
    }

    private func showOverlay() {
        guard enabled, overlay == nil else { return }
        let window: UIWindow
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.windowLevel = .alert + 1
        // Opaque dark cover matching the app's dark theme; never transparent.
        window.backgroundColor = UIColor(red: 0.07, green: 0.05, blue: 0.06, alpha: 1.0)
        window.isUserInteractionEnabled = false
        window.isHidden = false
        overlay = window
    }

    private func hideOverlay() {
        overlay?.isHidden = true
        overlay = nil
    }
}
#elseif os(macOS)
/// While a lease is held every window is excluded from screen capture and
/// sharing (sharingType = .none); clearing restores .readOnly. Windows
/// created later are covered when they become key or the app reactivates.
final class ParallaxSecureWindow {
    private var enabled = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self, self.enabled, let window = note.object as? NSWindow else { return }
            window.sharingType = .none
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.enabled else { return }
            self.applyToAllWindows()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setSecure(_ enabled: Bool) {
        self.enabled = enabled
        applyToAllWindows()
    }

    private func applyToAllWindows() {
        let sharing: NSWindow.SharingType = enabled ? .none : .readOnly
        for window in NSApplication.shared.windows {
            window.sharingType = sharing
        }
    }
}
#endif

// MARK: - Platform intents (parallax/platform_intents)

/// Process-wide queue of share/link payloads and the share copy cache,
/// mirroring SharedIntentStore in MainActivity.kt. Dart pulls the queue on
/// start and whenever native signals "pending", so cold-start intents are
/// never lost to a missing handler.
final class ParallaxIntentStore {
    static let shared = ParallaxIntentStore()

    static let appGroup = "group.net.samrussell.parallax"
    static let maxFiles = 10
    static let maxFileBytes = 20 * 1024 * 1024
    private static let maxPending = 5
    private static let maxLinkLength = 4096
    private static let staleSeconds: TimeInterval = 6 * 60 * 60

    private let ioQueue = DispatchQueue(label: "net.samrussell.parallax.intents", qos: .utility)
    /// Main thread only.
    private var pending: [[String: Any]] = []
    private var channel: FlutterMethodChannel?
    #if os(iOS)
    private var foregroundObserver: NSObjectProtocol?
    #endif

    /// Shared copies live under <cache>/shared_intents/<id>/ — Dart deletes
    /// them after sending and validates paths against this segment.
    var sharedRoot: URL {
        parallaxCachesDirectory().appendingPathComponent("shared_intents", isDirectory: true)
    }

    func attach(_ channel: FlutterMethodChannel) {
        self.channel = channel
        ioQueue.async { [weak self] in
            self?.pruneStale()
        }
        #if os(iOS)
        // Cold-start shares written by the share extension before this
        // process existed, plus a safety net on every foreground in case the
        // extension could not open the host app directly.
        drainShareInbox()
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.drainShareInbox()
            }
        }
        #endif
    }

    func enqueue(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pending.append(payload)
            while self.pending.count > ParallaxIntentStore.maxPending {
                let dropped = self.pending.removeFirst()
                self.discardPayloadFiles(dropped)
            }
            self.channel?.invokeMethod("pending", arguments: nil)
        }
    }

    /// Main thread (channel handlers run there).
    func takePending() -> [[String: Any]] {
        let items = pending
        pending.removeAll()
        return items
    }

    private func discardPayloadFiles(_ payload: [String: Any]) {
        guard let files = payload["files"] as? [[String: Any]] else { return }
        let paths = files.compactMap { $0["path"] as? String }
        discard(paths: paths)
    }

    /// Deletes copies, but only inside the share cache directory.
    func discard(paths: [String]) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let root = self.sharedRoot.resolvingSymlinksInPath().standardizedFileURL
            for path in paths {
                let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                guard file.path.hasPrefix(root.path + "/") else { continue }
                try? FileManager.default.removeItem(at: file)
                let parent = file.deletingLastPathComponent()
                if parent.path.hasPrefix(root.path + "/"),
                    let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
                    contents.isEmpty {
                    try? FileManager.default.removeItem(at: parent)
                }
            }
        }
    }

    /// Removes share copies abandoned by an earlier process.
    private func pruneStale() {
        let now = Date()
        let root = sharedRoot
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for dir in entries {
            let values = try? dir.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate,
                now.timeIntervalSince(modified) > ParallaxIntentStore.staleSeconds {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    // MARK: Link intents

    /// Routes an incoming URL. Returns true when Parallax consumed it.
    /// The OIDC scheme (net.samrusselltech.parallax) is never consumed —
    /// flutter_web_auth_2's ASWebAuthenticationSession owns that redirect.
    @discardableResult
    static func handleIncomingURL(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        switch scheme {
        case "net.samrusselltech.parallax":
            return false
        case "net.samrussell.parallax":
            if (url.host ?? "").lowercased() == "share-inbox" {
                #if os(iOS)
                ParallaxIntentStore.shared.drainShareInbox()
                #endif
                return true
            }
            return false
        case "matrix":
            enqueueLink(url)
            return true
        case "https", "http":
            let host = (url.host ?? "").lowercased()
            if host == "matrix.to" || host == "www.matrix.to" {
                enqueueLink(url)
                return true
            }
            return false
        default:
            return false
        }
    }

    private static func enqueueLink(_ url: URL) {
        let value = url.absoluteString
        guard value.count <= maxLinkLength else { return }
        shared.enqueue(["kind": "link", "uri": value])
    }

    // MARK: iOS share extension inbox

    #if os(iOS)
    /// Drains the App Group inbox written by the Share Extension into the
    /// app's own cache (Dart deletes shared files after sending, and the
    /// extension's container copies must not be handed to Dart directly).
    func drainShareInbox() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ParallaxIntentStore.appGroup)
            else { return }
            let inbox = container.appendingPathComponent("SharedInbox", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil) else { return }
            for dir in entries {
                self.drainInboxEntry(dir)
            }
        }
    }

    private func drainInboxEntry(_ dir: URL) {
        let fileManager = FileManager.default
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            try? fileManager.removeItem(at: dir)
            return
        }
        var files: [[String: Any]] = []
        var skipped = manifest["skipped"] as? Int ?? 0
        let tooLarge = manifest["tooLarge"] as? Int ?? 0
        let destination = sharedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inboxRoot = dir.resolvingSymlinksInPath().standardizedFileURL
        for raw in (manifest["files"] as? [[String: Any]]) ?? [] {
            guard files.count < ParallaxIntentStore.maxFiles else {
                skipped += 1
                continue
            }
            guard let sourcePath = raw["path"] as? String else {
                skipped += 1
                continue
            }
            let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL
            // Only accept files the extension actually wrote in this entry.
            guard source.path.hasPrefix(inboxRoot.path + "/") else {
                skipped += 1
                continue
            }
            let attributes = try? fileManager.attributesOfItem(atPath: source.path)
            let size = (attributes?[.size] as? Int) ?? (raw["size"] as? Int ?? 0)
            guard size > 0, size <= ParallaxIntentStore.maxFileBytes else {
                skipped += 1
                continue
            }
            let name = parallaxSanitiseName(raw["name"] as? String ?? source.lastPathComponent)
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                let target = uniqueDestination(in: destination, name: name)
                try fileManager.copyItem(at: source, to: target)
                files.append([
                    "path": target.path,
                    "name": target.lastPathComponent,
                    "mimeType": parallaxSanitiseMime(raw["mimeType"] as? String),
                    "size": size,
                ])
            } catch {
                skipped += 1
            }
        }
        try? fileManager.removeItem(at: dir)
        let text = (manifest["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = text != nil && !(text!.isEmpty)
        if files.isEmpty && !hasText && skipped == 0 && tooLarge == 0 { return }
        var payload: [String: Any] = [
            "kind": "share",
            "files": files,
            "skipped": skipped,
            "tooLarge": tooLarge,
        ]
        if let text = text, !text.isEmpty {
            payload["text"] = text
        }
        enqueue(payload)
    }

    private func uniqueDestination(in dir: URL, name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var index = 1
        repeat {
            let suffixed = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = dir.appendingPathComponent(suffixed)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
    #endif
}

// MARK: - Channel registration

/// Creates and owns all Parallax MethodChannels for one Flutter engine.
/// Construct from the AppDelegate once the binary messenger is available.
final class ParallaxAppleChannels {
    private let videoTools = ParallaxVideoTools()
    private let permissions = ParallaxPermissions()
    private let secureWindow = ParallaxSecureWindow()
    private let store = ParallaxIntentStore.shared
    private var channels: [FlutterMethodChannel] = []

    init(messenger: FlutterBinaryMessenger) {
        let video = FlutterMethodChannel(name: "parallax/video", binaryMessenger: messenger)
        video.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard let args = call.arguments as? [String: Any],
                let path = args["path"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing path", details: nil))
                return
            }
            switch call.method {
            case "probe":
                self.videoTools.probe(path: path, result: result)
            case "compress":
                let shortSide = args["shortSide"] as? Int ?? 720
                let bitrate = args["videoBitrate"] as? Int ?? 2_500_000
                self.videoTools.compress(path: path, shortSide: shortSide, bitrate: bitrate, result: result)
            case "sampleFrames":
                let maxEdge = parallaxClamp(args["maxEdge"] as? Int ?? 360, 64, 720)
                let maxFrames = parallaxClamp(args["maxFrames"] as? Int ?? 12, 2, 24)
                let maxDurationMs = parallaxClamp(args["maxDurationMs"] as? Int ?? 3000, 500, 10_000)
                self.videoTools.sampleFrames(
                    path: path, maxEdge: maxEdge, maxFrames: maxFrames,
                    maxDurationMs: maxDurationMs, result: result)
            case "delete":
                self.videoTools.delete(path: path, result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        let permissionsChannel = FlutterMethodChannel(name: "parallax/permissions", binaryMessenger: messenger)
        permissionsChannel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }
            self.permissions.handle(call, result: result)
        }

        let secure = FlutterMethodChannel(name: "parallax/secure_window", binaryMessenger: messenger)
        secure.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard call.method == "setSecure" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard let args = call.arguments as? [String: Any],
                let enabled = args["enabled"] as? Bool
            else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing enabled flag", details: nil))
                return
            }
            DispatchQueue.main.async {
                self.secureWindow.setSecure(enabled)
                result(nil)
            }
        }

        let intents = FlutterMethodChannel(name: "parallax/platform_intents", binaryMessenger: messenger)
        intents.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }
            switch call.method {
            case "takePending":
                result(self.store.takePending())
            case "discard":
                let args = call.arguments as? [String: Any]
                let paths = args?["paths"] as? [String] ?? []
                self.store.discard(paths: paths)
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        channels = [video, permissionsChannel, secure, intents]
        store.attach(intents)
    }

    /// Routes an incoming URL into the intent queue (see handleIncomingURL).
    @discardableResult
    static func handleIncomingURL(_ url: URL) -> Bool {
        return ParallaxIntentStore.handleIncomingURL(url)
    }
}