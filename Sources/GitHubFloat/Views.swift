import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: Store
    @ObservedObject var settings: Settings
    let showMenu: () -> Void
    let configure: () -> Void
    /// Renders lists without ScrollView (used for static screenshots).
    var staticLayout = false
    @State private var dropTarget: String?
    @State private var hoveredHeader: String?

    var body: some View {
        VStack(spacing: 0) {
            if bottom {
                if !settings.collapsed { content }
                header
            } else {
                header
                if !settings.collapsed { content }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: bottom ? .bottom : .top)
        .ignoresSafeArea() // the hidden title bar must not push the content down
    }

    /// Docked at the bottom of the screen: header last, so it stays put while the list opens upwards.
    private var bottom: Bool { settings.dockedBottom }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            setup
        } else if bottom {
            list
            Divider().opacity(0.5)
            tabBar
        } else {
            tabBar
            Divider().opacity(0.5)
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        switch settings.tab {
        case .mine: mineList
        case .reviewing: reviewingList
        case .open: openList
        }
    }

    // MARK: Setup

    private var setup: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.person.crop")
                .font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Track your GitHub Project").font(.system(size: 13, weight: .semibold))
            Text("Paste the URL of a GitHub Project (org or user) to see your tasks and their review state.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Connect a Project…", action: configure)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.person.crop")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.isConfigured ? store.projectTitle : "GitHub Float").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                subtitle
            }
            .overlay(staticLayout ? nil : WindowDragArea())
            Spacer(minLength: 4)
            if !store.changed.isEmpty {
                Button { store.acknowledgeAll() } label: {
                    Text("\(store.changed.count) new")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Mark all as seen")
            }
            iconButton(settings.collapsed != bottom ? "chevron.down" : "chevron.up", help: settings.collapsed ? "Expand" : "Collapse") {
                settings.collapsed.toggle()
            }
            ZStack {
                if store.loading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    iconButton("arrow.clockwise", help: "Refresh now (⌘R)") { Task { await store.refresh() } }
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
            .frame(width: 22, height: 22)
            iconButton("ellipsis.circle", help: "Options", action: showMenu)
        }
        .padding(.horizontal, 12)
        .padding(.top, bottom && !settings.collapsed ? 6 : 10)
        .padding(.bottom, bottom && !settings.collapsed ? 10 : 6)
        .background(staticLayout ? nil : WindowDragArea())
        .contentShape(Rectangle())
    }

    private var subtitle: some View {
        HStack(spacing: 4) {
            if let error = store.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(1).help(error)
            } else if !settings.isConfigured {
                Text("No project connected")
            } else if let last = store.lastUpdated {
                if settings.collapsed {
                    Label("\(store.mine.count)", systemImage: "person.fill").help("Mine")
                    Label("\(store.reviewing.count)", systemImage: "eye").help("Reviewing")
                    Label("\(store.open.count)", systemImage: "person.badge.plus").help("Needs reviewer")
                    Text("·")
                }
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(updatedText(last))
                }
                .lineLimit(1)
            } else {
                Text("Loading…")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func updatedText(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        switch s {
        case ..<30: return "updated just now"
        case ..<3600: return "updated \(max(1, s / 60))m ago"
        default: return "updated \(s / 3600)h ago"
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(.mine, title: "Mine", icon: "person.fill", count: store.mine.count, key: "1")
            tabButton(.reviewing, title: "Reviewing", icon: "eye", count: store.reviewing.count, key: "2")
            tabButton(.open, title: "Needs reviewer", icon: "person.badge.plus", count: store.open.count, key: "3")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 10)
        .padding(.vertical, bottom ? 8 : 0)
        .padding(.bottom, bottom ? 0 : 8)
    }

    private func tabButton(_ tab: Tab, title: String, icon: String, count: Int, key: KeyEquivalent) -> some View {
        let selected = settings.tab == tab
        let fresh = store.changedCount(tab)
        return Button { settings.tab = tab } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(fresh > 0 ? Color.accentColor : Color.primary.opacity(0.12)))
                    .foregroundStyle(fresh > 0 ? Color.white : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .keyboardShortcut(key, modifiers: .command)
        .help("\(title) (⌘\(key.character))")
    }

    // MARK: Lists

    @ViewBuilder
    private var mineList: some View {
        if store.mine.isEmpty {
            empty(icon: "tray", text: "Nothing assigned to you in \(settings.statuses.joined(separator: ", "))")
        } else {
            scroller {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let groups = store.mineGroups
                    ForEach(Array(groups.enumerated()), id: \.element.status) { i, group in
                        statusSection(group.status, tasks: group.tasks, index: i, total: groups.count)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private var reviewingList: some View {
        if store.reviewing.isEmpty {
            empty(icon: "eye.slash", text: "You're not reviewing anything right now.\nPick one up in Needs reviewer.")
        } else {
            let todo = store.reviewing.filter { $0.awaitsReview(from: store.viewer) }
            let waiting = store.reviewing.filter { !$0.awaitsReview(from: store.viewer) }
            scroller {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !todo.isEmpty {
                        foldableHeader("Your turn", tab: .reviewing, tasks: todo, color: .orange)
                        if !isFolded(.reviewing, "Your turn") { ForEach(todo) { row($0, tab: .reviewing) } }
                    }
                    if !waiting.isEmpty {
                        foldableHeader("Waiting on the author", tab: .reviewing, tasks: waiting, color: .blue)
                        if !isFolded(.reviewing, "Waiting on the author") { ForEach(waiting) { row($0, tab: .reviewing) } }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private var openList: some View {
        if store.open.isEmpty {
            empty(icon: "checkmark.circle", text: "Every task in \(settings.reviewStatus) has a reviewer")
        } else {
            scroller {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("Others' tasks in \(settings.reviewStatus) without a reviewer assigned · longest waiting first")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    ForEach(store.open) { task in
                        row(task, tab: .open)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if staticLayout {
            content().frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content() }
        }
    }

    private func row(_ task: BoardTask, tab: Tab) -> some View {
        let key = store.key(tab, task)
        return TaskRow(task: task,
                       viewer: store.viewer,
                       tab: tab,
                       isNew: store.changed.contains(key),
                       onAssign: tab == .open && (staticLayout || store.canAssignMe(task)) ? { store.assignMe(task) } : nil,
                       assigning: store.assigning.contains(task.id)) { store.acknowledge(key) }
            .id(key + task.signature) // redraw when the card moves between sections
    }

    @ViewBuilder
    private func empty(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: store.error == nil ? icon : "wifi.exclamationmark")
                .font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(store.error != nil ? "Could not load the board" : store.lastUpdated == nil ? "Loading…" : text)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Sections

    private func foldKey(_ tab: Tab, _ title: String) -> String { "\(tab.rawValue):\(title)" }

    private func isFolded(_ tab: Tab, _ title: String) -> Bool {
        settings.collapsedSections.contains(foldKey(tab, title))
    }

    private func toggleFold(_ tab: Tab, _ title: String) {
        let key = foldKey(tab, title)
        withAnimation(.easeOut(duration: 0.15)) {
            if settings.collapsedSections.contains(key) { settings.collapsedSections.remove(key) }
            else { settings.collapsedSections.insert(key) }
        }
    }

    /// A "Mine" status section: foldable, and reorderable by dragging its header onto another one.
    @ViewBuilder
    private func statusSection(_ status: String, tasks: [BoardTask], index: Int, total: Int) -> some View {
        let header = foldableHeader(status, tab: .mine, tasks: tasks, color: store.color(forStatus: status), draggable: !staticLayout)
        if staticLayout {
            header
        } else {
            header
            .overlay(alignment: .top) {
                if dropTarget == status {
                    Capsule().fill(Color.accentColor).frame(height: 2).offset(y: 2)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first else { return false }
                withAnimation(.easeOut(duration: 0.2)) { store.moveSection(dragged, to: status) }
                return true
            } isTargeted: { over in
                if over { dropTarget = status } else if dropTarget == status { dropTarget = nil }
            }
            .contextMenu {
                Button("Move Up") { withAnimation { store.moveSection(status, by: -1) } }.disabled(index == 0)
                Button("Move Down") { withAnimation { store.moveSection(status, by: 1) } }.disabled(index == total - 1)
                if !settings.sectionOrder.isEmpty {
                    Divider()
                    Button("Reset to Board Order") { withAnimation { settings.sectionOrder = [] } }
                }
            }
        }
        if !isFolded(.mine, status) {
            ForEach(tasks) { row($0, tab: .mine) }
        }
    }

    @ViewBuilder
    private func foldableHeader(_ title: String, tab: Tab, tasks: [BoardTask], color: Color, draggable: Bool = false) -> some View {
        let folded = isFolded(tab, title)
        let hasNew = tasks.contains { store.changed.contains(store.key(tab, $0)) }
        let header = HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 8)
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            Text("\(tasks.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            if folded && hasNew {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Something changed in this section")
            }
            Spacer()
            if draggable && hoveredHeader == foldKey(tab, title) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .help("Drag to reorder")
            }
        }
        .padding(.top, 6)
        .padding(.bottom, folded ? 2 : 0)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onTapGesture { toggleFold(tab, title) }
        .onHover { hoveredHeader = $0 ? foldKey(tab, title) : (hoveredHeader == foldKey(tab, title) ? nil : hoveredHeader) }
        .help(folded ? "Show \(title)" : "Hide \(title)")

        if draggable {
            header.draggable(title) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title.uppercased()).font(.system(size: 10, weight: .bold))
                    Text("\(tasks.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
            }
        } else {
            header
        }
    }
}

struct TaskRow: View {
    let task: BoardTask
    let viewer: String
    let tab: Tab
    let isNew: Bool
    var onAssign: (() -> Void)? = nil
    var assigning = false
    let onSeen: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isNew {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Changed since you last looked")
                }
                if let repo = task.repo, let n = task.number {
                    Text("\(repo)#\(n)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if task.kind == "DraftIssue" {
                    Text("Draft").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let since = task.statusSince {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(age(since))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(ageColor(since))
                    }
                    .help("In \(task.status) since \(since.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            Text(task.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if tab == .reviewing {
                reviewingLine
            }
            if tab == .open {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill").font(.system(size: 9))
                    Text(task.assignees.first ?? "Unassigned")
                    Spacer(minLength: 0)
                    if let onAssign {
                        assignButton(onAssign)
                    } else {
                        Text("needs a reviewer").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if task.prs.isEmpty, task.kind == "Issue" {
                Label("No linked PR", systemImage: "link.badge.plus")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(task.prs) { pr in
                PRLine(pr: pr, showRepo: pr.repo != task.repo)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isNew ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0; if $0 && isNew { onSeen() } }
        .onTapGesture { open(task.prs.first?.url ?? task.url) }
        .contextMenu {
            if let onAssign, !assigning { Button("Assign Me as Reviewer") { onSeen(); onAssign() }; Divider() }
            if let url = task.url { Button("Open \(task.kind == "PullRequest" ? "Pull Request" : "Issue")") { open(url) } }
            ForEach(task.prs) { pr in Button("Open PR #\(pr.number)") { open(pr.url) } }
            Divider()
            if let url = task.url ?? task.prs.first?.url {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        }
        .help(task.title)
    }

    private func assignButton(_ action: @escaping () -> Void) -> some View {
        Button { onSeen(); action() } label: {
            HStack(spacing: 3) {
                if assigning {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 10))
                }
                Text(assigning ? "Assigning…" : "Assign me").font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.accentColor.opacity(assigning ? 0.5 : 0.9)))
        }
        .buttonStyle(.plain)
        .disabled(assigning)
        .help("Add yourself as the reviewer (second assignee) of this task")
    }

    private var reviewingLine: some View {
        let author = task.prs.compactMap(\.author).first ?? task.assignees.first { $0 != viewer } ?? "unknown"
        let (text, color): (String, Color) = {
            switch task.reviewState(of: viewer) {
            case nil: return ("not reviewed yet", .orange)
            case "REQUESTED": return ("review requested", .orange)
            case "APPROVED": return ("you approved", .green)
            case "CHANGES_REQUESTED": return ("you requested changes", .red)
            case "COMMENTED": return ("you commented", .blue)
            case let s?: return ("you: " + s.replacingOccurrences(of: "_", with: " ").lowercased(), .secondary)
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: "person.fill").font(.system(size: 9))
            Text("by \(author)")
            Spacer(minLength: 0)
            Text(text).foregroundStyle(color)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func open(_ url: String?) {
        onSeen()
        guard let url, let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    private func age(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        switch s {
        case ..<3600: return "\(max(1, s / 60))m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }

    /// Highlights tasks that have been sitting in their status for a long time.
    private func ageColor(_ date: Date) -> Color {
        let hours = Date().timeIntervalSince(date) / 3600
        return hours > 72 ? .red : hours > 24 ? .orange : .secondary
    }
}

struct PRLine: View {
    let pr: PullRequest
    let showRepo: Bool

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: pr.stage.symbol)
                Text(pr.stage.label)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(pr.stage.color.opacity(0.18)))
            .foregroundStyle(pr.stage.color)
            .fixedSize()

            Text(showRepo ? "\(pr.repo)#\(pr.number)" : "PR #\(pr.number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let checks = pr.checks {
                Circle().fill(checks.color).frame(width: 6, height: 6).help(checks.help)
            }
            Spacer(minLength: 0)
            reviewers
        }
        .contentShape(Rectangle())
        .onTapGesture { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
        .help(pr.title)
    }

    private var reviewers: some View {
        HStack(spacing: 4) {
            ForEach(pr.reviewers.prefix(3), id: \.self) { r in
                HStack(spacing: 2) {
                    Image(systemName: r.symbol).foregroundStyle(r.color)
                    Text(r.login).lineLimit(1).truncationMode(.tail).frame(maxWidth: 64, alignment: .leading)
                }
                .help("\(r.login): \(r.state.replacingOccurrences(of: "_", with: " ").lowercased())")
            }
            if pr.reviewers.count > 3 {
                Text("+\(pr.reviewers.count - 3)")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }
}

/// Moves the panel when dragged; the panel is not movable by its whole background.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
