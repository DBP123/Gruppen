import Foundation

/// Which tool is showing, whether the rail is collapsed, and whether the
/// current tool's settings pane is open.
///
/// Deliberately three small `@Published` values with equality guards: an
/// identical write must never republish, or SwiftUI's scene updates can loop.
@MainActor
final class NavigationModel: ObservableObject {
    @Published var page: Page {
        didSet {
            guard page != oldValue else { return }
            defaults.set(page.rawValue, forKey: Keys.page)
            // A settings pane belongs to the tool that opened it.
            if showingSettingsPane { showingSettingsPane = false }
        }
    }

    @Published var sidebarCollapsed: Bool {
        didSet {
            guard sidebarCollapsed != oldValue else { return }
            defaults.set(sidebarCollapsed, forKey: Keys.collapsed)
        }
    }

    @Published var showingSettingsPane = false

    private enum Keys {
        static let page = "navigationPage"
        static let collapsed = "sidebarCollapsed"
    }

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [Keys.collapsed: false])
        sidebarCollapsed = defaults.bool(forKey: Keys.collapsed)
        page = defaults.string(forKey: Keys.page).flatMap(Page.init(rawValue:)) ?? .workspaces
    }

    func select(_ page: Page) {
        self.page = page
    }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

}
