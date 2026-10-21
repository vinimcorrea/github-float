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
    var submittedAt: Date?

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
    let nodeId: String?
    let number: Int
    let repo: String
    let title: String
    let url: String
    private(set) var stage: ReviewStage
    let author: String?
    private(set) var reviewers: [ReviewerState]
    let checks: CheckState?

    /// Reviewers whose "changes requested" review hasn't been re-requested yet.
    var changesRequestedBy: [String] { reviewers.filter { $0.state == "CHANGES_REQUESTED" }.map(\.login) }

    static func isBot(_ login: String) -> Bool {
        login.hasSuffix("[bot]") || login.hasPrefix("copilot-")
    }

    init(_ n: PRNode) {
        nodeId = n.id
        number = n.number
        repo = n.repository.name
        title = n.title
        url = n.url
        author = n.author?.login
        checks = n.state != "OPEN" ? nil : n.commits?.nodes?.compactMap { $0 }.last?.commit.statusCheckRollup.flatMap { CheckState(rawValue: $0.state) }

        var byLogin: [String: String] = [:]
        var at: [String: Date] = [:]
        var order: [String] = []
        for r in n.latestReviews?.nodes?.compactMap({ $0 }) ?? [] where r.state != "PENDING" {
            guard let login = r.author?.login, login != n.author?.login, !Self.isBot(login) else { continue }
            if byLogin[login] == nil { order.append(login) }
            byLogin[login] = r.state
            at[login] = r.submittedAt.flatMap(parseISODate)
        }
        let requested = n.reviewRequests?.nodes?.compactMap { $0?.requestedReviewer.flatMap { $0.login ?? $0.name } } ?? []
        for login in requested {
            if byLogin[login] == nil { order.append(login) }
            byLogin[login] = "REQUESTED" // re-requested reviews are waiting again
        }
        reviewers = order.map { ReviewerState(login: $0, state: byLogin[$0]!, submittedAt: at[$0]) }

        let submitted = byLogin.values.contains { $0 != "REQUESTED" && $0 != "DISMISSED" }
        if n.state == "MERGED" { stage = .merged }
        else if n.state == "CLOSED" { stage = .closed }
        else if n.isDraft { stage = .draft }
        else if n.reviewDecision == "APPROVED" { stage = .approved }
        // Once every reviewer who requested changes has been asked again, it's back to waiting for them.
        else if n.reviewDecision == "CHANGES_REQUESTED", byLogin.values.contains("CHANGES_REQUESTED") || requested.isEmpty { stage = .changesRequested }
        else if submitted { stage = .beingReviewed }
        else if !requested.isEmpty { stage = .awaitingReview }
        else { stage = .noReviewers }
    }
}

fileprivate let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
fileprivate let isoPlain = ISO8601DateFormatter()

func parseISODate(_ s: String) -> Date? { isoFractional.date(from: s) ?? isoPlain.date(from: s) }

extension PullRequest {
    /// Team convention: the task's other assignees are its reviewers, even when the PR has no review request.
    func withAssignedReviewers(_ assignees: [String]) -> PullRequest {
        var pr = self
        // A past review from someone no longer assigned (e.g. unassigned reviewer) doesn't count as in progress.
        if pr.stage == .beingReviewed, !assignees.isEmpty, !assignees.contains(where: { $0 != author }) {
            pr.stage = reviewers.contains { $0.state == "REQUESTED" } ? .awaitingReview : .noReviewers
        }
        let extra = assignees.filter { $0 != author && !reviewers.map(\.login).contains($0) }
        guard !extra.isEmpty else { return pr }
        pr.reviewers += extra.map { ReviewerState(login: $0, state: "REQUESTED") }
        if pr.stage == .noReviewers { pr.stage = .awaitingReview }
        return pr
    }
}

struct BoardTask: Identifiable, Hashable {
    let id: String
    /// Node id of the issue / pull request / draft behind the card.
    let contentId: String?
    let status: String
    let kind: String
    let repo: String?
    let number: Int?
    let title: String
    let url: String?
    let assignees: [String]
    let statusSince: Date?
    let prs: [PullRequest]
    let issueType: String?
    let subIssueCount: Int
    let subIssues: [SubIssueRef]
    let isOpenIssue: Bool

    struct SubIssueRef: Hashable {
        let closed: Bool
        /// Status per board (project id -> status name).
        let statuses: [String: String]
    }

    /// A User Story split into sub-issues: tracked through its sub-issues, never shown itself.
    var isSplitStory: Bool { issueType?.caseInsensitiveCompare("User Story") == .orderedSame && subIssueCount > 0 }

