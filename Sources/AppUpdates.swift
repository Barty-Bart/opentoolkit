import AppKit
import Security
import SwiftUI

struct PublishedRelease: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int }
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    var assets: [Asset] = []
    enum CodingKeys: String, CodingKey { case tag_name, html_url, draft, prerelease, assets }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag_name = try c.decode(String.self, forKey: .tag_name); html_url = try c.decode(String.self, forKey: .html_url)
        draft = try c.decode(Bool.self, forKey: .draft); prerelease = try c.decode(Bool.self, forKey: .prerelease)
        assets = (try? c.decode([Asset].self, forKey: .assets)) ?? []
    }
    static func approvedURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil,
              url.path.hasPrefix("/Barty-Bart/opentoolkit/releases/tag/") else { return nil }
        return url
    }
    /// The release's notarized DMG, only from this repository's release downloads.
    var installer: (url: URL, size: Int)? {
        for asset in assets where asset.name.hasPrefix("OpenToolkit") && asset.name.hasSuffix(".dmg") && asset.size > 0 && asset.size < 900_000_000 {
            guard let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com",
                  url.user == nil, url.path.hasPrefix("/Barty-Bart/opentoolkit/releases/download/") else { continue }
            return (url, asset.size)
        }
        return nil
    }
}

struct UpdateFailure: LocalizedError { let message: String; var errorDescription: String? { message } }

