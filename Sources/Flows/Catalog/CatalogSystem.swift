import AppKit
import CoreWLAN
import Foundation

extension Catalog {
    // MARK: Apps

    static let apps: [BlockDefinition] = [
        BlockDefinition("apps.open", "Open app", category: .apps, glyph: "macwindow",
                        phrase: "Open {app}", inputs: [Port("app", "App", .text, .app)], essential: true,
                        .builtIn { context in
                            let app = try Apps.url(context.text("app"))
                            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                            return ["message": .text("Opened \(Apps.name(context.text("app")))")]
                        }),
        BlockDefinition("apps.quit", "Quit app", category: .apps, glyph: "power",
                        phrase: "Quit {app}", inputs: [Port("app", "App", .text, .app)],
                        .builtIn { try await Apps.each($0.text("app"), "Quit") { $0.terminate() } }),
        BlockDefinition("apps.hide", "Hide app", category: .apps, glyph: "eye.slash",
                        phrase: "Hide {app}", inputs: [Port("app", "App", .text, .app)],
                        .builtIn { try await Apps.each($0.text("app"), "Hid") { $0.hide() } }),
        BlockDefinition("apps.frontmost", "Frontmost app", category: .apps, glyph: "macwindow.on.rectangle",
                        outputs: [Port("name", "Name", .text), Port("app", "Bundle id", .text)],
                        .builtIn { _ in
                            await MainActor.run {
                                let app = NSWorkspace.shared.frontmostApplication
                                return ["name": .text(app?.localizedName ?? ""), "app": .text(app?.bundleIdentifier ?? "")]
                            }
                        }),
        BlockDefinition("apps.isRunning", "Is app running", category: .apps, glyph: "app.connected.to.app.below.fill",
                        phrase: "Is {app} running", inputs: [Port("app", "App", .text, .app)],
                        outputs: [Port("running", "Running", .bool)],
                        .builtIn { context in
                            let id = context.text("app")
                            let running = await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
                            return ["running": .bool(running)]
                        }),
        BlockDefinition("apps.openURL", "Open link", category: .apps, glyph: "link",
                        phrase: "Open {url}", inputs: [Port("url", "Link", .text, default: .text("https://"))],
                        .builtIn { context in
                            let raw = try context.requireText("url", "No link given")
                            guard let url = URL(string: raw), url.scheme != nil else { throw FlowError.failed("“\(raw)” isn't a link") }
                            await MainActor.run { _ = NSWorkspace.shared.open(url) }
                            return ["message": .text("Opened \(url.host ?? raw)")]
                        }),
        BlockDefinition("apps.openFolder", "Open folder", category: .apps, glyph: "folder",
                        phrase: "Open folder {folder}", inputs: [Port("folder", "Folder", .text, .folder)],
                        .builtIn { context in
                            let folder = try context.folder()
                            await MainActor.run { _ = NSWorkspace.shared.open(folder) }
                            return ["message": .text("Opened \(folder.lastPathComponent)")]
                        }),
        BlockDefinition("apps.shortcut", "Run a Shortcut", category: .apps, glyph: "square.stack.3d.up",
                        phrase: "Run the Shortcut {name}",
                        help: "From the Shortcuts app. Files or text go in as its input; what it outputs comes back",
                        inputs: [Port("name", "Shortcut", .text), Port("input", "Input", .any, .text, optional: true)],
                        outputs: [Port("output", "Output", .text)],
                        .builtIn { context in
                            let name = try context.requireText("name", "No Shortcut named")
                            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gruppen-shortcut-\(UUID().uuidString)")
                            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                            defer { try? FileManager.default.removeItem(at: scratch) }
                            let outputFile = scratch.appendingPathComponent("output")
                            var arguments = ["run", name, "--output-path", outputFile.path]
                            switch context.value("input") {
                            case .nothing: break
                            case .files(let urls): urls.forEach { arguments += ["--input-path", $0.path] }
                            case let other:
                                let inputFile = scratch.appendingPathComponent("input.txt")
                                try RunMemory.inline(other).write(to: inputFile, atomically: true, encoding: .utf8)
                                arguments += ["--input-path", inputFile.path]
                            }
                            try await Apps.tool("/usr/bin/shortcuts", arguments, timeout: context.run.remaining)
                            let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
                            return ["output": .text(output.trimmingCharacters(in: .whitespacesAndNewlines))]
                        }),
    ]

