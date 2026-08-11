import AppKit
import Foundation
import Quartz
import UniformTypeIdentifiers

/// One thing sitting on the shelf.
///
/// Files are held by reference — the shelf points at where the file already
/// lives rather than copying it, so picking something up costs nothing.
struct StashItem: Identifiable, Equatable {
    enum Kind {
        case file
        case text
        case url

        var systemImage: String {
            switch self {
            case .file: return "doc"
            case .text: return "text.alignleft"
            case .url: return "link"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let url: URL?
    let text: String?
    /// True when the file behind this item was written by us — a text snippet,
    /// a fetched image, a `.webloc`. It lives in scratch, so it can be cleaned
    /// up, and it is the reason a snippet can be dragged out as a file at all.
    var isVirtual: Bool = false

    /// The item as something on disk, if it is one.
    var fileURL: URL? {
        guard let url, url.isFileURL else { return nil }
        return url
    }

    /// Resolved on demand and cached, so a shelf of twenty files doesn't hit
    /// IconServices twenty times per redraw.
    var icon: NSImage {
        if let fileURL { return IconCache.shared.icon(forPath: fileURL.path) }
        return NSImage(systemSymbolName: kind.systemImage, accessibilityDescription: nil)
            ?? NSImage()
    }

    /// Everything another app needs to accept this in a drag.
    ///
    /// **The file URL, and nothing else.**
    ///
    /// Two bugs came out of trying to be cleverer than this. First
    /// `NSItemProvider(contentsOf:)`, which leaves `suggestedName` nil and
    /// registers the file's *data* under its type — dragging out `Quarterly
    /// Report v2.pdf` produced `PDF document.pdf`. Replacing it with an explicit
    /// file representation fixed the name but left the second: `transfer.docx`
    /// came back as `transfer..docx.docx`, an extension re-derived and appended
    /// twice.
    ///
    /// That second one could not be reproduced at this layer — both a full and a
    /// base `suggestedName`, on both the in-place and the copy path, returned
    /// `transfer.docx` correctly — which puts the renaming in the bridge between
    /// the provider and the drag pasteboard. So the fix is not a better name: it
    /// is to stop shipping anything that a name can be *derived from*. A bare
    /// file URL is what Finder itself puts on the pasteboard for a file drag
    /// (measured: `public.file-url`, `NSFilenamesPboardType`, and friends), and
    /// a receiver given a path copies the file at that path. There is no
    /// content representation left to re-name, so the file that comes out is the
    /// file that went in, by construction rather than by correction.
    var itemProvider: NSItemProvider {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            return NSItemProvider(object: fileURL as NSURL)
        }
        if let url { return NSItemProvider(object: url as NSURL) }
        return NSItemProvider(object: (text ?? "") as NSString)
    }

    static func file(_ url: URL) -> StashItem {
        StashItem(kind: .file, title: url.lastPathComponent, url: url, text: nil)
    }

    static func link(_ url: URL) -> StashItem {
        StashItem(kind: .url, title: url.host ?? url.absoluteString, url: url, text: url.absoluteString)
    }

    /// Something we wrote to scratch on the way in.
    static func virtual(file url: URL, kind: Kind, title: String) -> StashItem {
        StashItem(kind: kind, title: title, url: url, text: nil, isVirtual: true)
    }

    static func text(_ string: String) -> StashItem {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(trimmed.prefix(48)).replacingOccurrences(of: "\n", with: " ")
        return StashItem(kind: .text, title: title.isEmpty ? "Text" : title, url: nil, text: trimmed)
    }

    static func == (lhs: StashItem, rhs: StashItem) -> Bool { lhs.id == rhs.id }
}

/// Quick Look for a shelved file.
///
/// `QLPreviewPanel` is a shared, app-wide panel that asks the *key* window's
/// responder chain who is driving it. A shelf is a non-activating panel that
/// deliberately never becomes key, so there is nobody in the chain to answer —
/// which is why the data source is installed directly here and kept alive by
/// this type rather than by a view controller. The app is activated first,
/// because the preview panel will not come forward for a background app.
@MainActor
enum QuickLook {
    private static let source = Source()

    static func preview(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let panel = QLPreviewPanel.shared() else { return }
        source.url = url as NSURL
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = source
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Retained for the lifetime of the app: `QLPreviewPanel.dataSource` is a
    /// weak reference, and a data source that deallocates leaves an empty panel.
    private final class Source: NSObject, QLPreviewPanelDataSource {
        var url: NSURL?

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            url
        }
    }
}