    init?(_ item: ItemNode) {
        guard let c = item.content else { return nil }
        id = item.id
        contentId = c.id
        status = item.status?.name ?? "No status"
        kind = c.typename
        repo = c.repository?.name
        number = c.number
        title = c.title ?? "(untitled)"
        url = c.url
        let people = c.assignees.filter { !PullRequest.isBot($0) }
        assignees = people
        statusSince = item.status?.updatedAt.flatMap(parseISODate)
        issueType = c.issueType
        isOpenIssue = c.typename == "Issue" && c.issueState == "OPEN"
        subIssueCount = c.subIssues?.totalCount ?? 0
        subIssues = (c.subIssues?.nodes ?? []).map { sub in
            let pairs = (sub.projectItems?.nodes ?? []).compactMap { $0 }.compactMap { p in p.status?.name.map { (p.project.id, $0) } }
            return SubIssueRef(closed: sub.state == "CLOSED", statuses: Dictionary(pairs, uniquingKeysWith: { a, _ in a }))
        }
        if let pr = c.pr {
            prs = [PullRequest(pr).withAssignedReviewers(people)]
        } else {
            let all = c.closingPRs.map(PullRequest.init)
            let live = all.filter { $0.stage != .closed }
            prs = (live.isEmpty ? all : live).map { $0.withAssignedReviewers(people) }
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

    /// Your most recent approval or change request across the linked PRs.
    func verdict(of viewer: String) -> ReviewerState? {
        prs.compactMap { $0.reviewers.first { $0.login == viewer } }
            .filter { $0.state == "APPROVED" || $0.state == "CHANGES_REQUESTED" }
            .max { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }
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
    /// "synth" (GitHub Float's own sounds) or "system" (the macOS default).
    @Published var soundStyle: String { didSet { d.set(soundStyle, forKey: "soundStyle") } }
    /// Custom order of the "Mine" status sections (drag and drop); statuses not listed follow the board order.
    @Published var sectionOrder: [String] { didSet { d.set(sectionOrder, forKey: "sectionOrder") } }
    /// After you approve, move the card to the status after the review one; after you request changes,
    /// move it back to "In Progress" and unassign yourself.
    @Published var autoMove: Bool { didSet { d.set(autoMove, forKey: "autoMove") } }
    /// Move your own tasks to `mergedStatus` once all their PRs are merged, from any earlier column.
    @Published var autoMoveMerged: Bool { didSet { d.set(autoMoveMerged, forKey: "autoMoveMerged") } }
    @Published var mergedStatus: String { didSet { d.set(mergedStatus, forKey: "mergedStatus") } }
    /// The panel hangs under the menu bar icon, which shows/hides it (right-click opens the menu).
    @Published var attached: Bool { didSet { d.set(attached, forKey: "attached") } }
    /// The panel sits in the lower part of the screen: the header goes to the bottom and the list opens upwards.
    @Published var dockedBottom = false
    /// Runtime only: how much taller (+) or shorter (−) the list's content is than the space it gets.
    /// How much the list over/underflows the panel (not @Published: the whole view would re-render on every layout).
    var listOverflow: CGFloat = 0 { didSet { if listOverflow != oldValue { listOverflowChanged.send(listOverflow) } } }
    let listOverflowChanged = PassthroughSubject<CGFloat, Never>()
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
            "soundStyle": "synth",
            "autoMove": true,
            "autoMoveMerged": true,
            "mergedStatus": "Ready to Verify",
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
        soundStyle = d.string(forKey: "soundStyle") ?? "synth"
        autoMove = d.bool(forKey: "autoMove")
        autoMoveMerged = d.bool(forKey: "autoMoveMerged")
        attached = d.bool(forKey: "attached")
        mergedStatus = d.string(forKey: "mergedStatus") ?? "Ready to Verify"
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
    var mineFilter: String { mineFilter(extra: []) }

    /// Statuses whose items are shown in "Mine" / "Reviewing" (empty = all).
    var shownStatuses: [String] {
        statuses.isEmpty ? [] : statuses + (statuses.contains(reviewStatus) ? [] : [reviewStatus])
    }

    func mineFilter(extra: [String]) -> String {
        let shown = shownStatuses
        let names = shown.isEmpty ? [] : shown + extra.filter { !shown.contains($0) }
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
    /// Tasks being assigned to you right now (item ids).
    @Published private(set) var assigning: Set<String> = []
    @Published private(set) var rerequesting: Set<String> = []

    let settings: Settings
    private let client = GitHubClient()
    private var signatures: [String: String]?
    private var previousMine: [String: BoardTask] = [:]
    private var previousReviewing: [String: BoardTask] = [:]
    private var previousOpen: [String: BoardTask] = [:]
    private var board: (viewerId: String, projectId: String, statusFieldId: String)?
    /// Cards already moved after your review (by item id + review time), so each review is handled once.
    private var handledVerdicts: Set<String> = []
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
                                                   mineFilter: settings.mineFilter(extra: statusesBeforeMerged + (settings.autoMoveMerged ? [settings.mergedStatus] : [])), openFilter: settings.openFilter)
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

    func canAssignMe(_ task: BoardTask) -> Bool {
        task.kind != "DraftIssue" && task.contentId != nil && board != nil && !task.assignees.contains(viewer)
    }

    /// Picks up a task as its reviewer: adds you as an assignee, then it shows up in "Reviewing".
    func assignMe(_ task: BoardTask) {
        guard canAssignMe(task), let content = task.contentId, let board, !assigning.contains(task.id) else { return }
        assigning.insert(task.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.addAssignee(board.viewerId, to: content)
                error = nil
            } catch {
                self.error = "Could not assign you to \(task.title): \(error.localizedDescription)"
            }
            await refresh()
            assigning.remove(task.id)
        }
    }

    /// Your PRs on this task with requested changes, i.e. the ones you can send back to their reviewers.
    func reReviewPRs(_ task: BoardTask) -> [PullRequest] {
        task.prs.filter { $0.author == viewer && $0.stage == .changesRequested && $0.nodeId != nil && !$0.changesRequestedBy.isEmpty }
    }

    /// Notifies the reviewers who requested changes that the PR is ready for another look,
    /// puts the card back in the review status and the reviewers back as assignees (team convention).
    func requestReReview(_ task: BoardTask) {
        let prs = reReviewPRs(task)
        guard !prs.isEmpty, !rerequesting.contains(task.id) else { return }
        let reviewers = Set(prs.flatMap(\.changesRequestedBy))
        let reviewOption = task.status == settings.reviewStatus ? nil : option(named: settings.reviewStatus)
        rerequesting.insert(task.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                for pr in prs { try await client.requestReviews(pr.changesRequestedBy, on: pr.nodeId!) }
                if let board, task.kind != "DraftIssue" {
                    if let id = reviewOption?.id {
                        try await client.setStatus(projectId: board.projectId, itemId: task.id, fieldId: board.statusFieldId, optionId: id)
                    }
                    if let content = task.contentId {
                        for login in reviewers.subtracting(task.assignees).sorted() {
                            if let uid = try await client.userId(login) { try await client.addAssignee(uid, to: content) }
                        }
                    }
                }
                error = nil
            } catch {
                self.error = "Could not re-request review on \(task.title): \(error.localizedDescription)"
            }
            await refresh()
            rerequesting.remove(task.id)
        }
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

    func task(_ tab: Tab, id: String) -> BoardTask? {
        switch tab {
        case .mine: mine.first { $0.id == id }
        case .reviewing: reviewing.first { $0.id == id }
        case .open: open.first { $0.id == id }
        }
    }

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
    private var notifyStatuses: Set<String> { [statusAfterReview] }

    private var statusAfterReview: String {
        let names = statusOptions.map(\.name)
        guard let i = names.firstIndex(of: settings.reviewStatus), i + 1 < names.count else { return "Reviewed" }
        return names[i + 1]
    }

    /// Board columns before the merged status: also fetched so merged work there can be moved forward.
    private var statusesBeforeMerged: [String] {
        guard settings.autoMoveMerged else { return [] }
        let names = statusOptions.map(\.name)
        guard let i = names.firstIndex(where: { $0.caseInsensitiveCompare(settings.mergedStatus) == .orderedSame }) else { return [] }
        return Array(names[..<i])
    }

    /// Your own tasks whose linked PRs are all done (at least one merged) go to the merged status, from any earlier column.
    private func applyMerged(_ tasks: [BoardTask]) {
        guard settings.autoMoveMerged, let board, let target = option(named: settings.mergedStatus), let targetId = target.id else { return }
        let earlier = Set(statusesBeforeMerged)
        for t in tasks where earlier.contains(t.status) || t.status == "No status" {
            guard t.prs.contains(where: { $0.stage == .merged }), t.prs.allSatisfy({ $0.stage == .merged || $0.stage == .closed }) else { continue }
            let key = "merged:\(t.id)"
            guard !handledVerdicts.contains(key) else { continue }
            handledVerdicts.insert(key)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await client.setStatus(projectId: board.projectId, itemId: t.id, fieldId: board.statusFieldId, optionId: targetId)
                    if settings.notifications {
                        Notifier.shared.post(.init(title: "Merged · \(t.repo.map { "\($0)#\(t.number ?? 0)" } ?? "Draft")",
                                                   body: "\(t.title)\nMoved to \(target.name)",
                                                   url: t.url, id: "merged-\(t.id)", kind: .info), sound: false)
                    }
                } catch {
                    handledVerdicts.remove(key)
                    self.error = "Could not move \(t.title): \(error.localizedDescription)"
                }
                await self.refresh()
            }
        }
    }

