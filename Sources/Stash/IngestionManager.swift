import AppKit
import Foundation
import UniformTypeIdentifiers
import CoreServices

/// Turns anything that can be dropped into something that can be dragged out.
///
/// A shelf is only as good as the worst thing you can put on it. A file URL is
/// easy; a selection of text, an image dragged straight off a web page, or a
/// promised file from Photos are not — they arrive as bytes, or as an IOU, and
/// neither can be handed to Finder later. This is where all of that is
/// normalised: everything that is not already a file on disk gets *materialised*
/// into one, in a scratch directory of our own, and the shelf then holds a plain
/// file URL like everything else.
///
/// Nothing here runs unless a drop actually happened.
enum IngestionManager {
    /// Where virtualised items live. Under `NSTemporaryDirectory()` so the
    /// system reclaims it, in our own folder so we can sweep it ourselves.
    static let scratch: URL = {
        let url = AppPaths.stashScratch
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Shelves do not survive a relaunch, so anything still in scratch at launch
    /// is orphaned by definition.
    ///
    /// Deleting everything in a folder is only safe if it is *our* folder. If
    /// the scratch path has been replaced by a symbolic link — or is not a
    /// directory this user owns — listing it would follow the link and delete
    /// whatever it points at. So that case deletes nothing: the odd thing is
    /// moved aside (a rename moves a link itself, never its target) and a fresh
    /// folder takes its place. Entries inside are removed with `removeItem`,
    /// which removes a link rather than following it.
    static func purgeScratch() {
        let manager = FileManager.default
        let path = scratch.path
        if let attributes = try? manager.attributesOfItem(atPath: path) {
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            guard isDirectory, owner == getuid() else {
                let aside = path + ".unexpected-" + Stamp.moment()
                try? manager.moveItem(atPath: path, toPath: aside)
                try? manager.createDirectory(at: scratch, withIntermediateDirectories: true)
                GroupStore.log("STASH scratch was not our own folder; moved it to \(aside) and deleted nothing")
                return
            }
        }
        guard let entries = try? manager.contentsOfDirectory(
            at: scratch, includingPropertiesForKeys: nil) else { return }
        for entry in entries { try? manager.removeItem(at: entry) }
    }

    // MARK: - AppKit path (drags, including promises)

    /// Reads a live drag. This is the path that supports file promises, which
    /// never appear as ordinary pasteboard items.
    @MainActor
    static func ingest(_ info: NSDraggingInfo, into sink: @escaping @MainActor @Sendable ([StashItem]) -> Void) {
        let pasteboard = info.draggingPasteboard

        // 1. Promises first. Safari, Photos and Mail hand over a receipt rather
        //    than a file: the source app writes the bytes only once a
        //    destination asks for them, at a directory we nominate.
        let promiseOptions: [NSPasteboard.ReadingOptionKey: Any] = [:]
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                                  options: promiseOptions) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: scratch,
                                              options: [:],
                                              operationQueue: queue) { url, error in
                    guard error == nil else {
                        NSLog("Gruppen: promise failed — %@", error!.localizedDescription)
                        return
                    }
                    Task { @MainActor in sink([.file(url)]) }
                }
            }
            return
        }

        // 2. Ordinary pasteboard contents.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            sink(urls.map { .file($0) })
            return
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first, pasteboard.data(forType: .fileURL) == nil {
            materialize(image: image) { item in Task { @MainActor in sink([item].compactMap { $0 }) } }
            return
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            for url in urls { materialize(webURL: url) { item in Task { @MainActor in sink([item]) } } }
            return
        }

        if let string = pasteboard.string(forType: .string) {
            sink([materialize(text: string)])
        }
    }

    // MARK: - SwiftUI path (item providers)

    /// Used where the drop surface is a SwiftUI `onDrop`. Providers that carry a
    /// file representation — which is how a promise surfaces here — are asked to
    /// write it out, and the result is copied into scratch before the source
    /// app reclaims its temporary.
    @MainActor
    static func ingest(_ providers: [NSItemProvider], into sink: @escaping @MainActor @Sendable ([StashItem]) -> Void) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in sink([.file(url)]) }
                }
            } else if provider.hasRepresentationConforming(toTypeIdentifier: UTType.image.identifier,
                                                           fileOptions: []) {
                claimFileRepresentation(from: provider, typeIdentifier: UTType.image.identifier, sink: sink)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    materialize(webURL: url) { item in Task { @MainActor in sink([item]) } }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string else { return }
                    Task { @MainActor in sink([materialize(text: string)]) }
                }
            }
        }
    }

    /// Asks a provider to write its bytes to disk and takes a copy we own.
    ///
    /// The URL handed to this callback is the *source app's* temporary and is
    /// deleted the moment the callback returns, so copying inside the callback
    /// is not an optimisation — it is the only correct place to do it.
    @MainActor
    private static func claimFileRepresentation(from provider: NSItemProvider,
                                                typeIdentifier: String,
                                                sink: @escaping @MainActor @Sendable ([StashItem]) -> Void) {
        // Read off the provider *here*, on the main actor: the callback runs on
        // an arbitrary queue and NSItemProvider is not Sendable.
        let suggested = provider.suggestedName
        _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            guard let url else { return }
            let name = suggested ?? url.lastPathComponent
            let destination = uniqueScratchURL(named: name)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                Task { @MainActor in sink([.file(destination)]) }
            } catch {
                NSLog("Gruppen: could not claim %@ — %@", name, error.localizedDescription)
            }
        }
    }

    // MARK: - Virtualisation

    /// Writes a text selection out as a real file so it can be dragged into
    /// Finder, an editor, or anything else that only speaks in files. The
    /// extension is guessed from the content, because a JSON blob saved as
    /// `.txt` opens in the wrong app for the rest of its life.
    @discardableResult
    static func materialize(text: String) -> StashItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = fileExtension(forText: trimmed)
        let stem = String(trimmed.prefix(32))
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = (stem.isEmpty ? "Snippet" : stem) + "." + ext
        let url = uniqueScratchURL(named: name)
        do {
            try trimmed.data(using: .utf8)?.write(to: url)
            return StashItem.virtual(file: url, kind: .text, title: stem.isEmpty ? "Snippet" : stem)
        } catch {
            // Still shelve it — it just cannot be dragged out as a file.
            return .text(trimmed)
        }
    }

    private static func fileExtension(forText text: String) -> String {
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil { return "json" }
        if text.contains("```") || text.hasPrefix("# ") || text.contains("\n## ") { return "md" }
        return "txt"
    }

    /// A remote image becomes a local one; anything else becomes a `.webloc`,
    /// which is the file Finder itself writes when you drag a link to the
    /// desktop, so double-clicking it opens the page.
    static func materialize(webURL url: URL, completion: @escaping @Sendable (StashItem) -> Void) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            completion(.link(url))
            return
        }

        let ext = url.pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        guard imageExtensions.contains(ext) else {
            completion(webloc(for: url))
            return
        }

        // One request, only because something was dropped — and a bounded one:
        // the link came from a web page, so its server decides what arrives.
        CappedImageDownload.start(url, limit: imageDownloadLimit) { data in
            guard let data else {
                completion(webloc(for: url))
                return
            }
            let name = url.lastPathComponent.isEmpty ? "Image.\(ext)" : url.lastPathComponent
            let destination = uniqueScratchURL(named: name)
            do {
                try data.write(to: destination)
                markDownloaded(destination, from: url)
                completion(StashItem.virtual(file: destination, kind: .file,
                                             title: destination.lastPathComponent))
            } catch {
                completion(webloc(for: url))
            }
        }
    }

    /// The largest image a dropped link may bring in. Past this it stays a link.
    static let imageDownloadLimit = 50 * 1024 * 1024

    /// Marks a file as downloaded from the web, the way a browser does, so
    /// Gatekeeper and the "downloaded from the internet" check see it as what
    /// it is if it is ever opened.
    private static func markDownloaded(_ file: URL, from origin: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: origin,
            kLSQuarantineAgentNameKey as String: AppPaths.name,
        ]
        var marked = file
        try? marked.setResourceValues(values)
    }

    /// An internet location file — a plist with the URL in it, exactly as Finder
    /// writes it.
    private static func webloc(for url: URL) -> StashItem {
        let name = (url.host ?? "Link") + ".webloc"
        let destination = uniqueScratchURL(named: name)
        let plist: [String: Any] = ["URL": url.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                             format: .xml,
                                                             options: 0),
              (try? data.write(to: destination)) != nil
        else { return .link(url) }
        return StashItem.virtual(file: destination, kind: .url, title: url.host ?? url.absoluteString)
    }

    /// Image data straight off the pasteboard — a screenshot, or a drag out of
    /// Preview — written as PNG.
    static func materialize(image: NSImage, completion: @escaping (StashItem?) -> Void) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { completion(nil); return }

        let name = "Image-\(Stamp.moment()).png"
        let destination = uniqueScratchURL(named: name)
        do {
            try png.write(to: destination)
            completion(StashItem.virtual(file: destination, kind: .file, title: name))
        } catch {
            completion(nil)
        }
    }

    // MARK: - Naming

    static func uniqueScratchURL(named name: String) -> URL {
        FileName.unique(name.isEmpty ? "Item" : name, in: scratch)
    }
}

