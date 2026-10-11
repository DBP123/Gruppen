import AppKit
import SwiftUI

/// Everything a shelf can do with its files, in one row at the bottom.
///
/// `[Extract ⌄] [Combine to PDF] [Convert ⌄] ······ [Deselect]`
///
/// **One row, and Deselect always last.** This used to be two bars stacked —
/// the selection's actions above, conversions below — each appearing only when
/// it had something to offer. Which of them showed depended on the files
/// picked, so Deselect sat on a different line from one selection to the next,
/// sometimes on a row of its own, and the pair took two rows of a 200pt shelf.
/// Converting is a menu key now rather than a row of format buttons, which is
/// what lets it all fit on one line: Extract and Combine never appear together
/// (an archive cannot be merged), so the widest case is Combine, Convert and
/// Deselect.
///
/// The count is not repeated here — the header already shows "3/5" — and
/// "across 2 locations" lives in Extract's tooltip, the one action it changes.
struct StashActionBar: View {
    @EnvironmentObject private var state: ShelfState

    /// Where extraction writes when an origin cannot take it.
    @EnvironmentObject private var settings: AppSettings

    /// One line, under the row: why something failed, or where an extraction
    /// went. Successes that leave their result on the shelf — a merge, a
    /// conversion — need no line; the new file is the result. Clears after five
    /// seconds, like the zip key's status.
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

    /// What converting acts on: the selection when there is one, otherwise
    /// every file on the shelf.
    private var convertible: [StashItem] {
        state.actionable.filter { $0.fileURL != nil }
    }

    private var targets: [FileConverter.Target] {
        FileConverter.targets(for: convertible.compactMap(\.fileURL))
    }

    private var hasSelection: Bool { !selected.isEmpty }

    var body: some View {
        if hasSelection || !targets.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if !archives.isEmpty { extractKey }
                    if let merge {
                        Button(working ? "Combining…" : merge.label) { combine(merge) }
                            .industrialButton(.secondary, compact: true)
                            .disabled(working)
                            .help(mergeHelp(merge))
                    }
                    if !targets.isEmpty { convertKey }
                    Spacer(minLength: 0)
                    if hasSelection {
                        Button("Deselect") { state.selection.removeAll() }
                            .industrialButton(.ghost, compact: true)
                            .disabled(working)
                    }
                }

                if let note {
                    Text(note)
                        .font(Theme.mono(8.5))
                        .foregroundStyle(note.hasPrefix("!") ? Theme.red : Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(note)
                        .transition(.opacity)
                }
            }
            .task(id: note) {
                guard note != nil else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                withAnimation(.easeOut(duration: 0.3)) { note = nil }
            }
        }
    }

    /// Extract, as one key — a menu when there is a genuine choice, back to
    /// the archives' own folders or all into the download folder, which there
    /// is only once an origin is involved.
    @ViewBuilder
    private var extractKey: some View {
        let label = working ? "Extracting…" : "Extract \(archives.count)"
        if origins > 0 {
            Menu {
                Button("Back to \(origins == 1 ? "its folder" : "their folders")") { extract(.origin) }
                Button("All to \(settings.exportDirectory.lastPathComponent)") { extract(.fallback) }
            } label: {
                MenuKeyLabel(title: label)
            }
            .menuKey(compact: true)
            .disabled(working)
            .help(locations.map { "Extract \(archives.count) — \($0)" } ?? "Extract \(archives.count)")
        } else {
            Button(label) { extract(.fallback) }
                .industrialButton(.secondary, compact: true)
                .disabled(working)
                .help("Extract into \(settings.exportDirectory.lastPathComponent)")
        }
    }

    /// Convert, as one key whose menu lists the formats. "Convert all" when
    /// nothing is selected, so the scope is never a guess.
    private var convertKey: some View {
        Menu {
            ForEach(targets) { target in
                Button("To \(target.label)") { convert(to: target) }
            }
        } label: {
            MenuKeyLabel(title: working ? "Converting…" : (hasSelection ? "Convert" : "Convert all"))
        }
        .menuKey(compact: true)
        .disabled(working)
    }

    // MARK: Copy

    /// Says where things came from, and only when that is load-bearing.
    ///
    /// One location is the unremarkable case and says nothing. More than one is
    /// worth knowing before extracting. Items with no origin — text, links,
    /// files we wrote to scratch — are counted separately rather than folded
    /// in, because "across 1 location" would be a lie about a selection where
    /// two of them came from nowhere.
    private var locations: String? {
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

    /// Says which merge is about to happen, since "Combine to PDF" does not
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
                GroupStore.log("STASH combine ×\(batch.count) [\(plan.ext)] — \(merged.lastPathComponent)")
            } catch {
                note = "! \(error.localizedDescription)"
                GroupStore.log("STASH combine ×\(batch.count) failed — \(error.localizedDescription)")
            }
            working = false
        }
    }

    /// Converts what is selected — or everything — and swaps the results in.
    ///
    /// The shelf ends up holding the *result*, not both, and the result lives
    /// in the stash's temporary directory rather than beside the original. The
    /// original is untouched, right where it was, and nothing new appears in
    /// its folder.
    private func convert(to target: FileConverter.Target) {
        let subjects = convertible
        let urls = subjects.compactMap(\.fileURL)
        guard !working, !urls.isEmpty else { return }
        working = true
        note = nil

        Task { @MainActor in
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try FileConverter.convert(urls, to: target)
                }.value
                // Added before the originals go, so the shelf is never empty
                // in between — an emptied shelf closes itself.
                state.add(results.map { StashItem.virtual(file: $0, kind: .file,
                                                          title: $0.lastPathComponent) })
                subjects.forEach { state.remove($0) }
            } catch {
                note = "! \(error.localizedDescription)"
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
