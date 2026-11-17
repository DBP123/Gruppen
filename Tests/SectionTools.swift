import Foundation

/// The shared plumbing: running a tool, saving a library.
func sectionTools() async {
    T.begin("H. Tools — running a command-line tool")

    // More than a pipe buffer on both streams. Read-after-exit hangs here for
    // ever; draining while it runs does not.
    do {
        let result = try await Tool.run("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' x; head -c 200000 /dev/zero | tr '\\0' y >&2"])
        T.equal("200KB of output arrives whole", result.output.count, 200_000)
        T.equal("200KB of errors arrives whole", result.errorOutput.count, 200_000)
        T.check("and the run succeeded", result.succeeded)
    } catch { T.check("a chatty tool runs", false, "\(error)") }

    do {
        let result = try await Tool.run("/bin/sh", ["-c", "echo 'no such file' >&2; exit 3"])
        T.equal("a failure keeps its exit status", result.status, 3)
        T.equal("and is worded in the tool's own words", result.failure, "no such file")
        let silent = try await Tool.run("/usr/bin/false", [])
        T.equal("a silent failure names the tool and status", silent.failure, "false failed (exit 1)")
    } catch { T.check("a failing tool runs", false, "\(error)") }

    do {
        let started = Date()
        let result = try await Tool.run("/bin/sleep", ["5"], timeout: 0.3)
        T.check("a timeout stops the tool", result.timedOut && !result.succeeded,
                "\(result.status), \(String(format: "%.1fs", Date().timeIntervalSince(started)))")
        T.check("and does not wait it out", Date().timeIntervalSince(started) < 3)
    } catch { T.check("a slow tool runs", false, "\(error)") }

    await withTempDirAsync { dir in
        do {
            let result = try await Tool.run("/bin/pwd", [], in: dir)
            // `/var` is `/private/var` to pwd, so compare the folder's own name.
            T.equal("the working folder is honoured",
                    (result.output.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent,
                    dir.lastPathComponent)
        } catch { T.check("pwd runs", false, "\(error)") }
    }

    do {
        _ = try await Tool.run("/nonexistent/tool", [])
        T.check("a missing tool throws", false, "it ran")
    } catch { T.check("a missing tool throws", true) }

    T.begin("H. Tools — saving a library")

    withTempDir { dir in
        let file = dir.appendingPathComponent("groups.json")
        T.check("a save to a writable folder succeeds",
                LenientLibrary.save(["a", "b"], to: file, label: "SUITE"))
        T.equal("and reads back", (try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? [], ["a", "b"])
        let missing = dir.appendingPathComponent("Nowhere/groups.json")
        T.check("a save that cannot be written says so",
                !LenientLibrary.save(["a"], to: missing, label: "SUITE"))
    }

    T.begin("H. Tools — naming without clashes")

    T.equal("the first copy keeps its name", FileName.numbered("Report.pdf", 1), "Report.pdf")
    T.equal("the second is numbered Finder's way", FileName.numbered("Report.pdf", 2), "Report 2.pdf")
    T.equal("a name without an extension", FileName.numbered("Notes", 3), "Notes 3")
    T.equal("a folder keeps its dots", FileName.numbered("v1.2", 2, isDirectory: true), "v1.2 2")

    // Names from outside — servers, dragging apps, archives — must stay one
    // harmless path component.
    T.equal("a climbing name stays put", FileName.sanitized("../../x.png"), "x.png")
    T.equal("separators become dashes", FileName.sanitized("a/b:c"), "a-b-c")
    T.equal("a dot file is not hidden", FileName.sanitized(".zshrc"), "zshrc")
    T.equal("a name cannot read as an option", FileName.sanitized("-rf"), "rf")
    T.equal("control characters go", FileName.sanitized("a\u{0}b\nc"), "a-b-c")
    T.equal("nothing left is the fallback", FileName.sanitized(".."), "Untitled")
    T.equal("an ordinary name is untouched", FileName.sanitized("Report 2024.pdf"), "Report 2024.pdf")
    let long = FileName.sanitized(String(repeating: "é", count: 300) + ".jpeg")
    T.check("a long name is cut, keeping its extension",
            long.utf8.count <= FileName.maxBytes && long.hasSuffix(".jpeg"), "\(long.utf8.count) bytes")
    // Archives are read before they are trusted.
    T.check("an entry climbing out is unsafe", StashBatchDispatcher.isUnsafeEntry("a/../../.zshrc"))
    T.check("an absolute entry is unsafe", StashBatchDispatcher.isUnsafeEntry("/etc/hosts"))
    T.check("an ordinary entry is not", !StashBatchDispatcher.isUnsafeEntry("folder/file..name.txt"))
    T.equal("zipinfo's total is read",
            StashBatchDispatcher.expandedBytes(fromTotals: "2 files, 1234 bytes uncompressed, 567 bytes compressed:  54.1%\n"),
            1234)
    T.check("a summary that isn't one reads as nothing",
            StashBatchDispatcher.expandedBytes(fromTotals: "zipinfo: cannot find zipfile") == nil)
    withTempDir { dir in
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("in"), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("in/inside").path,
                                                    withDestinationPath: "../in")
        T.check("a link that stays inside is fine", StashBatchDispatcher.linkLeaving(dir) == nil)
        try? FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("in/out").path,
                                                    withDestinationPath: "../../..")
        T.equal("a link that leaves is found", StashBatchDispatcher.linkLeaving(dir), "out")
    }
    withTempDir { dir in
        try? FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("abs").path,
                                                    withDestinationPath: "/Users")
        T.equal("an absolute link is found", StashBatchDispatcher.linkLeaving(dir), "abs")
    }
    withTempDir { dir in
        let url = FileName.unique("../../escape.txt", in: dir)
        T.equal("a unique URL is always a direct child of its folder",
                url.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
    }
    T.equal("taken names are skipped",
            FileName.unique("a.txt") { ["a.txt", "a 2.txt"].contains($0) }, "a 3.txt")
    withTempDir { dir in
        try? Data().write(to: dir.appendingPathComponent("Stash.zip"))
        T.equal("a file on disk is not overwritten",
                FileName.unique("Stash.zip", in: dir).lastPathComponent, "Stash 2.zip")
    }

    T.begin("H. Tools — dates in file names")

    var parts = DateComponents()
    (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 3, 7, 14, 5, 9)
    let date = Calendar.current.date(from: parts)!
    T.equal("a day", Stamp.day(date), "2026-03-07")
    T.equal("a month", Stamp.month(date), "2026-03")
    T.equal("a moment, 24-hour", Stamp.moment(date), "2026-03-07-140509")

    T.begin("H. Tools — the whole machine, and who shows the detail")

    // proc_listallpids counts pids, not bytes: read as bytes, every sweep saw
    // the first quarter of the machine. The oldest process and this one sit at
    // opposite ends of the list, so both are only there when all of it is.
    let pids = allProcesses()
    T.check("every process is listed, launchd included", pids.contains(1), "\(pids.count) pids")
    T.check("and this one", pids.contains(getpid()))
    T.check("each once", Set(pids).count == pids.count)

    // The dashboard's cards show a module's full detail, as its popover does,
    // so a visible dashboard must ask for the detail-only figures too.
    let detail = await MainActor.run { () -> (Bool?, Bool?) in
        let widgets = WidgetManager.shared
        widgets.setArmed(.network, true)
        widgets.dashboardDidAppear()
        let shown = widgets.module(NetworkTelemetryWidget.self, .network)?.showsDetail
        widgets.dashboardDidDisappear()
        let hidden = widgets.module(NetworkTelemetryWidget.self, .network)?.showsDetail
        widgets.shutdown()
        return (shown, hidden)
    }
    T.check("a visible dashboard shows a module's detail", detail.0 == true, "\(String(describing: detail.0))")
    T.check("and stops when it goes", detail.1 != true, "\(String(describing: detail.1))")
}