/// One image download that stops early instead of taking whatever arrives.
///
/// Refused at the headers — cancelled before a byte of body — unless the server
/// says success and an `image/` type, and doesn't announce more than `limit`.
/// Cancelled mid-stream the moment the body passes `limit`, for a server that
/// announced nothing or lied. 30 s without data, or 60 s in all, is a timeout.
/// Ephemeral, so nothing is cached or stored in a cookie jar.
private final class CappedImageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Touched only from the session's delegate queue, which is serial.
    private var body = Data()
    private var overLimit = false
    private let limit: Int
    private let finish: @Sendable (Data?) -> Void

    private init(limit: Int, finish: @escaping @Sendable (Data?) -> Void) {
        self.limit = limit
        self.finish = finish
    }

    static func start(_ url: URL, limit: Int, finish: @escaping @Sendable (Data?) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let delegate = CappedImageDownload(limit: limit, finish: finish)
        // The session holds its delegate until it is invalidated, which
        // `finishTasksAndInvalidate` does once this one task is over.
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: url).resume()
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let succeeded = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        let isImage = response.mimeType?.lowercased().hasPrefix("image/") ?? false
        let fits = response.expectedContentLength <= Int64(limit)
        completionHandler(succeeded && isImage && fits ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !overLimit else { return }
        body.append(data)
        if body.count > limit {
            overLimit = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil && !overLimit && !body.isEmpty ? body : nil)
    }
}
