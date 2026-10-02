import AppKit
import Foundation
import PDFKit

// MARK: - Fixtures

/// A real PNG on disk, written through ImageIO so the bytes are a genuine image
/// rather than something that only looks like one to a header check.
private func writePNG(_ url: URL, width: Int, height: Int) -> Bool {
    guard let context = CGContext(data: nil, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

/// A real multi-page PDF.
private func writePDF(_ url: URL, pages: Int) -> Bool {
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        context.endPDFPage()
    }
    context.closePDF()
    return true
}

func sectionMerge() {
    T.begin("H. Merge — what a selection is")

    let txt = URL(fileURLWithPath: "/tmp/a.txt")
    let md = URL(fileURLWithPath: "/tmp/b.md")
    let png = URL(fileURLWithPath: "/tmp/c.png")
    let jpg = URL(fileURLWithPath: "/tmp/d.JPG")
    let pdf = URL(fileURLWithPath: "/tmp/e.pdf")
    let docx = URL(fileURLWithPath: "/tmp/f.docx")
    let bin = URL(fileURLWithPath: "/tmp/g.sqlite")

    T.equal("plain text is plain text", StashFileMerger.ingredient(of: txt), .plainText)
    T.equal("markdown counts as plain text", StashFileMerger.ingredient(of: md), .plainText)
    T.equal("case does not matter", StashFileMerger.ingredient(of: jpg), .image)
    T.equal("docx is rich text, not plain",
            StashFileMerger.ingredient(of: docx), .richText)
    T.equal("an unknown extension is unsupported", StashFileMerger.ingredient(of: bin), .unsupported)

    T.equal("two text files merge as text", StashFileMerger.plan(for: [txt, md]), .text)
    T.equal("two PDFs append as a PDF", StashFileMerger.plan(for: [pdf, pdf]), .pdf)
    T.equal("two images become a PDF", StashFileMerger.plan(for: [png, jpg]), .images)
    T.equal("an image and a text file are mixed", StashFileMerger.plan(for: [png, txt]), .mixed)
    T.check("two docx files are a PDF merge, not a text one — "
            + "concatenating Word bytes produces a corrupt Word file",
            StashFileMerger.plan(for: [docx, docx]) == .mixed)
    T.check("one file is not a merge", StashFileMerger.plan(for: [txt]) == nil)
    T.check("nothing is not a merge", StashFileMerger.plan(for: []) == nil)
    T.check("an unreadable file refuses the whole batch rather than "
            + "silently dropping a page",
            StashFileMerger.plan(for: [txt, bin]) == nil)
    T.equal("text merges to .txt", StashFileMerger.Plan.text.ext, "txt")
    T.equal("every other merge is .pdf", StashFileMerger.Plan.mixed.ext, "pdf")

    T.begin("H. Merge — text")

    withTempDir { dir in
        let one = dir.appendingPathComponent("first.txt")
        let two = dir.appendingPathComponent("second.log")
        try? "alpha".write(to: one, atomically: true, encoding: .utf8)
        // No trailing newline on one, several on the other: the separators must
        // still line up.
        try? "beta\n\n\n".write(to: two, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("out.txt")

        do {
            let result = try StashFileMerger.combine([one, two], outputURL: out)
            let body = (try? String(contentsOf: result, encoding: .utf8)) ?? ""
            T.check("both bodies survive", body.contains("alpha") && body.contains("beta"),
                    "\(body.count) bytes")
            T.check("each section is labelled with its source",
                    body.contains("===== first.txt =====") && body.contains("===== second.log ====="))
            T.check("order follows the selection",
                    (body.range(of: "alpha")?.lowerBound ?? body.startIndex)
                        < (body.range(of: "beta")?.lowerBound ?? body.startIndex))
            T.equal("it wrote where it was told", result.path, out.path)
        } catch {
            T.check("text merge succeeds", false, "\(error)")
        }

        // A file that is not UTF-8 at all. Every byte sequence is valid Latin-1,
        // so this must cost mojibake on one line rather than failing the merge.
        let latin = dir.appendingPathComponent("latin.txt")
        try? Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: latin)
        let out2 = dir.appendingPathComponent("out2.txt")
        do {
            _ = try StashFileMerger.combine([one, latin], outputURL: out2)
            let body = (try? String(contentsOf: out2, encoding: .utf8)) ?? ""
            T.check("a non-UTF-8 file does not fail the merge",
                    body.contains("alpha") && body.contains("caf"),
                    "recovered as Latin-1")
        } catch {
            T.check("a non-UTF-8 file does not fail the merge", false, "\(error)")
        }
    }

    T.begin("H. Merge — PDF, images, and everything")

    withTempDir { dir in
        let a = dir.appendingPathComponent("a.pdf")
        let b = dir.appendingPathComponent("b.pdf")
        T.check("fixture: a 2-page PDF", writePDF(a, pages: 2))
        T.check("fixture: a 3-page PDF", writePDF(b, pages: 3))

        let out = dir.appendingPathComponent("merged.pdf")
        do {
            _ = try StashFileMerger.combine([a, b], outputURL: out)
            let merged = PDFDocument(url: out)
            T.equal("pages add up", merged?.pageCount, 5)
        } catch {
            T.check("PDF merge succeeds", false, "\(error)")
        }

        // Images, at two different sizes, so the per-image media box is visible.
        let wide = dir.appendingPathComponent("wide.png")
        let tall = dir.appendingPathComponent("tall.png")
        T.check("fixture: a 400×100 PNG", writePNG(wide, width: 400, height: 100))
        T.check("fixture: a 100×400 PNG", writePNG(tall, width: 100, height: 400))

        let sheet = dir.appendingPathComponent("sheet.pdf")
        do {
            _ = try StashFileMerger.combine([wide, tall], outputURL: sheet)
            let document = PDFDocument(url: sheet)
            T.equal("one page per image", document?.pageCount, 2)
            // Each page keeps the image's own pixel size, which is the whole
            // reason this path goes through CGContext and not PDFPage(image:).
            let first = document?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
            let second = document?.page(at: 1)?.bounds(for: .mediaBox) ?? .zero
            T.equal("the first page is the wide image's size",
                    "\(Int(first.width))×\(Int(first.height))", "400×100")
            T.equal("the second page is the tall image's size",
                    "\(Int(second.width))×\(Int(second.height))", "100×400")
        } catch {
            T.check("image merge succeeds", false, "\(error)")
        }

        // Mixed: a 2-page PDF, an image, and a text file.
        let note = dir.appendingPathComponent("note.txt")
        try? String(repeating: "The quick brown fox. ", count: 40)
            .write(to: note, atomically: true, encoding: .utf8)
        let mixed = dir.appendingPathComponent("mixed.pdf")
        do {
            _ = try StashFileMerger.combine([a, wide, note], outputURL: mixed)
            let document = PDFDocument(url: mixed)
            let pages = document?.pageCount ?? 0
            T.check("a mixed merge carries every input", pages >= 4,
                    "2 PDF pages + 1 image + at least 1 of text = \(pages)")
            // The image page is normalised to Letter in a mixed document, so the
            // paper size does not change halfway through.
            let imagePage = document?.page(at: 2)?.bounds(for: .mediaBox) ?? .zero
            T.equal("images are set on Letter when the document is mixed",
                    "\(Int(imagePage.width))×\(Int(imagePage.height))", "612×792")
        } catch {
            T.check("mixed merge succeeds", false, "\(error)")
        }

        // A file that claims to be a PDF and is not.
        let liar = dir.appendingPathComponent("liar.pdf")
        try? "not a pdf at all".write(to: liar, atomically: true, encoding: .utf8)
        let doomed = dir.appendingPathComponent("doomed.pdf")
        var threw = false
        do { _ = try StashFileMerger.combine([a, liar], outputURL: doomed) } catch { threw = true }
        T.check("a corrupt input throws rather than writing a short document", threw)
        T.check("and leaves nothing behind",
                !FileManager.default.fileExists(atPath: doomed.path))

        // The staging directory must not survive either.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path))?
            .filter { $0.hasPrefix("gruppen-merge-") } ?? []
        T.equal("no staging directories are left behind", leftovers.count, 0)
    }

    T.begin("H. Reveal in Finder — what it decides")

    withTempDir { dir in
        let there = dir.appendingPathComponent("there.txt")
        try? "x".write(to: there, atomically: true, encoding: .utf8)
        let gone = dir.appendingPathComponent("gone.txt")

        T.equal("an existing file is revealed",
                FinderUtility.resolve([there]), .reveal([there.standardizedFileURL]))
        T.equal("a missing file falls back to its folder",
                FinderUtility.resolve([gone]), .openFolder(dir.standardizedFileURL))
        T.equal("a missing file in a missing folder does nothing at all",
                FinderUtility.resolve([URL(fileURLWithPath: "/nope/nothing/x.txt")]), .nothing)
        T.equal("a batch keeps what survived and drops what did not",
                FinderUtility.resolve([gone, there]), .reveal([there.standardizedFileURL]))

        // Finder matches by path, so the same file spelled two ways must arrive
        // as one request it can act on.
        let awkward = URL(fileURLWithPath: dir.path + "/./there.txt")
        T.equal("paths are standardised before Finder sees them",
                FinderUtility.resolve([awkward]), .reveal([there.standardizedFileURL]))
        T.equal("nothing at all is nothing", FinderUtility.resolve([]), .nothing)
    }
}
