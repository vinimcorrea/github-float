import AppKit
import Combine
import SwiftUI

// MARK: - Domain

enum ReviewStage: Int, Comparable {
    case changesRequested, awaitingReview, beingReviewed, noReviewers, draft, approved, merged, closed

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .changesRequested: return "Changes requested"
        case .awaitingReview: return "Awaiting review"
        case .beingReviewed: return "Being reviewed"
        case .noReviewers: return "No reviewers"
        case .draft: return "Draft"
        case .approved: return "Approved"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    var color: Color {
        switch self {
        case .changesRequested: return .red
        case .awaitingReview: return .orange
        case .beingReviewed: return .blue
        case .noReviewers: return .gray
        case .draft: return .secondary
        case .approved: return .green
        case .merged: return .purple
        case .closed: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .awaitingReview: return "hourglass"
        case .beingReviewed: return "eye.fill"
        case .noReviewers: return "person.crop.circle.badge.questionmark"
        case .draft: return "pencil.circle"
        case .approved: return "checkmark.seal.fill"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }
}

struct ReviewerState: Hashable {
    let login: String
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED or REQUESTED
    let state: String

    var symbol: String {
        switch state {
        case "APPROVED": return "checkmark.circle.fill"
        case "CHANGES_REQUESTED": return "xmark.octagon.fill"
        case "COMMENTED": return "text.bubble.fill"
        case "REQUESTED": return "clock"
        default: return "circle"
        }
    }

    var color: Color {
        switch state {
        case "APPROVED": return .green
        case "CHANGES_REQUESTED": return .red
        case "COMMENTED": return .blue
        case "REQUESTED": return .orange
        default: return .secondary
        }
    }
}

enum CheckState: String {
    case success = "SUCCESS", failure = "FAILURE", error = "ERROR", pending = "PENDING", expected = "EXPECTED"

    var color: Color {
        switch self {
        case .success: return .green
        case .failure, .error: return .red
        case .pending, .expected: return .yellow
        }
    }

    var help: String {
        switch self {
        case .success: return "Checks passed"
        case .failure, .error: return "Checks failing"
        case .pending, .expected: return "Checks running"
        }
    }
}

struct PullRequest: Identifiable, Hashable {
    var id: String { url }
    let number: Int
    let repo: String
    let title: String
    let url: String
    let stage: ReviewStage
    let author: String?
    let reviewers: [ReviewerState]
    let checks: CheckState?

    static func isBot(_ login: String) -> Bool {
        login.hasSuffix("[bot]") || login.hasPrefix("copilot-")
    }

    init(_ n: PRNode) {
        number = n.number
        repo = n.repository.name
        title = n.title
        url = n.url
        author = n.author?.login
        checks = n.state != "OPEN" ? nil : n.commits?.nodes?.compactMap { $0 }.last?.commit.statusCheckRollup.flatMap { CheckState(rawValue: $0.state) }

        var byLogin: [String: String] = [:]
        var order: [String] = []
        for r in n.latestReviews?.nodes?.compactMap({ $0 }) ?? [] where r.state != "PENDING" {
            guard let login = r.author?.login, login != n.author?.login, !Self.isBot(login) else { continue }
            if byLogin[login] == nil { order.append(login) }
            byLogin[login] = r.state
        }
        let requested = n.reviewRequests?.nodes?.compactMap { $0?.requestedReviewer.flatMap { $0.login ?? $0.name } } ?? []
        for login in requested {
            if byLogin[login] == nil { order.append(login) }
            byLogin[login] = "REQUESTED" // re-requested reviews are waiting again
        }
        reviewers = order.map { ReviewerState(login: $0, state: byLogin[$0]!) }

        let submitted = byLogin.values.contains { $0 != "REQUESTED" && $0 != "DISMISSED" }
        if n.state == "MERGED" { stage = .merged }
        else if n.state == "CLOSED" { stage = .closed }
        else if n.isDraft { stage = .draft }
        else if n.reviewDecision == "APPROVED" { stage = .approved }
        else if n.reviewDecision == "CHANGES_REQUESTED" { stage = .changesRequested }
        else if submitted { stage = .beingReviewed }
        else if !requested.isEmpty { stage = .awaitingReview }
        else { stage = .noReviewers }
    }
}

struct BoardTask: Identifiable, Hashable {
    let id: String
    let status: String
    let kind: String
    let repo: String?
    let number: Int?
    let title: String
    let url: String?
    let assignees: [String]
    let statusSince: Date?
    let prs: [PullRequest]

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    init?(_ item: ItemNode) {
        guard let c = item.content else { return nil }
        id = item.id
        status = item.status?.name ?? "No status"
        kind = c.typename
        repo = c.repository?.name
        number = c.number
        title = c.title ?? "(untitled)"
        url = c.url
        assignees = c.assignees.filter { !PullRequest.isBot($0) }
        statusSince = item.status?.updatedAt.flatMap { Self.iso.date(from: $0) ?? Self.isoPlain.date(from: $0) }
        if let pr = c.pr {
            prs = [PullRequest(pr)]
        } else {
            let all = c.closingPRs.map(PullRequest.init)
            let live = all.filter { $0.stage != .closed }
            prs = live.isEmpty ? all : live
        }
    }