    // MARK: System

    static let system: [BlockDefinition] = [
        BlockDefinition("system.appearance", "Light or dark", category: .system, glyph: "circle.lefthalf.filled",
                        phrase: "Switch to {mode}",
                        inputs: [Port("mode", "Mode", .text, .choice, default: .text("the other one"),
                                      choices: ["the other one", "Dark Mode", "Light Mode"])],
                        permissions: [.automation("com.apple.systemevents")],
                        .builtIn { context in
                            let wanted: String
                            switch context.text("mode") {
                            case "Dark Mode": wanted = "true"
                            case "Light Mode": wanted = "false"
                            default: wanted = "not dark mode"
                            }
                            try await Apps.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(wanted)")
                            return ["message": .text("Switched appearance")]
                        }),
        BlockDefinition("system.volume", "Set volume", category: .system, glyph: "speaker.wave.2",
                        phrase: "Set volume to {level} %",
                        inputs: [Port("level", "Volume %", .number, default: .number(50))],
                        .builtIn { context in
                            let level = Int(min(100, max(0, context.number("level"))))
                            try await Apps.appleScript("set volume output volume \(level) without output muted")
                            return ["message": .text("Volume \(level)%")]
                        }),
        BlockDefinition("system.mute", "Mute", category: .system, glyph: "speaker.slash",
                        phrase: "{mode} the sound",
                        inputs: [Port("mode", "Mode", .text, .choice, default: .text("Toggle"),
                                      choices: ["Toggle", "Mute", "Unmute"])],
                        .builtIn { context in
                            let wanted = ["Mute": "true", "Unmute": "false"][context.text("mode")]
                                ?? "not (output muted of (get volume settings))"
                            try await Apps.appleScript("set volume output muted \(wanted)")
                            return ["message": .text("Sound \(context.text("mode").lowercased())")]
                        }),
        BlockDefinition("system.say", "Speak", category: .system, glyph: "waveform",
                        phrase: "Say {text}", inputs: [Port("text", "Text", .text)],
                        .builtIn { context in
                            try await Apps.tool("/usr/bin/say", [context.text("text")], timeout: context.run.remaining)
                            return [:]
                        }),
        BlockDefinition("system.keepAwake", "Keep awake", category: .system, glyph: "cup.and.saucer",
                        phrase: "Keep the Mac awake for {hours} hours",
                        help: "Run it again to let the Mac sleep",
                        inputs: [Port("hours", "Hours", .number, default: .number(1))],
                        outputs: [Port("awake", "Kept awake", .bool)],
                        .builtIn { context in
                            let hours = max(1, Int(context.number("hours")))
                            let on = await MainActor.run { KeepAwake.toggle(hours: hours) }
                            return ["awake": .bool(on), "message": .text(on ? "Awake for \(hours)h" : "Sleep allowed again")]
                        }),
        BlockDefinition("system.lock", "Lock screen", category: .system, glyph: "lock",
                        .builtIn { _ in
                            try await Apps.tool("/usr/bin/pmset", ["displaysleepnow"])
                            return ["message": .text("Locked")]
                        }),
        BlockDefinition("system.emptyTrash", "Empty Trash", category: .system, glyph: "trash.slash",
                        permissions: [.automation("com.apple.finder")],
                        .builtIn { _ in
                            try await Apps.appleScript("tell application \"Finder\" to empty trash")
                            return ["message": .text("Emptied the Trash")]
                        }),
        BlockDefinition("system.eject", "Eject disks", category: .system, glyph: "eject",
                        .builtIn { _ in
                            let ejected = try await MainActor.run { () throws -> Int in
                                let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey]
                                let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                                                    options: [.skipHiddenVolumes]) ?? []
                                let removable = volumes.filter { volume in
                                    let values = try? volume.resourceValues(forKeys: Set(keys))
                                    return values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
                                }
                                for volume in removable { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
                                return removable.count
                            }
                            return ["message": .text(ejected == 0 ? "Nothing to eject" : "Ejected \(ejected)")]
                        }),
        BlockDefinition("system.battery", "Battery", category: .system, glyph: "battery.75percent",
                        outputs: [Port("percent", "Level %", .number), Port("charging", "Charging", .bool),
                                  Port("plugged", "On power", .bool)],
                        .builtIn { _ in
                            let power = PowerSource.current()
                            return ["percent": power.percent.map { .number(Double($0)) } ?? .nothing,
                                    "charging": .bool(power.isCharging), "plugged": .bool(power.onExternalPower)]
                        }),
        BlockDefinition("system.wifi", "Wi-Fi network", category: .system, glyph: "wifi",
                        help: "macOS only gives apps the name with Location Services on",
                        outputs: [Port("network", "Network", .text)], permissions: [.location],
                        .builtIn { _ in ["network": .text(CWWiFiClient.shared().interface()?.ssid() ?? "")] }),
    ]

    // MARK: Gruppen

    static let gruppen: [BlockDefinition] = [
        BlockDefinition("gruppen.launch", "Launch a Gruppe", category: .gruppen, glyph: "square.grid.2x2",
                        phrase: "Launch {gruppe}", inputs: [Port("gruppe", "Gruppe", .text, .gruppe)],
                        .builtIn { try await target($0, "gruppe", $0.hooks.launchGroup, "Launched") }),
        BlockDefinition("gruppen.close", "Close a Gruppe", category: .gruppen, glyph: "xmark.square",
                        phrase: "Close {gruppe}", inputs: [Port("gruppe", "Gruppe", .text, .gruppe)],
                        .builtIn { try await target($0, "gruppe", $0.hooks.closeGroup, "Closed") }),
        BlockDefinition("gruppen.workspace", "Activate a workspace", category: .gruppen, glyph: "rectangle.3.group",
                        phrase: "Switch to {workspace}", inputs: [Port("workspace", "Workspace", .text, .workspace)],
                        .builtIn { try await target($0, "workspace", $0.hooks.activateWorkspace, "Activated") }),
        BlockDefinition("gruppen.openStash", "Open a stash", category: .gruppen, glyph: "tray",
                        phrase: "Open a stash with {files}", inputs: [Port("files", "Files", .files, optional: true)],
                        .builtIn { context in
                            let files = context.files("files")
                            await MainActor.run { _ = ShelfWindowManager.shared.spawnShelf(at: NSEvent.mouseLocation, with: files) }
                            return ["message": .text("Opened a stash")]
                        }),
        BlockDefinition("gruppen.toggleStashes", "Hide or show stashes", category: .gruppen, glyph: "tray.2",
                        .builtIn { _ in
                            await MainActor.run { ShelfWindowManager.shared.toggleHidden() }
                            return ["message": .text("Toggled stashes")]
                        }),
    ]

    /// A Gruppe or workspace input holds "uuid|name": the id finds it, the
    /// name says what it was if it has gone.
    private static func target(_ context: BlockContext, _ port: String,
                               _ act: @escaping @MainActor @Sendable (UUID) -> Bool, _ verb: String) async throws -> [String: Value] {
        let (id, name) = Pick.split(context.text(port))
        guard let id else { throw FlowError.notSetUp("Nothing chosen") }
        guard await act(id) else { throw FlowError.targetGone(name) }
        return ["message": .text("\(verb) \(name)")]
    }

    // MARK: Clipboard

    static let clipboard: [BlockDefinition] = [
        BlockDefinition("clip.get", "Get clipboard", category: .clipboard, glyph: "doc.on.clipboard",
                        outputs: [Port("text", "Text", .text), Port("files", "Files", .files)], essential: true,
                        .builtIn { _ in
                            await MainActor.run {
                                let board = NSPasteboard.general
                                let files = (board.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                                return ["text": .text(board.string(forType: .string) ?? ""), "files": .files(files)]
                            }
                        }),
        BlockDefinition("clip.set", "Copy", category: .clipboard, glyph: "doc.on.doc.fill",
                        phrase: "Copy {value}", inputs: [Port("value", "Value", .any, .text)],
                        .builtIn { context in
                            let value = context.value("value")
                            await MainActor.run {
                                let board = NSPasteboard.general
                                board.clearContents()
                                if case .files(let urls) = value { board.writeObjects(urls as [NSURL]) }
                                else { board.setString(RunMemory.inline(value), forType: .string) }
                            }
                            return ["message": .text("Copied \(value.summary)")]
                        }),
        BlockDefinition("clip.clean", "Clean copied text", category: .clipboard, glyph: "text.badge.checkmark",
                        phrase: "Clean the copied {what}",
                        help: "Text: plain quotes and dashes, tidy spaces. A link: tracking parameters removed",
                        inputs: [Port("what", "What", .text, .choice, default: .text("text"), choices: ["text", "link"])],
                        outputs: [Port("text", "Clean text", .text)],
                        .builtIn { context in
                            let link = context.text("what") == "link"
                            let cleaned = await MainActor.run { () -> String? in
                                guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
                                let result = link ? TextTools.cleanLinks(text) : TextTools.clean(text)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result, forType: .string)
                                return result
                            }
                            guard let cleaned else { throw FlowError.failed("There's no text on the clipboard") }
                            return ["text": .text(cleaned)]
                        }),
        BlockDefinition("clip.saveImage", "Save copied image", category: .clipboard, glyph: "photo.on.rectangle",
                        phrase: "Save the copied image to {folder}",
                        inputs: [Port("folder", "Folder", .text, .folder, help: "Empty: the stash export folder", optional: true)],
                        outputs: [Port("file", "Image", .files)],
                        .builtIn { context in
                            let folder = try await FileOps.outputFolder(context)
                            let data = await MainActor.run { () -> Data? in
                                guard let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation else { return nil }
                                return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                            }
                            guard let data else { throw FlowError.failed("There's no image on the clipboard") }
                            let file = FileName.unique(RenameStyle.datePrefix.apply(to: "Clipboard.png"), in: folder)
                            try data.write(to: file)
                            return ["file": .files([file])]
                        }),
        BlockDefinition("clip.paste", "Paste text", category: .clipboard, glyph: "text.insert",
                        phrase: "Paste {text}",
                        help: "Into the app in front. Typing it in needs Accessibility; without it the text is left on the clipboard",
                        inputs: [Port("text", "Text", .text, .multiline)], permissions: [.accessibility],
                        .builtIn { context in
                            let text = context.text("text")
                            let pasted = await MainActor.run { () -> Bool in
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                return Paste.intoFrontmostApp()
                            }
                            return ["message": .text(pasted ? "Pasted" : "Copied — paste with ⌘V")]
                        }),
    ]
}

