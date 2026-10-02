import Foundation

/// Where a batch extraction puts what it unpacks.
enum UnzipDestinationMode: Equatable {
    /// Each archive back into the directory it came from. Anything without a
    /// usable origin — or whose origin refuses the write — goes to the fallback.
    case origin
    /// Everything into the fallback folder, whatever the archives' origins.
    case fallback
}

/// Unpacks several archives at once, each to the right place.
///
/// ## The problem this solves
///
/// Drag three zips onto a shelf from three different folders and "extract" has
/// no single answer: each one belongs somewhere different. This groups the batch
/// by origin, decides per-directory whether that origin can actually take the
/// files, and runs the extractions concurrently.
///
/// ## Why `isWritableFile` is a filter and not the decision
///
/// The spec for this asked for `FileManager.default.isWritableFile` to gate the
/// destination, and it is the right first question — but it is only advisory. It
/// reports the POSIX permission bits for the effective uid, and on a modern Mac
/// that is not what decides whether a write succeeds: Desktop, Documents and
/// Downloads are TCC-protected, so a path can answer `true` here and still fail
/// with "Operation not permitted" because the user has not granted the app
/// access to that folder. An app that trusted the check would report success on
/// a batch that wrote nothing.
///
/// So the check runs first, cheaply, to redirect the origins we can already see
/// are hopeless — and a *real* write failure redirects to the fallback too, on
/// the same terms. The permission bits are a hint; the write is the truth.
///
/// ## Concurrency
///
/// `withTaskGroup`, bounded to four at a time. Unbounded would launch one
/// `ditto` per archive — fifty archives is fifty processes competing for the
/// same disk, which finishes no sooner and makes the machine unusable while it
/// does. Each extraction waits on a `terminationHandler` through a continuation
/// rather than `waitUntilExit()`: blocking inside a task group parks a thread
/// from the cooperative pool, and four parked threads is most of it.
@MainActor
enum StashBatchDispatcher {
    /// How many extractions run at once.
    static let maxConcurrent = 4

    // MARK: Types

    /// One archive and where it is going. Deliberately plain values — nothing
    /// here crosses a concurrency boundary holding a `StashItem`.
    struct Job: Sendable {
        let archive: URL
        let title: String
        /// Where it should land.
        let destination: URL
        /// Where to retry if `destination` turns out to refuse the write.
        /// Nil when the destination already *is* the fallback.
        let fallback: URL?
        /// True when the plan already sent this away from its origin, so the
        /// report can say how much of the batch was redirected before it ran.
        let redirectedByPlan: Bool
    }

    struct Plan: Sendable {
        var jobs: [Job] = []
        /// Titles of selected items that are not archives, so the UI can say
        /// "2 of 5 selected items are not archives" rather than silently
        /// dropping them.
        var skipped: [String] = []
        /// Distinct origins across the archives in this batch.
        var originCount: Int = 0
        var redirectedByPlan: Int = 0

        var isEmpty: Bool { jobs.isEmpty }
    }

    struct Failure: Sendable {
        let title: String
        let reason: String
    }

    struct Report: Sendable {
        var extracted: [URL] = []
        var failures: [Failure] = []
        /// Sent somewhere other than its origin, whether the plan decided that
        /// or the write itself did.
        var redirected: Int = 0
        var skipped: [String] = []

        var didAnything: Bool { !extracted.isEmpty }

        /// One line for the shelf's note row.
        var summary: String {
            var parts: [String] = []
            if !extracted.isEmpty { parts.append("Extracted \(extracted.count)") }
            if redirected > 0 { parts.append("\(redirected) redirected") }
            if !failures.isEmpty { parts.append("\(failures.count) failed") }
            if !skipped.isEmpty { parts.append("\(skipped.count) not an archive") }
            return parts.isEmpty ? "Nothing to extract" : parts.joined(separator: " · ")
        }
    }

    // MARK: Entry point

    /// Groups, decides, and runs. The signature the UI calls.
    ///
    /// `fallback` defaults to the shelf's configured download folder. It is an
    /// optional rather than a default argument of
    /// `AppSettings.shared.exportDirectory` because a default argument is
    /// evaluated in a *nonisolated* context — reaching a main-actor singleton
    /// from there does not compile. Resolving it in the body, which is already
    /// on the main actor, costs nothing and keeps the call site the same.
    @discardableResult
    static func executeBatchUnzip(items: [StashItem],
                                  mode: UnzipDestinationMode,
                                  fallback: URL? = nil) async -> Report {
        let destination = fallback ?? AppSettings.shared.exportDirectory
        let plan = plan(items: items, mode: mode, fallback: destination)
        guard !plan.isEmpty else {
            return Report(extracted: [], failures: [], redirected: 0, skipped: plan.skipped)
        }
        var report = await execute(plan)
        report.skipped = plan.skipped
        return report
    }

    // MARK: Planning

