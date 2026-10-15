import AppKit
import ApplicationServices
import Foundation
import IOKit.pwr_mgt

/// Performs one step of a script.
///
/// Files flow through: each step receives the files the step before it handed
/// on, and returns the files it hands on in turn — the moved paths, the zip,
/// the converted results. Steps that do not touch files pass them through.
///
/// Every step is built from something the app already does: moving and
/// copying are `FileManager`, zipping is the stash's `StashExporter`, converting
/// and combining are `FileConverter` and `StashFileMerger`, and the code steps
/// are `ScriptExecutionEngine`, argv-safe exactly as before. Nothing here owns
/// a timer or a thread; file work runs on the caller's task, and the steps
/// that touch AppKit hop to the main actor for that moment only.
enum ScriptRunner {
    struct Outcome {
        var files: [URL]
        /// What the step has to say for itself, for the run history.
        var message: String
    }

    /// The parts of the app a step can reach that are not singletons.
    struct Hooks {
        var launchGroup: @MainActor (UUID) -> Bool = { _ in false }
        var activateWorkspace: @MainActor (UUID) -> Bool = { _ in false }
    }

    enum StepError: LocalizedError {
        case notSetUp
        case noFiles
        case emptyClipboard
        case failed(String)
        case missingFolder(String)
        case appNotFound(String)
        case targetGone(String)

        var errorDescription: String? {
            switch self {
            case .notSetUp: return "Not set up"
            case .noFiles: return "No files to work on"
            case .emptyClipboard: return "Nothing suitable on the clipboard"
            case .failed(let message): return message
            case .missingFolder(let path): return "\((path as NSString).lastPathComponent) does not exist"
            case .appNotFound(let id): return "\(id) is not installed"
            case .targetGone(let name): return "\(name.isEmpty ? "It" : name) is no longer there"
            }
        }
    }