/// Apps by bundle identifier, and the system tools blocks call.
enum Apps {
    static func url(_ bundleID: String) throws -> URL {
        guard !bundleID.isEmpty else { throw FlowError.notSetUp("No app chosen") }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw FlowError.appNotFound(bundleID)
        }
        return url
    }

    /// The app's name as Finder shows it, or the identifier when it is not
    /// installed.
    static func name(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func each(_ bundleID: String, _ verb: String,
                     _ act: @escaping @MainActor @Sendable (NSRunningApplication) -> Void) async throws -> [String: Value] {
        guard !bundleID.isEmpty else { throw FlowError.notSetUp("No app chosen") }
        let touched = await MainActor.run { () -> Int in
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            running.forEach(act)
            return running.count
        }
        return ["message": .text(touched == 0 ? "\(name(bundleID)) was not running" : "\(verb) \(name(bundleID))")]
    }

    /// A few lines of AppleScript through osascript, so it can be stopped.
    /// The first run that controls another app asks for Automation
    /// permission; a refusal comes back as the error, translated.
    static func appleScript(_ source: String) async throws {
        let result = try await Tool.run("/usr/bin/osascript", ["-e", source], timeout: 30)
        guard result.succeeded else {
            throw FlowError.failed(Permissions.explain(result.failure) ?? result.failure)
        }
    }

    static func tool(_ path: String, _ arguments: [String], timeout: TimeInterval? = 60) async throws {
        let result = try await Tool.run(path, arguments, timeout: timeout)
        guard result.succeeded else { throw FlowError.failed(Permissions.explain(result.failure) ?? result.failure) }
    }
}

/// Picker values stored as "id|name".
enum Pick {
    static func join(_ id: UUID, _ name: String) -> String { "\(id.uuidString)|\(name)" }

    static func split(_ value: String) -> (UUID?, String) {
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        return (parts.first.flatMap(UUID.init(uuidString:)), parts.count > 1 ? parts[1] : value)
    }
}