    /// A split User Story goes to the merged status once every sub-issue is closed or already at/after that status.
    private func applyFinishedStories(_ stories: [BoardTask], projectId: String?) {
        guard settings.autoMoveMerged, let board, let target = option(named: settings.mergedStatus), let targetId = target.id else { return }
        let names = statusOptions.map(\.name)
        guard let targetIndex = names.firstIndex(of: target.name) else { return }
        let earlier = Set(statusesBeforeMerged)
        func done(_ sub: BoardTask.SubIssueRef) -> Bool {
            if sub.closed { return true }
            guard let pid = projectId, let status = sub.statuses[pid], let i = names.firstIndex(of: status) else { return false }
            return i >= targetIndex
        }
        for t in stories {
            guard t.subIssues.count == t.subIssueCount else { continue }
            let allClosed = t.subIssues.allSatisfy(\.closed)
            let shouldClose = allClosed && t.isOpenIssue && t.contentId != nil
            let shouldMove = (earlier.contains(t.status) || t.status == "No status") && t.subIssues.allSatisfy(done)
            guard shouldMove || (shouldClose && t.status == target.name) else { continue }
            let key = (shouldMove ? "story:" : "story-close:") + t.id
            guard !handledVerdicts.contains(key) else { continue }
            handledVerdicts.insert(key)
            Task { [weak self] in
                guard let self else { return }
                do {
                    if shouldMove {
                        try await client.setStatus(projectId: board.projectId, itemId: t.id, fieldId: board.statusFieldId, optionId: targetId)
                    }
                    // Every sub-issue is closed, so the story itself is complete.
                    if shouldClose, let issueId = t.contentId { try await client.closeIssue(issueId) }
                    if shouldMove, settings.notifications {
                        Notifier.shared.post(.init(title: "Story done · \(t.repo.map { "\($0)#\(t.number ?? 0)" } ?? "Draft")",
                                                   body: "\(t.title)\nAll \(t.subIssueCount) sub-issues are done · Moved to \(target.name)",
                                                   url: t.url, id: "story-\(t.id)", kind: .good), sound: settings.soundOnChange)
                    }
                } catch {
                    handledVerdicts.remove(key)
                    self.error = "Could not move \(t.title): \(error.localizedDescription)"
                }
                await self.refresh()
            }
        }
    }

