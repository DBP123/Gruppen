import AppKit

@main
struct Suite {
    static func main() async {
        await MainActor.run { sectionCore() }
        await MainActor.run { sectionMigration() }
        await sectionScripts()
        sectionTelemetry()
        await MainActor.run { sectionStash() }
        await sectionWorkspaces()
        await MainActor.run { sectionPortability() }
        exit(T.summary())
    }
}
