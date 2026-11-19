// Parallax iOS Share Extension.
//
// No Flutter engine here: the extension copies shared text/files into the
// App Group inbox (group.net.samrussell.parallax/SharedInbox/<uuid>/) with a
// manifest.json, then opens the host app via
// net.samrussell.parallax://share-inbox. The host's AppDelegate drains the
// inbox into the platform_intents queue (and re-checks it on every
// foreground, so the handoff survives even if the URL open fails).
//
// Caps match Android's SharedIntentStore: 10 files, 20 MB each, 32 KB text.

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let appGroup = "group.net.samrussell.parallax"
    private let maxFiles = 10
    private let maxFileBytes = 20 * 1024 * 1024
    private let maxTextLength = 32 * 1024

    /// Serialises all mutable state; item-provider callbacks arrive on
    /// arbitrary queues.
    private let stateQueue = DispatchQueue(label: "net.samrussell.parallax.share.state")
    private var pendingLoads = 0
    private var copyingFiles = 0
    private var finished = false
    private var textParts: [String] = []
    private var files: [[String: Any]] = []
    private var skipped = 0
    private var tooLarge = 0
    private var entryDirectory: URL?

    // MARK: UI

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.05, blue: 0.06, alpha: 1.0)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Sharing to Parallax…"
        label.textColor = .white
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(spinner)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 20),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        startProcessing()
    }

    // MARK: Processing

    private func startProcessing() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
            return
        }
        var providers: [NSItemProvider] = []
        for item in items {
            providers.append(contentsOf: item.attachments ?? [])
        }
        guard !providers.isEmpty,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup)
        else {
            finish()
            return
        }
        let entry = container
            .appendingPathComponent("SharedInbox", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        } catch {
            finish()
            return
        }
        entryDirectory = entry

        stateQueue.async {
            self.pendingLoads = providers.count
        }
        for provider in providers {
            handleProvider(provider, entry: entry)
        }
        // Safety net: never leave the share sheet hanging on a stuck load.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.finish()
        }
    }

    private func handleProvider(_ provider: NSItemProvider, entry: URL) {
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            loadText(provider, typeIdentifier: UTType.plainText.identifier)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            loadURL(provider, entry: entry)
        } else if let typeIdentifier = fileType(for: provider) {
            loadFile(provider, typeIdentifier: typeIdentifier, entry: entry)
        } else {
            stateQueue.async {
                self.skipped += 1
                self.loadCompleted()
            }
        }
    }

    /// Most specific file-backed type the provider offers.
    private func fileType(for provider: NSItemProvider) -> String? {
        let candidates: [UTType] = [.image, .movie, .audio, .audiovisualContent, .data, .content]
        for type in candidates {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                return type.identifier
            }
        }
        return nil
    }

    private func loadText(_ provider: NSItemProvider, typeIdentifier: String) {
        provider.loadItem(forTypeIdentifier: typeIdentifier) { [weak self] item, _ in
            guard let self = self else { return }
            var text: String?
            if let string = item as? String {
                text = string
            } else if let attributed = item as? NSAttributedString {
                text = attributed.string
            } else if let url = item as? URL {
                text = url.absoluteString
            } else if let data = item as? Data {
                text = String(data: data, encoding: .utf8)
            }
            self.stateQueue.async {
                if let text = text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.textParts.append(text)
                } else {
                    self.skipped += 1
                }
                self.loadCompleted()
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider, entry: URL) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
            guard let self = self else { return }
            let url = (item as? URL) ?? (item as? String).flatMap(URL.init(string:))
            guard let url = url else {
                self.stateQueue.async {
                    self.skipped += 1
                    self.loadCompleted()
                }
                return
            }
            if url.isFileURL {
                // The temporary file is only valid inside this callback.
                self.copyFile(
                    from: url, suggestedName: provider.suggestedName,
                    typeIdentifier: UTType.fileURL.identifier, entry: entry)
            } else {
                self.stateQueue.async {
                    self.textParts.append(url.absoluteString)
                    self.loadCompleted()
                }
            }
        }
    }

    private func loadFile(_ provider: NSItemProvider, typeIdentifier: String, entry: URL) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, _ in
            guard let self = self else { return }
            guard let url = url else {
                self.stateQueue.async {
                    self.skipped += 1
                    self.loadCompleted()
                }
                return
            }
            // Copy synchronously: the representation URL expires when this
            // callback returns.
            self.copyFile(
                from: url, suggestedName: provider.suggestedName,
                typeIdentifier: typeIdentifier, entry: entry)
        }
    }

    private func copyFile(from source: URL, suggestedName: String?, typeIdentifier: String?, entry: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes?[.size] as? Int) ?? 0

        // Reserve a slot so concurrent copies cannot exceed the file cap.
        var reserved = false
        stateQueue.sync {
            if self.files.count + self.copyingFiles >= self.maxFiles {
                self.skipped += 1
            } else if size <= 0 {
                self.skipped += 1
            } else if size > self.maxFileBytes {
                self.tooLarge += 1
            } else {
                self.copyingFiles += 1
                reserved = true
            }
        }
        guard reserved else {
            stateQueue.async { self.loadCompleted() }
            return
        }

        let name = sanitiseName(suggestedName ?? source.lastPathComponent)
        let target = uniqueDestination(in: entry, name: name)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            let mime = mimeType(for: typeIdentifier, fileURL: target)
            stateQueue.async {
                self.copyingFiles -= 1
                self.files.append([
                    "path": target.path,
                    "name": target.lastPathComponent,
                    "mimeType": mime,
                    "size": size,
                ])
                self.loadCompleted()
            }
        } catch {
            stateQueue.async {
                self.copyingFiles -= 1
                self.skipped += 1
                self.loadCompleted()
            }
        }
    }

    /// Must run on stateQueue.
    private func loadCompleted() {
        pendingLoads -= 1
        if pendingLoads <= 0 {
            finishLocked()
        }
    }

    private func finish() {
        stateQueue.async { [weak self] in
            self?.finishLocked()
        }
    }

    /// Must run on stateQueue.
    private func finishLocked() {
        guard !finished else { return }
        finished = true

        let text = textParts.joined(separator: "\n")
        let trimmed = String(text.prefix(maxTextLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !files.isEmpty || skipped > 0 || tooLarge > 0

        if let entry = entryDirectory {
            if hasContent {
                var manifest: [String: Any] = [
                    "files": files,
                    "skipped": skipped,
                    "tooLarge": tooLarge,
                ]
                if !trimmed.isEmpty {
                    manifest["text"] = trimmed
                }
                if let data = try? JSONSerialization.data(withJSONObject: manifest) {
                    try? data.write(to: entry.appendingPathComponent("manifest.json"))
                }
            } else {
                try? FileManager.default.removeItem(at: entry)
            }
        }

        if hasContent {
            openHostApp()
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    // MARK: Host handoff

    /// Extensions cannot use UIApplication.shared; walk the responder chain
    /// to reach the application object. Best effort only — the host also
    /// drains the inbox on launch and on every foreground.
    private func openHostApp() {
        guard let url = URL(string: "net.samrussell.parallax://share-inbox") else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    // MARK: Naming helpers

    private func sanitiseName(_ raw: String) -> String {
        var name = raw.split(separator: "/").last.map(String.init) ?? raw
        name = name.split(separator: "\\").last.map(String.init) ?? name
        name = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { return "shared-file" }
        return name.count > 120 ? String(name.suffix(120)) : name
    }

    private func uniqueDestination(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var index = 1
        repeat {
            let suffixed = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(suffixed)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    private func mimeType(for typeIdentifier: String?, fileURL: URL) -> String {
        if let typeIdentifier = typeIdentifier,
            let mime = UTType(typeIdentifier)?.preferredMIMEType {
            return mime
        }
        let ext = fileURL.pathExtension
        if !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}