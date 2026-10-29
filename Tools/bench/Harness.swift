import AppKit
import SwiftUI

/// Gruppen's own code, hosting one surface on its own, so its cost can be
/// measured without anyone clicking anything. Built by `Tools/bench.sh`
/// against a copy of Sources; `SURFACE` picks what runs:
///
/// - `panel`     the menu bar dropdown, its modules live
/// - `popover`   one module's popover — `KIND=cpu` (default), `network`, …
/// - `dashboard` the Telemetry page
/// - `pinned`    no window, modules pinned to the menu bar only (`PINNED=power,cpu`)
/// - `idle`      the app's objects alive, stash monitors armed, nothing open
@main
struct BenchHarness {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // A windowless helper is otherwise fair game for automatic termination,
        // which ended the first measurements halfway through.
        ProcessInfo.processInfo.disableAutomaticTermination("measuring")
        ProcessInfo.processInfo.disableSuddenTermination()
        MainActor.assumeIsolated { Bench.start() }
        app.run()
    }
}

@MainActor
enum Bench {
    static var keep: [AnyObject] = []

    static func start() {
        let environment = ProcessInfo.processInfo.environment
        let surface = environment["SURFACE"] ?? "panel"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gruppen-bench-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = GroupStore(fileURL: dir.appendingPathComponent("groups.json"))
        let scripts = ScriptLibrary(fileURL: dir.appendingPathComponent("scripts.json"))
        let triggers = ScriptTriggerCoordinator(library: scripts)
        let navigation = NavigationModel()
        keep = [store, scripts, triggers, navigation]
        let widgets = WidgetManager.shared

        func show<V: View>(_ view: V, size: NSSize) {
            let content = view
                .environmentObject(store)
                .environmentObject(navigation)
                .environmentObject(AppSettings.shared)
                .environmentObject(scripts)
                .environmentObject(triggers)
                .environmentObject(widgets)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: content)
            window.collectionBehavior = [.canJoinAllSpaces]
            window.orderFrontRegardless()
            keep.append(window)
        }

        widgets.start()
        switch surface {
        case "popover":
            let kind = environment["KIND"].flatMap(WidgetKind.init(rawValue:)) ?? .cpu
            show(ModuleDetail(kind: kind), size: NSSize(width: 320, height: 640))
            widgets.detailDidOpen(kind)
        case "dashboard":
            show(TelemetryDashboardView(), size: NSSize(width: 1100, height: 800))
        case "pinned":
            let kinds = (environment["PINNED"] ?? "power").split(separator: ",")
                .compactMap { WidgetKind(rawValue: String($0)) }
            for kind in WidgetKind.allCases where kind.isPinnable { widgets.setPinned(kind, kinds.contains(kind)) }
        case "idle":
            let stash = StashCoordinator(store: store)
            stash.enable()
            triggers.rearm()
            keep.append(stash)
        default:
            show(MonitorPanel(), size: NSSize(width: 306, height: 800))
            widgets.panelDidOpen()
        }
        print("bench \(surface) — pid \(getpid()), modules \(widgets.runningCount)")
        fflush(stdout)
    }
}