    /// Works out where everything goes, on the main actor, before any of it runs.
    ///
    /// Separated from execution on purpose: this is the half that reads
    /// `StashItem`, and keeping it here means the concurrent half never touches
    /// a type that is not `Sendable`.
    static func plan(items: [StashItem],
                     mode: UnzipDestinationMode,
                     fallback: URL) -> Plan {
        var plan = Plan()

        let archives = items.filter(\.isArchive)
        plan.skipped = items.filter { !$0.isArchive }.map(\.title)

        // Group by origin so each directory is asked about once, however many
        // archives came from it. Items with no origin — text, links, virtual
        // files — collect under nil and go straight to the fallback.
        let grouped = Dictionary(grouping: archives) { $0.originDirectoryURL }
        plan.originCount = grouped.keys.compactMap { $0 }.count

        // One writability test per unique directory, not per archive.
        var writable: [URL: Bool] = [:]
        for case let origin? in grouped.keys {
            writable[origin] = isWritableDirectory(origin)
        }

        for (origin, group) in grouped {
            let originUsable = mode == .origin && origin.map { writable[$0] == true } == true
            for item in group {
                guard let archive = item.fileURL else { continue }
                let destination = originUsable ? origin! : fallback
                let redirected = mode == .origin && !originUsable
                if redirected { plan.redirectedByPlan += 1 }
                plan.jobs.append(Job(archive: archive,
                                     title: item.title,
                                     destination: destination,
                                     // No point retrying the fallback at the
                                     // fallback.
                                     fallback: destination == fallback ? nil : fallback,
                                     redirectedByPlan: redirected))
            }
        }
        return plan
    }

    /// Exists, is a directory, and the permission bits say we may write it.
    ///
    /// See the note at the top: a `true` here is necessary, not sufficient.
    static func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    // MARK: Execution

    private static func execute(_ plan: Plan) async -> Report {
        var report = Report(redirected: plan.redirectedByPlan)

        await withTaskGroup(of: JobResult.self) { group in
            var next = 0

            func addNext() {
                guard next < plan.jobs.count else { return }
                let job = plan.jobs[next]
                next += 1
                group.addTask { await run(job) }
            }

            for _ in 0..<min(maxConcurrent, plan.jobs.count) { addNext() }

            for await result in group {
                switch result.outcome {
                case .extracted(let url):
                    report.extracted.append(url)
                    // Redirected *after* planning: the origin passed the
                    // permission check and refused the write anyway.
                    if result.redirectedAtWrite { report.redirected += 1 }
                case .failed(let reason):
                    report.failures.append(Failure(title: result.title, reason: reason))
                }
                addNext()
            }
        }
        return report
    }

    private struct JobResult: Sendable {
        enum Outcome: Sendable {
            case extracted(URL)
            case failed(String)
        }
        let title: String
        let outcome: Outcome
        let redirectedAtWrite: Bool
    }

    /// One archive. Tries its destination; on a real refusal, tries the fallback.
    private nonisolated static func run(_ job: Job) async -> JobResult {
        do {
            let url = try await extract(job.archive, into: job.destination)
            return JobResult(title: job.title, outcome: .extracted(url), redirectedAtWrite: false)
        } catch {
            guard let fallback = job.fallback else {
                return JobResult(title: job.title,
                                 outcome: .failed(error.localizedDescription),
                                 redirectedAtWrite: false)
            }
            // The permission bits lied — TCC, a read-only mount, a directory
            // that vanished between planning and writing. The fallback is what
            // it is for.
            do {
                let url = try await extract(job.archive, into: fallback)
                return JobResult(title: job.title, outcome: .extracted(url), redirectedAtWrite: true)
            } catch {
                return JobResult(title: job.title,
                                 outcome: .failed(error.localizedDescription),
                                 redirectedAtWrite: false)
            }
        }
    }

    /// Unpacks into a folder named after the archive, never over the top of
    /// whatever is already there.
    ///
    /// Archive Utility's behaviour, and for its reason: `report.zip` extracted
    /// beside an existing `report/` would merge into it, and a batch that
    /// quietly overwrites someone's folder is not recoverable.
    private nonisolated static func extract(_ archive: URL, into directory: URL) async throws -> URL {
        let base = archive.deletingPathExtension().lastPathComponent
        let folder = uniqueFolder(in: directory, named: base.isEmpty ? "Extracted" : base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // `-x -k`: extract, treating the input as a PKZip archive. The same pair
        // Archive Utility uses. `unzip` would also work and is not equivalent —
        // it drops resource forks and extended attributes that ditto preserves.
        //
        // Quarantine is deliberately *not* stripped. `--noqtn` would make
        // extracted files launch without Gatekeeper ever asking, which is not a
        // decision a shelf gets to make on the user's behalf.
        process.arguments = ["-x", "-k", archive.path, folder.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        let status = try await terminationStatus(of: process)
        guard status == 0 else {
            // Clean up the empty folder, or a failed batch litters the
            // destination with directories containing nothing.
            try? FileManager.default.removeItem(at: folder)
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExtractionError.dittoFailed(status: status,
                                              message: message.isEmpty ? "exit \(status)" : message)
        }
        return folder
    }

    /// Awaits a process without parking a cooperative thread.
    ///
    /// `waitUntilExit()` blocks whichever thread it is called on. Inside a task
    /// group that is a thread from the cooperative pool, which is sized to the
    /// core count — four concurrent extractions would hold four of them for the
    /// duration. The termination handler hands the wait back to the runtime.
    private nonisolated static func terminationStatus(of process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            // Set before `run()`: a process that exits immediately can call this
            // back before the call to run returns.
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                // `run()` throwing means nothing launched, so the handler will
                // never fire and this is the only resume.
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private nonisolated static func uniqueFolder(in directory: URL, named base: String) -> URL {
        var candidate = directory.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    enum ExtractionError: LocalizedError {
        case dittoFailed(status: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .dittoFailed(_, let message): return message
            }
        }
    }
}
