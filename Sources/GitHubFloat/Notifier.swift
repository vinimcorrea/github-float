import AppKit
import UserNotifications

struct AttentionEvent {
    let title: String
    let body: String
    let url: String?
    let id: String
}

/// Turns board diffs into the events worth interrupting you for.
enum AttentionDetector {
    static func events(oldMine: [String: BoardTask], newMine: [BoardTask],
                       oldReviewing: [String: BoardTask] = [:], newReviewing: [BoardTask] = [],
                       oldOpen: [String: BoardTask], newOpen: [BoardTask],
                       viewer: String, notifyStatuses: Set<String>) -> [AttentionEvent] {
        var out: [AttentionEvent] = []

        for t in newOpen where oldOpen[t.id] == nil {
            out.append(.init(title: "Needs a reviewer · \(ref(t))",
                             body: "\(t.title)\nby \(t.assignees.first ?? "unassigned")",
                             url: t.prs.first?.url ?? t.url, id: "open-\(t.id)"))
        }

        for t in newReviewing {
            guard let old = oldReviewing[t.id] else { continue }
            let before = old.reviewState(of: viewer), now = t.reviewState(of: viewer)
            if now == "REQUESTED", before != nil, before != "REQUESTED" {
                let author = t.prs.compactMap(\.author).first ?? t.assignees.first ?? "The author"
                out.append(.init(title: "Re-review requested · \(ref(t))",
                                 body: "\(t.title)\n\(author) asked for your review again",
                                 url: t.prs.first?.url ?? t.url, id: "reviewing-\(t.id)"))
            }
        }

        for t in newMine {
            guard let old = oldMine[t.id] else { continue }
            var lines: [String] = []

            if old.status != t.status, notifyStatuses.contains(t.status) {
                lines.append("Moved to \(t.status)")
            }
            let newcomers = t.assignees.filter { !old.assignees.contains($0) && $0 != viewer }
            if !newcomers.isEmpty {
                lines.append("\(newcomers.joined(separator: ", ")) picked up the review")
            }
            let oldPRs = Dictionary(old.prs.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            for pr in t.prs {
                guard let before = oldPRs[pr.url] else { continue }
                let prevReviews = Dictionary(before.reviewers.map { ($0.login, $0.state) }, uniquingKeysWith: { a, _ in a })
                for r in pr.reviewers where r.state != "REQUESTED" && prevReviews[r.login] != r.state {
                    lines.append("PR #\(pr.number): \(r.login) \(verb(r.state))")
                }
                if pr.stage != before.stage, pr.stage == .merged {
                    lines.append("PR #\(pr.number) merged")
                }
                if pr.checks != before.checks, pr.checks == .failure || pr.checks == .error {
                    lines.append("PR #\(pr.number): checks failing")
                }
            }
            if !lines.isEmpty {
                out.append(.init(title: "\(ref(t)) · \(t.title)",
                                 body: lines.joined(separator: "\n"),
                                 url: t.prs.first?.url ?? t.url, id: "mine-\(t.id)"))
            }
        }
        return out
    }

    private static func ref(_ t: BoardTask) -> String {
        if let r = t.repo, let n = t.number { return "\(r)#\(n)" }
        return "Draft"
    }

    private static func verb(_ state: String) -> String {
        switch state {
        case "APPROVED": return "approved ✅"
        case "CHANGES_REQUESTED": return "requested changes ❌"
        case "COMMENTED": return "commented 💬"
        case "DISMISSED": return "review dismissed"
        default: return state.lowercased()
        }
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { NSLog("GitHubFloat notifications: \(error.localizedDescription)") }
            if !granted { NSLog("GitHubFloat notifications not granted") }
        }
    }

    func post(_ e: AttentionEvent, sound: Bool, completion: ((Error?) -> Void)? = nil) {
        guard let center else { completion?(nil); return }
        let content = UNMutableNotificationContent()
        content.title = e.title
        content.body = e.body
        if sound { content.sound = .default }
        if let url = e.url { content.userInfo = ["url": url] }
        content.threadIdentifier = e.id
        if let attachment = iconAttachment() { content.attachments = [attachment] }
        // Unique id so successive updates on the same task stack instead of replacing each other.
        let req = UNNotificationRequest(identifier: "\(e.id)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        center.add(req) { completion?($0) }
    }

    /// Thumbnail of the app icon (UserNotifications moves the file, so attach a fresh copy each time).
    private func iconAttachment() -> UNNotificationAttachment? {
        guard let src = Bundle.main.url(forResource: "NotificationIcon", withExtension: "png") else { return nil }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("ghfloat-\(UUID().uuidString).png")
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: dst)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let u = URL(string: s) {
            NSWorkspace.shared.open(u)
        }
        completionHandler()
    }
}
