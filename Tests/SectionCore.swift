import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
func sectionCore() {
    T.begin("A. Core model — shortcuts")

    let valid = Shortcut(keyCode: 2, modifiers: UInt32(cmdKey | optionKey), label: "D")
    T.check("a shortcut with ⌘ is valid", valid.isValid)
    T.check("shift alone is refused", !Shortcut(keyCode: 2, modifiers: UInt32(shiftKey), label: "D").isValid,
            "a bare ⇧D would swallow typing system-wide")
    T.check("no modifier is refused", !Shortcut(keyCode: 2, modifiers: 0, label: "D").isValid)
    T.equal("display order is ⌃⌥⇧⌘",
            Shortcut(keyCode: 2, modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), label: "D").display,
            "⌃ ⌥ ⇧ ⌘ D")
    // Equality ignores the label: the same physical combination recorded on a
    // different keyboard layout must still collide.
    T.check("equality ignores the drawn label",
            Shortcut(keyCode: 2, modifiers: 1_048_576, label: "D")
            == Shortcut(keyCode: 2, modifiers: 1_048_576, label: "É"))

    T.begin("A. Core model — group persistence and migration")

    // A group written by a current build must survive a round trip intact.
    var group = AppGroup(name: "Dev", colorHex: "#FF6B00")
    group.shortcut = valid
    group.isSequenced = true
    group.sequenceDelay = 1.25
    group.fillsWhenPartial = false
    group.isActive = true
    do {
        let data = try JSONEncoder().encode([group])
        let back = try JSONDecoder().decode([AppGroup].self, from: data)[0]
        T.check("round trip preserves every field",
                back.name == group.name && back.colorHex == group.colorHex
                && back.shortcut == group.shortcut && back.isSequenced
                && back.sequenceDelay == 1.25 && back.fillsWhenPartial == false
                && back.isActive && back.id == group.id)
    } catch { T.check("round trip preserves every field", false, "\(error)") }

    // Files written by older builds must still load. These are the two
    // documented legacy shapes.
    let legacyPacked = """
    [{"name":"Old","apps":[],"isActive":false,"colorHex":16739072}]
    """.data(using: .utf8)!
    if let decoded = try? JSONDecoder().decode([AppGroup].self, from: legacyPacked) {
        T.equal("legacy packed-integer colour migrates", decoded[0].colorHex, "#FF6B00")
    } else {
        T.check("legacy packed-integer colour migrates", false, "decode threw")
    }

    let legacyShortcut = """
    [{"name":"Old","apps":[],"isActive":false,"shortcutKey":"d"}]
    """.data(using: .utf8)!
    if let decoded = try? JSONDecoder().decode([AppGroup].self, from: legacyShortcut) {
        T.check("legacy bare-letter shortcut migrates to ⌥⌘",
                decoded[0].shortcut?.modifiers == UInt32(cmdKey | optionKey)
                && decoded[0].shortcut?.label == "D",
                decoded[0].shortcut?.display ?? "nil")
    } else {
        T.check("legacy bare-letter shortcut migrates to ⌥⌘", false, "decode threw")
    }

    // The minimum a decoder must tolerate: a name and nothing else.
    let bare = #"[{"name":"Bare"}]"#.data(using: .utf8)!
    if let decoded = try? JSONDecoder().decode([AppGroup].self, from: bare) {
        T.check("a group with only a name decodes with defaults",
                decoded[0].apps.isEmpty && decoded[0].fillsWhenPartial
                && decoded[0].colorHex == Theme.defaultGroupHex)
    } else {
        T.check("a group with only a name decodes with defaults", false, "decode threw")
    }

    T.begin("A. Core model — the store on disk")

    withTempDir { dir in
        let file = dir.appendingPathComponent("groups.json")
        let store = GroupStore(fileURL: file)
        T.check("a fresh store is empty", store.groups.isEmpty)

        let a = store.addGroup(named: "Work")
        _ = store.addGroup(named: "Work")
        T.equal("duplicate names are disambiguated", Set(store.groups.map(\.name)).count, 2)
        T.check("adding a group writes the file immediately",
                FileManager.default.fileExists(atPath: file.path))

        store.duplicate(a)
        T.equal("duplicating adds one", store.groups.count, 3)
        T.check("a duplicate gets a new identity", Set(store.groups.map(\.id)).count == 3)
        T.check("a duplicate is never active", store.groups.allSatisfy { !$0.isActive })

        store.rename(a, to: "   ")
        T.check("a blank rename is refused", store.groups.contains { $0.name == "Work" })

        // The real question: does what was written come back?
        let reloaded = GroupStore(fileURL: file)
        T.equal("the store reloads what it wrote", reloaded.groups.count, store.groups.count)
        T.equal("names survive the round trip",
                reloaded.groups.map(\.name).sorted(), store.groups.map(\.name).sorted())

        store.delete(a)
        let afterDelete = GroupStore(fileURL: file)
        T.equal("a delete is persisted", afterDelete.groups.count, 2)
    }

    // Corrupt data must not take the app down with it.
    withTempDir { dir in
        let file = dir.appendingPathComponent("groups.json")
        try? Data("{ this is not json".utf8).write(to: file)
        let store = GroupStore(fileURL: file)
        T.check("a corrupt store file degrades to empty rather than crashing",
                store.groups.isEmpty)
    }

    T.begin("A. Core model — app entry matching")

    // AppEntry has two running-tests that must never disagree: the allocating
    // one and the set-based one used on every telemetry tick.
    guard let finder = AppEntry(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")) else {
        T.check("Finder.app parses as an AppEntry", false, "nil")
        return
    }
    T.check("Finder.app parses as an AppEntry", true, finder.bundleID)
    T.check("a non-bundle is refused",
            AppEntry(url: URL(fileURLWithPath: "/usr/bin/zsh")) == nil)
    T.check("a missing bundle is refused",
            AppEntry(url: URL(fileURLWithPath: "/Applications/NoSuchApp.app")) == nil)

    let running = NSWorkspace.shared.runningApplications
    let ids = Set(running.compactMap(\.bundleIdentifier))
    let paths = running.compactMap { $0.bundleURL?.standardizedFileURL.path }
    T.equal("the fast running-test agrees with the slow one",
            finder.isRunning(identifiers: ids, bundlePaths: paths),
            !finder.instances(among: running).isEmpty)

    // A nested helper must count as the parent running — the documented
    // Backdrop case. Synthesised here from a path rather than a real app.
    let parent = AppEntry(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))!
    T.check("a nested helper counts as the parent running",
            parent.isRunning(identifiers: [],
                             bundlePaths: ["/System/Library/CoreServices/Finder.app/Contents/Resources/Helper.app"]))
    T.check("a sibling with a shared prefix does not",
            !parent.isRunning(identifiers: [],
                              bundlePaths: ["/System/Library/CoreServices/Finder Extras.app"]),
            "prefix matching must be path-segment aware")
}
