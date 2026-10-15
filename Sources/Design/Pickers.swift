import AppKit
import UniformTypeIdentifiers

/// Every "choose a file, folder or app" panel in Gruppen, built one way.
@MainActor
enum Pickers {
    static func folder(title: String, prompt: String = "Choose", startingAt start: URL? = nil) -> URL? {
        choose(title: title, prompt: prompt, folders: true, in: start).first
    }

    static func folders(title: String) -> [URL] {
        choose(title: title, prompt: "Add", folders: true, multiple: true)
    }

    static func files(title: String, prompt: String) -> [URL] {
        choose(title: title, prompt: prompt, files: true, folders: true, multiple: true)
    }

    static func apps(title: String = "Add Applikationen") -> [URL] {
        choose(title: title, prompt: "Add", files: true, multiple: true,
               types: [.application], in: URL(fileURLWithPath: "/Applications"))
    }

    /// One app, as its bundle identifier and the name Finder shows.
    static func app() -> (bundleID: String, name: String)? {
        guard let url = choose(title: "Which application?", prompt: "Choose", files: true,
                               types: [.application], in: URL(fileURLWithPath: "/Applications")).first,
              let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return (identifier, name)
    }

    private static func choose(title: String, prompt: String,
                               files: Bool = false, folders: Bool = false, multiple: Bool = false,
                               types: [UTType] = [], in directory: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = files
        panel.canChooseDirectories = folders
        panel.canCreateDirectories = folders
        panel.allowsMultipleSelection = multiple
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.urls : []
    }
}
