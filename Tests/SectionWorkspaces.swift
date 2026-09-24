import AppKit
import Foundation

@MainActor
func sectionWorkspaces() async {
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

        let reloaded = WorkspaceEngine(fileURL: file)
        let back = reloaded.profiles.first { $0.id == p.id }
        T.check("a profile round-trips through the file",
                back?.links == ["https://example.com"] && back?.folders == ["/tmp"]
                && back?.replacesDock == true && back?.spaceIndex == 2,
                back.map { "\($0.links) \($0.folders)" } ?? "missing")

        engine.remove(p)
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

    T.begin("F. Metrics — definitions and the database")

    let metricDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gruppen-metrics-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: metricDir, withIntermediateDirectories: true)
    do {
        let store = MetricStore(url: metricDir.appendingPathComponent("metrics.sqlite"))
        let id = UUID()
        store.insert(metric: id, values: ["track": "Song", "artist": "Someone"])
        store.insert(metric: id, values: ["track": "Другая", "artist": "Ыыы"])
        store.insert(metric: id, values: ["track": "emoji 🎧", "artist": "quote\"and'apostrophe"])

        let rows = await store.records(for: id, limit: 100)
        let counted = await store.count(for: id)
        T.equal("every row written comes back", rows.count, 3)
        T.equal("the count agrees with the rows", counted, 3)
        T.check("non-ASCII survives the round trip",
                rows.contains { $0.values["track"] == "Другая" })
        T.check("quotes and apostrophes are not an injection",
                rows.contains { $0.values["artist"] == "quote\"and'apostrophe" },
                "values are bound, not interpolated")

        await store.deleteAll(for: id)
        let remaining = await store.count(for: id)
        T.equal("deleting a metric empties it", remaining, 0)
    }
    try? FileManager.default.removeItem(at: metricDir)

    // A definition written by an earlier build.
    let legacyMetric = """
    [{"id":"22222222-2222-2222-2222-222222222222","name":"Tracks","isRecording":true,
      "source":{"kind":"musicTrack"}}]
    """.data(using: .utf8)!
    if let decoded = try? JSONDecoder().decode([MetricDefinition].self, from: legacyMetric) {
        T.check("a metric definition from an earlier build still loads",
                decoded[0].name == "Tracks")
    } else {
        T.check("a metric definition from an earlier build still loads", false, "decode threw")
    }

    T.begin("F. Libraries — one bad record must not take the file with it")

    // This is the failure mode that matters: these loaders decode the whole
    // array at once, so what happens to the good entries beside a bad one?
    withTempDir { dir in
        let file = dir.appendingPathComponent("scripts.json")
        let mixed = """
        [{"id":"33333333-3333-3333-3333-333333333333","name":"Good","isActive":false,
          "trigger":{"kind":"manual","watchedFolder":"","appMatch":"bundleIdentifier",
                     "bundleIdentifier":"","appName":"","processName":"","appEvent":"launched",
                     "systemEvent":"batteryBelow","threshold":20,
                     "notificationScope":"darwin","notificationName":""},
          "action":{"kind":"shellCommand","interpreter":"zsh","command":"echo ok",
                    "webhookURL":"","httpMethod":"post","source":"","isCustomised":false},
          "feedback":"silent"},
         {"id":"44444444-4444-4444-4444-444444444444","name":"FromAnOlderBuild","isActive":false,
          "trigger":{"kind":"manual"},
          "action":{"kind":"shellCommand"},
          "feedback":"silent"}]
        """
        try? Data(mixed.utf8).write(to: file)
        let loaded = (try? JSONDecoder().decode([Script].self,
                                                from: Data(contentsOf: file))) ?? []
        T.equal("both scripts load — one old entry must not erase the other",
                loaded.count, 2)
    }
}
