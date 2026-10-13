import Foundation

// What a file rule asks of a file, and the small pure tools the rule and
// clipboard actions are made of. Nothing here touches AppKit, so all of it is
// tested directly against files in a temporary folder.

/// One test a file must pass for a rule to act on it.
struct RuleCondition: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case family, ext, nameContains, nameStartsWith, downloadedFrom, olderThan, largerThan
        var id: String { rawValue }

        var label: String {
            switch self {
            case .family: return "Kind is"
            case .ext: return "Extension is"
            case .nameContains: return "Name contains"
            case .nameStartsWith: return "Name starts with"
            case .downloadedFrom: return "Downloaded from"
            case .olderThan: return "Older than"
            case .largerThan: return "Larger than"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// `ext`, `nameContains`, `nameStartsWith`, `downloadedFrom`.
    var text: String = ""
    /// `olderThan` in days, `largerThan` in megabytes.
    var number: Int = 7
    /// `family`.
    var family: FileFamily = .pdf

    init(_ kind: Kind, text: String = "", number: Int = 7, family: FileFamily = .pdf) {
        self.kind = kind
        self.text = text
        self.number = number
        self.family = family
    }

    /// Text matches ignore case, and an empty text matches nothing — a
    /// condition you have not filled in should not quietly match every file.
    func matches(_ url: URL, now: Date = Date()) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        let name = url.lastPathComponent.lowercased()
        switch kind {
        case .family:
            return FileFamily.of(url) == family
        case .ext:
            let wanted = needle.hasPrefix(".") ? String(needle.dropFirst()) : needle
            return !wanted.isEmpty && url.pathExtension.lowercased() == wanted
        case .nameContains:
            return !needle.isEmpty && name.contains(needle)
        case .nameStartsWith:
            return !needle.isEmpty && name.hasPrefix(needle)
        case .downloadedFrom:
            return !needle.isEmpty && FileFacts.whereFroms(url).contains { $0.lowercased().contains(needle) }
        case .olderThan:
            guard let added = FileFacts.dateAdded(url) else { return false }
            return now.timeIntervalSince(added) > Double(number) * 86_400
        case .largerThan:
            return FileFacts.size(url) > Int64(number) * 1_000_000
        }
    }

    var summary: String {
        switch kind {
        case .family: return "is \(family.label.lowercased())"
        case .ext: return "is .\(text.isEmpty ? "…" : text)"
        case .nameContains: return "name has “\(text)”"
        case .nameStartsWith: return "name starts “\(text)”"
        case .downloadedFrom: return "from \(text.isEmpty ? "…" : text)"
        case .olderThan: return "older than \(number)d"
        case .largerThan: return "over \(number) MB"
        }
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = ((try? box.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil) ?? .nameContains
        text = try box.decodeIfPresent(String.self, forKey: .text) ?? ""
        number = try box.decodeIfPresent(Int.self, forKey: .number) ?? 7
        family = ((try? box.decodeIfPresent(FileFamily.self, forKey: .family)) ?? nil) ?? .pdf
    }

    private enum CodingKeys: String, CodingKey { case id, kind, text, number, family }
}

/// Broad kinds of file, by extension — what a person means by "a PDF" or "an
/// image", not a UTI tree.
enum FileFamily: String, Codable, CaseIterable, Identifiable {
    case pdf, image, archive, document, audio, video, installer
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "Image"
        case .archive: return "Archive"
        case .document: return "Document"
        case .audio: return "Audio"
        case .video: return "Video"
        case .installer: return "Installer"
        }
    }

    static func of(_ url: URL) -> FileFamily? {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "webp", "bmp": return .image
        case "zip", "tar", "gz", "tgz", "7z", "rar", "xz", "bz2": return .archive
        case "doc", "docx", "pages", "rtf", "txt", "md", "odt", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "csv":
            return .document
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac": return .audio
        case "mp4", "mov", "m4v", "avi", "mkv", "webm": return .video
        case "dmg", "pkg", "mpkg", "iso": return .installer
        default: return nil
        }
    }
}

