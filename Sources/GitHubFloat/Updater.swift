import AppKit

/// Checks GitHub Releases for a newer version and installs it in place with one click.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "vinimcorrea/github-float"

    @Published private(set) var latest: String?
    @Published private(set) var installing = false
    private var zipURL: URL?
    private var notes: String?
    private var loop: Task<Void, Never>?
    private let checkEvery: UInt64 = 3 * 3600
    private let remindAfter: TimeInterval = 24 * 3600
    private var progressWindow: NSPanel?

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
                try? await Task.sleep(nanoseconds: (self?.checkEvery ?? 10_800) * 1_000_000_000)
            }
        }
    }

    /// Returns false when GitHub could not be reached.
    @discardableResult
    func check(promptIfDue: Bool = true) async -> Bool {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return false }
        latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        notes = json["body"] as? String
        let assets = json["assets"] as? [[String: Any]] ?? []
        zipURL = assets.first { ($0["name"] as? String) == "GitHubFloat.zip" }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        if promptIfDue { self.promptIfDue() }
        return true
    }

    /// Asks right away for a new version, then again a day after each "Remind Me Later".
    private func promptIfDue() {
        guard available, !installing, let latest else { return }
        let d = UserDefaults.standard
        if d.string(forKey: "remindVersion") == latest, let after = d.object(forKey: "remindAfter") as? Date, Date() < after { return }
        prompt()
    }

    func prompt() {
        guard let latest, !installing else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "A new version of GitHub Float is available"
        var info = "GitHub Float \(latest) is ready to install (you have \(current ?? "?")). It takes a few seconds and the app reopens by itself."
        if let notes = Self.summary(of: notes) { info += "\n\nWhat's new:\n\(notes)" }
        alert.informativeText = info
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Remind Me Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await install() }
        } else {
            UserDefaults.standard.set(latest, forKey: "remindVersion")
            UserDefaults.standard.set(Date().addingTimeInterval(remindAfter), forKey: "remindAfter")
        }
    }

    // MARK: Install

    /// Downloads the release zip, swaps the app bundle in place and relaunches.
    func install() async {
        guard !installing, let latest else { return }
        installing = true
        showProgress("Downloading GitHub Float \(latest)…")
        defer { installing = false; hideProgress() }
        do {
            let zip = zipURL ?? URL(string: "https://github.com/\(Self.repo)/releases/download/v\(latest)/GitHubFloat.zip")!
            let (file, resp) = try await URLSession.shared.download(from: zip)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
            showProgress("Installing GitHub Float \(latest)…")
            let target = Bundle.main.bundleURL
            try await Task.detached { try Self.replace(app: target, withZip: file, expecting: latest) }.value
            relaunch(target)
        } catch {
            hideProgress()
            let alert = NSAlert()
            alert.messageText = "Could not update GitHub Float"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can download it manually from the releases page."
            alert.addButton(withTitle: "Open Releases Page")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
            }
        }
    }

    private nonisolated static func replace(app target: URL, withZip zip: URL, expecting version: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("githubfloat-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let fresh = work.appendingPathComponent("GitHubFloat.app")
        guard let bundle = Bundle(url: fresh),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw UpdateError("The downloaded app is not valid.")
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", fresh.path])
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError("No permission to write to \(target.deletingLastPathComponent().path).")
        }
        _ = try fm.replaceItemAt(target, withItemAt: fresh)
    }

    private nonisolated static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(p.terminationStatus)).") }
    }

    /// Waits for this process to exit, then opens the new bundle.
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func showProgress(_ text: String) {
        if progressWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
                                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Updating GitHub Float"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            let spinner = NSProgressIndicator(frame: NSRect(x: 18, y: 22, width: 20, height: 20))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 48, y: 22, width: 260, height: 20)
            label.tag = 1
            panel.contentView?.addSubview(spinner)
            panel.contentView?.addSubview(label)
            panel.center()
            progressWindow = panel
        }
        (progressWindow?.contentView?.viewWithTag(1) as? NSTextField)?.stringValue = text
        progressWindow?.orderFrontRegardless()
    }

    private func hideProgress() {
        progressWindow?.orderOut(nil)
    }

    /// First few bullet lines of the release notes.
    private static func summary(of notes: String?) -> String? {
        guard let notes else { return nil }
        let lines = notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .prefix(5).map { "• " + $0.dropFirst(2) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
