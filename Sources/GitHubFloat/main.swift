import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Lets clicks act immediately even when the panel isn't the key window.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    /// Native menu for the task row under the point, in the SwiftUI root view's coordinate space.
    var rowMenu: ((CGPoint) -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI re-sets the cursor on every display cycle and mouse move; with a custom pointer size or color
    /// (Accessibility) each set re-renders the pointer image. The panel only ever uses the arrow.
    override func cursorUpdate(with event: NSEvent) {
        if NSCursor.current != NSCursor.arrow { NSCursor.arrow.set() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !showRowMenu(event) { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if !(event.modifierFlags.contains(.control) && showRowMenu(event)) { super.mouseDown(with: event) }
    }

    private func showRowMenu(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        // SwiftUI measures from below the (hidden) title bar's safe area.
        let y = (isFlipped ? p.y : bounds.height - p.y) - safeAreaInsets.top
        guard let menu = rowMenu?(CGPoint(x: p.x - safeAreaInsets.left, y: y)) else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// Text field that handles the standard editing shortcuts itself: an accessory app has no Edit menu to route them.
final class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        let action: Selector?
        switch key {
        case "v": action = #selector(NSText.paste(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = Selector(("undo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let settings = Settings.shared
    private lazy var store = Store(settings: settings)
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var collapsedHeight: CGFloat { 50 + (settings.attached ? arrowHeight : 0) }
    private let arrowHeight: CGFloat = 10
    private let cornerRadius: CGFloat = 12
    private var blur: NSVisualEffectView!
    private let surface = SurfaceView()
    private var hostTop: NSLayoutConstraint!
    /// Attached: x of the arrow tip that points at the menu bar icon, in panel coordinates.
    private var arrowX: CGFloat?
    private let minExpandedHeight: CGFloat = 130

    /// Height the list's content needs; the panel never grows past `expandedHeight` (the user's chosen size).
    private var fittedHeight: CGFloat?

    /// Persisted separately from the window frame so collapsing never overwrites it.
    private var expandedHeight: CGFloat {
        get {
            let v = CGFloat(UserDefaults.standard.double(forKey: "expandedHeight"))
            return v > 0 ? max(minExpandedHeight, v) : 460
        }
        set { UserDefaults.standard.set(Double(max(minExpandedHeight, newValue)), forKey: "expandedHeight") }
    }
    private var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMouseDownMonitor()
        buildMainMenu()
        buildPanel()
        buildStatusItem()
        Notifier.shared.setUp()

        settings.$opacity.sink { [weak self] in self?.panel.alphaValue = $0 }.store(in: &bag)
        settings.$attached.dropFirst().receive(on: RunLoop.main).sink { [weak self] in self?.applyAttached($0) }.store(in: &bag)
        if settings.attached { showPanel() }
        // Follows the icon when the menu bar is laid out (launch, other icons, display changes).
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: statusItem.button?.window)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.settings.attached, self.panel.isVisible else { return }
                self.pinToStatusItem(expand: false)
            }
            .store(in: &bag)
        settings.$collapsed.dropFirst().receive(on: RunLoop.main).sink { [weak self] in self?.applyCollapsed($0) }.store(in: &bag)
        // Next run loop turn (not a debounce): the resize lands right with the content change.
        settings.listOverflowChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self.map { $0.fitToContent($0.settings.listOverflow) } }
            .store(in: &bag)
        Publishers.CombineLatest4(store.$mine, store.$reviewing, store.$open, store.$changed.combineLatest(store.$error))
            .sink { [weak self] mine, reviewing, open, rest in
                self?.updateStatusItem(mine: mine.count, reviewing: reviewing.count, open: open.count,
                                       changed: rest.0.count, error: rest.1 != nil)
            }
            .store(in: &bag)

        store.start()
        Updater.shared.start()
        if !settings.isConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.configureProject() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // MARK: Panel

    /// Never shown (accessory app), but it gives text fields the standard ⌘X/⌘C/⌘V/⌘A/⌘Z shortcuts.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func buildPanel() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.maxX - 380, y: screen.maxY - expandedHeight - 20, width: 360, height: expandedHeight)
        panel = FloatingPanel(
            contentRect: rect,
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        // Moved only by its header (WindowDragArea), so dragging a section header reorders instead of moving the panel.
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self

        blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active

        let host = FirstClickHostingView(rootView: ContentView(store: store, settings: settings,
                                                         showMenu: { [weak self] in self?.popUpMenu() },
                                                         configure: { [weak self] in self?.configureProject() }))
        host.sizingOptions = [] // the window decides its size; SwiftUI must not impose min/max constraints
        host.rowMenu = { [weak self] in self?.rowMenu(at: $0) }
        host.translatesAutoresizingMaskIntoConstraints = false
        surface.frame = blur.bounds
        surface.autoresizingMask = [.width, .height]
        blur.addSubview(surface)
        blur.addSubview(host)
        hostTop = host.topAnchor.constraint(equalTo: blur.topAnchor)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hostTop,
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur
        updateShape()

        panel.setFrameAutosaveName("GitHubFloatPanel")
        applyCollapsed(settings.collapsed)
        panel.orderFrontRegardless()
        snapToEdges()
        updateDock()
    }

    private func rowMenu(at point: CGPoint) -> NSMenu? {
        guard let hit = RowHits.shared.hit(at: point), let task = store.task(hit.tab, id: hit.id) else { return nil }
        let store = store
        let key = store.key(hit.tab, task)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func open(_ url: String) {
            store.acknowledge(key)
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
        if hit.tab == .open, store.canAssignMe(task), !store.assigning.contains(task.id) {
            menu.addItem(ActionMenuItem("Assign Me as Reviewer") { store.acknowledge(key); store.assignMe(task) })
            menu.addItem(.separator())
        }
        if let url = task.url {
            menu.addItem(ActionMenuItem("Open \(task.kind == "PullRequest" ? "Pull Request" : "Issue")") { open(url) })
        }
        for pr in task.prs {
            menu.addItem(ActionMenuItem("Open PR #\(pr.number)") { open(pr.url) })
        }
        if let url = task.url ?? task.prs.first?.url {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
        }
        return menu.items.isEmpty ? nil : menu
    }

    private var screenOfPanel: NSScreen? {
        NSScreen.screens.max { $0.frame.intersection(panel.frame).area < $1.frame.intersection(panel.frame).area }
    }

    /// A panel sitting at the bottom of its screen grows upwards (bottom edge fixed); otherwise downwards (top edge fixed).
    /// Only right at the bottom (with some hysteresis), so moving it around mid-screen never flips the layout.
    private var anchoredToBottom: Bool {
        guard !settings.attached, let vf = screenOfPanel?.visibleFrame else { return false }
        return panel.frame.minY - vf.minY < (settings.dockedBottom ? 120 : 64)
    }

    /// Resizes instantly (animated frames block the UI), keeping the edge nearest to the screen edge in place.
    private func applyCollapsed(_ collapsed: Bool) {
        let height = collapsed ? collapsedHeight : targetExpandedHeight
        var f = panel.frame
        if !anchoredToBottom { f.origin.y += f.height - height }
        f.size.height = height
        if collapsed {
            panel.minSize = NSSize(width: 260, height: collapsedHeight)
            panel.maxSize = NSSize(width: 10_000, height: collapsedHeight)
        } else {
            panel.minSize = NSSize(width: 260, height: minExpandedHeight)
            panel.maxSize = NSSize(width: 10_000, height: 10_000)
        }
        let screen = NSScreen.screens.max { $0.frame.intersection(f).area < $1.frame.intersection(f).area }
        // Keep the panel vertically on its screen without moving it sideways.
        if let vf = screen?.visibleFrame, screen!.frame.intersects(f) {
            if f.minY < vf.minY { f.origin.y = vf.minY }
            if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
        }
        panel.setFrame(f, display: true, animate: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !settings.collapsed else { return }
        expandedHeight = panel.frame.height
        fittedHeight = nil
        fitToContent(settings.listOverflow)
        if settings.attached { pinToStatusItem() }
    }

    private var targetExpandedHeight: CGFloat {
        min(expandedHeight, max(minExpandedHeight, fittedHeight ?? expandedHeight))
    }

    /// Trims empty space below short lists (and grows back up to the user's size when they get longer).
    private func fitToContent(_ overflow: CGFloat) {
        guard settings.isConfigured, !settings.collapsed, !panel.inLiveResize else { return }
        fittedHeight = panel.frame.height + overflow
        let height = targetExpandedHeight.rounded()
        guard abs(height - panel.frame.height) > 1 else { return }
        var f = panel.frame
        if !anchoredToBottom { f.origin.y += f.height - height }
        f.size.height = height
        panel.setFrame(f, display: true, animate: false)
    }

    // MARK: Magnetic edges

    private let snapDistance: CGFloat = 48
    private let snapMargin: CGFloat = 8
    private var pendingSnap: DispatchWorkItem?
    private var draggedByUser = false
    /// The left button went down on the panel itself (pressedMouseButtons alone is global and would count clicks in other apps).
    private var mouseDownInPanel = false
    private var mouseDownMonitor: Any?

    private func installMouseDownMonitor() {
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouseDownInPanel = event.type == .leftMouseDown && event.window === self.panel
            }
            return event
        }
    }

    /// Snaps once the user lets go of the panel (moves fire continuously while dragging).
    func windowDidMove(_ notification: Notification) {
        guard !panel.inLiveResize, !popoverAnimating else { return }
        if mouseDownInPanel, NSEvent.pressedMouseButtons & 1 != 0 { draggedByUser = true }
        // Hint that letting go here attaches the panel to the menu bar icon.
        if draggedByUser, !settings.attached { statusItem?.button?.highlight(nearStatusIcon()) }
        scheduleSnap()
    }

    /// The panel's top edge is right at the menu bar icon.
    private func nearStatusIcon() -> Bool {
        guard let button = statusItem?.button, let window = button.window, window.frame.height > 0,
              let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) else { return false }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let menuBarBottom = min(icon.minY, screen.frame.maxY - NSStatusBar.system.thickness)
        let f = panel.frame
        let dx = max(f.minX - icon.midX, 0, icon.midX - f.maxX)
        return dx < 30 && menuBarBottom - f.maxY < 30 && f.maxY - screen.frame.maxY < 30
    }

    private func scheduleSnap() {
        pendingSnap?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.scheduleSnap() } else { self.didFinishMove() }
        }
        pendingSnap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func didFinishMove() {
        let dragged = draggedByUser
        draggedByUser = false
        mouseDownInPanel = false
        if dragged, !settings.attached {
            statusItem?.button?.highlight(false)
            if nearStatusIcon() { settings.attached = true; return }
        }
        if settings.attached {
            // Pulling the panel away from the menu bar icon detaches it.
            guard dragged, let pinned = pinnedFrame(), abs(pinned.origin.x - panel.frame.origin.x) > 2 || abs(pinned.maxY - panel.frame.maxY) > 2 else { return }
            settings.attached = false
        }
        snapToEdges()
        updateDock()
    }

    /// Flips the layout (header at the bottom) when the panel lives in the lower part of the screen.
    private func updateDock() {
        let bottom = anchoredToBottom
        if settings.dockedBottom != bottom { settings.dockedBottom = bottom }
    }

    /// Pulls the panel to the screen edges / corners it was dropped near, and back inside the screen.
    private func snapToEdges() {
        guard !settings.attached, let vf = screenOfPanel?.visibleFrame else { return }
        var f = panel.frame
        if abs(f.minX - vf.minX) < snapDistance || f.minX < vf.minX { f.origin.x = vf.minX + snapMargin }
        else if abs(vf.maxX - f.maxX) < snapDistance || f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width - snapMargin }
        if abs(vf.maxY - f.maxY) < snapDistance || f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height - snapMargin }
        else if abs(f.minY - vf.minY) < snapDistance || f.minY < vf.minY { f.origin.y = vf.minY + snapMargin }
        guard f.origin != panel.frame.origin else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(f, display: true)
        }
    }

    /// Bumped on every show/hide so a finished zoom-out never hides a panel that was reopened meanwhile.
    private var popoverGeneration = 0
    private var popoverAnimating = false
    private var popoverHiding = false
    private let popoverMinScale: CGFloat = 0.15

    /// Scales the panel content around the arrow tip, i.e. the menu bar icon.
    private func popoverTransform(_ scale: CGFloat) -> CATransform3D {
        guard let layer = blur.layer else { return CATransform3DIdentity }
        let size = layer.bounds.size
        let tip = CGPoint(x: arrowX ?? size.width / 2, y: size.height)
        let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        let dx = (tip.x - anchor.x) * (1 - scale), dy = (tip.y - anchor.y) * (1 - scale)
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(dx, dy, 0))
    }

    /// Zooms the content to `to` scale; the window shadow is off meanwhile since it can't follow the scaling.
    private func animatePopover(from start: CGFloat? = nil, to scale: CGFloat, duration: CFTimeInterval, spring: Bool, completion: @escaping () -> Void) {
        blur.wantsLayer = true
        guard let layer = blur.layer else { completion(); return }
        let from = start.map(popoverTransform) ?? layer.presentation()?.transform ?? popoverTransform(1)
        layer.removeAnimation(forKey: "popover")
        panel.hasShadow = false
        let anim: CABasicAnimation
        if spring {
            let s = CASpringAnimation(keyPath: "transform")
            s.mass = 1; s.stiffness = 320; s.damping = 24; s.initialVelocity = 0
            s.duration = s.settlingDuration
            anim = s
        } else {
            anim = CABasicAnimation(keyPath: "transform")
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        anim.fromValue = NSValue(caTransform3D: from)
        anim.toValue = NSValue(caTransform3D: popoverTransform(scale))
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        layer.add(anim, forKey: "popover")
        CATransaction.commit()
    }

    private func finishPopoverAnimation() {
        blur.layer?.removeAnimation(forKey: "popover")
        panel.hasShadow = true
        panel.invalidateShadow()
        popoverAnimating = false
    }

    private func showPanel() {
        popoverGeneration += 1
        popoverHiding = false
        statusItem?.button?.highlight(settings.attached)
        guard settings.attached else {
            panel.alphaValue = settings.opacity
            panel.orderFrontRegardless()
            updateOutsideClickMonitor()
            return
        }
        pinToStatusItem()
        if !panel.isVisible || popoverAnimating {
            // Popover-style entrance: grows out of the menu bar icon.
            let wasHidden = !panel.isVisible
            if wasHidden { panel.alphaValue = 0 }
            popoverAnimating = true
            panel.orderFrontRegardless()
            let generation = popoverGeneration
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = settings.opacity
            }
            animatePopover(from: wasHidden ? popoverMinScale : nil, to: 1, duration: 0.3, spring: true) { [weak self] in
                guard let self, generation == self.popoverGeneration else { return }
                self.finishPopoverAnimation()
            }
        } else {
            panel.orderFrontRegardless()
        }
        updateOutsideClickMonitor()
    }

    private func hidePanel() {
        if popoverHiding { return }
        popoverGeneration += 1
        statusItem?.button?.highlight(false)
        guard settings.attached, panel.isVisible else {
            panel.orderOut(nil)
            updateOutsideClickMonitor()
            return
        }
        popoverAnimating = true
        popoverHiding = true
        let generation = popoverGeneration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        // Shrinks back into the menu bar icon.
        animatePopover(to: popoverMinScale, duration: 0.18, spring: false) { [weak self] in
            guard let self else { return }
            self.popoverHiding = false
            guard generation == self.popoverGeneration else { return }
            self.panel.orderOut(nil)
            self.finishPopoverAnimation()
            self.panel.alphaValue = self.settings.opacity
            self.updateOutsideClickMonitor()
        }
    }

    private var outsideClickMonitor: Any?

    /// Attached, the panel behaves like a menu bar popover: a click in any other app hides it.
    /// (Clicks in the panel, its menus or the menu bar icon are this app's own events and never reach the global monitor.)
    private func updateOutsideClickMonitor() {
        let wanted = settings.attached && panel.isVisible
        if wanted, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hidePanel() }
            }
        } else if !wanted, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: Attached to the menu bar

    /// Right under the menu bar icon, centered on it and kept inside its screen.
    private func pinnedFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window,
              window.frame.height > 0, // not laid out yet right after launch
              let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) else { return nil }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let vf = screen.visibleFrame
        var f = panel.frame
        f.origin.x = min(max(icon.midX - f.width / 2, vf.minX + snapMargin), vf.maxX - f.width - snapMargin)
        let menuBarBottom = min(icon.minY, screen.frame.maxY - NSStatusBar.system.thickness)
        f.origin.y = menuBarBottom - 1 - f.height
        return f
    }

    private func iconMidX() -> CGFloat? {
        guard let button = statusItem?.button, let window = button.window, window.frame.height > 0 else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).midX
    }

    /// Rounded panel background, with a popover arrow towards the menu bar icon when attached.
    private func updateShape() {
        let arrow = arrowX.map { min(max($0, cornerRadius + arrowHeight * 2.1), panel.frame.width - cornerRadius - arrowHeight * 2.1) }
        hostTop.constant = arrow == nil ? 0 : arrowHeight
        let size = blur.bounds.size == .zero ? panel.frame.size : blur.bounds.size
        let path = Self.shapePath(size: size, radius: cornerRadius, tip: arrowHeight, arrowX: arrow)
        blur.maskImage = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path)
            ctx.setFillColor(.black)
            ctx.fillPath()
            return true
        }
        surface.path = path
        panel.invalidateShadow()
    }

    /// Rounded rect, plus a soft-edged popover arrow (like the macOS one) at `arrowX` when attached.
    private static func shapePath(size: CGSize, radius: CGFloat, tip: CGFloat, arrowX: CGFloat?) -> CGPath {
        let body = CGRect(x: 0, y: 0, width: size.width, height: size.height - (arrowX == nil ? 0 : tip))
        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: radius, cornerHeight: radius)
        if let x = arrowX {
            let top = body.maxY, w = tip * 2.1, apex = top + tip
            path.move(to: CGPoint(x: x - w, y: top))
            path.addCurve(to: CGPoint(x: x - 4, y: apex - 2.2), control1: CGPoint(x: x - w * 0.55, y: top), control2: CGPoint(x: x - 7, y: apex - 5))
            path.addCurve(to: CGPoint(x: x + 4, y: apex - 2.2), control1: CGPoint(x: x - 2, y: apex + 0.2), control2: CGPoint(x: x + 2, y: apex + 0.2))
            path.addCurve(to: CGPoint(x: x + w, y: top), control1: CGPoint(x: x + 7, y: apex - 5), control2: CGPoint(x: x + w * 0.55, y: top))
            path.closeSubpath()
        }
        return path
    }

    func windowDidResize(_ notification: Notification) {
        if settings.attached, let mid = iconMidX() { arrowX = mid - panel.frame.minX }
        updateShape()
    }

    private func pinToStatusItem(expand: Bool = true) {
        if expand, settings.collapsed { settings.collapsed = false }
        defer { arrowX = iconMidX().map { $0 - panel.frame.minX }; updateShape() }
        guard let f = pinnedFrame(), f != panel.frame else { return }
        panel.setFrame(f, display: true, animate: false)
        updateDock()
    }

    private func applyAttached(_ attached: Bool) {
        statusItem.menu = attached ? nil : statusMenu
        if attached {
            if panel.isVisible { showPanel() }
        } else {
            statusItem.button?.highlight(false)
            arrowX = nil
            updateShape()
        }
        applyCollapsed(settings.collapsed)
        updateDock()
        updateOutsideClickMonitor()
    }

    /// Attached: left click shows/hides the panel; right click (or ⌃-click) opens the menu.
    @objc private func statusItemClicked(_ sender: Any?) {
        guard settings.attached else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            if panel.isVisible { statusItem.button?.highlight(true) }
        } else {
            togglePanel()
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.stack.badge.person.crop", accessibilityDescription: "GitHub Float")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu.delegate = self
        statusItem.menu = settings.attached ? nil : statusMenu
    }

    private func updateStatusItem(mine: Int, reviewing: Int, open: Int, changed: Int, error: Bool) {
        statusItem.button?.title = error ? " !" : " \(mine) · \(reviewing) · \(open)" + (changed > 0 ? " •" : "")
        statusItem.button?.toolTip = "Mine: \(mine) · Reviewing: \(reviewing) · Needs reviewer: \(open)"
    }

    private func popUpMenu() {
        let menu = NSMenu()
        populate(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        if Updater.shared.available, let latest = Updater.shared.latest {
            menu.addItem(item("Update GitHub Float to \(latest)", #selector(upgrade), key: ""))
            menu.addItem(.separator())
        }
        menu.addItem(item(panel.isVisible ? "Hide Panel" : "Show Panel", #selector(togglePanel), key: ""))
        let attach = item("Attach to Menu Bar", #selector(toggleAttached), key: "")
        attach.state = settings.attached ? .on : .off
        attach.toolTip = "Click the menu bar icon to show or hide the panel right under it. Right-click the icon for this menu."
        menu.addItem(attach)
        menu.addItem(item("Refresh Now", #selector(refreshNow), key: "r"))
        menu.addItem(item("Connect a Project…", #selector(configureProject), key: ","))
        if let url = store.projectURL { menu.addItem(item("Open Board", #selector(openBoard), key: "b", represented: url)) }
        menu.addItem(.separator())

        let statusMenu = NSMenu()
        let names = store.statusOptions.isEmpty
            ? ["Ready to Start", "In Progress", "In Review", "Reviewed", "Ready to Verify", "To Deploy"]
            : store.statusOptions.map(\.name)
        for name in names {
            let i = item(name, #selector(toggleStatus(_:)), represented: name)
            i.state = settings.statuses.contains(name) ? .on : .off
            statusMenu.addItem(i)
        }
        menu.addItem(submenu("\"Mine\" Statuses", statusMenu))

        let reviewMenu = NSMenu()
        for name in names {
            let i = item(name, #selector(setReviewStatus(_:)), represented: name)
            i.state = settings.reviewStatus == name ? .on : .off
            reviewMenu.addItem(i)
        }
        menu.addItem(submenu("\"Needs Reviewer\" Status", reviewMenu))

        let pollMenu = NSMenu()
        for (title, secs) in [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)] {
            let i = item(title, #selector(setPoll(_:)), represented: secs)
            i.state = settings.pollSeconds == secs ? .on : .off
            pollMenu.addItem(i)
        }
        menu.addItem(submenu("Poll Every", pollMenu))

        let opacityMenu = NSMenu()
        for pct in [100, 95, 85, 70, 50] {
            let i = item("\(pct)%", #selector(setOpacity(_:)), represented: Double(pct) / 100)
            i.state = abs(settings.opacity - Double(pct) / 100) < 0.01 ? .on : .off
            opacityMenu.addItem(i)
        }
        menu.addItem(submenu("Opacity", opacityMenu))

        let notify = item("Notifications", #selector(toggleNotifications), key: "")
        notify.state = settings.notifications ? .on : .off
        menu.addItem(notify)
        menu.addItem(item("Send Test Notification", #selector(testNotification), key: ""))

        let autoMove = item("Move Cards After My Review", #selector(toggleAutoMove), key: "")
        autoMove.state = settings.autoMove ? .on : .off
        autoMove.toolTip = "Approve → next status after review. Request changes → In Progress and you're unassigned."
        menu.addItem(autoMove)
        let autoMerged = item("Move My Merged Tasks to \(settings.mergedStatus)", #selector(toggleAutoMoveMerged), key: "")
        autoMerged.state = settings.autoMoveMerged ? .on : .off
        autoMerged.toolTip = "When all PRs of a task of yours are merged, move it to \(settings.mergedStatus) from any earlier column. Same for a User Story once all its sub-issues are closed or in \(settings.mergedStatus) (or later)."
        menu.addItem(autoMerged)

        let soundMenu = NSMenu()
        for (title, style) in [("GitHub Float Synth", "synth"), ("macOS Default", "system"), ("Off", "off")] {
            let i = item(title, #selector(setSoundStyle(_:)), key: "", represented: style)
            i.state = (style == "off" ? !settings.soundOnChange : settings.soundOnChange && settings.soundStyle == style) ? .on : .off
            soundMenu.addItem(i)
        }
        soundMenu.addItem(.separator())
        let previewHeader = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        previewHeader.isEnabled = false
        soundMenu.addItem(previewHeader)
        for k in SoundKind.allCases {
            soundMenu.addItem(item("▶︎ \(k.title)", #selector(previewSound(_:)), key: "", represented: k.rawValue))
        }
        menu.addItem(submenu("Sound", soundMenu))

        let login = item("Launch at Login", #selector(toggleLogin), key: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Check for Updates… (v\(Updater.shared.current ?? "dev"))", #selector(checkForUpdates), key: ""))
        menu.addItem(item("Quit GitHub Float", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", represented: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.representedObject = represented
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    // MARK: Actions

    @objc func configureProject() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect a GitHub Project"
        alert.informativeText = "Paste the project URL, e.g.\nhttps://github.com/orgs/acme/projects/5\nhttps://github.com/users/octocat/projects/2"
        alert.icon = NSApp.applicationIconImage
        let field = EditableTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://github.com/orgs/<org>/projects/<number>"
        field.isEditable = true
        field.isSelectable = true
        if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           Settings.parseProject(copied) != nil {
            field.stringValue = copied // a project URL on the clipboard is most likely the one to connect
        } else if settings.isConfigured {
            field.stringValue = store.projectURL ?? "https://github.com/orgs/\(settings.owner)/projects/\(settings.projectNumber)"
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if let p = Settings.parseProject(field.stringValue) {
                settings.owner = p.owner
                settings.projectNumber = p.number
                store.start()
                return
            }
            alert.informativeText = "⚠️ That doesn't look like a GitHub Project URL.\nExpected https://github.com/orgs/<org>/projects/<number> or /users/<user>/projects/<number>."
        }
    }

    @objc private func refreshNow() { Task { await store.refresh() } }

    @objc private func openBoard(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    @objc private func toggleStatus(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if let idx = settings.statuses.firstIndex(of: name) { settings.statuses.remove(at: idx) }
        else { settings.statuses.append(name) }
    }

    @objc private func setReviewStatus(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? String { settings.reviewStatus = v }
    }

    @objc private func setPoll(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Int { settings.pollSeconds = v }
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { settings.opacity = v }
    }

    @objc private func setSoundStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? String else { return }
        settings.soundOnChange = style != "off"
        if style != "off" { settings.soundStyle = style }
    }

    @objc private func previewSound(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = SoundKind(rawValue: raw) else { return }
        Sounds.play(kind)
    }

    @objc private func toggleNotifications() { settings.notifications.toggle() }

    @objc private func toggleAttached() { settings.attached.toggle() }

    @objc private func toggleAutoMove() { settings.autoMove.toggle() }

    @objc private func toggleAutoMoveMerged() { settings.autoMoveMerged.toggle() }

    @objc private func testNotification() {
        Notifier.shared.post(.init(title: "GitHub Float", body: "Notifications are working 🎉",
                                   url: store.projectURL, id: "test", kind: .attention), sound: settings.soundOnChange) { error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Notifications are blocked"
                alert.informativeText = "\(error.localizedDescription)\n\nEnable them in System Settings → Notifications → GitHubFloat."
                alert.runModal()
            }
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func upgrade() { Task { await Updater.shared.install() } }

    @objc private func checkForUpdates() {
        Task {
            let updater = Updater.shared
            let reached = await updater.check(promptIfDue: false)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.icon = NSApp.applicationIconImage
            if !reached {
                alert.messageText = "Could not check for updates"
                alert.informativeText = "GitHub could not be reached. Try again later."
            } else if updater.available {
                updater.prompt()
                return
            } else {
                alert.messageText = "You're up to date"
                alert.informativeText = "GitHub Float \(updater.current ?? "?") is the latest version."
            }
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// `GitHubFloat --render-sounds <dir>` writes the notification sounds (used by build.sh).
if let i = CommandLine.arguments.firstIndex(of: "--render-sounds") {
    Sounds.render(to: CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ".")
    exit(0)
}

// `GitHubFloat --notify-test` posts a sample notification and reports the authorization state.
if CommandLine.arguments.contains("--notify-test") {
    let sema = DispatchSemaphore(value: 0)
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
        print("granted=\(granted) error=\(error?.localizedDescription ?? "-")")
        Notifier.shared.post(.init(title: "GitHub Float", body: "Notifications are working 🎉", url: nil, id: "test", kind: .good), sound: true) { err in
            print("posted error=\(err?.localizedDescription ?? "-")")
            sema.signal()
        }
    }
    sema.wait()
    RunLoop.main.run(until: Date().addingTimeInterval(2)) // let the sound finish
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--screenshots") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "docs"
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Screenshots.render(to: dir)
    }
    UserDefaults.standard.removePersistentDomain(forName: "githubfloat.screenshots")
    exit(0)
}

// `GitHubFloat --dump` prints the current board snapshot to stdout (handy for debugging).
if CommandLine.arguments.contains("--dump") {
    let s = Settings.shared
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            guard s.isConfigured else { print("No project configured. Use \"Connect a Project…\" in the app."); sema.signal(); return }
            let snap = try await GitHubClient().fetchBoard(owner: s.owner, number: s.projectNumber,
                                                           mineFilter: s.mineFilter, openFilter: s.openFilter)
            print("\(snap.projectTitle) — viewer: \(snap.viewer)")
            func dump(_ title: String, _ tasks: [BoardTask]) {
                print("== \(title) (\(tasks.count))")
                for t in tasks {
                    print("[\(t.status) since \(t.statusSince.map { "\($0)" } ?? "?")] \(t.repo ?? "-")#\(t.number.map(String.init) ?? "-") \(t.title) — assignees: \(t.assignees.joined(separator: ","))")
                    for pr in t.prs {
                        let reviewers = pr.reviewers.map { "\($0.login)=\($0.state)" }.joined(separator: ", ")
                        print("    PR #\(pr.number) \(pr.stage.label) checks=\(pr.checks?.rawValue ?? "-") \(reviewers)")
                    }
                }
            }
            let all = snap.mine.compactMap(BoardTask.init)
            print("== Split User Stories (hidden)")
            for t in all where t.isSplitStory {
                let open = t.subIssues.filter { !$0.closed }.map { sub in snap.projectId.flatMap { sub.statuses[$0] } ?? "?" }
                print("[\(t.status)] \(t.repo ?? "-")#\(t.number ?? 0) \(t.title) — \(t.subIssueCount - open.count)/\(t.subIssueCount) closed; open: \(open.joined(separator: ", "))")
            }
            let assigned = all.filter { !$0.isSplitStory }
            dump("Mine: \(s.mineFilter)", assigned.filter { !$0.isReviewing(by: snap.viewer) })
            dump("Reviewing", assigned.filter { $0.isReviewing(by: snap.viewer) })
            dump("Needs reviewer: \(s.openFilter) + <2 assignees", snap.open.compactMap(BoardTask.init).filter { !$0.isSplitStory && $0.assignees.count < 2 && !$0.assignees.contains(snap.viewer) })
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

/// The panel's solid background, filled with the same shape as the window mask (rounded corners and arrow).
final class SurfaceView: NSView {
    private let shape = CAShapeLayer()
    var path: CGPath? { didSet { shape.path = path } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
        refreshColor()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        shape.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    private func refreshColor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // GitHub's canvas colors (dark: #161B22, light: #F6F8FA).
        shape.fillColor = dark ? CGColor(srgbRed: 0.086, green: 0.106, blue: 0.133, alpha: 1)
                               : CGColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
    }
}
