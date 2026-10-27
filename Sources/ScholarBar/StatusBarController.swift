import AppKit
import Combine
import SwiftUI

/// Menu bar item: "🎓 1,234 +3". Left click toggles the SwiftUI popover;
/// right click (or ⌃-click) opens a small menu.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate, NSMenuDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let ui = PopoverUI()
    private let model: AppModel
    /// Newest event when the popover opened; only those count as seen on close.
    private var seenThrough: UUID?
    private var cancellables = Set<AnyCancellable>()
    /// Kept alive while shown: the chosen item's action is sent after the
    /// menu closes.
    private var contextMenu: NSMenu?
    private var menuIsOpen = false
    /// Timestamp of the mouse-down that made the transient popover close
    /// itself; see `clicked`.
    private var selfClosedAt: TimeInterval?
    private var lastTitle: NSAttributedString?
    /// The same panel in an ordinary window, for when the menu bar item
    /// can't be seen (crowded menu bar: macOS hides items behind the notch).
    private var window: NSWindow?
    private let windowUI = PopoverUI()
    private var windowSeenThrough: UUID?

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView(model: model, ui: ui))
        // Let the popover follow the SwiftUI size (settings vs. main view
        // differ); without this the content is laid out wider than the
        // popover and gets clipped on the left.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            let image = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: "Scholar")
            image?.isTemplate = true
            button.image = image
        }
        // objectWillChange fires before the change, so render on the next
        // turn. The main queue also drains while a menu is tracking, unlike
        // the RunLoop.main scheduler (default mode only).
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }
            .store(in: &cancellables)
        render()
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let title = NSMutableAttributedString()
        // Always give a color: a run without one draws black, which vanishes
        // on a dark menu bar.
        func add(_ s: String, _ color: NSColor) {
            title.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }
        var tip: String
        if model.state.profileID == nil {
            tip = "ScholarBar：点击设置 Scholar 主页"
        } else if let snap = model.snapshot {
            let stale: String?
            switch model.health {
            case .blocked(let until): stale = "Scholar 要求验证，\(Fmt.time.string(from: until)) 后重试"
            case .error(let m): stale = "刷新失败：\(m)"
            default: stale = nil
            }
            // Last known number, greyed while refreshing is failing.
            add(" " + Fmt.n(snap.totalCitations), stale == nil ? .labelColor : .secondaryLabelColor)
            let unseen = model.unseenDelta
            if unseen > 0 { add(" +\(unseen)", .systemGreen) }
            tip = "总引用 \(Fmt.n(snap.totalCitations))" + (unseen > 0 ? "，新增 \(unseen)" : "")
            if let stale { tip += "\n" + stale }
            // The "+N" may now come from OpenAlex while the total stays at
            // Scholar's last number; say so, or the two look inconsistent.
            if model.backupActive { tip += "\n正在用 OpenAlex 补位提示新引用（总引用仍以 Scholar 为准）" }
        } else {
            // No data yet: say whether it's coming or failed, not a bare icon.
            switch model.health {
            case .error(let m):
                add(" !", .secondaryLabelColor)
                tip = "ScholarBar：\(m)"
            case .blocked(let until):
                add(" !", .secondaryLabelColor)
                tip = "ScholarBar：Scholar 要求验证，\(Fmt.time.string(from: until)) 后重试"
            default:
                add(" …", .secondaryLabelColor)
                tip = "ScholarBar：正在读取 Scholar 主页…"
            }
        }
        // Reassigning an identical title still relayouts the menu bar. (Compare
        // with what we set: the button's getter adds its own attributes.)
        if lastTitle?.isEqual(to: title) != true {
            button.attributedTitle = title
            lastTitle = title
        }
        if button.toolTip != tip { button.toolTip = tip }
    }

    // MARK: - Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        // A transient popover closes itself on the mouse-down of a click on
        // the status item; this action only arrives on mouse-up, finds the
        // popover gone and would reopen it straight away.
        let closedByThisClick = selfClosedAt.map { (event?.timestamp ?? .infinity) - $0 < 1 } ?? false
        selfClosedAt = nil
        if rightClick {
            if popover.isShown { popover.performClose(nil) }
            showContextMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if !closedByThisClick {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, button.window != nil else { return }
        NSApp.activate()
        if !popover.isShown {
            seenThrough = model.newestEventID
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Opening from the app icon (Dock, Desktop, Launchpad)

    /// What clicking the app icon does: the popover under the menu bar item
    /// on the screen the user is working on (where the mouse is), or the
    /// panel in a window on that screen when the item isn't visible there
    /// (crowded menu bar behind the notch, or the item sits on another display).
    /// Right after launch the item may not be placed yet, so `waitForItem`
    /// gives it a moment before falling back to the window.
    func open(waitForItem: TimeInterval = 0) {
        if popover.isShown || window?.isVisible == true {
            NSApp.activate()
            (popover.isShown ? popover.contentViewController?.view.window : window)?.makeKeyAndOrderFront(nil)
            return
        }
        let screen = Self.screenUnderMouse
        let forceWindow = ProcessInfo.processInfo.environment["SCHOLARBAR_FORCE_WINDOW"] != nil
        if !forceWindow && statusItemVisible(on: screen) {
            showPopover()
        } else if waitForItem > 0 && !forceWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.open(waitForItem: waitForItem - 0.25)
            }
        } else {
            showWindow(on: screen)
        }
    }

    private static var screenUnderMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func statusItemVisible(on screen: NSScreen?) -> Bool {
        guard let screen, let w = statusItem.button?.window, w.isVisible,
              w.occlusionState.contains(.visible) else { return false }
        return screen.frame.contains(NSPoint(x: w.frame.midX, y: w.frame.midY))
    }

    private func showWindow(on screen: NSScreen?) {
        if window == nil {
            let hosting = NSHostingController(rootView: PopoverView(model: model, ui: windowUI))
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "ScholarBar"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible {
            windowSeenThrough = model.newestEventID
            windowUI.willShow()
            // Size first: placing a not-yet-laid-out window by its width put it
            // half off the screen once SwiftUI grew it to 400 pt.
            if let view = w.contentViewController?.view {
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                if size.width > 0, size.height > 0 { w.setContentSize(size) }
            }
            // Top-right of the screen the user is on, where the menu bar item
            // would have opened it; never past the screen's edges.
            if let screen = screen ?? NSScreen.main ?? NSScreen.screens.first {
                let vf = screen.visibleFrame
                let x = max(vf.minX + 8, vf.maxX - w.frame.width - 16)
                w.setFrameTopLeftPoint(NSPoint(x: x, y: vf.maxY - 8))
            }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        windowUI.didClose()
        model.markSeen(through: windowSeenThrough)
        windowSeenThrough = nil
    }

    // MARK: - Context menu

    private func showContextMenu() {
        // Re-entrancy: if performClick ever sent our action instead of
        // opening the menu, `clicked` would land here again.
        guard contextMenu == nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let refresh = menu.addItem(withTitle: "立即刷新", action: #selector(menuRefresh), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = model.canManualRefresh
        let openItem = menu.addItem(withTitle: "打开 Scholar 主页", action: #selector(menuOpenProfile), keyEquivalent: "")
        openItem.target = self
        openItem.isEnabled = model.state.profileID != nil
        let settings = menu.addItem(withTitle: "设置…", action: #selector(menuSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 ScholarBar", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.target = NSApp
        contextMenu = menu
        // Attached only for this click, so a left click still reaches
        // `clicked` and toggles the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Normally performClick tracks the menu modally and it has closed by
        // now; if it's still open, menuDidClose detaches it instead.
        DispatchQueue.main.async { [weak self] in
            if self?.menuIsOpen == false { self?.detachContextMenu() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Next turn: the chosen item's action is sent after this callback.
        DispatchQueue.main.async { [weak self] in self?.detachContextMenu() }
    }

    private func detachContextMenu() {
        statusItem.menu = nil
        contextMenu = nil
    }

    @objc private func menuRefresh() { model.refreshNow() }

    @objc private func menuOpenProfile() {
        if let id = model.state.profileID { NSWorkspace.shared.open(ScholarAPI.profileURL(id)) }
    }

    @objc private func menuSettings() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.showPopover()
            // After showing: popoverWillShow may reset a stale settings page.
            self.ui.showSettings = true
        }
    }

    // MARK: - Debug

    /// Debug: render the open popover's content to a PNG (layout check).
    func snapshotPopover(to path: String) {
        guard let view = popover.contentViewController?.view,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write("snapshot failed: shown=\(popover.isShown)\n".data(using: .utf8)!)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("popover \(view.bounds.size) shown=\(popover.isShown) → \(path)\n".data(using: .utf8)!)
    }

    /// Debug: render the fallback window's content to a PNG.
    func snapshotWindow(to path: String) {
        guard let view = window?.contentViewController?.view,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("window \(window?.frame ?? .zero) visible=\(window?.isVisible ?? false) key=\(window?.isKeyWindow ?? false) → \(path)\n".data(using: .utf8)!)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        ui.willShow()
    }

    func popoverDidShow(_ notification: Notification) {
        // Pressed look while open, like a menu-bar menu.
        statusItem.button?.highlight(true)
    }

    func popoverWillClose(_ notification: Notification) {
        // Closed by a mouse-down outside the popover — in this app that can
        // only be the status item itself (clicks in other apps never reach
        // us). Remember it so the same click's mouse-up doesn't reopen.
        if let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .rightMouseDown,
           e.window !== popover.contentViewController?.view.window {
            selfClosedAt = e.timestamp
        }
    }

    /// The "+N" badge means "new since you last looked" — clear it on close,
    /// so the highlighted rows are still visible while the popover is open.
    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        ui.didClose()
        model.markSeen(through: seenThrough)
        seenThrough = nil
    }
}
