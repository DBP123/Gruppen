import AppKit
import SwiftUI

/// The bar that appears when files are picked out of a shelf.
///
/// Present only while something is selected — an empty selection has nothing to
/// act on, and a row of disabled buttons is worse than no row. The subtitle is
/// the point of the component: a batch drawn from more than one folder behaves
/// differently from one drawn from a single folder, and the moment to say so is
/// before the button is pressed, not in the result afterwards.
struct StashSelectionToolbar: View {
    @EnvironmentObject private var state: ShelfState

    /// Where extraction writes when an origin cannot take it.
    @EnvironmentObject private var settings: AppSettings

    @State private var note: String?
    @State private var working = false

    private var selected: [StashItem] { state.selectedItems }
    private var archives: [StashItem] { selected.filter(\.isArchive) }
    private var origins: Int { state.selectedOriginsCount }

    var body: some View {
        if !selected.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(headline)
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let subtitle {
                            Text(subtitle)
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if !archives.isEmpty {
                        // One button for the ordinary case, a menu only when
                        // there is a genuine choice to make — which there is
                        // only once an origin is involved at all.
                        if origins > 0 {
                            Menu {
                                Button("Back to \(origins == 1 ? "its folder" : "their folders")") {
                                    extract(.origin)
                                }
                                Button("All to \(settings.exportDirectory.lastPathComponent)") {
                                    extract(.fallback)
                                }
                            } label: {
                                Text(working ? "Extracting…" : "Extract \(archives.count)")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(working)
                        } else {
                            Button(working ? "Extracting…" : "Extract \(archives.count)") {
                                extract(.fallback)
                            }
                            .industrialButton(.secondary)
                            .disabled(working)
                        }
                    }

                    Button("Deselect") { state.selection.removeAll() }
                        .industrialButton(.ghost)
                        .disabled(working)
                }

                if let note {
                    Text(note)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .machined(cornerRadius: Theme.radiusSm)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: selected.count)
        }
    }

    // MARK: Copy

    private var headline: String {
        "\(selected.count) item\(selected.count == 1 ? "" : "s") selected"
    }

    /// Says where things came from, and only when that is load-bearing.
    ///
    /// One location is the unremarkable case and gets no second line. More than
    /// one is the whole reason this component exists. Items with no origin —
    /// text, links, files we wrote to scratch — are counted separately rather
    /// than folded in, because "3 items across 1 location" would be a lie about
    /// a selection where two of them came from nowhere.
    private var subtitle: String? {
        let originless = selected.count - selected.filter { $0.originDirectoryURL != nil }.count
        switch (origins, originless) {
        case (0, _):
            return nil
        case (let n, 0) where n > 1:
            return "across \(n) locations"
        case (let n, let loose) where n > 1:
            return "across \(n) locations · \(loose) with no origin"
        case (_, let loose) where loose > 0:
            return "\(loose) with no origin"
        default:
            return nil
        }
    }

    // MARK: Actions

    private func extract(_ mode: UnzipDestinationMode) {
        guard !working else { return }
        working = true
        note = nil
        let batch = archives
        let fallback = settings.exportDirectory

        Task { @MainActor in
            let report = await StashBatchDispatcher.executeBatchUnzip(items: batch,
                                                                     mode: mode,
                                                                     fallback: fallback)
            note = report.summary
            working = false
            // Reveal what landed, the way the zip button does — a batch that
            // finished somewhere you were not looking is a batch you have to go
            // and find.
            if !report.extracted.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(report.extracted)
            }
            GroupStore.log("STASH extract ×\(batch.count) [\(mode == .origin ? "origin" : "fallback")] — "
                           + report.summary)
        }
    }
}