/// What the file system knows about a file beyond its name.
enum FileFacts {
    /// Where a download came from: the page and file URLs the browser wrote
    /// into `com.apple.metadata:kMDItemWhereFroms` as it saved it.
    ///
    /// Read from the extended attribute rather than Spotlight: a file that has
    /// just landed is not indexed yet, and a rule acts on it at once.
    static func whereFroms(_ url: URL) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return [] }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        guard read == length,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list
    }

    /// When the file arrived in its folder — what "older than" means for a
    /// Downloads folder — falling back to its creation date.
    static func dateAdded(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

// MARK: - Renaming

enum RenameStyle: String, Codable, CaseIterable, Identifiable {
    /// `2026-10-12 Lab report.pdf`
    case datePrefix
    /// `ENGR133 Lab report.pdf`
    case textPrefix
    /// `Lab report (1).pdf` → `Lab report.pdf`, collapsed spaces.
    case clean

    var id: String { rawValue }

    var label: String {
        switch self {
        case .datePrefix: return "Add the date"
        case .textPrefix: return "Add a prefix"
        case .clean: return "Clean up the name"
        }
    }

    /// The new file name for `name`, without touching the disk.
    func apply(to name: String, prefix: String = "", date: Date = Date()) -> String {
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        switch self {
        case .datePrefix:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            base = "\(formatter.string(from: date)) \(base)"
        case .textPrefix:
            let trimmed = prefix.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { base = "\(trimmed) \(base)" }
        case .clean:
            // Browsers' " (1)" / "-1" duplicate markers, then runs of spaces.
            base = base.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
            base = base.replacingOccurrences(of: #"[_\s]+"#, with: " ", options: .regularExpression)
            base = base.trimmingCharacters(in: .whitespaces)
        }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}

// MARK: - Text

enum CaseStyle: String, Codable, CaseIterable, Identifiable {
    case upper, lower, title, sentence
    var id: String { rawValue }

    var label: String {
        switch self {
        case .upper: return "UPPERCASE"
        case .lower: return "lowercase"
        case .title: return "Title Case"
        case .sentence: return "Sentence case"
        }
    }
}

/// The clipboard tools, as pure functions on text.
enum TextTools {
    /// Plain, tidy text: smart quotes and dashes made plain, non-breaking and
    /// repeated spaces collapsed, trailing space on each line removed, and no
    /// more than one blank line in a row.
    static func clean(_ text: String) -> String {
        var result = text
        let replacements = ["\u{201C}": "\"", "\u{201D}": "\"", "\u{2018}": "'", "\u{2019}": "'",
                            "\u{2013}": "-", "\u{2014}": "-", "\u{00A0}": " ", "\u{2026}": "..."]
        for (from, to) in replacements { result = result.replacingOccurrences(of: from, with: to) }
        result = result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #" +\n"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tracking parameters every link shortener and newsletter adds.
    private static let trackers: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "si", "ref", "ref_src",
        "spm", "yclid", "_hsenc", "_hsmi", "mkt_tok", "vero_id", "oly_anon_id", "oly_enc_id",
    ]

    /// Every URL in `text` with its tracking parameters removed; anything that
    /// is not a link is left alone.
    static func cleanLinks(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        var result = text
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text), let url = match.url,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { continue }
            let kept = components.queryItems?.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !trackers.contains(name)
            }
            components.queryItems = (kept?.isEmpty ?? true) ? nil : kept
            if let cleaned = components.string { result.replaceSubrange(range, with: cleaned) }
        }
        return result
    }

    static func change(_ text: String, to style: CaseStyle) -> String {
        switch style {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.capitalized
        case .sentence:
            // One pass: the first letter, and the first after . ! or ?, go up.
            var result = ""
            var capitalise = true
            for character in text.lowercased() {
                if capitalise && character.isLetter {
                    result += character.uppercased()
                    capitalise = false
                } else {
                    result.append(character)
                }
                if ".!?".contains(character) { capitalise = true }
            }
            return result
        }
    }
}
