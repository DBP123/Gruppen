import AppKit

// The `gruppen` command: runs a flow from Terminal, cron or another app, and
// waits to say how it went.
//
//   gruppen run "Flow name" [--key value]… [--file path]… [--no-wait]
//   gruppen list
//
// It asks the app through a gruppen:// link, so the flow runs inside Gruppen
// with its environment, permissions and history — the same as any other run —
// and hears back through a distributed notification.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("gruppen: \(message)\n".utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: gruppen run \"Flow name\" [--key value] [--file path] [--no-wait] | gruppen list", code: 2)
}
arguments.removeFirst()

switch command {
case "list":
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    // The app this command came inside: a beta build keeps its flows apart.
    #if BETA
    let file = support.appendingPathComponent("Gruppen Beta/flows.json")
    #else
    let file = support.appendingPathComponent("Gruppen/flows.json")
    #endif
    guard let data = try? Data(contentsOf: file),
          let flows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { fail("no flows yet") }
    for flow in flows {
        let name = flow["name"] as? String ?? "?"
        let on = (flow["isEnabled"] as? Bool) == true ? "on " : "off"
        print("\(on)  \(name)")
    }
    exit(0)

case "run":
    guard let name = arguments.first, !name.hasPrefix("--") else { fail("which flow? gruppen run \"Flow name\"", code: 2) }
    arguments.removeFirst()
    var query: [URLQueryItem] = []
    var wait = true
    while let flag = arguments.first {
        arguments.removeFirst()
        switch flag {
        case "--no-wait": wait = false
        case "--file":
            guard let path = arguments.first else { fail("--file needs a path", code: 2) }
            arguments.removeFirst()
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                          relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            query.append(URLQueryItem(name: "file", value: url.standardizedFileURL.path))
        case let key where key.hasPrefix("--"):
            let value = arguments.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "yes"
            if value != "yes" || arguments.first == "yes" { arguments.removeFirst() }
            query.append(URLQueryItem(name: String(key.dropFirst(2)), value: value))
        default:
            // A bare word is the flow's input.
            query.append(URLQueryItem(name: "input", value: flag))
        }
    }
    let reply = UUID().uuidString
    if wait { query.append(URLQueryItem(name: "reply", value: reply)) }
    var components = URLComponents()
    components.scheme = "gruppen"
    components.host = "run"
    components.path = "/" + name
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { fail("couldn't make a link for \(name)") }

    var outcome: (String, String)?
    let observer = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.dhilanpatel.gruppen.flowFinished"), object: reply, queue: .main) { note in
            outcome = (note.userInfo?["outcome"] as? String ?? "failed", note.userInfo?["message"] as? String ?? "")
        }
    guard NSWorkspace.shared.open(url) else { fail("Gruppen isn't installed, or couldn't be opened") }
    guard wait else { exit(0) }
    while outcome == nil {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    DistributedNotificationCenter.default().removeObserver(observer)
    let (result, message) = outcome!
    if !message.isEmpty { print(message) }
    exit(result == "succeeded" ? 0 : 1)

default:
    fail("unknown command \(command) — try run or list", code: 2)
}