    /// The most urgent stage across linked PRs, used for sorting.
    var stage: ReviewStage? { prs.map(\.stage).min() }

    /// Assigned to you, but someone else's work: you're the reviewer.
    /// Decided by the linked PRs' author, falling back to the first assignee.
    func isReviewing(by viewer: String) -> Bool {
        guard assignees.contains(viewer) else { return false }
        let authors = prs.compactMap(\.author)
        if !authors.isEmpty { return !authors.contains(viewer) }
        return assignees.first != viewer
    }

    /// Your own review on the linked PRs (nil when you haven't been requested or reviewed yet).
    func reviewState(of viewer: String) -> String? {
        prs.lazy.compactMap { $0.reviewers.first { $0.login == viewer }?.state }.first
    }

    /// Whether the ball is in your court: no review from you yet, or your review was re-requested.
    func awaitsReview(from viewer: String) -> Bool {
        let state = reviewState(of: viewer)
        return state == nil || state == "REQUESTED"
    }

    var signature: String {
        status + "|" + assignees.joined(separator: ",") + "|" + prs.map { "\($0.number):\($0.stage.rawValue):\($0.checks?.rawValue ?? "")" + $0.reviewers.map { $0.login + $0.state }.joined() }.joined(separator: ",")
    }
}

// MARK: - Settings

enum Tab: String, CaseIterable {
    case mine, reviewing, open
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d: UserDefaults = CommandLine.arguments.contains("--screenshots")
        ? UserDefaults(suiteName: "githubfloat.screenshots")!
        : .standard

    /// Login of the organization or user that owns the project.
    @Published var owner: String { didSet { d.set(owner, forKey: "owner") } }
    @Published var projectNumber: Int { didSet { d.set(projectNumber, forKey: "projectNumber") } }
    /// Statuses shown in the "Mine" tab.
    @Published var statuses: [String] { didSet { d.set(statuses, forKey: "statuses") } }
    /// Status whose items with fewer than two assignees are "open for review".
    @Published var reviewStatus: String { didSet { d.set(reviewStatus, forKey: "reviewStatus") } }
    @Published var tab: Tab { didSet { d.set(tab.rawValue, forKey: "tab") } }
    @Published var pollSeconds: Int { didSet { d.set(pollSeconds, forKey: "pollSeconds") } }
    @Published var opacity: Double { didSet { d.set(opacity, forKey: "opacity") } }
    @Published var collapsed: Bool { didSet { d.set(collapsed, forKey: "collapsed") } }
    @Published var soundOnChange: Bool { didSet { d.set(soundOnChange, forKey: "soundOnChange") } }
    @Published var notifications: Bool { didSet { d.set(notifications, forKey: "notifications") } }
    /// Custom order of the "Mine" status sections (drag and drop); statuses not listed follow the board order.
    @Published var sectionOrder: [String] { didSet { d.set(sectionOrder, forKey: "sectionOrder") } }
    /// Folded sections, keyed by "<tab>:<title>".
    @Published var collapsedSections: Set<String> { didSet { d.set(Array(collapsedSections), forKey: "collapsedSections") } }

    private init() {
        d.register(defaults: [
            "owner": "",
            "projectNumber": 0,
            "statuses": ["In Progress", "In Review", "Reviewed"],
            "reviewStatus": "In Review",
            "tab": Tab.mine.rawValue,
            "pollSeconds": 60,
            "opacity": 0.95,
            "collapsed": false,
            "soundOnChange": true,
            "notifications": true,
        ])
        owner = d.string(forKey: "owner") ?? ""
        projectNumber = d.integer(forKey: "projectNumber")
        statuses = d.stringArray(forKey: "statuses") ?? []
        reviewStatus = d.string(forKey: "reviewStatus")!
        tab = Tab(rawValue: d.string(forKey: "tab") ?? "") ?? .mine
        pollSeconds = max(15, d.integer(forKey: "pollSeconds"))
        opacity = d.double(forKey: "opacity")
        collapsed = d.bool(forKey: "collapsed")
        soundOnChange = d.bool(forKey: "soundOnChange")
        notifications = d.bool(forKey: "notifications")
        sectionOrder = d.stringArray(forKey: "sectionOrder") ?? []
        collapsedSections = Set(d.stringArray(forKey: "collapsedSections") ?? [])
    }

