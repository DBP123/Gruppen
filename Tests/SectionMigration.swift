import AppKit
import Foundation

/// The failure mode this section exists for: a saved file written by a build
/// that is not this one. Every model here is persisted, so every one of them is
/// read back on someone's Mac after an update.
@MainActor
func sectionMigration() {
    T.begin("B. Migration — a single field is all an old file has")

    // The minimum each persisted type must tolerate.
    let cases: [(String, Bool)] = [
        ("AppGroup", (try? JSONDecoder().decode(AppGroup.self,
            from: Data(#"{"name":"x"}"#.utf8))) != nil),
        ("WorkspaceProfile", (try? JSONDecoder().decode(WorkspaceProfile.self,
            from: Data(#"{"name":"x"}"#.utf8))) != nil),
        ("SystemBuildInfo", (try? JSONDecoder().decode(SystemBuildInfo.self,
            from: Data(#"{"osVersion":"14.0"}"#.utf8))) != nil),
        ("MacHardwareProfile", (try? JSONDecoder().decode(MacHardwareProfile.self,
            from: Data(#"{"rawModelIdentifier":"Mac15,3"}"#.utf8))) != nil),
        ("TelemetryLayout", (try? JSONDecoder().decode(TelemetryLayout.self,
            from: Data(#"{"armed":["cpu"]}"#.utf8))) != nil),
    ]
    for (name, ok) in cases {
        T.check("\(name) survives a file missing every optional key", ok,
                ok ? "" : "decode threw — this type's saved data is discarded on update")
    }

    T.begin("B. Migration — one bad entry must cost one entry")

    // The real failure: these libraries decode as an array in one call, so
    // before this a single unreadable record emptied the user's whole file and
    // the next save wrote the empty array back over it.
    let mixedGroups = """
    [{"name":"Keep"}, 42, {"name":"AlsoKeep","apps":[]}]
    """
    let groups = LenientLibrary.decode(AppGroup.self, from: Data(mixedGroups.utf8))
    T.equal("the readable groups survive a corrupt neighbour", groups.items.count, 2)
    T.equal("the unreadable one is counted, not hidden", groups.skipped, 1)
    T.check("the survivors are the right ones",
            groups.items.map(\.name).sorted() == ["AlsoKeep", "Keep"],
            groups.items.map(\.name).description)

    // A well-formed file must still take the fast path and lose nothing.
    let clean = try! JSONEncoder().encode([AppGroup(name: "A"), AppGroup(name: "B")])
    let cleanResult = LenientLibrary.decode(AppGroup.self, from: clean)
    T.equal("a clean file decodes whole", cleanResult.items.count, 2)
    T.equal("a clean file reports nothing skipped", cleanResult.skipped, 0)

    // Garbage that is not an array at all must not be mistaken for salvage.
    let notAnArray = LenientLibrary.decode(AppGroup.self, from: Data("{not json".utf8))
    T.equal("a mangled file yields nothing rather than crashing", notAnArray.items.count, 0)

    T.begin("B. Migration — end to end, through the real loaders")

    withTempDir { dir in
        let file = dir.appendingPathComponent("groups.json")
        try? Data(mixedGroups.utf8).write(to: file)
        let store = GroupStore(fileURL: file)
        T.equal("GroupStore keeps what it can read", store.groups.count, 2)
    }

    withTempDir { dir in
        let file = dir.appendingPathComponent("workspaces.json")
        try? Data(#"[{"name":"Keep"}, null, 7, {"name":"AlsoKeep"}]"#.utf8).write(to: file)
        let engine = WorkspaceEngine(fileURL: file)
        // `null` and a bare `7` are the fragments that once raised an
        // uncatchable exception in `LenientLibrary`; both must cost one entry.
        T.equal("WorkspaceEngine keeps what it can read", engine.profiles.count, 2)
    }
}
