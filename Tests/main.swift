import AppKit

@main
struct Suite {
    static func main() async {
        await MainActor.run { sectionCore() }
        await MainActor.run { sectionMigration() }
        await sectionFlows()
        await MainActor.run { sectionFlowEditing() }
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