    var isConfigured: Bool { !owner.isEmpty && projectNumber > 0 }

    /// Accepts project URLs like https://github.com/orgs/acme/projects/5 or https://github.com/users/me/projects/2.
    static func parseProject(_ input: String) -> (owner: String, number: Int)? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"github\.com/(?:orgs|users)/([A-Za-z0-9-]+)/projects/(\d+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let o = Range(m.range(at: 1), in: s), let n = Range(m.range(at: 2), in: s),
              let number = Int(s[n]) else { return nil }
        return (String(s[o]), number)
    }

    private static func statusFilter(_ names: [String]) -> String {
        names.isEmpty ? "" : "status:" + names.map { "\"\($0)\"" }.joined(separator: ",")
    }

    /// Everything assigned to you; split client-side into "Mine" and "Reviewing".
    var mineFilter: String {
        let names = statuses.isEmpty ? [] : statuses + (statuses.contains(reviewStatus) ? [] : [reviewStatus])
        return ("assignee:@me " + Self.statusFilter(names)).trimmingCharacters(in: .whitespaces)
    }
    var openFilter: String { "is:open -assignee:@me " + Self.statusFilter([reviewStatus]) }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published private(set) var mine: [BoardTask] = []
    @Published private(set) var reviewing: [BoardTask] = []
    @Published private(set) var open: [BoardTask] = []
    @Published private(set) var viewer = ""
    @Published private(set) var statusOptions: [StatusOption] = []
    @Published private(set) var projectTitle = "GitHub Project"
    @Published private(set) var projectURL: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var changed: Set<String> = []

    let settings: Settings
    private let client = GitHubClient()
    private var signatures: [String: String]?
    private var previousMine: [String: BoardTask] = [:]
    private var previousReviewing: [String: BoardTask] = [:]
    private var previousOpen: [String: BoardTask] = [:]
    private var loop: Task<Void, Never>?
    private var failures = 0
    private var paused = false
    private var bag: Set<AnyCancellable> = []

    init(settings: Settings = .shared) {
        self.settings = settings
        settings.$pollSeconds.dropFirst().sink { [weak self] _ in self?.start() }.store(in: &bag)
        Publishers.Merge3(
            settings.$statuses.dropFirst().map { _ in () },
            settings.$reviewStatus.dropFirst().map { _ in () },
            settings.$owner.dropFirst().map { _ in () }.merge(with: settings.$projectNumber.dropFirst().map { _ in () })
        )
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.signatures = nil
            self?.previousMine = [:]
            self?.previousReviewing = [:]
            self?.previousOpen = [:]
            self?.start()
        }
        .store(in: &bag)

