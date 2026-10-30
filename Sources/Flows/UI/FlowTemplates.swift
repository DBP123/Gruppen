import Foundation

/// Starting points: whole flows, built from the same blocks you would drag
/// in, so opening one is also how to learn what a flow looks like.
struct FlowTemplate: Identifiable, Sendable {
    let id: String
    let name: String
    let glyph: String
    let summary: String
    let make: @Sendable () -> Flow

    private static func text(_ value: String) -> ValueSource { .literal(.text(value)) }
    private static func number(_ value: Double) -> ValueSource { .literal(.number(value)) }

    /// A stack whose blocks each read the files the one before handed on.
    private static func chain(_ blocks: [Block], from first: ValueSource) -> [Block] {
        var previous = first
        return blocks.map { block in
            var block = block
            if block.inputs["files"] == nil, Catalog.definition(block.definition)?.input("files") != nil {
                block.inputs["files"] = previous
            }
            if Catalog.definition(block.definition)?.output("files") != nil {
                previous = .output(block: block.id, port: "files")
            }
            return block
        }
    }

    static let all: [FlowTemplate] = [
        FlowTemplate(id: "pdfs", name: "File PDFs from Downloads", glyph: "doc.richtext",
                     summary: "Each PDF that lands in Downloads goes to Documents/PDFs, in a folder per month") {
            let hat = Block(Catalog.folder, inputs: ["folder": text("~/Downloads")])
            return Flow(name: "File PDFs", glyph: "doc.richtext", triggers: [hat], body: chain([
                Block("files.filter", inputs: ["test": text(FileTest.ext.rawValue), "value": text("pdf")]),
                Block("files.move", inputs: ["folder": text("~/Documents/PDFs"), "sort": text(FileOps.Sort.month.rawValue)]),
            ], from: .trigger(port: "files")))
        },
        FlowTemplate(id: "screenshots", name: "Tidy screenshots", glyph: "camera.viewfinder",
                     summary: "Screenshots on the Desktop move to Pictures/Screenshots") {
            let hat = Block(Catalog.folder, inputs: ["folder": text("~/Desktop")])
            return Flow(name: "Tidy screenshots", glyph: "photo", triggers: [hat], body: chain([
                Block("files.filter", inputs: ["test": text(FileTest.nameStarts.rawValue), "value": text("Screenshot")]),
                Block("files.move", inputs: ["folder": text("~/Pictures/Screenshots")]),
            ], from: .trigger(port: "files")))
        },
        FlowTemplate(id: "heic", name: "HEIC photos to JPEG", glyph: "photo",
                     summary: "iPhone photos arriving in Downloads are converted to JPEG, originals to the Trash") {
            let hat = Block(Catalog.folder, inputs: ["folder": text("~/Downloads")])
            let filter = Block("files.filter", inputs: ["files": .trigger(port: "files"),
                                                        "test": text(FileTest.ext.rawValue), "value": text("heic")])
            let convert = Block("files.convert", inputs: ["files": .output(block: filter.id, port: "files"), "format": text("jpg")])
            let trash = Block("files.trash", inputs: ["files": .output(block: filter.id, port: "files")])
            return Flow(name: "HEIC to JPEG", glyph: "photo", triggers: [hat], body: [filter, convert, trash])
        },
        FlowTemplate(id: "zip", name: "Zip and reveal a stash", glyph: "doc.zipper",
                     summary: "From a stash's Run menu: its files zipped into one archive, shown in Finder") {
            let hat = Block(Catalog.stash)
            let zip = Block("files.zip", inputs: ["files": .trigger(port: "files")])
            let reveal = Block("files.reveal", inputs: ["files": .output(block: zip.id, port: "zip")])
            return Flow(name: "Zip and reveal", glyph: "doc.zipper", triggers: [hat], body: [zip, reveal])
        },
        FlowTemplate(id: "rename", name: "Date-stamp a stash", glyph: "calendar",
                     summary: "From a stash: each file renamed to start with the day it arrived") {
            let hat = Block(Catalog.stash)
            return Flow(name: "Date-stamp", glyph: "calendar", triggers: [hat], body: chain([
                Block("files.rename", inputs: ["pattern": text("{date} {name}"), "tidy": .literal(.bool(true))]),
            ], from: .trigger(port: "files")))
        },
        FlowTemplate(id: "link", name: "Clean a copied link", glyph: "link.badge.plus",
                     summary: "⌃⌥L anywhere: tracking parameters stripped from the link you copied") {
            let keys = Shortcut(keyCode: 37, modifiers: 4096 | 2048, label: "L")
            let hat = Block(Catalog.hotkey, inputs: ["keys": text(HotkeyValue.text(keys))])
            return Flow(name: "Clean link", glyph: "link", triggers: [hat],
                        body: [Block("clip.clean", inputs: ["what": text("link")])])
        },
        FlowTemplate(id: "morning", name: "Start the workday", glyph: "sunrise",
                     summary: "Weekdays at 9:00: your calendar and mail open, and a notification says good morning") {
            let hat = Block("when.schedule", inputs: ["time": number(9 * 60), "days": text("2,3,4,5,6")])
            return Flow(name: "Workday", glyph: "clock", triggers: [hat], body: [
                Block("apps.open", inputs: ["app": text("com.apple.iCal")]),
                Block("apps.open", inputs: ["app": text("com.apple.mail")]),
                Block("logic.notify", inputs: ["title": text("Good morning"), "body": text("Calendar and Mail are open")]),
            ])
        },
        FlowTemplate(id: "battery", name: "Low battery", glyph: "battery.25percent",
                     summary: "Below 15%: a notification, and Dark Mode to save a little power") {
            let hat = Block(Catalog.battery, inputs: ["below": number(15)])
            return Flow(name: "Low battery", glyph: "bolt", triggers: [hat], body: [
                Block("logic.notify", inputs: ["title": .template([.text("Battery at "), .value(.trigger(port: "battery")), .text("%")])]),
                Block("system.appearance", inputs: ["mode": text("Dark Mode")]),
            ])
        },
        FlowTemplate(id: "webhook", name: "Post to a webhook", glyph: "network",
                     summary: "By hand: a JSON message sent to a URL you choose — Slack, Discord, your own server") {
            let record = Block("text.record", inputs: ["fields": text("text: Hello from Gruppen")])
            let post = Block("web.request", inputs: ["method": text("POST"), "url": text("https://"),
                                                     "body": .output(block: record.id, port: "record")])
            return Flow(name: "Webhook", glyph: "network", triggers: [Block(Catalog.manual)], body: [record, post])
        },
        FlowTemplate(id: "python", name: "Python on a stash", glyph: "chevron.left.forwardslash.chevron.right",
                     summary: "From a stash: your Python gets the files, and what it hands back can be used by later blocks") {
            let hat = Block(Catalog.stash)
            let code = Block(Catalog.codeBlockID(.python), inputs: ["input": .trigger(port: "files")])
            let notify = Block("logic.notify", inputs: ["title": .template([.text("Python said: "), .value(.output(block: code.id, port: "output"))])])
            return Flow(name: "Python on a stash", glyph: "terminal", triggers: [hat], body: [code, notify])
        },
    ]
}
