import AppKit

/// Updater checks with local files only: no network, no real app or speech service.
/// Usage: AppUpdatesTests <notarized.dmg> <signed-but-unnotarized.dmg>
@main @MainActor struct AppUpdatesTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, "FAIL: " + message); count += 1 }
        let args = CommandLine.arguments
        let notarized = URL(fileURLWithPath: args[1]), unnotarized = URL(fileURLWithPath: args[2])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opentoolkit-update-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let team = CodeIdentity(identifier: "local.pico", team: "XWGJRF99GJ")
        func stage(_ dmg: URL, _ identity: CodeIdentity, _ version: String) -> (Bool, URL) {
            let work = root.appendingPathComponent(UUID().uuidString); try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let staged = root.appendingPathComponent(".staged-\(UUID().uuidString).app")
            do { try AppUpdates.verifyAndStage(dmg: dmg, work: work, staged: staged, identity: identity, installedVersion: version); return (true, staged) }
            catch { return (false, staged) }
        }
        // Release asset parsing only accepts this repository's DMG downloads.
        let json = #"{"tag_name":"v0.3.1","html_url":"https://github.com/Barty-Bart/opentoolkit/releases/tag/v0.3.1","draft":false,"prerelease":false,"assets":[{"name":"notes.txt","browser_download_url":"https://github.com/Barty-Bart/opentoolkit/releases/download/v0.3.1/notes.txt","size":10},{"name":"OpenToolkit-0.3.1.dmg","browser_download_url":"https://evil.example/OpenToolkit-0.3.1.dmg","size":100},{"name":"OpenToolkit-0.3.1.dmg","browser_download_url":"https://github.com/Barty-Bart/opentoolkit/releases/download/v0.3.1/OpenToolkit-0.3.1.dmg","size":429000000}]}"#
        let release = try JSONDecoder().decode(PublishedRelease.self, from: Data(json.utf8))
        check(release.installer?.url.host == "github.com" && release.installer?.size == 429000000, "picks this repo's DMG, never another host")
        let other = try JSONDecoder().decode(PublishedRelease.self, from: Data(json.replacingOccurrences(of: "Barty-Bart/opentoolkit/releases/download", with: "someone/else/releases/download").utf8))
        check(other.installer == nil, "rejects DMGs from other repositories")

        let (ok, staged) = stage(notarized, team, "0.1.0")
        check(ok && CodeIdentity.of(staged) == team, "notarized, same-team, newer DMG is staged with its signature intact")
        check(!stage(notarized, team, "0.2.0").0, "same version is refused")
        check(!stage(notarized, CodeIdentity(identifier: "local.pico", team: "OTHERTEAM1"), "0.1.0").0, "different developer is refused")
        check(!stage(unnotarized, team, "0.1.0").0, "un-notarized DMG is refused")

        // Swap script: fake app folders and a fake service label; the real worker is never touched.
        let apps = root.appendingPathComponent("Applications"); let backups = root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let current = apps.appendingPathComponent("OpenToolkit.app"), next = apps.appendingPathComponent(".OpenToolkit-update.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true); try Data("old".utf8).write(to: current.appendingPathComponent("marker"))
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true); try Data("new".utf8).write(to: next.appendingPathComponent("marker"))
        let script = root.appendingPathComponent("swap.sh")
        // Do not let the test open a real app: replace `open` with a no-op recorder.
        try AppUpdates.swapScript.replacingOccurrences(of: "/usr/bin/open \"$current\"", with: "touch \"$backups/opened\"").write(to: script, atomically: true, encoding: .utf8)
        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["1"]; try sleeper.run()
        let swap = Process(); swap.executableURL = URL(fileURLWithPath: "/bin/bash")
        swap.arguments = [script.path, String(sleeper.processIdentifier), current.path, next.path, backups.path, "gui/\(getuid())/opentoolkit.test.nonexistent"]
        try swap.run(); swap.waitUntilExit()
        check(swap.terminationStatus == 0, "swap script succeeds after the app quits")
        check((try? String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8)) == "new", "new app is in place")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        check(kept.contains { $0.hasPrefix("app-") && $0.hasSuffix(".app") } && kept.contains("opened"), "previous app kept for rollback and new app opened")
        check(!FileManager.default.fileExists(atPath: next.path), "staging copy consumed")
        print("App updates: \(count) checks passed using local DMGs and fake folders.")
    }
}

import SwiftUI
/// Minimal stand-in for the app's card view so AppUpdates.swift compiles on its own.
struct ToolCard<Content: View>: View {
    let title: String; let subtitle: String; @ViewBuilder var content: () -> Content
    var body: some View { VStack { content() } }
}