/// Identity of a signed bundle, read with the Security framework.
struct CodeIdentity: Equatable {
    let identifier: String
    let team: String
    static func of(_ url: URL) -> CodeIdentity? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return read(code)
    }
    static func running() -> CodeIdentity? {
        var code: SecCode?; var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return read(staticCode)
    }
    private static func read(_ code: SecStaticCode) -> CodeIdentity? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return CodeIdentity(identifier: identifier, team: team)
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    let report: (Int64) -> Void
    init(_ report: @escaping (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { report(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

@MainActor final class AppUpdates: ObservableObject {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    @Published var message = "Check GitHub for a published release. Your installed app stays running."
    @Published var checking = false
    @Published var installing = false
    @Published var releaseURL: URL?
    @Published var available: PublishedRelease?
    /// Returns a reason to wait (recording, dictating…) or nil when it's safe to restart.
    var busyReason: () -> String? = { nil }

    func check() {
        guard !checking, !installing else { return }
        checking = true; releaseURL = nil; available = nil; message = "Checking releases…"
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/Barty-Bart/opentoolkit/releases/latest")!)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("OpenToolkit-update-check", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode
                if code == 404 { message = "No public release is available yet. This local build is installed."; return }
                guard code == 200, data.count < 1_000_000 else { throw URLError(.badServerResponse) }
                let release = try JSONDecoder().decode(PublishedRelease.self, from: data)
                guard !release.draft, !release.prerelease, let url = PublishedRelease.approvedURL(release.html_url) else { throw URLError(.badServerResponse) }
                let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                guard version.range(of: "^[0-9]+(?:\\.[0-9]+){1,2}$", options: .regularExpression) != nil else {
                    message = "Release \(release.tag_name) is available to review."; releaseURL = url; return
                }
                if version.compare(Self.version, options: .numeric) == .orderedDescending {
                    releaseURL = url
                    if release.installer != nil { available = release; message = "OpenToolkit \(version) is available." }
                    else { message = "Update available: \(release.tag_name). Download it from the release page." }
                } else { message = "You're up to date · OpenToolkit \(Self.version) (latest release \(release.tag_name))." }
            } catch { message = "Could not check GitHub. Your app is unchanged. Try again when online." }
        }
    }

    /// Download the release DMG, verify it is notarized and signed by the same developer,
    /// then quit, swap the app in place and relaunch. Library and settings live outside the app.
    func install() {
        guard let release = available, let installer = release.installer, !installing else { return }
        if let reason = busyReason() { message = reason; return }
        installing = true
        Task {
            do {
                let staged = try await prepare(installer.url, expected: installer.size, tag: release.tag_name)
                if let reason = busyReason() { try? FileManager.default.removeItem(at: staged); throw UpdateFailure(message: reason) }
                try launchSwap(staged)
                message = "Restarting OpenToolkit…"
                NSApp.terminate(nil)
                // If quitting was cancelled (for example an unsaved editor), the swap script gives up and keeps this app.
                installing = false
            } catch {
                installing = false
                message = "Update not installed: \(error.localizedDescription) Your current app is unchanged."
            }
        }
    }

    private func prepare(_ url: URL, expected: Int, tag: String) async throws -> URL {
        let current = Bundle.main.bundleURL
        guard let identity = CodeIdentity.running() else { throw UpdateFailure(message: "This copy isn't from a signed release, so it can't update itself.") }
        guard !current.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdateFailure(message: "Move OpenToolkit into your Applications folder first.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("OpenToolkit-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let megabytes = expected / 1_000_000
        message = "Downloading \(tag) (\(megabytes) MB)…"
        let progress = DownloadProgress { [weak self] written in
            let percent = Int(Double(written) / Double(max(expected, 1)) * 100)
            Task { @MainActor in self?.message = "Downloading \(tag)… \(min(percent, 100))%" }
        }
        var request = URLRequest(url: url); request.timeoutInterval = 60
        request.setValue("OpenToolkit-updater", forHTTPHeaderField: "User-Agent")
        let (downloaded, response) = try await URLSession.shared.download(for: request, delegate: progress)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure(message: "The download failed.") }
        let dmg = work.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: downloaded, to: dmg)
        message = "Checking the download…"
        let staged = current.deletingLastPathComponent().appendingPathComponent(".OpenToolkit-update-\(UUID().uuidString).app")
        let installedVersion = Self.version
        try await Task.detached(priority: .userInitiated) {
            try Self.verifyAndStage(dmg: dmg, work: work, staged: staged, identity: identity, installedVersion: installedVersion)
        }.value
        return staged
    }

    /// Accept the DMG only if Apple notarized it and its app is the same signed product, newer
    /// than this one. Copies the app next to the current one; never touches the running app.
    nonisolated static func verifyAndStage(dmg: URL, work: URL, staged: URL, identity: CodeIdentity, installedVersion: String) throws {
        let mount = work.appendingPathComponent("mount")
        try run("/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg.path, failure: "The download isn't a notarized disk image.")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path, failure: "The disk image couldn't be opened.")
        defer { try? run("/usr/bin/hdiutil", "detach", mount.path, "-force", failure: "") }
        let app = mount.appendingPathComponent("OpenToolkit.app")
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path, failure: "The new app's signature is invalid.")
        try run("/usr/sbin/spctl", "--assess", "--type", "execute", app.path, failure: "The new app isn't notarized by Apple.")
        guard CodeIdentity.of(app) == identity else { throw UpdateFailure(message: "The new app isn't signed by the same developer.") }
        let newVersion = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard newVersion.compare(installedVersion, options: .numeric) == .orderedDescending else { throw UpdateFailure(message: "The download isn't newer than this app.") }
        try run("/usr/bin/ditto", app.path, staged.path, failure: "The new app couldn't be copied.")
        do { try run("/usr/bin/codesign", "--verify", "--deep", "--strict", staged.path, failure: "The copied app failed verification.") }
        catch { try? FileManager.default.removeItem(at: staged); throw error }
    }

    nonisolated private static func run(_ tool: String, _ arguments: String..., failure: String) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure(message: failure) }
    }

    /// A detached script waits for this app to quit, stops the old speech worker, swaps the
    /// bundles (keeping the previous app for rollback), and opens the new version.
    private func launchSwap(_ staged: URL) throws {
        let current = Bundle.main.bundleURL
        let backups = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pico/InstallBackups")
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("opentoolkit-swap-\(UUID().uuidString).sh")
        try Self.swapScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), current.path, staged.path, backups.path, "gui/\(getuid())/local.pico.speech"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    nonisolated static let swapScript = """
        #!/bin/bash
        pid="$1"; current="$2"; staged="$3"; backups="$4"; service="$5"
        for _ in $(seq 1 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$pid" 2>/dev/null; then rm -rf "$staged"; rm -f "$0"; exit 1; fi
        /bin/launchctl kill SIGTERM "$service" 2>/dev/null
        for _ in $(seq 1 100); do /bin/launchctl print "$service" 2>/dev/null | grep -q "state = running" || break; sleep 0.1; done
        mkdir -p "$backups"; previous="$backups/app-$(date +%Y%m%d-%H%M%S)"
        if mv "$current" "$previous.app"; then
          if mv "$staged" "$current"; then
            # Keep only the newest previous app (each is a full copy of OpenToolkit).
            ls -d "$backups"/app-*.app 2>/dev/null | sort | sed '$d' | while IFS= read -r old; do rm -rf "$old"; done
            /usr/bin/open "$current"; rm -f "$0"; exit 0
          fi
          mv "$previous.app" "$current"
        fi
        rm -rf "$staged"; /usr/bin/open "$current"; rm -f "$0"
        """
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdates
    var body: some View {
        ToolCard(title: "OpenToolkit \(AppUpdates.version)", subtitle: "Build \(AppUpdates.build) · installed on this Mac") {
            HStack {
                Button(updates.checking ? "Checking…" : "Check for updates") { updates.check() }.disabled(updates.checking || updates.installing)
                if let release = updates.available {
                    Button(updates.installing ? "Installing…" : "Download & install \(release.tag_name)") { updates.install() }
                        .buttonStyle(.borderedProminent).disabled(updates.installing)
                }
                if let url = updates.releaseURL { Button("What's new") { NSWorkspace.shared.open(url) } }
            }
            Text(updates.message).font(.callout).foregroundStyle(.secondary)
            Text("Updates come only from this app's GitHub releases. The download must be notarized by Apple and signed by the same developer before it replaces the app. Your library, settings and permissions stay as they are.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
