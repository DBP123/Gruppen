import AppKit
import Foundation

@MainActor
func sectionStash() {
    T.begin("D. Stash — item classification")

    let zip = StashItem.file(URL(fileURLWithPath: "/tmp/a/report.zip"))
    T.check("a zip is an archive", zip.isArchive)
    T.check("a tarball is not offered", !StashItem.file(URL(fileURLWithPath: "/tmp/a.tar.gz")).isArchive,
            "ditto cannot read it, so no button")
    T.check("case does not matter", StashItem.file(URL(fileURLWithPath: "/tmp/A.ZIP")).isArchive)
    T.equal("a file's origin is its folder", zip.originDirectoryURL?.path, "/tmp/a")
    T.check("text has no origin", StashItem.text("hello").originDirectoryURL == nil)
    T.check("a link has no origin",
            StashItem.link(URL(string: "https://example.com")!).originDirectoryURL == nil)
    T.check("a virtual file has no origin — scratch is purged at launch",
            StashItem.virtual(file: URL(fileURLWithPath: "/tmp/scratch/x.zip"),
                              kind: .file, title: "x.zip").originDirectoryURL == nil)

    T.begin("D. Stash — selection")

    let items = ["a", "b", "c", "d", "e"].map { StashItem.file(URL(fileURLWithPath: "/tmp/\($0)")) }
    let shelf = ShelfState(items: items)
    func titles() -> [String] { shelf.selectedItems.map(\.title) }
    func tap(_ i: Int, _ flags: NSEvent.ModifierFlags) {
        shelf.select(items[i], gesture: .init(modifiers: flags))
    }
    let none: NSEvent.ModifierFlags = []

    tap(0, .shift); tap(2, .shift)
    T.equal("⇧ on the 1st and 3rd selects those two, not the one between",
            titles(), ["a", "c"])
    tap(4, .shift)
    T.equal("another ⇧ adds just that one", titles(), ["a", "c", "e"])
    tap(2, .shift)
    T.equal("⇧ on a selected item takes it back out", titles(), ["a", "e"])
    tap(1, none)
    T.equal("a plain click replaces the selection", titles(), ["b"])
    tap(3, .command)
    T.equal("⌘ adds one, the same as ⇧", titles(), ["b", "d"])
    tap(3, [.shift, .command])
    T.equal("⇧⌘ together toggles too", titles(), ["b"])
    tap(1, none)
    T.equal("clicking the lone selection clears it", titles(), [])

    tap(0, .shift); tap(2, .shift); tap(3, .shift)
    T.equal("actionable is the selection when there is one", shelf.actionable.count, 3)

    T.begin("D. Stash — dragging a selection")

    T.equal("dragging a selected item takes the whole selection, in shelf order",
            shelf.dragBatch(for: items[2]).map(\.title), ["a", "c", "d"])
    T.equal("dragging an unselected item takes only that item",
            shelf.dragBatch(for: items[1]).map(\.title), ["b"])
    shelf.remove(shelf.dragBatch(for: items[0]))
    T.equal("a dropped batch leaves the shelf together", shelf.items.map(\.title), ["b", "e"])
    T.check("and leaves nothing selected", shelf.selection.isEmpty)
    T.equal("with nothing selected, dragging takes just the one",
            shelf.dragBatch(for: shelf.items[0]).map(\.title), ["b"])
    T.equal("actionable is everything when nothing is selected", shelf.actionable.count, 2)

    T.begin("D. Stash — emptying, which closes the notch tray")

    // The notch tray closes on `onEmptied`, so when it fires is the behaviour.
    let tray = ShelfState()
    var emptied = 0
    tray.onEmptied = { emptied += 1 }
    tray.clear()
    T.equal("a tray that never held anything does not close itself", emptied, 0)

    let three = ["x", "y", "z"].map { StashItem.file(URL(fileURLWithPath: "/tmp/\($0)")) }
    tray.add(three)
    tray.remove(three[0])
    T.equal("taking one item out leaves the tray open", emptied, 0)
    tray.remove(Array(three.dropFirst()))
    T.equal("the last items leaving together close it exactly once", emptied, 1)

    tray.add([three[0]])
    tray.clear()
    T.equal("clearing a loaded tray closes it", emptied, 2)

    T.begin("D. Stash — batch extraction planning")

    withTempDir { dir in
        let writable = dir.appendingPathComponent("A", isDirectory: true)
        let locked = dir.appendingPathComponent("B", isDirectory: true)
        let fallback = dir.appendingPathComponent("Fallback", isDirectory: true)
        for d in [writable, locked, fallback] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // Two real archives, one per origin.
        for (folder, name) in [(writable, "alpha"), (locked, "beta")] {
            let payload = folder.appendingPathComponent("\(name).txt")
            try? Data("hello".utf8).write(to: payload)
            let zipProcess = Process()
            zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zipProcess.arguments = ["-j", "-q", folder.appendingPathComponent("\(name).zip").path,
                                    payload.path]
            try? zipProcess.run(); zipProcess.waitUntilExit()
            try? FileManager.default.removeItem(at: payload)
        }
        // Make B refuse writes.
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: locked.path) }

        T.check("a writable directory is detected",
                StashBatchDispatcher.isWritableDirectory(writable))
        T.check("a read-only directory is detected",
                !StashBatchDispatcher.isWritableDirectory(locked))
        T.check("a file is not a directory",
                !StashBatchDispatcher.isWritableDirectory(writable.appendingPathComponent("alpha.zip")))
        T.check("a missing directory is not writable",
                !StashBatchDispatcher.isWritableDirectory(dir.appendingPathComponent("nope")))

        let batch = [
            StashItem.file(writable.appendingPathComponent("alpha.zip")),
            StashItem.file(locked.appendingPathComponent("beta.zip")),
            StashItem.text("just a note"),
            StashItem.virtual(file: dir.appendingPathComponent("scratchy.zip"),
                              kind: .file, title: "scratchy.zip"),
        ]
        let plan = StashBatchDispatcher.plan(items: batch, mode: .origin, fallback: fallback)
        T.equal("non-archives are reported, not dropped", plan.skipped, ["just a note"])
        T.equal("distinct origins are counted", plan.originCount, 2)
        T.equal("the unwritable origin and the virtual item are redirected",
                plan.redirectedByPlan, 2)
        T.check("the writable origin keeps its archive",
                plan.jobs.contains { $0.destination == writable && !$0.redirectedByPlan })
        T.check("nothing is planned into the locked folder",
                !plan.jobs.contains { $0.destination == locked })

        let forced = StashBatchDispatcher.plan(items: batch, mode: .fallback, fallback: fallback)
        T.check("forced-fallback sends everything to one place",
                forced.jobs.allSatisfy { $0.destination == fallback })
        T.equal("forced-fallback is not counted as a redirection", forced.redirectedByPlan, 0)
    }

    T.begin("D. Stash — export naming")

    withTempDir { dir in
        let a = dir.appendingPathComponent("one.txt")
        try? Data("a".utf8).write(to: a)
        do {
            let first = try StashExporter.export(items: [("one.txt", a, nil)], to: dir)
            let second = try StashExporter.export(items: [("one.txt", a, nil)], to: dir)
            T.check("two exports do not overwrite each other",
                    first != second, "\(first.lastPathComponent) then \(second.lastPathComponent)")
            T.check("the archive exists and is not empty",
                    (try? Data(contentsOf: second))?.isEmpty == false)
        } catch { T.check("exporting a file works", false, "\(error)") }

        do {
            _ = try StashExporter.export(items: [], to: dir)
            T.check("an empty export is refused", false, "it produced an archive")
        } catch { T.check("an empty export is refused", true, "\(error.localizedDescription)") }

        // The failures the shelf has to put into words, read back the way the
        // shelf reads them.
        func failure(_ destination: URL) -> String? {
            do { _ = try StashExporter.export(items: [("one.txt", a, nil)], to: destination); return nil }
            catch { return (error as? StashExporter.ExportError)?.errorDescription }
        }
        let missing = dir.appendingPathComponent("Nowhere", isDirectory: true)
        T.equal("a missing folder is named, not left to zip's stderr",
                failure(missing), "Nowhere folder not found")

        let locked = dir.appendingPathComponent("Locked", isDirectory: true)
        try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        T.equal("a read-only folder says so", failure(locked), "Can't write to Locked")
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)

        let messages = [StashExporter.ExportError.nothingToExport, .folderMissing("Downloads"),
                        .folderNotWritable("Downloads"), .zipFailed(String(repeating: "x", count: 400))]
            .compactMap(\.errorDescription)
        T.check("every failure fits on the shelf's one line", messages.allSatisfy { $0.count <= 32 },
                messages.map { "\($0.count)" }.joined(separator: ", ") + " characters")
    }

    T.begin("D. Stash — conversion targets")

    T.check("a png offers conversions",
            !FileConverter.targets(for: [URL(fileURLWithPath: "/tmp/a.png")]).isEmpty,
            FileConverter.targets(for: [URL(fileURLWithPath: "/tmp/a.png")]).map(\.label).description)
    T.check("a mixed selection offers nothing",
            FileConverter.targets(for: [URL(fileURLWithPath: "/tmp/a.png"),
                                        URL(fileURLWithPath: "/tmp/b.wav")]).isEmpty,
            "there is no single answer for a png and a wav")
    T.check("an unknown extension offers nothing",
            FileConverter.targets(for: [URL(fileURLWithPath: "/tmp/a.xyz")]).isEmpty)
    T.check("a target never offers to convert a file to itself",
            FileConverter.targets(for: [URL(fileURLWithPath: "/tmp/a.png")])
                .allSatisfy { $0.label.lowercased() != "png" })

    T.begin("D. Stash — dragging out: move or copy")

    // What a receiver outside the app is allowed to do.
    let outside = NSDraggingContext.outsideApplication
    let inside = NSDraggingContext.withinApplication
    T.equal("copy mode offers a copy and nothing else",
            StashDragOut.operations(for: outside, moving: false), .copy)
    T.check("move mode offers Finder a move",
            StashDragOut.operations(for: outside, moving: true).contains(.move))
    // A browser maps the mask onto the page's effectAllowed, and a page taking
    // a file asks for "copy". Move alone was refused by every web drop zone.
    T.check("move mode still offers copy, or every browser refuses the drop",
            StashDragOut.operations(for: outside, moving: true).contains(.copy))
    T.check("copy mode never offers a move — nothing may relocate the file",
            !StashDragOut.operations(for: outside, moving: false).contains(.move))

    // Whether the finished drag takes the item off the stash.
    // Any drop that landed takes the item off the stash, whatever the receiver
    // did with the file; only a cancelled drag leaves it there.
    T.check("a moved file leaves the stash", StashDragOut.consumes(.move))
    T.check("a copied file leaves the stash too — it was dragged out",
            StashDragOut.consumes(.copy))
    T.check("so does a drop the receiver only reported as generic — "
            + "the 'accepted' drags that used to stay behind",
            StashDragOut.consumes(.generic))
    T.check("a cancelled drag leaves the item where it was", !StashDragOut.consumes([]))
    // Another stash takes a reference and its drop zone answers copy; offering
    // only move there would make it refuse the drop.
    T.equal("a drop on another stash is a copy even in move mode",
            StashDragOut.operations(for: inside, moving: true), .copy)
    T.equal("and in copy mode", StashDragOut.operations(for: inside, moving: false), .copy)

    T.equal("a move the receiver performed is logged as moved",
            StashDragOut.describe(.move), "moved")
    T.equal("a copy is logged as copied", StashDragOut.describe(.copy), "copied")
    T.equal("a drop nobody took is cancelled — and keeps the item",
            StashDragOut.describe([]), "cancelled")

    // What goes on the pasteboard: a path a receiver can relocate, and only
    // when there is still a file at it.
    withTempDir { dir in
        let file = dir.appendingPathComponent("report.pdf")
        try? Data("x".utf8).write(to: file)
        let onDisk = StashItem.file(file).pasteboardWriter as? NSURL
        T.equal("a stashed file is dragged as its own path",
                (onDisk as URL?)?.standardizedFileURL, file.standardizedFileURL)

        let vanished = dir.appendingPathComponent("gone.pdf")
        let stale = StashItem.file(vanished).pasteboardWriter
        T.check("a file that has since gone is still a URL, not a path to move",
                (stale as? NSURL) != nil)
    }
    let link = StashItem.link(URL(string: "https://example.com/a")!).pasteboardWriter as? NSURL
    T.equal("a link is dragged as its URL", link?.absoluteString, "https://example.com/a")
    let snippet = StashItem.text("hello there").pasteboardWriter as? NSString
    T.equal("text is dragged as text", snippet as String?, "hello there")

    // The setting itself: off by default, because a stash has always copied
    // and nobody should find their files moved by an update.
    let defaults = UserDefaults.standard
    let saved = defaults.object(forKey: "stashMovesOnDragOut")
    defaults.removeObject(forKey: "stashMovesOnDragOut")
    T.check("a fresh install copies", AppSettings().stashMovesOnDragOut == false)
    let settings = AppSettings()
    settings.stashMovesOnDragOut = true
    T.check("the choice is persisted", defaults.bool(forKey: "stashMovesOnDragOut"))
    T.check("and survives a relaunch", AppSettings().stashMovesOnDragOut)
    if let saved { defaults.set(saved, forKey: "stashMovesOnDragOut") }
    else { defaults.removeObject(forKey: "stashMovesOnDragOut") }
}
