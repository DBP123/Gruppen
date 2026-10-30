import AppKit
import Foundation
import ImageIO

extension Catalog {
    static let files: [BlockDefinition] = [
        BlockDefinition("files.move", "Move", category: .files, glyph: "arrow.right.square",
                        phrase: "Move {files} to {folder}",
                        inputs: [filesIn, Port("folder", "Folder", .text, .folder), sortIn],
                        outputs: [filesOut("Moved files")], essential: true,
                        .builtIn { try place($0, moving: true) }),
        BlockDefinition("files.copy", "Copy", category: .files, glyph: "doc.on.doc",
                        phrase: "Copy {files} to {folder}",
                        inputs: [filesIn, Port("folder", "Folder", .text, .folder), sortIn],
                        outputs: [filesOut("Copies")], .builtIn { try place($0, moving: false) }),
        BlockDefinition("files.rename", "Rename", category: .files, glyph: "character.cursor.ibeam",
                        phrase: "Rename {files} to {pattern}",
                        help: "{name} the name now, {ext} its extension, {date} the day it arrived, {today}, {n} a count, {folder} the folder it is in",
                        inputs: [filesIn, Port("pattern", "Pattern", .text, default: .text("{date} {name}")),
                                 Port("tidy", "Tidy up", .bool, default: .bool(false),
                                      help: "Drop browsers' “ (1)” and collapse spaces and underscores")],
                        outputs: [filesOut("Renamed files")], essential: true,
                        .builtIn { context in
                            let files = try context.requireFiles()
                            let pattern = context.text("pattern")
                            let renamed = try files.enumerated().map { index, file -> URL in
                                var name = FileOps.name(for: file, pattern: pattern, index: index + 1)
                                if context.flag("tidy") { name = RenameStyle.clean.apply(to: name) }
                                guard name != file.lastPathComponent, !name.isEmpty else { return file }
                                let destination = FileName.unique(name, in: file.deletingLastPathComponent())
                                try FileManager.default.moveItem(at: file, to: destination)
                                return destination
                            }
                            return ["files": .files(renamed), "message": .text("Renamed \(FileOps.count(renamed))")]
                        }),
        BlockDefinition("files.zip", "Zip", category: .files, glyph: "doc.zipper",
                        phrase: "Zip {files}",
                        inputs: [filesIn, Port("folder", "Into folder", .text, .folder,
                                               help: "Empty: the stash export folder", optional: true)],
                        outputs: [Port("zip", "Zip", .files)], essential: true,
                        .builtIn { context in
                            let files = try context.requireFiles()
                            let folder = try await FileOps.outputFolder(context)
                            let archive = try await StashExporter.export(
                                items: files.map { (name: $0.lastPathComponent, url: $0, text: nil) }, to: folder)
                            return ["zip": .files([archive])]
                        }),
        BlockDefinition("files.unzip", "Unzip", category: .files, glyph: "archivebox",
                        phrase: "Unzip {files}",
                        help: "Each archive is unpacked beside itself and goes to the Trash",
                        inputs: [filesIn], outputs: [Port("folders", "Folders", .files)],
                        .builtIn { context in
                            let archives = try context.requireFiles().filter { $0.pathExtension.lowercased() == "zip" }
                            guard !archives.isEmpty else { throw FlowError.failed("None of these is a .zip") }
                            var folders: [URL] = []
                            for archive in archives {
                                folders.append(try await StashBatchDispatcher.extract(archive, into: archive.deletingLastPathComponent()))
                                try FileManager.default.trashItem(at: archive, resultingItemURL: nil)
                            }
                            return ["folders": .files(folders)]
                        }),
        BlockDefinition("files.convert", "Convert", category: .files, glyph: "arrow.triangle.2.circlepath",
                        phrase: "Convert {files} to {format}",
                        help: "Images (png, jpg, heic, pdf…), documents to pdf, audio (m4a, mp3, wav…)",
                        inputs: [filesIn, Port("format", "Format", .text, default: .text("png"))],
                        outputs: [filesOut("Converted files")],
                        .builtIn { context in
                            let format = try context.requireText("format", "No format chosen")
                                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                            let target = FileConverter.Target(label: format.uppercased(), ext: format)
                            return ["files": .files(try await FileConverter.convert(try context.requireFiles(), to: target))]
                        }),
        BlockDefinition("files.compress", "Compress images", category: .files, glyph: "arrow.down.right.and.arrow.up.left",
                        phrase: "Compress images {files}",
                        help: "Each becomes a JPEG in its place; an original that was not one goes to the Trash",
                        inputs: [filesIn, Port("quality", "Quality %", .number, default: .number(75))],
                        outputs: [filesOut("Compressed images")],
                        .builtIn { context in
                            let images = try context.requireFiles().filter { FileFamily.of($0) == .image }
                            guard !images.isEmpty else { throw FlowError.failed("None of these is an image") }
                            let quality = min(100, max(5, context.number("quality"))) / 100
                            return ["files": .files(try images.map { try FileOps.compress($0, quality: quality) })]
                        }),
        BlockDefinition("files.combine", "Combine into PDF", category: .files, glyph: "doc.richtext",
                        phrase: "Combine {files} into one file",
                        help: "PDFs and images into one PDF, text files into one text file",
                        inputs: [filesIn], outputs: [Port("file", "Combined file", .files)],
                        .builtIn { context in
                            let files = try context.requireFiles()
                            guard files.count > 1 else { throw FlowError.failed("Combining needs two files or more") }
                            return ["file": .files([try StashFileMerger.combine(files)])]
                        }),
        BlockDefinition("files.tag", "Tag", category: .files, glyph: "tag",
                        phrase: "Tag {files} with {tag}",
                        inputs: [filesIn, Port("tag", "Tag", .text)], outputs: [filesOut("Files")],
                        .builtIn { context in
                            let files = try context.requireFiles()
                            let tag = try context.requireText("tag", "No tag given")
                            for file in files {
                                var tags = (try? file.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                                guard !tags.contains(tag) else { continue }
                                tags.append(tag)
                                try (file as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
                            }
                            return ["files": .files(files), "message": .text("Tagged \(FileOps.count(files)) “\(tag)”")]
                        }),
        BlockDefinition("files.stash", "Put on a stash", category: .files, glyph: "tray.and.arrow.down",
                        phrase: "Put {files} on a stash", inputs: [filesIn], outputs: [filesOut("Files")],
                        .builtIn { context in
                            let files = try context.requireFiles()
                            await MainActor.run { _ = ShelfWindowManager.shared.spawnShelf(at: NSEvent.mouseLocation, with: files) }
                            return ["files": .files(files), "message": .text("Stashed \(FileOps.count(files))")]
                        }),
        BlockDefinition("files.reveal", "Reveal in Finder", category: .files, glyph: "magnifyingglass",
                        phrase: "Reveal {files} in Finder", inputs: [filesIn], outputs: [filesOut("Files")],
                        .builtIn { context in
                            let files = try context.requireFiles()
                            await MainActor.run { _ = FinderUtility.revealAndFocus(urls: files) }
                            return ["files": .files(files)]
                        }),
        BlockDefinition("files.open", "Open", category: .files, glyph: "arrow.up.forward.app",
                        phrase: "Open {files}",
                        inputs: [filesIn, Port("app", "With app", .text, .app, help: "Empty: each file's own app", optional: true)],
                        outputs: [filesOut("Files")],
                        .builtIn { context in
                            let files = try context.requireFiles()
                            if context.text("app").isEmpty {
                                await MainActor.run { files.forEach { NSWorkspace.shared.open($0) } }
                            } else {
                                let app = try Apps.url(context.text("app"))
                                _ = try await NSWorkspace.shared.open(files, withApplicationAt: app,
                                                                      configuration: NSWorkspace.OpenConfiguration())
                            }
                            return ["files": .files(files), "message": .text("Opened \(FileOps.count(files))")]
                        }),
        BlockDefinition("files.trash", "Move to Trash", category: .files, glyph: "trash",
                        phrase: "Move {files} to the Trash", inputs: [filesIn],
                        outputs: [filesOut("Where they went")],
                        .builtIn { context in
                            var landed: [URL] = []
                            for file in try context.requireFiles() {
                                var result: NSURL?
                                try FileManager.default.trashItem(at: file, resultingItemURL: &result)
                                if let result { landed.append(result as URL) }
                            }
                            return ["files": .files(landed), "message": .text("Moved \(FileOps.count(landed)) to the Trash")]
                        }),
        BlockDefinition("files.list", "Files in a folder", category: .files, glyph: "folder.badge.questionmark",
                        phrase: "Files in {folder}",
                        inputs: [Port("folder", "Folder", .text, .folder),
                                 Port("deep", "Include subfolders", .bool, default: .bool(false))],
                        outputs: [Port("files", "Files", .files)], essential: true,
                        .builtIn { context in
                            let folder = try context.folder()
                            let files = context.flag("deep") ? FileOps.allFiles(in: folder) : FileFacts.regularFiles(in: folder)
                            return ["files": .files(files)]
                        }),
        BlockDefinition("files.filter", "Filter files", category: .files, glyph: "line.3.horizontal.decrease.circle",
                        phrase: "Keep {files} where {test} {value}",
                        help: "Files that pass come out as Kept, the others as Rest",
                        inputs: [filesIn,
                                 Port("test", "Test", .text, .choice, default: .text(FileTest.ext.rawValue),
                                      choices: FileTest.allCases.map(\.rawValue)),
                                 Port("value", "Value", .text)],
                        outputs: [Port("files", "Kept", .files), Port("rest", "Rest", .files)], essential: true,
                        .builtIn { context in
                            let files = context.files("files")
                            let test = FileTest(rawValue: context.text("test")) ?? .ext
                            let condition = test.condition(context.text("value"))
                            let kept = files.filter { condition.matches($0) }
                            return ["files": .files(kept), "rest": .files(files.filter { !kept.contains($0) }),
                                    "message": .text("Kept \(kept.count) of \(files.count)")]
                        }),
        BlockDefinition("files.info", "File info", category: .files, glyph: "info.circle",
                        phrase: "Info about {file}",
                        inputs: [Port("file", "File", .files)],
                        outputs: [Port("name", "Name", .text), Port("base", "Name without extension", .text),
                                  Port("ext", "Extension", .text), Port("folder", "Folder", .files),
                                  Port("size", "Size (bytes)", .number), Port("added", "Date added", .text),
                                  Port("source", "Downloaded from", .text)],
                        .builtIn { context in
                            guard let file = context.files("file").first else { throw FlowError.noFiles }
                            return [
                                "name": .text(file.lastPathComponent),
                                "base": .text(file.deletingPathExtension().lastPathComponent),
                                "ext": .text(file.pathExtension),
                                "folder": .files([file.deletingLastPathComponent()]),
                                "size": .number(Double(FileFacts.size(file))),
                                "added": .text(Stamp.day(FileFacts.dateAdded(file) ?? Date())),
                                "source": .text(FileFacts.whereFroms(file).last ?? ""),
                            ]
                        }),
        BlockDefinition("files.read", "Read text file", category: .files, glyph: "doc.plaintext",
                        phrase: "Read {file}", inputs: [Port("file", "File", .files)],
                        outputs: [Port("text", "Text", .text)],
                        .builtIn { context in
                            guard let file = context.files("file").first else { throw FlowError.noFiles }
                            return ["text": .text(try String(contentsOf: file, encoding: .utf8))]
                        }),
        BlockDefinition("files.write", "Write text file", category: .files, glyph: "square.and.pencil",
                        phrase: "Write {text} to {name} in {folder}",
                        inputs: [Port("text", "Text", .text, .multiline),
                                 Port("name", "File name", .text, default: .text("Notes.txt")),
                                 Port("folder", "Folder", .text, .folder),
                                 Port("mode", "If it exists", .text, .choice, default: .text("replace it"),
                                      choices: ["replace it", "add to the end", "make a new one"])],
                        outputs: [Port("file", "File", .files)],
                        .builtIn { context in
                            let folder = try context.folder()
                            let name = try context.requireText("name", "No file name")
                            var file = folder.appendingPathComponent(name)
                            let text = context.text("text")
                            switch context.text("mode") {
                            case "add to the end" where FileManager.default.fileExists(atPath: file.path):
                                let handle = try FileHandle(forWritingTo: file)
                                defer { try? handle.close() }
                                try handle.seekToEnd()
                                try handle.write(contentsOf: Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
                            case "make a new one":
                                file = FileName.unique(name, in: folder)
                                try text.write(to: file, atomically: true, encoding: .utf8)
                            default:
                                try text.write(to: file, atomically: true, encoding: .utf8)
                            }
                            return ["file": .files([file])]
                        }),
        BlockDefinition("files.newFolder", "New folder", category: .files, glyph: "folder.badge.plus",
                        phrase: "New folder {name} in {folder}",
                        inputs: [Port("name", "Name", .text, default: .text("New Folder")),
                                 Port("folder", "Inside", .text, .folder)],
                        outputs: [Port("folder", "Folder", .files)],
                        .builtIn { context in
                            let parent = try context.folder()
                            let target = parent.appendingPathComponent(try context.requireText("name", "No name"), isDirectory: true)
                            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                            return ["folder": .files([target])]
                        }),
    ]

    // Ports most file blocks share.
    static let filesIn = Port("files", "Files", .files)
    static func filesOut(_ label: String) -> Port { Port("files", label, .files) }
    static let sortIn = Port("sort", "Sort into", .text, .choice, default: .text(FileOps.Sort.none.rawValue),
                             choices: FileOps.Sort.allCases.map(\.rawValue))

    private static func place(_ context: BlockContext, moving: Bool) throws -> [String: Value] {
        let files = try context.requireFiles()
        let folder = try context.folder()
        let sort = FileOps.Sort(rawValue: context.text("sort")) ?? .none
        let placed = try files.map { file -> URL in
            let target = try sort.folder(for: file, in: folder)
            let destination = FileName.unique(file.lastPathComponent, in: target)
            if moving {
                try FileManager.default.moveItem(at: file, to: destination)
            } else {
                try FileManager.default.copyItem(at: file, to: destination)
            }
            return destination
        }
        return ["files": .files(placed),
                "message": .text("\(moving ? "Moved" : "Copied") \(FileOps.count(placed)) to \(folder.lastPathComponent)")]
    }
}

/// What Filter files can test, each one of the file rules' conditions.
enum FileTest: String, CaseIterable, Sendable {
    case kind = "kind is"
    case ext = "extension is"
    case nameContains = "name contains"
    case nameStarts = "name starts with"
    case source = "downloaded from"
    case older = "older than (days)"
    case larger = "larger than (MB)"

    func condition(_ value: String) -> RuleCondition {
        let number = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        switch self {
        case .kind:
            let family = FileFamily.allCases.first { $0.label.lowercased() == value.lowercased().trimmingCharacters(in: .whitespaces) }
            return RuleCondition(.family, family: family ?? .pdf)
        case .ext: return RuleCondition(.ext, text: value)
        case .nameContains: return RuleCondition(.nameContains, text: value)
        case .nameStarts: return RuleCondition(.nameStartsWith, text: value)
        case .source: return RuleCondition(.downloadedFrom, text: value)
        case .older: return RuleCondition(.olderThan, number: number)
        case .larger: return RuleCondition(.largerThan, number: number)
        }
    }
}

/// File work the blocks share.
enum FileOps {
    /// Where a move or copy puts each file inside its folder.
    enum Sort: String, CaseIterable, Sendable {
        case none = "the folder itself"
        case month = "a folder per month"
        case site = "a folder per website"

        func folder(for file: URL, in folder: URL) throws -> URL {
            let name: String
            switch self {
            case .none: return folder
            case .month: name = Stamp.month(FileFacts.dateAdded(file) ?? Date())
            case .site:
                name = FileFacts.whereFroms(file).compactMap { URL(string: $0)?.host }
                    .last.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "Other"
            }
            let target = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return target
        }
    }

    /// A rename pattern filled in for one file. The extension is kept unless
    /// the pattern names it.
    static func name(for file: URL, pattern: String, index: Int, now: Date = Date()) -> String {
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var name = pattern
            .replacingOccurrences(of: "{name}", with: base)
            .replacingOccurrences(of: "{date}", with: Stamp.day(FileFacts.dateAdded(file) ?? now))
            .replacingOccurrences(of: "{today}", with: Stamp.day(now))
            .replacingOccurrences(of: "{n}", with: String(index))
            .replacingOccurrences(of: "{folder}", with: file.deletingLastPathComponent().lastPathComponent)
        let namesExtension = name.contains("{ext}")
        name = name.replacingOccurrences(of: "{ext}", with: ext)
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return namesExtension || ext.isEmpty ? name : "\(name).\(ext)"
    }

    static func count(_ files: [URL]) -> String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }

    static func outputFolder(_ context: BlockContext) async throws -> URL {
        if !context.text("folder").isEmpty { return try context.folder() }
        return await MainActor.run { AppSettings.shared.exportDirectory }
    }

    /// Every file under `folder`, hidden ones and packages' insides left out.
    static func allFiles(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
    }

    /// The image as a JPEG in its place; the original goes to the Trash when
    /// it was not already a JPEG, so a compression can be undone.
    static func compress(_ file: URL, quality: Double) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FlowError.failed("\(file.lastPathComponent) is not an image") }
        let isJPEG = ["jpg", "jpeg"].contains(file.pathExtension.lowercased())
        let output = isJPEG ? file : FileName.unique(file.deletingPathExtension().lastPathComponent + ".jpg",
                                               in: file.deletingLastPathComponent())
        let staging = output.deletingLastPathComponent().appendingPathComponent(".gruppen-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw FlowError.failed("Couldn't write \(output.lastPathComponent)") }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FlowError.failed("Couldn't write \(output.lastPathComponent)")
        }
        if isJPEG {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: output)
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        return output
    }
}
