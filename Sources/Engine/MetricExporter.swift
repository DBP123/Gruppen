import Foundation

/// Writes captured metrics out as CSV or as a real `.xlsx`.
///
/// **The xlsx is genuinely an xlsx**, not a CSV wearing the extension. An Office
/// Open XML workbook is a zip of a handful of small XML parts, and writing them
/// by hand is about eighty lines — considerably less than the cost of taking on
/// a spreadsheet library, and it opens in Excel, Numbers and Sheets. Strings are
/// written inline (`t="inlineStr"`), which skips the shared-strings table
/// entirely and keeps the writer to one pass.
enum MetricExporter {
    enum ExportError: LocalizedError {
        case nothingToExport
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .nothingToExport: return "This metric has not captured anything yet."
            case .zipFailed(let message):
                return message.isEmpty ? "The workbook could not be packed." : message
            }
        }
    }

    /// Columns, in the order the metric defines, followed by any field that
    /// appears in the data but not in the definition — a source that started
    /// reporting something new should not silently drop it.
    static func columns(for metric: MetricDefinition, records: [MetricRecord]) -> [String] {
        var ordered = metric.keptKeys
        var seen = Set(ordered)
        for record in records {
            for key in record.values.keys.sorted() where !seen.contains(key) {
                ordered.append(key)
                seen.insert(key)
            }
        }
        return ordered
    }

    // MARK: CSV

    @discardableResult
    nonisolated static func exportCSV(_ metric: MetricDefinition,
                                      records: [MetricRecord],
                                      to directory: URL) throws -> URL {
        guard !records.isEmpty else { throw ExportError.nothingToExport }
        let fields = columns(for: metric, records: records)

        var text = (["Captured At"] + fields).map(escape).joined(separator: ",") + "\n"
        let stamp = ISO8601DateFormatter()
        for record in records.reversed() {
            var row = [escape(stamp.string(from: record.capturedAt))]
            row += fields.map { escape(record.values[$0] ?? "") }
            text += row.joined(separator: ",") + "\n"
        }

        let url = uniqueURL(in: directory, base: fileStem(for: metric), ext: "csv")
        try text.data(using: .utf8)?.write(to: url)
        return url
    }

    /// RFC 4180: quote anything containing a comma, a quote or a newline, and
    /// double the quotes inside.
    private nonisolated static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: XLSX

    @discardableResult
    nonisolated static func exportXLSX(_ metric: MetricDefinition,
                                       records: [MetricRecord],
                                       to directory: URL) throws -> URL {
        guard !records.isEmpty else { throw ExportError.nothingToExport }
        let fields = columns(for: metric, records: records)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("gruppen-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("_rels"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("xl/worksheets"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("xl/_rels"),
                                                withIntermediateDirectories: true)

        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            </Types>
            """, to: staging.appendingPathComponent("[Content_Types].xml"))

        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """, to: staging.appendingPathComponent("_rels/.rels"))

        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets><sheet name="\(xmlEscape(sheetName(for: metric)))" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
            """, to: staging.appendingPathComponent("xl/workbook.xml"))

        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            </Relationships>
            """, to: staging.appendingPathComponent("xl/_rels/workbook.xml.rels"))

        var sheet = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
            """
        sheet += row(1, values: ["Captured At"] + fields)
        let stamp = ISO8601DateFormatter()
        for (index, record) in records.reversed().enumerated() {
            let values = [stamp.string(from: record.capturedAt)] + fields.map { record.values[$0] ?? "" }
            sheet += row(index + 2, values: values)
        }
        sheet += "</sheetData></worksheet>"
        try write(sheet, to: staging.appendingPathComponent("xl/worksheets/sheet1.xml"))

        let url = uniqueURL(in: directory, base: fileStem(for: metric), ext: "xlsx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-r", "-q", "-X", url.path, "."]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.zipFailed(String(data: data, encoding: .utf8) ?? "")
        }
        return url
    }

    /// One `<row>` of inline strings. Columns are lettered A, B … Z, AA, AB …
    private nonisolated static func row(_ number: Int, values: [String]) -> String {
        var xml = "<row r=\"\(number)\">"
        for (index, value) in values.enumerated() {
            let reference = "\(columnLetters(index))\(number)"
            xml += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">"
            xml += xmlEscape(value)
            xml += "</t></is></c>"
        }
        return xml + "</row>"
    }

    private nonisolated static func columnLetters(_ index: Int) -> String {
        var value = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + value % 26))) + letters
            value = value / 26 - 1
        } while value >= 0
        return letters
    }

    private nonisolated static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            // Control characters are not legal in XML 1.0 and Excel refuses the
            // whole file if one appears.
            .filter { $0 == "\n" || $0 == "\t" || $0.asciiValue ?? 32 >= 32 || !$0.isASCII }
    }

    // MARK: Naming

    private nonisolated static func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)?.write(to: url)
    }

    /// Excel rejects sheet names over 31 characters or containing `[]:*?/\`.
    private nonisolated static func sheetName(for metric: MetricDefinition) -> String {
        let cleaned = metric.name.filter { !"[]:*?/\\".contains($0) }
        return String(cleaned.isEmpty ? "Metric" : cleaned.prefix(31))
    }

    private nonisolated static func fileStem(for metric: MetricDefinition) -> String {
        let cleaned = metric.name.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "Metric" : cleaned
    }

    private nonisolated static func uniqueURL(in directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
