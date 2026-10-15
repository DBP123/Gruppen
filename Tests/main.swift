import AppKit

@main
struct Suite {
    static func main() async {
        await MainActor.run { sectionCore() }
        await MainActor.run { sectionMigration() }
        await sectionScripts()
        await sectionScriptSteps()
        await sectionScriptTransfer()
        await sectionAutomationEngine()
        await sectionTools()
        await sectionSequencing()
        sectionTelemetry()
        await sectionStash()
        await sectionWorkspaces()
        await MainActor.run { sectionPortability() }
        sectionMerge()
        await sectionAppPower()
        exit(T.summary())
    }
}
