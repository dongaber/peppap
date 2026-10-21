import Foundation

@main
@MainActor
enum PeppapTests {
    static func main() {
        Prefs.register()
        TestRun.run([
            ("HookEvent", hookEventTests),
            ("StatusInfo", statusInfoTests),
            ("Diff", diffTests),
            ("Usage", usageTests),
            ("Transcript", transcriptTests),
            ("SessionStore", sessionStoreTests),
            ("HookInstaller", hookInstallerTests),
            ("Server token", serverTokenTests),
            ("Report", reportTests),
            ("L10n", l10nTests),
            ("Updater", updaterTests),
            ("GitLab", gitlabTests),
            ("GitLab events", gitlabEventTests),
            ("Navigation", navigationTests),
            ("GitLab actions", gitlabActionTests),
            ("GitHub", githubTests),
            ("Codex", codexTests),
            ("Codex cost", codexCostTests),
        ])
    }
}
