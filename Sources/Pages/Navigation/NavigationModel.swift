import Foundation

/// Which tool is showing, whether the rail is collapsed, and whether the
/// current tool's settings pane is open.
///
/// Deliberately three small `@Published` values with equality guards: an
/// identical write must never republish, or SwiftUI's scene updates can loop.
@MainActor
final class NavigationModel: ObservableObject {
    /// The live instance, so the developer menu can move the selection off a
    /// tool it has just switched off. Set on init; there is only ever one.
    private(set) static weak var shared: NavigationModel?

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

    /// Moves off a page that is no longer available — either because the
    /// developer menu just hid it, or because it was hidden when the app last
    /// quit and the stored selection points at it.
    func retreatIfUnavailable() {
        let available = Page.available
        guard !available.contains(page) else { return }
        page = available.first ?? .settings
    }

    private enum Keys {
        static let page = "navigationPage"
        static let collapsed = "sidebarCollapsed"
    }

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [Keys.collapsed: false])
        sidebarCollapsed = defaults.bool(forKey: Keys.collapsed)
        page = defaults.string(forKey: Keys.page).flatMap(Page.init(rawValue:)) ?? .workspaces
        Self.shared = self
        retreatIfUnavailable()
    }

    func select(_ page: Page) {
        self.page = page
    }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

}
