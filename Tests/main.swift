import AppKit

@main
struct Suite {
    static func main() async {
        await MainActor.run { sectionCore() }
        await MainActor.run { sectionMigration() }
        await sectionScripts()
        await sectionScriptSteps()
        await sectionScriptTransfer()
        sectionTelemetry()
        await MainActor.run { sectionStash() }
        await sectionWorkspaces()
        await MainActor.run { sectionPortability() }
        sectionMerge()
        await sectionAppPower()
        exit(T.summary())
    }
}
