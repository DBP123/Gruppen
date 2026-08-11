import AppKit
import Foundation

/// Static, deterministic Gruppe suggestions.
///
/// No heuristics and no background indexing: each rule lists candidate app
/// bundles, and a rule matches when at least two of them are physically on
/// disk. Matching is a handful of `fileExists` calls, which is cheap enough to
/// run on demand and never needs a timer.
enum Presets {
    struct Rule: Identifiable {
        let id: String
        let name: String
        let colorHex: String
        /// Bundle names as they appear on disk, e.g. "Visual Studio Code.app".
        let bundleNames: [String]
        /// Bundle identifiers, used to catch apps installed somewhere unusual.
        let bundleIDs: [String]
    }

    /// Where applications legitimately live. `~/Applications` matters for
    /// per-user installs; `/System/Applications` for Apple's own.
    static var searchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
        ]
    }

    static let rules: [Rule] = [
        Rule(id: "dev",
             name: "Dev & Engineering",
             colorHex: "#FF6B00",
             bundleNames: ["Visual Studio Code.app", "Ghostty.app", "Docker.app", "iTerm.app",
                           "Xcode.app", "Terminal.app", "GitHub Desktop.app", "Cursor.app",
                           "Sublime Text.app", "Warp.app"],
             bundleIDs: ["com.microsoft.VSCode", "com.mitchellh.ghostty", "com.docker.docker",
                         "com.googlecode.iterm2", "com.apple.dt.Xcode", "com.apple.Terminal",
                         "com.github.GitHubClient", "com.todesktop.230313mzl4w4u92",
                         "com.sublimetext.4", "dev.warp.Warp-Stable"]),

        Rule(id: "motorsport",
             name: "Sim Racing & Hardware",
             colorHex: "#E10600",
             bundleNames: ["Assetto Corsa.app", "Content Manager.app", "Fanatec Control Panel.app",
                           "SimHub.app", "iRacing.app", "Steam.app", "Discord.app"],
             bundleIDs: ["com.valvesoftware.steam", "com.hicorp.simhub", "com.fanatec.controlpanel",
                         "com.iracing.launcher", "com.hnsgames.discord", "com.discordapp.Discord"]),

        Rule(id: "design",
             name: "Design & CAD",
             colorHex: "#88E600",
             bundleNames: ["Figma.app", "Blender.app", "Adobe Photoshop 2024.app",
                           "Adobe Illustrator 2024.app", "Sketch.app", "Affinity Designer 2.app",
                           "Fusion 360.app", "Cinema 4D.app"],
             bundleIDs: ["com.figma.Desktop", "org.blenderfoundation.blender",
                         "com.adobe.Photoshop", "com.adobe.illustrator", "com.bohemiancoding.sketch3",
                         "com.seriflabs.affinitydesigner2", "com.autodesk.fusion360"]),

        Rule(id: "comms",
             name: "Comms",
             colorHex: "#0051A8",
             bundleNames: ["Slack.app", "Discord.app", "zoom.us.app", "Microsoft Teams.app",
                           "Signal.app", "Telegram.app", "Microsoft Outlook.app"],
             bundleIDs: ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "us.zoom.xos",
                         "com.microsoft.teams2", "org.whispersystems.signal-desktop",
                         "ru.keepcoder.Telegram", "com.microsoft.Outlook"]),

        Rule(id: "focus",
             name: "Focus & Writing",
             colorHex: "#FAD02C",
             bundleNames: ["Obsidian.app", "Notion.app", "Bear.app", "Ulysses.app",
                           "Spotify.app", "Notes.app", "Music.app", "Things3.app"],
             bundleIDs: ["md.obsidian", "notion.id", "net.shinyfrog.bear", "com.ulyssesapp.mac",
                         "com.spotify.client", "com.apple.Notes", "com.apple.Music",
                         "com.culturedcode.ThingsMac"]),
    ]

    // MARK: - Matching

    struct Match: Identifiable {
        let rule: Rule
        let urls: [URL]
        var id: String { rule.id }
        var name: String { rule.name }
        var colorHex: String { rule.colorHex }
        var count: Int { urls.count }
    }

    /// Resolves a rule using `FileManager` only. Safe to call off the main
    /// actor, which is what the rescan does.
    static func locateOnDisk(_ rule: Rule) -> [URL] {
        var found: [URL] = []
        var seen: Set<String> = []
        for directory in searchDirectories {
            for bundleName in rule.bundleNames {
                let candidate = directory.appendingPathComponent(bundleName)
                if !seen.contains(candidate.path),
                   FileManager.default.fileExists(atPath: candidate.path) {
                    seen.insert(candidate.path)
                    found.append(candidate)
                }
            }
        }
        return found
    }

    /// Adds anything installed off the beaten path, resolved by bundle
    /// identifier. Uses `NSWorkspace`, so call it from the main actor.
    static func locate(_ rule: Rule) -> [URL] {
        var found = locateOnDisk(rule)
        var seen = Set(found.map(\.path))
        for bundleID in rule.bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  !seen.contains(url.path) else { continue }
            seen.insert(url.path)
            found.append(url)
        }
        return found
    }

    /// Rules with at least `minimum` apps present, strongest match first.
    static func matches(minimum: Int = 2) -> [Match] {
        assemble(minimum: minimum, resolver: locate)
    }

    /// `matches` without the LaunchServices lookups — usable off the main actor.
    static func matchesOnDisk(minimum: Int = 2) -> [Match] {
        assemble(minimum: minimum, resolver: locateOnDisk)
    }

    private static func assemble(minimum: Int, resolver: (Rule) -> [URL]) -> [Match] {
        rules
            .map { Match(rule: $0, urls: resolver($0)) }
            .filter { $0.urls.count >= minimum }
            .sorted { $0.urls.count > $1.urls.count }
    }

    /// Total `.app` bundles visible in the search paths — the "indexed" count.
    static func indexedApplicationCount() -> Int {
        var total = 0
        for directory in searchDirectories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }
            total += contents.filter { $0.pathExtension == "app" }.count
        }
        return total
    }
}
