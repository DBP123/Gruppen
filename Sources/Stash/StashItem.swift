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

    /// The directory this item's file already lives in.
    ///
    /// Not a stored property, because there is nothing to store: the shelf holds
    /// files *by reference*, so `url` is already the file where it has always
    /// been and its parent is the origin by definition.
    ///
    /// Nil in two cases, and the second is the one that matters. Text and links
    /// have nothing on disk. **Virtual** items do have a file, but we wrote it
    /// into `IngestionManager.scratch` on the way in, and that directory is
    /// emptied on every launch — it is somewhere a file is passing through, not
    /// somewhere anything should be written back to. Treating it as an origin
    /// would extract an archive into a folder macOS deletes at next start.
    var originDirectoryURL: URL? {
        guard !isVirtual, let fileURL else { return nil }
        return fileURL.deletingLastPathComponent()
    }

    /// Whether this is something `ditto -x -k` can open.
    ///
    /// The PKZip family only. `.tar.gz`, `.7z` and `.rar` are deliberately absent:
    /// ditto does not read them, and offering an Extract button that fails on the
    /// file you pressed it for is worse than not offering it.
    var isArchive: Bool {
        guard let fileURL else { return false }
        return ["zip", "cbz", "jar", "ipa", "war"].contains(fileURL.pathExtension.lowercased())
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
    /// a receiver given a path acts on the file at that path. There is no
    /// content representation left to re-name, so the file that comes out is the
    /// file that went in, by construction rather than by correction.
    ///
    /// It is also what makes *moving* possible at all: a path is something a
    /// receiver can relocate, where a blob of file data can only ever be copied.
    /// Written straight to the pasteboard now rather than through
    /// `NSItemProvider`, because the drag is an AppKit session — see
    /// `StashDragOut` for why.
    var pasteboardWriter: NSPasteboardWriting {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL as NSURL
        }
        if let url { return url as NSURL }
        return (text ?? "") as NSString
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
///
/// ## Giving the foreground back
///
/// Activating Gruppen for the preview has a cost when the preview closes: the
/// app is still active, so AppKit makes its next window key — and if that is
/// the main window on another desktop, macOS switches you to that desktop. You
/// pressed Quick Look on a stash; you did not ask to go anywhere.
///
/// So when Gruppen was in the background before the preview, the preview hands
/// the foreground back to whichever app had it the moment it closes, before
/// AppKit can pick another Gruppen window to make key. If Gruppen was already
/// the app you were using, nothing is handed back — you stay where you were.
@MainActor
enum QuickLook {
    private static let source = Source()

    static func preview(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let panel = QLPreviewPanel.shared() else { return }
        source.url = url as NSURL
        source.handBackTo = NSApp.isActive ? nil : NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = source
        panel.delegate = source
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Retained for the lifetime of the app: `QLPreviewPanel.dataSource` and
    /// `delegate` are weak references, and a data source that deallocates
    /// leaves an empty panel.
    private final class Source: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var url: NSURL?
        /// The app that was in front before the preview took the foreground,
        /// or nil when Gruppen already had it.
        var handBackTo: NSRunningApplication?

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            url
        }

        // Two ways the panel goes away, and both are covered: closed outright,
        // or ordered out (which it reports as losing key while no longer on
        // screen). Losing key while still visible is the user clicking into
        // another app, which needs nothing from us.
        func windowWillClose(_ notification: Notification) { handBack() }

        func windowDidResignKey(_ notification: Notification) {
            guard let panel = notification.object as? NSWindow, !panel.isVisible else { return }
            handBack()
        }

        /// Resigns first, synchronously, so Gruppen is no longer active by the
        /// time AppKit looks for a window to make key; then returns the
        /// foreground to the app that had it.
        private func handBack() {
            guard let app = handBackTo else { return }
            handBackTo = nil
            NSApp.deactivate()
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [])
            }
        }
    }
}
