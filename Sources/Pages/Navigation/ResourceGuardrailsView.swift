import SwiftUI

/// Resource Guardrails — designed, not built. It shows what it will be and
/// says so, rather than presenting controls that do nothing.
struct ResourceGuardrailsView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: Page.guardrails.systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text("RESOURCE GUARDRAILS")
                .font(Theme.mono(12, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Text(Page.guardrails.summary)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Chip(text: "NOT BUILT YET", tint: Theme.textMuted, size: 9)

            FootNote("Gruppen's own footprint is already measurable — see the performance readout in the menu bar.")
                .frame(maxWidth: 360)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(40)
        .background(Theme.panel.grain(0.26))
    }
}
