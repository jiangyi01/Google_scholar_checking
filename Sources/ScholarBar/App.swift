import AppKit
import ServiceManagement

@main
enum ScholarBarMain {
    static func main() {
        // One-shot diagnostic (no GUI): `ScholarBar --check <profile URL or ID>`
        if let i = CommandLine.arguments.firstIndex(of: "--check") {
            let arg = CommandLine.arguments.dropFirst(i + 1).first ?? ""
            runCheck(arg)
            return
        }
        // `ScholarBar --login-item on|off|status` (run the binary inside the
        // .app, so SMAppService.mainApp means this bundle).
        if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
            runLoginItem(CommandLine.arguments.dropFirst(i + 1).first ?? "status")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private static func runLoginItem(_ command: String) {
        let service = SMAppService.mainApp
        func describe(_ s: SMAppService.Status) -> String {
            switch s {
            case .enabled: return "已开启"
            case .requiresApproval: return "已登记，但需要在“系统设置 › 通用 › 登录项”里允许"
            case .notRegistered: return "未开启"
            case .notFound: return "找不到（请从 .app 里运行）"
            @unknown default: return "未知状态 \(s.rawValue)"
            }
        }
        do {
            switch command {
            case "on": try service.register()
            case "off": try service.unregister()
            default: break
            }
            print("登录时启动：\(describe(service.status))（\(Bundle.main.bundlePath)）")
        } catch {
            print("❌ \(error.localizedDescription)；当前：\(describe(service.status))")
        }
    }

    private static func runCheck(_ input: String) {
        guard let id = ScholarAPI.extractProfileID(input) else {
            print("用法: ScholarBar --check <Scholar 主页链接或 user ID>")
            return
        }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            defer { sem.signal() }
            do {
                let s = try await ScholarAPI.fetchProfile(id: id)
                print("✅ \(s.name) — \(s.affiliation)")
                print("   引用 \(s.totalCitations)（\(s.sinceLabel) 起 \(s.citationsSince)）  h=\(s.hIndex)  i10=\(s.i10Index)")
                print("   年度: " + s.yearly.suffix(6).map { "\($0.year):\($0.count)" }.joined(separator: " "))
                print("   论文 \(s.papers.count) 篇，前 5：")
                for p in s.papers.prefix(5) {
                    print("   \(p.citations)\t\(p.year.map(String.init) ?? "-")\t\(p.title.prefix(70))")
                }
                // Self-test of the diff: pretend the top paper had 3 fewer citations.
                var old = s
                if !old.papers.isEmpty { old.papers[0].citations -= 3; old.totalCitations -= 3 }
                let ev = AppModel.diff(old: old, new: s)
                print("   diff 自检: \(ev.map { "+\($0.delta) \($0.title.prefix(30))" })")
            } catch {
                print("❌ \(error.localizedDescription)")
            }
        }
        sem.wait()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusBar: StatusBarController!
    /// Started by the login item rather than by a click on the app icon.
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        model = AppModel()
        statusBar = StatusBarController(model: model)
        model.start()
        // Debug: `--snapshot out.png` opens the popover, renders it, quits.
        let args = CommandLine.arguments
        let snapshotPath = args.firstIndex(of: "--snapshot").flatMap { i in i + 1 < args.count ? args[i + 1] : nil }
        // The status item isn't placed on screen until the run loop turns,
        // so opening the popover synchronously here silently does nothing.
        // (Once only: first run and --snapshot used to both schedule it.)
        // Started from the Dock / Desktop / Launchpad: show the panel, so the
        // click visibly does something. A login launch stays quiet. (The
        // login item may not carry the Apple Event flag, so a launch soon
        // after boot with launch-at-login on counts as one too.)
        let atLogin = launchedAtLogin || (model.launchAtLogin && ProcessInfo.processInfo.systemUptime < 600)
        if snapshotPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.statusBar.showPopover() }
        } else if model.state.profileID == nil || !atLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.statusBar.open(waitForItem: 2) }
        }
        if let i = args.firstIndex(of: "--snapshot-window"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.statusBar.snapshotWindow(to: path)
                NSApp.terminate(nil)
            }
        }
        if let path = snapshotPath {
            // Not before the popover has opened (0.5 s) and laid out.
            let wait = max(1, Double(ProcessInfo.processInfo.environment["SNAPSHOT_WAIT"] ?? "") ?? 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self.statusBar.snapshotPopover(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    // Silences the macOS 14 "secure coding is not enabled for restorable
    // state" console warning; this app restores nothing anyway.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// A menu-bar-only app has no main menu, so ⌘V/⌘C/⌘A have nothing to
    /// route through and text fields silently ignore them. An (invisible)
    /// Edit menu restores the standard shortcuts.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // ⌘W for the window opened from the app icon.
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Clicking the app icon while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusBar.open()
        return false
    }
}