    static func perform(_ step: ScriptStep, files: [URL], hooks: Hooks) async throws -> Outcome {
        guard step.isConfigured else { throw StepError.notSetUp }

        switch step.kind {
        case .moveTo, .copyTo:
            guard !files.isEmpty else { throw StepError.noFiles }
            let folder = URL(fileURLWithPath: step.folder, isDirectory: true)
            guard isFolder(folder) else { throw StepError.missingFolder(step.folder) }
            let moving = step.kind == .moveTo
            let placed = try files.map { file -> URL in
                let target = try subfolder(step.subfolder, for: file, in: folder)
                let destination = FileName.unique(file.lastPathComponent, in: target)
                if moving {
                    try FileManager.default.moveItem(at: file, to: destination)
                } else {
                    try FileManager.default.copyItem(at: file, to: destination)
                }
                return destination
            }
            return Outcome(files: placed,
                           message: "\(moving ? "Moved" : "Copied") \(count(placed)) to \(folder.lastPathComponent)")

        case .rename:
            guard !files.isEmpty else { throw StepError.noFiles }
            let renamed = try files.map { file -> URL in
                let name = step.renameStyle.apply(to: file.lastPathComponent, prefix: step.text,
                                                  date: FileFacts.dateAdded(file) ?? Date())
                guard name != file.lastPathComponent else { return file }
                let destination = FileName.unique(name, in: file.deletingLastPathComponent())
                try FileManager.default.moveItem(at: file, to: destination)
                return destination
            }
            return Outcome(files: renamed, message: "Renamed \(count(renamed))")

        case .unzip:
            let archives = files.filter { FileFamily.of($0) == .archive && $0.pathExtension.lowercased() == "zip" }
            guard !archives.isEmpty else { throw StepError.noFiles }
            var folders: [URL] = []
            for archive in archives {
                folders.append(try await StashBatchDispatcher.extract(archive, into: archive.deletingLastPathComponent()))
                try FileManager.default.trashItem(at: archive, resultingItemURL: nil)
            }
            return Outcome(files: folders, message: "Unzipped \(count(folders))")

        case .compress:
            let images = files.filter { FileFamily.of($0) == .image }
            guard !images.isEmpty else { throw StepError.noFiles }
            let compressed = try images.map(compressImage)
            return Outcome(files: compressed, message: "Compressed \(count(compressed))")

        case .tag:
            guard !files.isEmpty else { throw StepError.noFiles }
            let tag = step.text.trimmingCharacters(in: .whitespaces)
            for file in files {
                var tags = (try? file.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                guard !tags.contains(tag) else { continue }
                tags.append(tag)
                try (file as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            }
            return Outcome(files: files, message: "Tagged \(count(files)) “\(tag)”")

        case .open:
            guard !files.isEmpty else { throw StepError.noFiles }
            await MainActor.run { files.forEach { NSWorkspace.shared.open($0) } }
            return Outcome(files: files, message: "Opened \(count(files))")

        case .trash:
            guard !files.isEmpty else { throw StepError.noFiles }
            for file in files { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
            return Outcome(files: [], message: "Moved \(count(files)) to the Trash")

        case .openFolder:
            let folder = URL(fileURLWithPath: (step.folder as NSString).expandingTildeInPath, isDirectory: true)
            guard isFolder(folder) else { throw StepError.missingFolder(step.folder) }
            await MainActor.run { _ = NSWorkspace.shared.open(folder) }
            return Outcome(files: files, message: "Opened \(folder.lastPathComponent)")

        case .darkMode:
            try await appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            return Outcome(files: files, message: "Switched appearance")

        case .mute:
            try await appleScript("set volume output muted (not (output muted of (get volume settings)))")
            return Outcome(files: files, message: "Toggled mute")

        case .keepAwake:
            let on = await MainActor.run { KeepAwake.toggle(hours: step.hours) }
            return Outcome(files: files, message: on ? "Awake for \(step.hours)h" : "Sleep allowed again")

        case .lockScreen:
            try await tool("/usr/bin/pmset", ["displaysleepnow"])
            return Outcome(files: files, message: "Locked")

        case .emptyTrash:
            try await appleScript("tell application \"Finder\" to empty trash")
            return Outcome(files: files, message: "Emptied the Trash")

        case .ejectDisks:
            let ejected = try await MainActor.run { () throws -> Int in
                let volumes = FileManager.default.mountedVolumeURLs(
                    includingResourceValuesForKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey],
                    options: [.skipHiddenVolumes]) ?? []
                let removable = volumes.filter { volume in
                    let values = try? volume.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey])
                    return values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
                }
                for volume in removable { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
                return removable.count
            }
            return Outcome(files: files, message: ejected == 0 ? "Nothing to eject" : "Ejected \(ejected)")

        case .openStash:
            await MainActor.run { _ = ShelfWindowManager.shared.spawnShelf(at: NSEvent.mouseLocation, with: files) }
            return Outcome(files: files, message: "Opened a stash")

        case .toggleStashes:
            await MainActor.run { ShelfWindowManager.shared.toggleHidden() }
            return Outcome(files: files, message: "Toggled stashes")

        case .cleanText, .cleanLink, .changeCase:
            let changed = await MainActor.run { () -> Bool in
                guard let text = NSPasteboard.general.string(forType: .string) else { return false }
                let result: String
                switch step.kind {
                case .cleanText: result = TextTools.clean(text)
                case .cleanLink: result = TextTools.cleanLinks(text)
                default: result = TextTools.change(text, to: step.caseStyle)
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                return true
            }
            guard changed else { throw StepError.emptyClipboard }
            return Outcome(files: files, message: step.kind.label)

        case .saveClipboardImage:
            let folder = step.folder.isEmpty
                ? await MainActor.run { AppSettings.shared.exportDirectory }
                : URL(fileURLWithPath: step.folder, isDirectory: true)
            let data = await MainActor.run { () -> Data? in
                guard let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation else { return nil }
                return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            }
            guard let data else { throw StepError.emptyClipboard }
            let name = RenameStyle.datePrefix.apply(to: "Clipboard.png")
            let file = FileName.unique(name, in: folder)
            try data.write(to: file)
            return Outcome(files: [file], message: file.lastPathComponent)

        case .snippet:
            let pasted = await MainActor.run { () -> Bool in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(step.text, forType: .string)
                return Paste.intoFrontmostApp()
            }
            return Outcome(files: files, message: pasted ? "Pasted" : "Copied — paste with ⌘V")

        case .runShortcut:
            let name = step.text.trimmingCharacters(in: .whitespaces)
            var arguments = ["run", name]
            for file in files { arguments += ["--input-path", file.path] }
            try await tool("/usr/bin/shortcuts", arguments)
            return Outcome(files: files, message: "Ran “\(name)”")

        case .zip:
            guard !files.isEmpty else { throw StepError.noFiles }
            let folder = step.folder.isEmpty
                ? await MainActor.run { AppSettings.shared.exportDirectory }
                : URL(fileURLWithPath: step.folder, isDirectory: true)
            let archive = try await StashExporter.export(
                items: files.map { (name: $0.lastPathComponent, url: $0, text: nil) }, to: folder)
            return Outcome(files: [archive], message: archive.lastPathComponent)

        case .convert:
            guard !files.isEmpty else { throw StepError.noFiles }
            let target = FileConverter.Target(label: step.format.uppercased(), ext: step.format)
            let results = try await FileConverter.convert(files, to: target)
            return Outcome(files: results, message: "Converted \(count(results)) to \(target.label)")

        case .combinePDF:
            guard files.count > 1 else { throw StepError.noFiles }
            let merged = try StashFileMerger.combine(files)
            return Outcome(files: [merged], message: merged.lastPathComponent)

        case .stash:
            guard !files.isEmpty else { throw StepError.noFiles }
            await MainActor.run { _ = ShelfWindowManager.shared.spawnShelf(at: NSEvent.mouseLocation, with: files) }
            return Outcome(files: files, message: "Stashed \(count(files))")

        case .reveal:
            guard !files.isEmpty else { throw StepError.noFiles }
            await MainActor.run { _ = FinderUtility.revealAndFocus(urls: files) }
            return Outcome(files: files, message: "Revealed \(count(files))")

        case .openApp:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: step.appBundleID) else {
                throw StepError.appNotFound(step.appName.isEmpty ? step.appBundleID : step.appName)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            if files.isEmpty {
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            } else {
                _ = try await NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration)
            }
            return Outcome(files: files, message: "Opened \(step.summary)")

        case .quitApp, .hideApp:
            let quitting = step.kind == .quitApp
            let touched = await MainActor.run { () -> Int in
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: step.appBundleID)
                for app in running {
                    if quitting { app.terminate() } else { app.hide() }
                }
                return running.count
            }
            return Outcome(files: files,
                           message: touched == 0 ? "\(step.summary) was not running"
                                                 : "\(quitting ? "Quit" : "Hid") \(step.summary)")

        case .launchGruppe, .activateWorkspace:
            guard let id = step.targetID else { throw StepError.notSetUp }
            let found = await MainActor.run {
                step.kind == .launchGruppe ? hooks.launchGroup(id) : hooks.activateWorkspace(id)
            }
            guard found else { throw StepError.targetGone(step.targetName) }
            return Outcome(files: files, message: "Started \(step.summary)")

        case .openURL:
            guard let url = URL(string: step.url) else { throw StepError.notSetUp }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return Outcome(files: files, message: "Opened \(url.host ?? step.url)")

        case .webhook, .shell, .javascript, .applescript:
            let run = try await ScriptExecutionEngine.run(step.code, paths: files)
            return Outcome(files: files, message: run.transcript)

        case .wait:
            try await Task.sleep(nanoseconds: UInt64(step.seconds) * 1_000_000_000)
            return Outcome(files: files, message: "Waited \(step.seconds)s")
        }
    }

