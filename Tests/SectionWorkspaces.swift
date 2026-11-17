import AppKit
import Foundation

@MainActor
func sectionWorkspaces() async {
    T.begin("F. Workspaces — reordering the Dock")

    let dock = (try? JSONDecoder().decode([AppEntry].self, from: Data("""
        [{"name":"A","bundleID":"a","path":"/A.app"}, {"name":"B","bundleID":"b","path":"/B.app"},
         {"name":"C","bundleID":"c","path":"/C.app"}, {"name":"D","bundleID":"","path":"/D.app"}]
        """.utf8))) ?? []
    T.equal("dropped on a later app, it sits just before it", dock.moving("a", before: "c").map(\.id), ["b", "a", "c", "/D.app"])
    T.equal("dropped on an earlier app, likewise", dock.moving("c", before: "a").map(\.id), ["c", "a", "b", "/D.app"])
    T.equal("dropped below them all, it goes last", dock.moving("a", before: nil).map(\.id), ["b", "c", "/D.app", "a"])
    T.equal("an app with no bundle id moves by its path", dock.moving("/D.app", before: "a").map(\.id), ["/D.app", "a", "b", "c"])
    T.equal("dropped on itself, nothing moves", dock.moving("b", before: "b"), dock)
    T.equal("an app from another list is ignored", dock.moving("z", before: "a"), dock)
    T.equal("a target that isn't there means last", dock.moving("a", before: "z").map(\.id), ["b", "c", "/D.app", "a"])

    T.begin("F. Workspaces — profiles on disk")

    withTempDir { dir in
        let file = dir.appendingPathComponent("workspaces.json")
        let engine = WorkspaceEngine(fileURL: file)
        T.check("a fresh engine is empty", engine.profiles.isEmpty)

        let p = engine.add(named: "Focus")
        _ = engine.add(named: "Focus")
        T.equal("duplicate names are disambiguated", Set(engine.profiles.map(\.name)).count, 2)

        var edited = p
        edited.links = ["https://example.com"]
        edited.folders = ["/tmp"]
        edited.replacesDock = true
        edited.spaceIndex = 2
        engine.update(edited)
        engine.flushPendingSave()

        let reloaded = WorkspaceEngine(fileURL: file)
        let back = reloaded.profiles.first { $0.id == p.id }
        T.check("a profile round-trips through the file",
                back?.links == ["https://example.com"] && back?.folders == ["/tmp"]
                && back?.replacesDock == true && back?.spaceIndex == 2,
                back.map { "\($0.links) \($0.folders)" } ?? "missing")

        engine.remove(p)
        engine.flushPendingSave()
        T.equal("a removal is persisted", WorkspaceEngine(fileURL: file).profiles.count, 1)
    }

    // A profile written by an earlier build — only a name — must still load.
    let bare = #"[{"name":"Old"}]"#.data(using: .utf8)!
    if let decoded = try? JSONDecoder().decode([WorkspaceProfile].self, from: bare) {
        T.check("a profile with only a name decodes with defaults",
                decoded[0].launches.isEmpty && decoded[0].links.isEmpty
                && decoded[0].colorHex == Theme.defaultGroupHex)
    } else {
        T.check("a profile with only a name decodes with defaults", false, "decode threw")
    }

    // The telemetry snapshot inside a profile is the newest nested type, so it
    // is the likeliest to gain fields.
    let partialLayout = #"[{"name":"Old","telemetry":{"armed":["cpu"]}}]"#.data(using: .utf8)!
    if let decoded = try? JSONDecoder().decode([WorkspaceProfile].self, from: partialLayout) {
        T.check("a partial telemetry layout decodes",
                decoded[0].telemetry?.armed == ["cpu"] && decoded[0].telemetry?.pinned.isEmpty == true)
    } else {
        T.check("a partial telemetry layout decodes", false, "decode threw")
    }
}
