import AppKit
import Foundation

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
        case missingFolder(String)
        case appNotFound(String)
        case targetGone(String)

        var errorDescription: String? {
            switch self {
            case .notSetUp: return "Not set up"
            case .noFiles: return "No files to work on"
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
                let destination = uniqueURL(for: file.lastPathComponent, in: folder)
                if moving {
                    try FileManager.default.moveItem(at: file, to: destination)
                } else {
                    try FileManager.default.copyItem(at: file, to: destination)
                }
                return destination
            }
            return Outcome(files: placed,
                           message: "\(moving ? "Moved" : "Copied") \(count(placed)) to \(folder.lastPathComponent)")

        case .zip:
            guard !files.isEmpty else { throw StepError.noFiles }
            let folder = step.folder.isEmpty
                ? await MainActor.run { AppSettings.shared.exportDirectory }
                : URL(fileURLWithPath: step.folder, isDirectory: true)
            let archive = try StashExporter.export(
                items: files.map { (name: $0.lastPathComponent, url: $0, text: nil) }, to: folder)
            return Outcome(files: [archive], message: archive.lastPathComponent)

        case .convert:
            guard !files.isEmpty else { throw StepError.noFiles }
            let target = FileConverter.Target(label: step.format.uppercased(), ext: step.format)
            let results = try FileConverter.convert(files, to: target)
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

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `name`, or `name 2`, `name 3`… — never over an existing file.
    static func uniqueURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    private static func count(_ files: [URL]) -> String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }
}
