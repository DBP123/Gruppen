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

    /// The merge this selection supports, if it supports one.
    ///
    /// Nil for a single file — combining one thing produces a copy, not a merge —
    /// and nil for a selection holding something that cannot be read, rather than
    /// quietly dropping that file and handing back a document with a page
    /// missing. See `StashFileMerger.plan(for:)`.
    private var merge: StashFileMerger.Plan? {
        StashFileMerger.plan(for: selected.compactMap(\.fileURL))
    }

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

                    if let merge {
                        Button(working ? "Combining…" : merge.label) { combine(merge) }
                            .industrialButton(.secondary)
                            .disabled(working)
                            .help(mergeHelp(merge))
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
            // Rises from the bottom edge, which is where it sits and where the
            // rows above it make room. The animation that drives this lives on
            // the enclosing stack in `StashTrayView`: a `.transition` is played
            // by whatever animates the *insertion*, so an `.animation` attached
            // here would only ever cover changes within a bar already on screen.
            .transition(.move(edge: .bottom).combined(with: .opacity))
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

    /// Says which merge is about to happen, since "Combine into PDF" does not
    /// distinguish appending six PDFs from rendering six screenshots.
    private func mergeHelp(_ plan: StashFileMerger.Plan) -> String {
        switch plan {
        case .text: return "Join \(selected.count) text files into one, each section labelled"
        case .pdf: return "Append \(selected.count) PDFs into one, in the order shown"
        case .images: return "One page per image, each at its own size"
        case .mixed: return "Render \(selected.count) mixed files onto Letter pages in one PDF"
        }
    }

    // MARK: Actions

    /// Merges the selection, puts the result on the shelf, and leaves the
    /// originals alone.
    ///
    /// The same contract as a conversion: the merged file lands in scratch and
    /// becomes a real file somewhere real at the moment it is dragged out.
    /// Unlike a conversion, the inputs stay on the shelf — a merge you dislike
    /// should be one deletion to undo, not six files to find again.
    private func combine(_ plan: StashFileMerger.Plan) {
        guard !working else { return }
        working = true
        note = nil
        let batch = selected

        Task { @MainActor in
            do {
                let merged = try await StashFileMerger.combineStashItems(batch)
                state.add([StashItem.virtual(file: merged, kind: .file,
                                             title: merged.lastPathComponent)])
                // The inputs are no longer the thing you are carrying, so the
                // selection moves off them; the merged file is what is left to
                // act on. Deselecting rather than removing keeps them on the
                // shelf, which is the point.
                state.selection.removeAll()
                note = "Combined \(batch.count) → \(merged.lastPathComponent)"
                GroupStore.log("STASH combine ×\(batch.count) [\(plan.ext)] — \(merged.lastPathComponent)")
            } catch {
                note = "! \(error.localizedDescription)"
                GroupStore.log("STASH combine ×\(batch.count) failed — \(error.localizedDescription)")
            }
            working = false
        }
    }

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
            // Reveal what landed, the way the zip key does — a batch that
            // finished somewhere you were not looking is a batch you have to go
            // and find.
            if !report.extracted.isEmpty {
                FinderUtility.revealAndFocus(urls: report.extracted)
            }
            GroupStore.log("STASH extract ×\(batch.count) [\(mode == .origin ? "origin" : "fallback")] — "
                           + report.summary)
        }
    }
}
