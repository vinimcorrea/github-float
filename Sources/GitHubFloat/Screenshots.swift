import AppKit
import SwiftUI

/// Renders README / social-preview images from the real views with fictional data:
/// `GitHubFloat --screenshots <dir>`
@MainActor
enum Screenshots {
    static func render(to dir: String) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let settings = Settings.shared
        settings.owner = "acme"
        settings.projectNumber = 1
        settings.collapsed = false
        settings.statuses = ["In Progress", "In Review", "Reviewed"]
        settings.reviewStatus = "In Review"
        settings.sectionOrder = []
        settings.collapsedSections = []
        let store = Store(settings: settings)
        store.loadDemo(demoSnapshot(), changed: ["mine:i-ds77"])

        settings.tab = .mine
        save(panel(store, settings, height: 560), url.appendingPathComponent("mine.png"))
        settings.tab = .reviewing
        save(panel(store, settings, height: 440), url.appendingPathComponent("reviewing.png"))
        settings.tab = .open
        save(panel(store, settings, height: 360), url.appendingPathComponent("needs-reviewer.png"))
        settings.collapsed = true
        save(panel(store, settings, height: 50), url.appendingPathComponent("collapsed.png"))
        settings.collapsed = false
        settings.tab = .mine
        save(Hero(store: store, settings: settings), url.appendingPathComponent("social-preview.png"), scale: 1)
        print("wrote screenshots to \(dir)")
    }

    private static func panel(_ store: Store, _ settings: Settings, height: CGFloat) -> some View {
        PanelChrome {
            ContentView(store: store, settings: settings, showMenu: {}, configure: {}, staticLayout: true)
        }
        .frame(width: 380, height: height)
        .padding(30)
        .background(Color.clear)
    }

    private static func save<V: View>(_ view: V, _ url: URL, scale: CGFloat = 2) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        r.scale = scale
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("failed to render \(url.lastPathComponent)"); return
        }
        try? png.write(to: url)
    }

    // MARK: Demo data (fictional)

    private static func demoSnapshot() -> BoardSnapshot {
        let mine = [
            item("i-web142", repo: "web-app", n: 142, title: "Add dark mode toggle to settings", status: "In Progress",
                 hours: 5, assignees: ["you"], pr: pr(201, draft: true, checks: "PENDING")),
            item("i-api311", repo: "api", n: 311, title: "Rate-limit the public search endpoint", status: "In Review",
                 hours: 3, assignees: ["you"], pr: pr(318, requested: ["bob"], checks: "PENDING")),
            item("i-web138", repo: "web-app", n: 138, title: "Migrate sign-in to the OAuth device flow", status: "In Review",
                 hours: 30, assignees: ["you", "carol"], pr: pr(139, reviews: [("carol", "CHANGES_REQUESTED")], decision: "CHANGES_REQUESTED", checks: "FAILURE")),
            item("i-ds77", repo: "design-system", n: 77, title: "Ship the accessible tooltip component", status: "In Review",
                 hours: 1, assignees: ["you", "alice"], pr: pr(80, reviews: [("alice", "COMMENTED")], checks: "SUCCESS")),
            item("i-mob59", repo: "mobile", n: 59, title: "Offline cache for the activity feed", status: "Reviewed",
                 hours: 2, assignees: ["you", "dave"], pr: pr(61, reviews: [("bob", "APPROVED"), ("dave", "APPROVED")], decision: "APPROVED", checks: "SUCCESS")),
            item("r-api305", repo: "api", n: 305, title: "Stream large CSV exports instead of buffering", status: "In Review",
                 hours: 20, assignees: ["alice", "you"], pr: pr(306, author: "alice", requested: ["you"], checks: "SUCCESS")),
            item("r-web147", repo: "web-app", n: 147, title: "Lazy-load the analytics dashboard charts", status: "In Review",
                 hours: 4, assignees: ["bob", "you"], pr: pr(148, author: "bob", reviews: [("you", "COMMENTED")], checks: "SUCCESS")),
            item("r-mob63", repo: "mobile", n: 63, title: "Retry failed uploads with exponential backoff", status: "In Review",
                 hours: 9, assignees: ["erin", "you"], pr: pr(64, author: "erin", requested: ["you"], reviews: [("you", "COMMENTED")], checks: "SUCCESS")),
        ]
        let open = [
            item("o-api320", repo: "api", n: 320, title: "Paginate the audit log export", status: "In Review",
                 hours: 80, assignees: ["carol"], pr: pr(322, author: "carol", checks: "SUCCESS")),
            item("o-web151", repo: "web-app", n: 151, title: "Fix the flaky checkout end-to-end test", status: "In Review",
                 hours: 26, assignees: ["dave"], pr: pr(152, author: "dave", requested: ["team-web"], checks: "SUCCESS")),
            item("o-docs12", repo: "docs", n: 12, title: "Document webhook retry behaviour", status: "In Review",
                 hours: 2, assignees: ["erin"], pr: pr(13, author: "erin", checks: "PENDING")),
        ]
        let options = [("Backlog", "GRAY"), ("In Progress", "YELLOW"), ("In Review", "ORANGE"), ("Reviewed", "PURPLE"), ("Done", "GREEN")]
            .map { StatusOption(name: $0.0, color: $0.1) }
        return BoardSnapshot(viewer: "you", projectTitle: "Acme Roadmap", projectURL: "https://github.com/orgs/acme/projects/1",
                             statusOptions: options, mine: mine.map(decode), open: open.map(decode))
    }

    private static func pr(_ n: Int, author: String = "you", draft: Bool = false, requested: [String] = [], reviews: [(String, String)] = [],
                           decision: String? = nil, checks: String) -> String {
        let rv = reviews.map { #"{"author":{"login":"\#($0.0)"},"state":"\#($0.1)"}"# }.joined(separator: ",")
        let rq = requested.map { #"{"requestedReviewer":{"login":"\#($0)"}}"# }.joined(separator: ",")
        let dec = decision.map { "\"\($0)\"" } ?? "null"
        return #"{"number":\#(n),"title":"PR \#(n)","url":"https://github.com/acme/x/pull/\#(n)","state":"OPEN","isDraft":\#(draft),"reviewDecision":\#(dec),"author":{"login":"\#(author)"},"repository":{"name":"x"},"assignees":{"nodes":[]},"reviewRequests":{"nodes":[\#(rq)]},"latestReviews":{"nodes":[\#(rv)]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"\#(checks)"}}}]}}"#
    }

    private static func item(_ id: String, repo: String, n: Int, title: String, status: String, hours: Double,
                             assignees: [String], pr: String) -> String {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hours * 3600))
        let asg = assignees.map { #"{"login":"\#($0)"}"# }.joined(separator: ",")
        let prJSON = pr.replacingOccurrences(of: #""repository":{"name":"x"}"#, with: #""repository":{"name":"\#(repo)"}"#)
        return #"{"id":"\#(id)","status":{"name":"\#(status)","updatedAt":"\#(since)"},"content":{"__typename":"Issue","number":\#(n),"title":"\#(title)","url":"https://github.com/acme/\#(repo)/issues/\#(n)","issueState":"OPEN","repository":{"name":"\#(repo)"},"assignees":{"nodes":[\#(asg)]},"closedByPullRequestsReferences":{"nodes":[\#(prJSON)]}}}"#
    }

    private static func decode(_ json: String) -> ItemNode {
        try! JSONDecoder().decode(ItemNode.self, from: Data(json.utf8))
    }
}

/// The panel's solid surface (see SurfaceView) for static renders.
struct PanelChrome<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.086, green: 0.106, blue: 0.133))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }
}

/// 1280×640 social preview / README hero.
struct Hero: View {
    @ObservedObject var store: Store
    @ObservedObject var settings: Settings

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.43, green: 0.25, blue: 0.79), Color(red: 0.18, green: 0.24, blue: 0.62),
                                    Color(red: 0.05, green: 0.07, blue: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 56) {
                VStack(alignment: .leading, spacing: 18) {
                    if let icon = NSImage(contentsOfFile: "Icon/AppIcon.png") {
                        Image(nsImage: icon).resizable().frame(width: 132, height: 132)
                    }
                    Text("GitHub Float")
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Your GitHub Project reviews,\nalways on top of your Mac.")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    HStack(spacing: 10) {
                        pill("Native SwiftUI")
                        pill("~0% CPU")
                        pill("Free & open source")
                    }
                }
                PanelChrome {
                    ContentView(store: store, settings: settings, showMenu: {}, configure: {}, staticLayout: true)
                }
                .frame(width: 400, height: 540)
                .rotation3DEffect(.degrees(-8), axis: (x: 0, y: 1, z: 0))
            }
            .padding(.horizontal, 70)
        }
        .frame(width: 1280, height: 640)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(0.16)))
            .foregroundStyle(.white)
    }
}