    private func option(named name: String) -> StatusOption? {
        statusOptions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Your own task with changes requested goes back to In Progress (Reviewed is only for approved work),
    /// even if it sits in the review status or was moved to Reviewed by hand. Handled once per review.
    private func applyChangesRequested(_ tasks: [BoardTask]) {
        guard settings.autoMove, let board, let target = option(named: "In Progress"), let targetId = target.id else { return }
        for t in tasks where [settings.reviewStatus, statusAfterReview].contains(t.status) {
            let requests = t.prs.filter { $0.stage == .changesRequested }.flatMap(\.reviewers).filter { $0.state == "CHANGES_REQUESTED" }
            guard let latest = requests.max(by: { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }) else { continue }
            let key = "changes:\(t.id)@\(latest.submittedAt?.timeIntervalSince1970 ?? 0)"
            guard !handledVerdicts.contains(key) else { continue }
            handledVerdicts.insert(key)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await client.setStatus(projectId: board.projectId, itemId: t.id, fieldId: board.statusFieldId, optionId: targetId)
                    if settings.notifications {
                        Notifier.shared.post(.init(title: "Changes requested · \(t.repo.map { "\($0)#\(t.number ?? 0)" } ?? "Draft")",
                                                   body: "\(t.title)\nMoved back to \(target.name)",
                                                   url: t.prs.first?.url ?? t.url, id: "changes-\(t.id)", kind: .info), sound: false)
                    }
                } catch {
                    handledVerdicts.remove(key)
                    self.error = "Could not move \(t.title): \(error.localizedDescription)"
                }
                await self.refresh()
            }
        }
    }

    /// Moves cards you just reviewed: approved -> the status after review, changes requested -> In Progress + unassign you.
    /// Only reviews submitted after the card entered the review status count, so older verdicts never move cards back.
    private func applyVerdicts(_ tasks: [BoardTask], viewer: String) {
        guard settings.autoMove, let board else { return }
        for t in tasks where t.status == settings.reviewStatus {
            guard let v = t.verdict(of: viewer), let at = v.submittedAt, at > (t.statusSince ?? .distantPast) else { continue }
            let key = "\(t.id)@\(at.timeIntervalSince1970)"
            guard !handledVerdicts.contains(key) else { continue }
            handledVerdicts.insert(key)
            let approved = v.state == "APPROVED"
            let target = option(named: approved ? statusAfterReview : "In Progress")
            Task { [weak self] in
                guard let self else { return }
                var done: [String] = []
                do {
                    if let id = target?.id {
                        try await client.setStatus(projectId: board.projectId, itemId: t.id, fieldId: board.statusFieldId, optionId: id)
                        done.append("Moved to \(target!.name)")
                    }
                    if !approved, let content = t.contentId, t.assignees.contains(viewer) {
                        try await client.removeAssignee(board.viewerId, from: content)
                        done.append("You were unassigned")
                    }
                    if !done.isEmpty, settings.notifications {
                        Notifier.shared.post(.init(title: "\(approved ? "Approved" : "Changes requested") · \(t.repo.map { "\($0)#\(t.number ?? 0)" } ?? "Draft")",
                                                   body: "\(t.title)\n" + done.joined(separator: " · "),
                                                   url: t.url, id: "verdict-\(t.id)", kind: .info), sound: false)
                    }
                } catch {
                    self.error = "Could not update \(t.title): \(error.localizedDescription)"
                }
                await self.refresh()
            }
        }
    }

    private func apply(_ snap: BoardSnapshot) {
        if viewer != snap.viewer { viewer = snap.viewer }
        if projectTitle != snap.projectTitle { projectTitle = snap.projectTitle }
        if projectURL != snap.projectURL { projectURL = snap.projectURL }
        if statusOptions != snap.statusOptions { statusOptions = snap.statusOptions }
        lastUpdated = Date()
        if let v = snap.viewerId, let p = snap.projectId, let f = snap.statusFieldId { board = (v, p, f) }

        // User Stories split into sub-issues are followed through their sub-issues, so they never show up.
        let all = snap.mine.compactMap(BoardTask.init)
        applyFinishedStories(all.filter(\.isSplitStory), projectId: snap.projectId)
        let fetched = all.filter { !$0.isSplitStory }
        applyMerged(fetched.filter { !$0.isReviewing(by: snap.viewer) })
        // Extra columns are only fetched for the merged move; the tabs keep showing the configured statuses.
        let shown = settings.shownStatuses
        let assigned = shown.isEmpty ? fetched : fetched.filter { shown.contains($0.status) }
        applyVerdicts(assigned.filter { $0.isReviewing(by: snap.viewer) }, viewer: snap.viewer)
        applyChangesRequested(assigned.filter { !$0.isReviewing(by: snap.viewer) })
        let newMine = assigned.filter { !$0.isReviewing(by: snap.viewer) && (settings.statuses.isEmpty || settings.statuses.contains($0.status)) }
        // Reviewing = others' work assigned to you, until you approve / request changes or its PRs are merged or closed.
        let newReviewing = assigned
            .filter { $0.isReviewing(by: snap.viewer) && ($0.prs.isEmpty || $0.prs.contains { $0.stage != .merged && $0.stage != .closed }) }
            .filter { $0.verdict(of: snap.viewer) == nil }
            .sorted {
                let a = $0.awaitsReview(from: snap.viewer), b = $1.awaitsReview(from: snap.viewer)
                if a != b { return a }
                return ($0.statusSince ?? .distantFuture) < ($1.statusSince ?? .distantFuture)
            }
        // Open for review = in the review status with no second (reviewer) assignee.
        let newOpen = snap.open.compactMap(BoardTask.init)
            .filter { !$0.isSplitStory && $0.assignees.count < 2 && !$0.assignees.contains(snap.viewer) }
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
                    // Most important event first, and only one sound per poll.
                    let ranked = events.sorted { SoundKind.allCases.firstIndex(of: $0.kind)! < SoundKind.allCases.firstIndex(of: $1.kind)! }
                    for (i, e) in ranked.enumerated() { Notifier.shared.post(e, sound: settings.soundOnChange && i == 0) }
                } else if settings.soundOnChange {
                    let kind = SoundKind.allCases.first { k in events.contains { $0.kind == k } } ?? .info
                    if settings.soundStyle == "synth" { Sounds.play(kind) } else { NSSound(named: "Glass")?.play() }
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
