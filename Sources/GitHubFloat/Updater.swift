import AppKit

/// Checks GitHub Releases for a newer version and upgrades through Homebrew when possible.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "vinimcorrea/github-float"

    @Published private(set) var latest: String?
    @Published private(set) var releaseURL: URL?
    private var loop: Task<Void, Never>?
    private let checkEvery: UInt64 = 6 * 3600

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var available: Bool {
        guard let latest, let current else { return false }
        return Self.isNewer(latest, than: current)
    }

    func start() {
        guard current != nil, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: (self?.checkEvery ?? 21_600) * 1_000_000_000)
            }
        }
    }

    /// Returns false when GitHub could not be reached.
    @discardableResult
    func check() async -> Bool {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return false }
        latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
        promptOnce()
        return true
    }

    /// Pops up once per new version; "Later" leaves the Update button in the panel header.
    private func promptOnce() {
        guard available, let latest, UserDefaults.standard.string(forKey: "promptedVersion") != latest else { return }
        UserDefaults.standard.set(latest, forKey: "promptedVersion")
        prompt()
    }

    func prompt() {
        guard let latest else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "GitHub Float \(latest) is available"
        alert.informativeText = "You have \(current ?? "?")."
            + (Self.viaBrew ? " It will upgrade with Homebrew in Terminal and relaunch." : " The download page will open.")
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if let releaseURL {
            alert.addButton(withTitle: "What's New")
            alert.buttons[2].keyEquivalent = ""
            switch alert.runModal() {
            case .alertFirstButtonReturn: upgrade()
            case .alertThirdButtonReturn: NSWorkspace.shared.open(releaseURL)
            default: break
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            upgrade()
        }
    }

    /// Homebrew installs upgrade in Terminal (so the user sees progress) and relaunch; others get the release page.
    func upgrade() {
        guard Self.viaBrew, let brew = Self.brewPath else {
            NSWorkspace.shared.open(releaseURL ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
            return
        }
        let script = """
        #!/bin/zsh
        clear
        echo "Upgrading GitHub Float…"
        "\(brew)" update --quiet && "\(brew)" upgrade --cask github-float && open -a GitHubFloat && echo "\\n✅ Done. You can close this window."
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("upgrade-github-float.command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            NSWorkspace.shared.open(releaseURL ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
        }
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", NSHomeDirectory() + "/homebrew/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var viaBrew: Bool { brewPath.map(installedWithBrew) ?? false }

    private static func installedWithBrew(_ brew: String) -> Bool {
        let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: prefix.appendingPathComponent("Caskroom/github-float").path)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