    // MARK: Helpers

    /// The folder inside `folder` a file goes into: itself, a month folder
    /// (`2026-10`), or one named after the site it was downloaded from.
    private static func subfolder(_ style: ScriptStep.Subfolder, for file: URL, in folder: URL) throws -> URL {
        let name: String
        switch style {
        case .none: return folder
        case .month:
            name = Stamp.month(FileFacts.dateAdded(file) ?? Date())
        case .site:
            name = FileFacts.whereFroms(file).compactMap { URL(string: $0)?.host }
                .last.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "Other"
        }
        let target = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// The image as a 75%-quality JPEG in its place; the original goes to the
    /// Trash when it was not already a JPEG, so a compression can be undone.
    private static func compressImage(_ file: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw StepError.failed("\(file.lastPathComponent) is not an image") }
        let isJPEG = ["jpg", "jpeg"].contains(file.pathExtension.lowercased())
        let output = isJPEG ? file : FileName.unique(file.deletingPathExtension().lastPathComponent + ".jpg",
                                               in: file.deletingLastPathComponent())
        let staging = output.deletingLastPathComponent().appendingPathComponent(".gruppen-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw StepError.failed("Couldn't write \(output.lastPathComponent)") }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw StepError.failed("Couldn't write \(output.lastPathComponent)")
        }
        if isJPEG {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: output)
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        return output
    }

    /// Runs a few lines of AppleScript on the main actor, where NSAppleScript
    /// has to live. The first run of one that controls another app asks for
    /// Automation permission; a refusal comes back as the error.
    private static func appleScript(_ source: String) async throws {
        let failure = await MainActor.run { () -> String? in
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            return error?[NSAppleScript.errorMessage] as? String
        }
        if let failure { throw StepError.failed(failure) }
    }

    /// Runs a system tool; a failure carries the tool's own words.
    private static func tool(_ path: String, _ arguments: [String]) async throws {
        let result = try await Tool.run(path, arguments)
        guard result.succeeded else { throw StepError.failed(result.failure) }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func count(_ files: [URL]) -> String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }
}

/// Holds the Mac awake for a while: one power assertion, released when its
/// time is up or when it is toggled off. One scheduled release, not a timer
/// that ticks.
@MainActor
enum KeepAwake {
    private static var assertion: IOPMAssertionID?
    private static var release: DispatchWorkItem?

    /// Returns whether the Mac is now being kept awake.
    static func toggle(hours: Int) -> Bool {
        if let current = assertion {
            IOPMAssertionRelease(current)
            assertion = nil
            release?.cancel()
            return false
        }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Gruppen keep awake" as CFString, &id) == kIOReturnSuccess
        else { return false }
        assertion = id
        let work = DispatchWorkItem { _ = toggle(hours: 0) }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(hours * 3600), execute: work)
        return true
    }
}

/// ⌘V into whatever app is in front — only with Accessibility granted, since
/// posting keystrokes needs it. Without it the text is simply on the
/// clipboard, which is said in the run's message.
@MainActor
enum Paste {
    static func intoFrontmostApp() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        return true
    }
}