        // No polling while the Mac sleeps, the screen is off or the session is locked/switched.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            nc.publisher(for: name).sink { [weak self] _ in self?.pause() }.store(in: &bag)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.publisher(for: name).sink { [weak self] _ in self?.resume() }.store(in: &bag)
        }
        DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))
            .sink { [weak self] _ in self?.pause() }.store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsUnlocked"))
            .sink { [weak self] _ in self?.resume() }.store(in: &bag)
    }

    func start() {
        loop?.cancel()
        guard !paused else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(self.nextDelay) * 1_000_000_000)
            }
        }
    }

    private func pause() {
        paused = true
        loop?.cancel()
        loop = nil
    }

    private func resume() {
        guard paused else { return }
        paused = false
        start()
    }

    /// Exponential backoff on errors, capped at 10 minutes.
    private var nextDelay: Int {
        let base = settings.pollSeconds
        return failures == 0 ? base : min(600, base << min(failures, 4))
    }

    func refresh() async {
        guard !loading, settings.isConfigured else { return }
        loading = true
        defer { loading = false }
        do {
            let snap = try await client.fetchBoard(owner: settings.owner, number: settings.projectNumber,
                                                   mineFilter: settings.mineFilter, openFilter: settings.openFilter)
            apply(snap)
            failures = 0
            if error != nil { error = nil }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            failures += 1
            self.error = error.localizedDescription
        }
    }

    func loadDemo(_ snap: BoardSnapshot, changed ids: Set<String>) {
        apply(snap)
        changed = ids
    }

    func acknowledge(_ id: String) { changed.remove(id) }
    func acknowledgeAll() { changed.removeAll() }

    func color(forStatus name: String) -> Color {
        switch statusOptions.first(where: { $0.name == name })?.color {
        case "BLUE": return .blue
        case "GREEN": return .green
        case "YELLOW": return .yellow
        case "ORANGE": return .orange
        case "RED": return .red
        case "PINK": return .pink
        case "PURPLE": return .purple
        default: return .gray
        }
    }

    func tasks(_ tab: Tab) -> [BoardTask] {
        switch tab {
        case .mine: return mine
        case .reviewing: return reviewing
        case .open: return open
        }
    }

    func changedCount(_ tab: Tab) -> Int {
        tasks(tab).filter { changed.contains(key(tab, $0)) }.count
    }

    func key(_ tab: Tab, _ task: BoardTask) -> String { "\(tab.rawValue):\(task.id)" }

    /// "Mine" grouped by status, in board order.
    var mineGroups: [(status: String, tasks: [BoardTask])] {
        let board = statusOptions.isEmpty ? settings.statuses : statusOptions.map(\.name)
        let order = settings.sectionOrder + board.filter { !settings.sectionOrder.contains($0) }
        let grouped = Dictionary(grouping: mine, by: \.status)
        let names = order.filter { grouped[$0] != nil } + grouped.keys.filter { !order.contains($0) }.sorted()
        return names.map { name in
            (name, grouped[name]!.sorted {
                ($0.stage ?? .closed, $0.repo ?? "", $0.number ?? 0) < ($1.stage ?? .closed, $1.repo ?? "", $1.number ?? 0)
            })
        }
    }

    /// Moves the `dragged` section to the position of `target` in "Mine".
    func moveSection(_ dragged: String, to target: String) {
        var names = mineGroups.map(\.status)
        guard dragged != target, let from = names.firstIndex(of: dragged), let to = names.firstIndex(of: target) else { return }
        names.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        settings.sectionOrder = names + settings.sectionOrder.filter { !names.contains($0) }
    }

    func moveSection(_ name: String, by offset: Int) {
        let names = mineGroups.map(\.status)
        guard let i = names.firstIndex(of: name), names.indices.contains(i + offset) else { return }
        moveSection(name, to: names[i + offset])
    }

    /// Statuses worth a notification when your task enters them: the one right after the review status (e.g. "Reviewed").
    private var notifyStatuses: Set<String> {
        let names = statusOptions.map(\.name)
        guard let i = names.firstIndex(of: settings.reviewStatus), i + 1 < names.count else { return ["Reviewed"] }
        return [names[i + 1]]
    }

    private func apply(_ snap: BoardSnapshot) {
        if viewer != snap.viewer { viewer = snap.viewer }
        if projectTitle != snap.projectTitle { projectTitle = snap.projectTitle }
        if projectURL != snap.projectURL { projectURL = snap.projectURL }
        if statusOptions != snap.statusOptions { statusOptions = snap.statusOptions }
        lastUpdated = Date()

        let assigned = snap.mine.compactMap(BoardTask.init)
        let newMine = assigned.filter { !$0.isReviewing(by: snap.viewer) && (settings.statuses.isEmpty || settings.statuses.contains($0.status)) }
        // Reviewing = others' work assigned to you, until its PRs are merged or closed.
        let newReviewing = assigned
            .filter { $0.isReviewing(by: snap.viewer) && ($0.prs.isEmpty || $0.prs.contains { $0.stage != .merged && $0.stage != .closed }) }
            .sorted {
                let a = $0.awaitsReview(from: snap.viewer), b = $1.awaitsReview(from: snap.viewer)
                if a != b { return a }
                return ($0.statusSince ?? .distantFuture) < ($1.statusSince ?? .distantFuture)
            }
        // Open for review = in the review status with no second (reviewer) assignee.
        let newOpen = snap.open.compactMap(BoardTask.init)
            .filter { $0.assignees.count < 2 && !$0.assignees.contains(snap.viewer) }
            .sorted { ($0.statusSince ?? .distantFuture) < ($1.statusSince ?? .distantFuture) }

        var newSigs: [String: String] = [:]
        for t in newMine { newSigs[key(.mine, t)] = t.signature }
        for t in newReviewing { newSigs[key(.reviewing, t)] = t.signature }
        for t in newOpen { newSigs[key(.open, t)] = t.signature }
        guard newSigs != signatures else { return }

        if let old = signatures {
            let diff = newSigs.filter { old[$0.key] != $0.value }.map(\.key)
            if !diff.isEmpty {
                changed.formUnion(diff)
                let events = AttentionDetector.events(oldMine: previousMine, newMine: newMine,
                                                      oldReviewing: previousReviewing, newReviewing: newReviewing,
                                                      oldOpen: previousOpen, newOpen: newOpen,
                                                      viewer: snap.viewer, notifyStatuses: notifyStatuses)
                if settings.notifications {
                    events.forEach { Notifier.shared.post($0, sound: settings.soundOnChange) }
                } else if settings.soundOnChange {
                    NSSound(named: "Glass")?.play()
                }
            }
        }
        previousMine = Dictionary(newMine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        previousReviewing = Dictionary(newReviewing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        previousOpen = Dictionary(newOpen.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        changed.formIntersection(newSigs.keys)
        signatures = newSigs
        mine = newMine
        reviewing = newReviewing
        open = newOpen
    }
}
