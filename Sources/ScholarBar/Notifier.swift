import Foundation
import UserNotifications

/// New-citation notifications. UNUserNotificationCenter only works inside a
/// real .app bundle (`current()` raises otherwise, e.g. under `swift run`);
/// there, and when the system refuses this ad-hoc-signed app outright, it
/// falls back to osascript.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let canUseUN: Bool = {
        let b = Bundle.main
        return b.bundleIdentifier != nil && b.bundleURL.pathExtension == "app"
    }()
    /// The system rejected the authorization request itself (not the user saying no).
    private var unRefused = false
    private var delegateSet = false

    /// Ask for permission ahead of the first notification (at launch, or when
    /// notifications get switched on), so the prompt doesn't race it.
    func prepare() {
        guard canUseUN, !unRefused else { return }
        Task { _ = await authorization() }
    }

    /// `source` says who saw the gains. Counts are `newDelta`: a Scholar
    /// gain that OpenAlex already announced during a backup period isn't
    /// announced a second time, and a paper whose whole gain was covered is
    /// left out. `total` is Scholar's headline number; OpenAlex counts differ
    /// from Scholar's, so an OpenAlex notice shows only the increase.
    func announce(_ events: [CitationEvent], total: Int, source: EventSource = .scholar) {
        let events = events.filter { $0.newDelta > 0 }
        guard !events.isEmpty else { return }
        let sum = events.reduce(0) { $0 + $1.newDelta }
        var lines = events.prefix(3).map { "+\($0.newDelta)  \($0.title)" }
        if events.count > 3 { lines.append("…另有 \(events.count - 3) 篇") }
        switch source {
        case .scholar:
            send(title: "新增 \(sum) 次引用 · 总计 \(Fmt.n(total))", body: lines.joined(separator: "\n"))
        case .openAlex:
            lines.append("Google Scholar 暂时受限，数字以 Scholar 为准")
            send(title: "OpenAlex：新增 \(sum) 次引用", body: lines.joined(separator: "\n"))
        }
    }

    /// Scholar refused automatic access; say when the app tries again.
    func announceBlocked(until: Date) {
        send(title: "Google Scholar 暂时限制了自动访问",
             body: "ScholarBar 会在 \(Fmt.time.string(from: until)) 再试，此后一周内放慢到每 \(Int(AppModel.slowIntervalHours)) 小时一次。")
    }

    private func send(title: String, body: String) {
        guard canUseUN, !unRefused else { return osascript(title: title, body: body) }
        Task {
            switch await authorization() {
            case .some(true):
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.threadIdentifier = "citations"
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    NSLog("ScholarBar notification: \(error)")
                    osascript(title: title, body: body)
                }
            case .some(false):
                break // turned off in System Settings: respect it, don't route around it
            case .none:
                osascript(title: title, body: body)
            }
        }
    }

    /// The user's choice (asking first if undecided, and waiting for the
    /// answer); nil when notifications aren't available to this app at all.
    private func authorization() async -> Bool? {
        let center = UNUserNotificationCenter.current()
        if !delegateSet {
            center.delegate = self
            delegateSet = true
        }
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        default:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                NSLog("ScholarBar notification authorization: \(error)")
                unRefused = true
                return nil
            }
        }
    }

    /// Show banners while the popover (and so the app) is frontmost too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    private func osascript(title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Text goes in as argv rather than spliced into the script source, so
        // quotes, backslashes and newlines in titles can't break it.
        p.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
            "-e", "end run",
            title, body,
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { NSLog("ScholarBar osascript: \(error)") }
    }
}
