import SwiftUI

/// Collapsible tool rail.
///
/// Fixed width that animates between expanded and icons-only. It carries the
/// *only* sidebar toggle in the app, and reserves the top-left corner for the
/// traffic lights so nothing ever renders underneath them.
struct SidebarView: View {
    @EnvironmentObject private var navigation: NavigationModel

    static let expandedWidth: CGFloat = 208
    static let collapsedWidth: CGFloat = 64

    private var collapsed: Bool { navigation.sidebarCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            VStack(spacing: 4) {
                ForEach(Page.allCases) { page in
                    SidebarItem(page: page,
                                selected: navigation.page == page,
                                collapsed: collapsed) {
                        navigation.select(page)
                    }
                }
            }
            .padding(.horizontal, collapsed ? 8 : 10)

            Spacer(minLength: 0)
            footer
        }
        .frame(width: collapsed ? Self.collapsedWidth : Self.expandedWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Theme.surfaceTop, Theme.panel],
                           startPoint: .top, endPoint: .bottom)
                .grain(0.30)
        )
        .overlay(alignment: .trailing) {
            Rectangle().fill(.black.opacity(0.55)).frame(width: 1)
        }
        .animation(.easeOut(duration: 0.18), value: collapsed)
    }

    /// Top block. The 30pt inset keeps everything clear of the traffic lights,
    /// which float over this corner in a hidden-title-bar window.
    private var brand: some View {
        HStack(spacing: 8) {
            if collapsed {
                // Centred in the rail rather than pinned right, which looked
                // off-axis against the icon column below it.
                Spacer(minLength: 0)
                toggle
                Spacer(minLength: 0)
            } else {
                Text("GRUPPEN")
                    .font(Theme.mono(11, .medium))
                    .tracking(1.3)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                toggle
            }
        }
        .padding(.horizontal, collapsed ? 0 : 14)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }

    private var toggle: some View {
        Button(action: navigation.toggleSidebar) {
            Image(systemName: collapsed ? "sidebar.left" : "sidebar.leading")
                .font(.system(size: 12, weight: .medium))
        }
        .industrialButton(.ghost)
        .help(collapsed ? "Expand sidebar (⌘\\)" : "Collapse sidebar (⌘\\)")
    }

    private var footer: some View {
        Group {
            if collapsed {
                LED(color: Theme.green, lit: true, size: 6)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 6) {
                    LED(color: Theme.green, lit: true, size: 6)
                    Text("GRUPPEN \(Bundle.shortVersion)")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 12)
    }
}

private struct SidebarItem: View {
    let page: Page
    let selected: Bool
    let collapsed: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.orange : (hovering ? Theme.textPrimary : Theme.textSecondary))
                    .frame(width: 18)

                if !collapsed {
                    Text(page.shortTitle)
                        .font(Theme.sans(12, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !page.isImplemented {
                        Text("SOON")
                            .font(Theme.mono(8, .semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .padding(.horizontal, collapsed ? 0 : 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                    .fill(selected ? Theme.orange.opacity(0.12) : (hovering ? Theme.surfaceHover : .clear))
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.orange)
                        .frame(width: 2, height: 16)
                        .shadow(color: Theme.orange.opacity(0.6), radius: 4)
                        .offset(x: collapsed ? -4 : -6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(collapsed ? page.rawValue : page.summary)
    }
}
