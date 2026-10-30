import Foundation
import JavaScriptCore

// Runs a JavaScript file with JavaScriptCore, for code blocks on a Mac without
// Node. Its own process, so a runaway script can be stopped like any other.
//
//   gruppen-js script.js [file…]
//
// Gives the script what the Node bootstrap does: `gruppen.inputs`,
// `gruppen.files(name)`, `gruppen.out({…})`, `console.log`, `argv` and `env`.

let arguments = CommandLine.arguments
guard arguments.count >= 2, let source = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: gruppen-js script.js [file…]\n".utf8))
    exit(2)
}
let scriptName = (arguments[1] as NSString).lastPathComponent
let environment = ProcessInfo.processInfo.environment

guard let context = JSContext() else { exit(1) }
var failed = false
context.exceptionHandler = { _, exception in
    let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
    let message = exception?.toString() ?? "error"
    FileHandle.standardError.write(Data("\(scriptName):\(line): \(message)\n".utf8))
    failed = true
}

let print: @convention(block) () -> Void = {
    let parts = (JSContext.currentArguments() ?? []).map { ($0 as? JSValue)?.toString() ?? "" }
    FileHandle.standardOutput.write(Data((parts.joined(separator: " ") + "\n").utf8))
}
let printError: @convention(block) () -> Void = {
    let parts = (JSContext.currentArguments() ?? []).map { ($0 as? JSValue)?.toString() ?? "" }
    FileHandle.standardError.write(Data((parts.joined(separator: " ") + "\n").utf8))
}
let console = JSValue(newObjectIn: context)!
console.setObject(print, forKeyedSubscript: "log" as NSString)
console.setObject(print, forKeyedSubscript: "info" as NSString)
console.setObject(printError, forKeyedSubscript: "error" as NSString)
console.setObject(printError, forKeyedSubscript: "warn" as NSString)
context.setObject(console, forKeyedSubscript: "console" as NSString)

let write: @convention(block) (JSValue) -> Void = { json in
    guard let path = environment["GRUPPEN_OUTPUT"], let text = json.toString() else { return }
    try? text.write(toFile: path, atomically: false, encoding: .utf8)
}
context.setObject(write, forKeyedSubscript: "__gruppenWrite" as NSString)
context.setObject(Array(arguments.dropFirst(2)), forKeyedSubscript: "argv" as NSString)
context.setObject(environment, forKeyedSubscript: "env" as NSString)

let inputs = environment["GRUPPEN_INPUT_FILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "{}"
context.evaluateScript("""
const __outputs = {};
globalThis.gruppen = {
  inputs: \(inputs),
  files(name = "input") { const v = this.inputs[name]; return v == null ? [] : Array.isArray(v) ? v : [v]; },
  out(values) { Object.assign(__outputs, values); __gruppenWrite(JSON.stringify(__outputs)); },
};
""")
context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: arguments[1]))
exit(failed ? 1 : 0)
