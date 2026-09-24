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

    tap(0, none); tap(3, .shift)
    T.equal("⇧ takes the range from the anchor", titles(), ["a", "b", "c", "d"])
    tap(1, .shift)
    T.equal("a second ⇧ re-measures rather than ratcheting", titles(), ["a", "b"])
    tap(3, none); tap(1, .shift)
    T.equal("⇧ works backwards", titles(), ["b", "c", "d"])
    tap(0, none); tap(4, .command)
    T.equal("⌘ adds one", titles(), ["a", "e"])
    tap(4, .command)
    T.equal("⌘ removes one", titles(), ["a"])
    tap(0, none)
    T.equal("clicking the lone selection clears it", titles(), [])
    tap(2, .shift)
    T.equal("⇧ with no anchor behaves as a plain click", titles(), ["c"])
    tap(0, none); tap(3, [.shift, .command])
    T.equal("⇧ beats ⌘ when both are held", titles(), ["a", "b", "c", "d"])
    T.equal("actionable is the selection when there is one", shelf.actionable.count, 4)
    shelf.selection.removeAll()
    T.equal("actionable is everything when there is not", shelf.actionable.count, 5)

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
}
