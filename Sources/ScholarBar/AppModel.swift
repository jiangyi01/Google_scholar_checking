import AppKit
import Foundation
import ServiceManagement

enum Health: Equatable {
    case idle
    case fetching
    case ok
    case blocked(until: Date)
    case error(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: PersistedState
    @Published private(set) var health: Health = .idle
    /// Last problem reading or writing state.json; nil when all is well.
    @Published private(set) var persistError: String?
    /// Why the launch-at-login toggle didn't take, or that it awaits approval.
    @Published private(set) var launchAtLoginError: String?

    @Published var intervalHours: Double {
        didSet {
            UserDefaults.standard.set(intervalHours, forKey: "intervalHours")
            reschedule()
        }
    }
    @Published var notifyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notifyEnabled, forKey: "notifyEnabled")
            if notifyEnabled { notifier.prepare() }
        }
    }
    /// Mirrors SMAppService: a failed (un)register snaps back to the real status.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !syncingLoginItem else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }
    /// Use OpenAlex to keep reporting new citations while Scholar refuses
    /// automatic access.
    @Published var openAlexEnabled: Bool {
        didSet {
            UserDefaults.standard.set(openAlexEnabled, forKey: "openAlexEnabled")
            guard !openAlexEnabled else {
                // Switched on mid-outage: start now rather than at the next tick.
                if timer != nil { tickOpenAlex(Date()) }
                return
            }
            abandonOpenAlex()
            // Counts go stale while it's off: a later period must re-baseline.
            if state.openAlex?.active == true {
                state.openAlex?.active = false
                save()
            }
        }
    }

    static let intervalOptions: [Double] = [1, 2, 4, 8, 12, 24]
    /// Manual refreshes are throttled too — Scholar CAPTCHAs fast clients.
    static let manualMinGap: TimeInterval = 5 * 60
    /// A fetch is a few pages; one running this long is hung.
    private static let fetchTimeout: TimeInterval = 10 * 60
    /// The network is usually still coming up right after wake.
    private static let wakeGrace: TimeInterval = 30
    private static let maxEvents = 500
    private static let maxHistory = 2000
    /// Failures that never reached Scholar, so retrying soon costs nothing.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
    ]
    /// Failures where the request never left the Mac, so nothing was charged.
    private static let unsentCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed]
    private static let approvalNote = "需要在“系统设置 › 通用 › 登录项”中允许 ScholarBar"

    private let notifier = Notifier()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var nextDue: Date = .distantPast
    /// No automatic fetch before this (wake grace).
    private var notBefore: Date = .distantPast
    private var jitter = Double.random(in: 0.8...1.2)
    /// Set after a failed attempt: retry this soon instead of a full interval.
    private var retryDelay: TimeInterval?
    private var failureStreak = 0
    /// The single fetch in flight; starting another while it runs is a no-op.
    private var fetchTask: Task<Void, Never>?
    private var fetchStartedAt: Date?
    /// Bumped to orphan a running fetch (profile changed, timed out).
    private var fetchGeneration = 0
    private var syncingLoginItem = false
    private var lastCanManualRefresh: Bool?
    private var lastSavedData: Data?
    /// state.json exists but couldn't be read or backed up: never overwrite it.
    private var saveDisabled = false
    private var persistErrorIsSave = false

    /// OpenAlex backup: its own single run (resolve + counts), generation and
    /// retry state, so it can never hold up or orphan the Scholar fetch.
    private var openAlexTask: Task<Void, Never>?
    private var openAlexStartedAt: Date?
    private var openAlexGeneration = 0
    /// After a failed run (other than a used-up budget): no new run before this.
    private var openAlexRetryAt: Date?
    private var openAlexFailureStreak = 0
    /// Spreads the post-quiet-hours start like the Scholar schedule does.
    private var openAlexJitter = Double.random(in: 0.8...1.2)
    /// Cached so SwiftUI re-renders don't hit the Keychain.
    private var openAlexKeyValue: String?

    /// While backing up, OpenAlex counts are compared this often (a count
    /// check costs 1 credit per 100 works).
    static let openAlexCheckHours: Double = 6
    /// Papers followed per profile (most cited first).
    nonisolated private static let openAlexMaxPapers = 200
    /// Title searches cost 10 credits each; cap them per day.
    private static let openAlexSearchesPerDay = 40
    /// A paper whose title search found nothing isn't searched again for this long.
    private static let openAlexUnmatchedRetry: TimeInterval = 30 * 86400
    private static let openAlexTimeout: TimeInterval = 10 * 60

    private static let stateURL: URL = {
        // SCHOLARBAR_STATE_DIR lets tests run against a throwaway state.
        let dir = ProcessInfo.processInfo.environment["SCHOLARBAR_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ScholarBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    init() {
        ScholarAPI.diagnosticsDir = Self.stateURL.deletingLastPathComponent()
        let d = UserDefaults.standard
        let rawInterval = d.object(forKey: "intervalHours")
        let storedInterval = (rawInterval as? NSNumber)?.doubleValue ?? (rawInterval as? String).flatMap(Double.init)
        // Snap stale / hand-edited values onto the Picker's options (and never below 1h).
        intervalHours = Self.validInterval(storedInterval)
        notifyEnabled = d.object(forKey: "notifyEnabled") == nil ? true : d.bool(forKey: "notifyEnabled")
        launchAtLogin = Self.loginItemRegistered
        openAlexEnabled = d.object(forKey: "openAlexEnabled") == nil ? true : d.bool(forKey: "openAlexEnabled")
        let loaded = Self.loadState()
        state = loaded.state
        openAlexKeyValue = OpenAlexKey.load()
        OpenAlexAPI.apiKey = openAlexKeyValue

        if rawInterval != nil, storedInterval != intervalHours { d.set(intervalHours, forKey: "intervalHours") }
        persistError = loaded.problem
        saveDisabled = !loaded.canSave
        if let until = state.blockedUntil, until > Date() { health = .blocked(until: until) }
        else if state.snapshot != nil { health = .ok }
        if SMAppService.mainApp.status == .requiresApproval { launchAtLoginError = Self.approvalNote }
    }

    // MARK: - Derived

    var snapshot: ProfileSnapshot? { state.snapshot }

    /// Gains logged since the popover was last closed. Tracked by position in
    /// the append-only log rather than by date, so clock changes can neither
    /// hide new events nor pin old ones as unseen.
    var unseenEvents: [CitationEvent] {
        let events = state.events
        let start: Int
        if let mark = state.lastSeenEventID {
            // Marker trimmed off the front ⇒ everything left came after it.
            start = events.lastIndex(where: { $0.id == mark }).map { $0 + 1 } ?? 0
        } else {
            // State saved before the marker existed.
            start = events.firstIndex(where: { $0.date > state.lastSeenAt }) ?? events.count
        }
        // newDelta: a Scholar gain OpenAlex already reported counts only once.
        return events[start...].filter { $0.newDelta > 0 }
    }
    var unseenDelta: Int { unseenEvents.reduce(0) { $0 + $1.newDelta } }
    /// Same rule as the badge, for per-row "new" dots.
    var unseenEventIDs: Set<UUID> { Set(unseenEvents.map(\.id)) }

    /// Change in total citations over the last `days`. If tracking began more
    /// recently, the change since then, with `days` = the span actually covered.
    /// nil with under a day of history (that says nothing about a week).
    func totalChange(days: Double) -> (delta: Int, days: Double)? {
        guard let now = state.snapshot?.totalCitations, let first = state.totalHistory.first else { return nil }
        let cutoff = Date().addingTimeInterval(-days * 86400)
        // History holds change points only: the total at `cutoff` is the last point at or before it.
        if let base = state.totalHistory.last(where: { $0.date <= cutoff }) {
            return (now - base.total, days)
        }
        let span = Date().timeIntervalSince(first.date) / 86400
        guard span >= 1 else { return nil }
        return (now - first.total, span)
    }

    /// Net change in total citations over the last `days`; nil until the
    /// recorded history (nearly) covers that whole window.
    func totalDelta(days: Double) -> Int? {
        guard let c = totalChange(days: days), c.days >= days * 0.95 else { return nil }
        return c.delta
    }

    /// OpenAlex is currently standing in for Scholar (inside a backup period
    /// with a valid baseline).
    var backupActive: Bool { openAlexEnabled && state.openAlex?.active == true }

    /// The optional personal OpenAlex key (Keychain); "" = the shared
    /// anonymous daily budget.
    var openAlexKey: String {
        get { openAlexKeyValue ?? "" }
        set {
            // Same cleanup as OpenAlexKey.save (spaces, quotes from a paste),
            // so the key in use is the key stored.
            let trimmed = newValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’").union(.whitespacesAndNewlines))
            let key = trimmed.isEmpty ? nil : trimmed
            guard key != openAlexKeyValue else { return }
            objectWillChange.send()
            openAlexKeyValue = key
            OpenAlexKey.save(key)
            OpenAlexAPI.apiKey = key
            // A different key has its own budget (and may fix an auth error):
            // waits imposed under the old one no longer apply.
            openAlexRetryAt = nil
            openAlexFailureStreak = 0
            if state.openAlex?.budgetRetryAt != nil {
                state.openAlex?.budgetRetryAt = nil
                save()
            }
        }
    }

    /// Papers the backup follows: cited ones, most cited first, at most 200.
    /// An uncited paper's first citation waits for Scholar.
    nonisolated static func openAlexPapers(_ papers: [Paper]) -> [Paper] {
        let cited = papers.filter { $0.citations > 0 }
            .sorted { ($0.citations, $1.id) > ($1.citations, $0.id) }
        return Array(cited.prefix(openAlexMaxPapers))
    }

    /// Followed papers (see `openAlexPapers`) on the current profile.
    var scholarPaperCount: Int { state.snapshot.map { Self.openAlexPapers($0.papers).count } ?? 0 }

    /// How many of those have an OpenAlex work.
    var openAlexMatchedCount: Int {
        guard let s = state.snapshot, let ids = state.openAlex?.workIDs, !ids.isEmpty else { return 0 }
        return Self.openAlexPapers(s.papers).filter { ids[$0.id] != nil }.count
    }

    /// Short status line for the banner / settings; nil while OpenAlex is
    /// off or has never been used.
    var openAlexStatus: String? {
        guard openAlexEnabled, let oa = state.openAlex else { return nil }
        let now = Date()
        let detail: String
        if openAlexTask != nil {
            detail = oa.active ? "正在检查 OpenAlex…" : "正在匹配 OpenAlex 论文…"
        } else if let retry = oa.budgetRetryAt, retry > now {
            detail = "OpenAlex 今日额度已用完，\(Fmt.time.string(from: retry)) 再试"
        } else if let error = oa.lastError {
            // OpenAlexAPI's own messages already name OpenAlex.
            detail = error.hasPrefix("OpenAlex") ? error : "OpenAlex 出错：\(error)"
        } else if let checked = oa.lastCheckedAt {
            detail = oa.active ? "OpenAlex 补位中 · \(Fmt.ago(checked))检查" : "OpenAlex 上次补位 \(Fmt.ago(checked))"
        } else {
            detail = "OpenAlex 待命"
        }
        let total = scholarPaperCount
        return total > 0 ? "\(detail) · 已匹配 \(openAlexMatchedCount)/\(total) 篇" : detail
    }

    var canManualRefresh: Bool {
        guard state.profileID != nil, fetchTask == nil else { return false }
        if case .fetching = health { return false }
        if let until = state.blockedUntil, until > Date() { return false }
        guard let last = state.lastAttemptAt else { return true }
        let since = Date().timeIntervalSince(last)
        return since >= Self.manualMinGap || since < 0 // < 0: clock went back
    }

    // MARK: - Scheduling

    func start() {
        guard timer == nil else { return }
        normalizeClock()
        // Last run ended in a failed attempt (or quit mid-fetch): retry soon.
        if let last = state.lastAttemptAt, last > (state.snapshot?.fetchedAt ?? .distantPast) {
            failureStreak = 1
            retryDelay = 15 * 60
        }
        reschedule()
        // A coarse 60s tick survives sleep/wake: after wake the next tick
        // simply sees the deadline has passed.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common) // keep ticking while a menu is tracking
        timer = t
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clockDidChange() }
        })
        if notifyEnabled { notifier.prepare() }
        tick()
    }

    private func tick() {
        let now = Date()
        if let started = fetchStartedAt, fetchTask != nil, now.timeIntervalSince(started) > Self.fetchTimeout {
            abandonFetch()
            finish(.failure(URLError(.timedOut)))
        }
        // Nothing else re-renders the refresh button when the throttle runs out.
        let canManual = canManualRefresh
        if canManual != lastCanManualRefresh {
            lastCanManualRefresh = canManual
            objectWillChange.send()
        }
        if state.profileID != nil, fetchTask == nil, now >= nextDue, now >= notBefore {
            startFetch()
        }
        // After the Scholar decision, so a due Scholar fetch goes first.
        tickOpenAlex(now)
    }

    /// After Scholar has asked for verification, poll at most every 6 hours
    /// for a week: the same steady rate is what got flagged.
    static let slowIntervalHours: Double = 6
    private static let slowdownPeriod: TimeInterval = 7 * 86400

    /// True while the post-block slowdown is in force.
    var slowedByBlocks: Bool {
        guard let last = state.lastBlockedAt else { return false }
        return Date().timeIntervalSince(last) < Self.slowdownPeriod
            && Self.validInterval(intervalHours) < Self.slowIntervalHours
    }

    /// The interval polling actually uses (the setting, or the slowdown).
    var effectiveIntervalHours: Double {
        let chosen = Self.validInterval(intervalHours)
        return slowedByBlocks ? Self.slowIntervalHours : chosen
    }

    /// Next automatic fetch, derived from persisted state so it stays right
    /// across interval changes, relaunches and clock changes.
    private func reschedule() {
        let now = Date()
        let interval = effectiveIntervalHours * 3600
        var due = now
        if let last = state.lastAttemptAt {
            let gap = retryDelay.map { min($0, interval) } ?? interval * jitter
            due = min(last, now).addingTimeInterval(gap)
        }
        if let until = state.blockedUntil, until > due { due = until }
        // A first fetch (no data yet) shouldn't wait for morning.
        nextDue = state.snapshot == nil ? due : Self.outsideQuietHours(due, jitter: jitter)
    }

    /// No automatic polling from 1:00 to 7:00: a request every couple of
    /// hours through the night is the clearest sign of a script. A due time
    /// in that window moves to 7:00 plus up to ~40 minutes.
    static func outsideQuietHours(_ due: Date, jitter: Double) -> Date {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: due)
        guard (1..<7).contains(hour),
              let seven = cal.date(bySettingHour: 7, minute: 0, second: 0, of: due) else { return due }
        let extraMinutes = max(0, min(1, (jitter - 0.8) / 0.4)) * 40
        return seven.addingTimeInterval(extraMinutes * 60)
    }

    private func didWake() {
        notBefore = Date().addingTimeInterval(Self.wakeGrace)
        clockDidChange()
    }

    private func clockDidChange() {
        normalizeClock()
        reschedule()
        objectWillChange.send() // "updated … ago", throttle
    }

    /// Timestamps from a clock that was ahead would stall polling and the
    /// manual throttle until real time caught up; clamp them.
    private func normalizeClock() {
        let now = Date()
        var changed = false
        if let t = state.lastAttemptAt, t > now { state.lastAttemptAt = now; changed = true }
        if let t = state.lastBlockedAt, t > now { state.lastBlockedAt = now; changed = true }
        let maxUntil = now.addingTimeInterval(24 * 3600)
        if let t = state.blockedUntil, t > maxUntil {
            state.blockedUntil = maxUntil
            changed = true
            if case .blocked = health { health = .blocked(until: maxUntil) }
        }
        if changed { save() }
    }

    private static func validInterval(_ hours: Double?) -> Double {
        guard let hours, hours.isFinite else { return 2 }
        return intervalOptions.min(by: { abs($0 - hours) < abs($1 - hours) }) ?? 2
    }

    func refreshNow() {
        guard canManualRefresh else { return }
        startFetch()
    }

    func setProfile(_ input: String) -> String? {
        guard let id = ScholarAPI.extractProfileID(input) else {
            return "请粘贴 Scholar 个人主页链接（含 user=…）或 12 位 user ID"
        }
        guard id != state.profileID else { return nil }
        // A fetch still running for the old profile must not land in the new state.
        abandonFetch()
        abandonOpenAlex()
        var fresh = PersistedState(profileID: id)
        // Scholar blocks the client, not the profile: keep the backoff.
        fresh.lastAttemptAt = state.lastAttemptAt
        fresh.blockedUntil = state.blockedUntil
        fresh.blockCount = state.blockCount
        fresh.lastBlockedAt = state.lastBlockedAt
        // OpenAlex mappings, baseline and period belong to the old person;
        // only its spending limits (per client/key) carry over.
        if let old = state.openAlex, old.budgetRetryAt != nil || old.searchesInWindow > 0 {
            var oa = OpenAlexState()
            oa.budgetRetryAt = old.budgetRetryAt
            oa.searchWindowStart = old.searchWindowStart
            oa.searchesInWindow = old.searchesInWindow
            fresh.openAlex = oa
        }
        state = fresh
        retryDelay = nil
        failureStreak = 0
        openAlexRetryAt = nil
        openAlexFailureStreak = 0
        if let until = state.blockedUntil, until > Date() {
            health = .blocked(until: until)
            save()
            reschedule()
        } else {
            health = .idle
            startFetch()
        }
        return nil
    }

    /// Newest logged event; capture it when the popover opens and pass it to
    /// `markSeen(through:)` on close.
    var newestEventID: UUID? { state.events.last?.id }

    /// Popover closed: events up to `eventID` (the newest one when it was
    /// shown; default: everything logged so far) count as seen, so citations
    /// that arrive while it's open stay unseen.
    func markSeen(through eventID: UUID? = nil) {
        let events = state.events
        let found: Int? = eventID.map { id in events.lastIndex(where: { $0.id == id }) } ?? events.indices.last
        guard let upTo = found else { return } // unknown id (trimmed): leave as is
        // Never move the marker backwards.
        if let mark = state.lastSeenEventID, let current = events.lastIndex(where: { $0.id == mark }), current > upTo { return }
        let newest = events[...upTo].lazy.map(\.date).max() ?? events[upTo].date
        guard events[upTo].id != state.lastSeenEventID || state.lastSeenAt < newest else { return }
        state.lastSeenEventID = events[upTo].id
        // Never behind the newest seen event, or one dated by a clock that was
        // ahead would stay "unseen" for date-based callers.
        state.lastSeenAt = max(state.lastSeenAt, newest)
        save()
    }

    // MARK: - Fetch & diff

    private func startFetch() {
        guard fetchTask == nil, let id = state.profileID else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        let now = Date()
        health = .fetching
        state.lastAttemptAt = now
        fetchStartedAt = now
        // Persisted before fetching: a crash or quit mid-fetch must still count
        // toward the schedule, or a relaunch loop would hammer Scholar.
        save()
        fetchTask = Task {
            let result: Result<ProfileSnapshot, Error>
            do { result = .success(try await ScholarAPI.fetchProfile(id: id)) }
            catch { result = .failure(error) }
            // Orphaned (profile changed / timed out): the newer state owns health.
            guard generation == self.fetchGeneration, id == self.state.profileID else { return }
            self.finish(result)
        }
    }

    private func abandonFetch() {
        fetchGeneration += 1
        fetchTask?.cancel()
        fetchTask = nil
        fetchStartedAt = nil
    }

    private func finish(_ result: Result<ProfileSnapshot, Error>) {
        fetchTask = nil
        fetchStartedAt = nil
        switch result {
        case .success(let new):
            apply(new)
            endBackup()
            state.blockedUntil = nil
            retryDelay = nil
            failureStreak = 0
            health = .ok
        case .failure(let error):
            if case .blocked? = error as? ScholarAPI.FetchError {
                block()
            } else if case .consent? = error as? ScholarAPI.FetchError {
                // Google's cookie-consent interstitial won't clear by itself:
                // no quick retry, just the normal interval.
                retryDelay = nil
                failureStreak = 0
                health = .error(error.localizedDescription)
            } else {
                // Retry soon, not in hours (offline after wake, timeout, list
                // shifted mid-fetch), backing off 15 → 30 → 60 min (capped at
                // the interval) so a persistent failure doesn't add requests.
                failureStreak += 1
                if let urlError = error as? URLError, Self.offlineCodes.contains(urlError.code) {
                    retryDelay = 2 * 60
                } else {
                    retryDelay = 15 * 60 * pow(2, Double(min(failureStreak, 4) - 1))
                }
                health = .error(error.localizedDescription)
            }
        }
        jitter = Double.random(in: 0.8...1.2)
        save()
        reschedule()
    }

    /// CAPTCHA / 429: back off 6h, 12h, 24h (cap). The streak counts blocks
    /// within 3 days of the previous one — one success doesn't reset it
    /// (Scholar tends to block again right away); quiet time does.
    private func block() {
        let now = Date()
        if let last = state.lastBlockedAt, now.timeIntervalSince(last) > 3 * 86400 { state.blockCount = 0 }
        state.blockCount = min(state.blockCount + 1, 3)
        let hours = 6 * pow(2, Double(state.blockCount - 1))
        let until = now.addingTimeInterval(hours * 3600)
        state.lastBlockedAt = now
        state.blockedUntil = until
        retryDelay = nil
        failureStreak = 0
        health = .blocked(until: until)
        if notifyEnabled { notifier.announceBlocked(until: until) }
    }

    private func apply(_ new: ProfileSnapshot) {
        // The whole log, in order: Scholar gains logged after an OpenAlex rise
        // show how much of it was already used up.
        let events = Self.diff(old: state.snapshot, new: new, openAlexEvents: state.events)
        state.snapshot = new
        state.events.append(contentsOf: events)
        if state.events.count > Self.maxEvents { state.events.removeFirst(state.events.count - Self.maxEvents) }
        if state.totalHistory.last?.total != new.totalCitations {
            // Keep history sorted even if the clock went back.
            let date = max(new.fetchedAt, state.totalHistory.last?.date ?? .distantPast)
            state.totalHistory.append(TotalPoint(date: date, total: new.totalCitations))
            if state.totalHistory.count > Self.maxHistory {
                state.totalHistory.removeFirst(state.totalHistory.count - Self.maxHistory)
            }
        }
        // Gains OpenAlex already announced during the outage aren't repeated.
        if notifyEnabled {
            notifier.announce(events.filter { $0.newDelta > 0 }, total: new.totalCitations, source: .scholar)
        }
    }

    /// Per-paper citation changes between two fetches. Yields nothing when the
    /// change looks like Scholar bookkeeping rather than new citations — the
    /// total fell (duplicates merged, re-indexing) or many papers vanished
    /// (truncated list, profile re-org) — and drops gains the profile total
    /// doesn't back: "new" papers (a split, rows back after a truncated fetch)
    /// count only if the total rose by at least as much, and gains on known
    /// papers must fit the total's rise plus what other papers lost.
    /// Gains OpenAlex reported since `old` (from `openAlexEvents`) are marked
    /// in `creditedByOpenAlex`; the checks above use the full Scholar deltas.
    nonisolated static func diff(old: ProfileSnapshot?, new: ProfileSnapshot,
                                 openAlexEvents: [CitationEvent] = []) -> [CitationEvent] {
        guard let old else { return [] } // first fetch is the baseline
        let totalGain = new.totalCitations - old.totalCitations
        guard totalGain >= 0 else {
            NSLog("ScholarBar: total fell \(old.totalCitations) → \(new.totalCitations); re-baselining without events")
            return []
        }
        let newIDs = Set(new.papers.map(\.id))
        // A list capped at ScholarAPI.maxPapers drops its least-cited tail, so
        // papers slip off / back on at the bottom without being deleted or new.
        let oldFloor = old.papers.count >= ScholarAPI.maxPapers ? old.papers.map(\.citations).min() : nil
        let newFloor = new.papers.count >= ScholarAPI.maxPapers ? new.papers.map(\.citations).min() : nil
        let vanished = old.papers.filter { p in
            !newIDs.contains(p.id) && !(newFloor.map { p.citations <= $0 } ?? false)
        }
        guard vanished.count <= max(2, old.papers.count / 10) else {
            NSLog("ScholarBar: \(vanished.count) of \(old.papers.count) papers vanished; re-baselining without events")
            return []
        }
        let oldByID = Dictionary(old.papers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var events = new.papers.compactMap { p -> CitationEvent? in
            let known = oldByID[p.id]?.citations
            // Unknown under a capped old list: it may have climbed out of the
            // hidden tail, whose counts were at most the floor.
            let before = known ?? oldFloor ?? 0
            let delta = p.citations - before
            guard delta != 0, known != nil || delta > 0 else { return nil }
            return CitationEvent(date: new.fetchedAt, paperID: p.id, title: p.title,
                                 delta: delta, newCount: p.citations, citesURL: p.citesURL,
                                 isNewPaper: known == nil && oldFloor == nil)
        }
        func gain(_ es: [CitationEvent]) -> Int { es.reduce(0) { $0 + max(0, $1.delta) } }

        var budget = totalGain
        let freshGain = gain(events.filter(\.isNewPaper))
        if freshGain > budget {
            NSLog("ScholarBar: new papers bring \(freshGain) but total rose \(totalGain); not counting them")
            events.removeAll(where: \.isNewPaper)
        } else {
            budget -= freshGain
        }
        let known = events.filter { !$0.isNewPaper }
        let knownLoss = known.reduce(0) { $0 + max(0, -$1.delta) }
        // Small slack for header/rows skew — none when papers vanished, since
        // their citations most likely moved into a survivor (merge).
        let slack = vanished.isEmpty ? 2 : 0
        if gain(known) > budget + knownLoss + slack {
            NSLog("ScholarBar: paper gains \(gain(known)) not backed by total (+\(totalGain)); re-baselining without events")
            return []
        }
        return credit(events.sorted { $0.delta > $1.delta }, openAlexEvents: openAlexEvents,
                      since: old.fetchedAt, until: new.fetchedAt)
    }

    /// Per paper, the part of a Scholar gain that OpenAlex events logged
    /// after the previous Scholar snapshot already announced (at most the
    /// gain itself). OpenAlex counts differ from Scholar's, so only their
    /// rises are compared, never the absolute numbers.
    /// Scholar often lists a citation a fetch or a few days after OpenAlex
    /// did, so what one success leaves over carries to later ones (rises since
    /// the previous snapshot, or within the last week). "Used up" goes by
    /// position in the append-only log (`openAlexEvents` is the whole log), so
    /// a rise is never credited twice, whatever the clocks said.
    nonisolated static func credit(_ events: [CitationEvent], openAlexEvents log: [CitationEvent],
                                   since: Date, until: Date = .distantFuture) -> [CitationEvent] {
        let from = min(since, until.addingTimeInterval(-7 * 86400))
        var reported: [String: Int] = [:]
        for e in log {
            if e.isFromOpenAlex {
                if e.delta > 0, e.date > from { reported[e.paperID, default: 0] += e.delta }
            } else if let used = e.creditedByOpenAlex, used > 0, let r = reported[e.paperID] {
                reported[e.paperID] = max(0, r - used)
            }
        }
        reported = reported.filter { $0.value > 0 }
        guard !reported.isEmpty else { return events }
        return events.map { e in
            guard e.delta > 0, !e.isFromOpenAlex, let r = reported[e.paperID] else { return e }
            var credited = e
            credited.creditedByOpenAlex = min(e.delta, r)
            return credited
        }
    }

    // MARK: - OpenAlex backup

    /// Scholar refuses automatic access, or has failed for over two polling
    /// intervals since its last success: time for OpenAlex to stand in.
    private func scholarNeedsBackup(_ now: Date) -> Bool {
        if case .blocked = health { return true }
        if let until = state.blockedUntil, until > now { return true }
        // An attempt after the last success that isn't running any more failed.
        guard let last = state.snapshot?.fetchedAt, let attempt = state.lastAttemptAt,
              attempt > last, fetchTask == nil else { return false }
        return now.timeIntervalSince(last) > 2 * effectiveIntervalHours * 3600
    }

    /// Starts an OpenAlex run when one is due: the baseline when a backup
    /// period begins, then a count check every 6 hours while it lasts. The
    /// period ends only when Scholar succeeds again (`endBackup`).
    private func tickOpenAlex(_ now: Date) {
        if let started = openAlexStartedAt, openAlexTask != nil, now.timeIntervalSince(started) > Self.openAlexTimeout {
            abandonOpenAlex()
            openAlexFailed(URLError(.timedOut))
        }
        // A check stamped by a clock that was ahead would stall the schedule.
        if let checked = state.openAlex?.lastCheckedAt, checked > now {
            state.openAlex?.lastCheckedAt = now
            save()
        }
        // A running Scholar fetch goes first: its success ends the period anyway.
        guard openAlexEnabled, openAlexTask == nil, fetchTask == nil, now >= notBefore,
              state.profileID != nil, state.snapshot != nil else { return }
        let active = state.openAlex?.active == true
        guard active || scholarNeedsBackup(now), now >= openAlexDue(active: active, now: now) else { return }
        startOpenAlex()
    }

    /// Next run: 6h after the last check (right away for a new period), not
    /// before a 429's retry time or a failed run's backoff, and not during
    /// the night's quiet hours.
    private func openAlexDue(active: Bool, now: Date) -> Date {
        var due = now
        if active, let checked = state.openAlex?.lastCheckedAt {
            due = checked.addingTimeInterval(Self.openAlexCheckHours * 3600)
        }
        // A retry time over a day out comes from a clock that was ahead.
        if let retry = state.openAlex?.budgetRetryAt, retry <= now.addingTimeInterval(86400) { due = max(due, retry) }
        if let retry = openAlexRetryAt { due = max(due, retry) }
        return Self.outsideQuietHours(due, jitter: openAlexJitter)
    }

    private func startOpenAlex() {
        guard openAlexTask == nil, let id = state.profileID, let snap = state.snapshot else { return }
        // The Keychain may still have been locked at launch (early login);
        // OpenAlexKey caches a definite answer, so this is cheap afterwards.
        if openAlexKeyValue == nil, let key = OpenAlexKey.load() {
            openAlexKeyValue = key
            OpenAlexAPI.apiKey = key
        }
        openAlexGeneration += 1
        let generation = openAlexGeneration
        let now = Date()
        var oa = state.openAlex ?? OpenAlexState()
        let papers = Self.openAlexPapers(snap.papers)
        // Unmapped papers; a failed title search is retried only after 30 days.
        let unmapped = papers.filter { p in
            guard oa.workIDs[p.id] == nil else { return false }
            guard let failed = oa.unmatchedAt[p.id], failed <= now else { return true }
            return now.timeIntervalSince(failed) >= Self.openAlexUnmatchedRetry
        }
        // A new 24h search window once the last one is over.
        let inWindow = oa.searchWindowStart.map { $0 <= now && now.timeIntervalSince($0) < 86400 } ?? false
        if !inWindow {
            oa.searchWindowStart = nil
            oa.searchesInWindow = 0
        }
        let searches = min(max(0, Self.openAlexSearchesPerDay - oa.searchesInWindow), unmapped.count)
        // Out of searches, a period's first run still lists known authors'
        // works (1 credit per page) to match new papers.
        let resolveNeeded = !unmapped.isEmpty && (searches > 0 || (!oa.active && !oa.authorIDs.isEmpty))
        // Charged up front (a run that fails midway may already have spent
        // them), refunded for papers it never got to.
        if resolveNeeded, searches > 0 {
            oa.searchWindowStart = oa.searchWindowStart ?? now
            oa.searchesInWindow += searches
        }
        let knownAuthors = oa.authorIDs
        state.openAlex = oa
        save()
        openAlexStartedAt = now
        objectWillChange.send() // status: "正在…"
        openAlexTask = Task {
            var resolved = !resolveNeeded
            do {
                if resolveNeeded {
                    let r = try await OpenAlexAPI.resolve(unmapped, knownAuthorIDs: knownAuthors, maxSearches: searches)
                    // Merged right away: searches are the expensive part, keep
                    // them even if the count check below fails.
                    guard self.openAlexCurrent(generation, profile: id) else { return }
                    self.mergeResolved(r, asked: unmapped, charged: searches, at: now)
                    resolved = true
                }
                let works = AppModel.trackedWorks(papers, workIDs: self.state.openAlex?.workIDs ?? [:])
                let counts = works.isEmpty ? [:] : try await OpenAlexAPI.citedByCounts(works.map(\.work))
                guard self.openAlexCurrent(generation, profile: id) else { return }
                self.finishOpenAlex(counts: counts, works: works)
            } catch {
                guard self.openAlexCurrent(generation, profile: id) else { return }
                // resolve throws only when it settled nothing: at most the request
                // that failed was a search, and not even that one if it never left
                // the Mac. Give back the rest of the up-front charge.
                if !resolved, searches > 0, let used = self.state.openAlex?.searchesInWindow {
                    let neverSent = (error as? URLError).map { AppModel.unsentCodes.contains($0.code) } ?? false
                    self.state.openAlex?.searchesInWindow = max(0, used - (neverSent ? searches : searches - 1))
                }
                self.openAlexFailed(error)
            }
        }
    }

    /// False once a run was orphaned (Scholar came back, profile changed,
    /// OpenAlex switched off, timed out): it must not touch the state.
    private func openAlexCurrent(_ generation: Int, profile: String) -> Bool {
        generation == openAlexGeneration && profile == state.profileID && openAlexEnabled
    }

    private func abandonOpenAlex() {
        openAlexGeneration += 1
        openAlexTask?.cancel()
        openAlexTask = nil
        openAlexStartedAt = nil
    }

    private func mergeResolved(_ r: (matches: [String: OpenAlexAPI.Work], authorIDs: [String], unmatched: Set<String>),
                               asked: [Paper], charged: Int, at now: Date) {
        var oa = state.openAlex ?? OpenAlexState()
        for (paperID, work) in r.matches {
            oa.workIDs[paperID] = work.id
            oa.unmatchedAt[paperID] = nil
        }
        for paperID in r.unmatched where r.matches[paperID] == nil { oa.unmatchedAt[paperID] = now }
        // Newest first; capped so listing them stays a few credits.
        var seen = Set<String>()
        oa.authorIDs = Array((r.authorIDs + oa.authorIDs).filter { seen.insert($0).inserted }.prefix(10))
        // Papers left neither matched nor unmatched were never searched.
        let touched = asked.filter { r.matches[$0.id] != nil || r.unmatched.contains($0.id) }.count
        oa.searchesInWindow = max(0, oa.searchesInWindow - max(0, charged - touched))
        state.openAlex = oa
        save()
    }

    /// A run's counts: the baseline when a period begins, otherwise rises
    /// since the last check become OpenAlex events.
    private func finishOpenAlex(counts: [String: Int], works: [(work: String, paper: Paper)]) {
        openAlexTask = nil
        openAlexStartedAt = nil
        openAlexRetryAt = nil
        openAlexFailureStreak = 0
        let now = Date()
        var oa = state.openAlex ?? OpenAlexState()
        // A new period always re-baselines: counts from an earlier one are stale.
        let changes = Self.openAlexChanges(previous: oa.active ? oa.counts : nil, counts: counts, works: works, at: now)
        oa.counts = changes.baseline
        oa.active = true
        oa.lastCheckedAt = now
        oa.lastError = nil
        oa.budgetRetryAt = nil
        if let current = state.snapshot.map({ Set($0.papers.map(\.id)) }) {
            // Papers gone from the profile.
            oa.workIDs = oa.workIDs.filter { current.contains($0.key) }
            oa.unmatchedAt = oa.unmatchedAt.filter { current.contains($0.key) }
        }
        state.openAlex = oa
        let events = changes.events
        if !events.isEmpty {
            state.events.append(contentsOf: events)
            if state.events.count > Self.maxEvents { state.events.removeFirst(state.events.count - Self.maxEvents) }
            if notifyEnabled {
                notifier.announce(events, total: state.snapshot?.totalCitations ?? 0, source: .openAlex)
            }
        }
        openAlexJitter = Double.random(in: 0.8...1.2)
        save()
    }

    private func openAlexFailed(_ error: Error) {
        openAlexTask = nil
        openAlexStartedAt = nil
        let now = Date()
        var oa = state.openAlex ?? OpenAlexState()
        if case .budgetExhausted(let retryAfter)? = error as? OpenAlexAPI.OAError {
            // The daily budget refills on its own; asking sooner only earns more 429s.
            let wait = min(max(retryAfter ?? 6 * 3600, 5 * 60), 24 * 3600)
            oa.budgetRetryAt = now.addingTimeInterval(wait)
            oa.lastError = nil // the status shows the budget instead
            openAlexRetryAt = nil
            openAlexFailureStreak = 0
        } else {
            // 30 min, 1h, 2h … up to the check interval; soon when it never got online.
            openAlexFailureStreak += 1
            let offline = (error as? URLError).map { Self.offlineCodes.contains($0.code) } ?? false
            let backoff = min(Self.openAlexCheckHours * 3600, 30 * 60 * pow(2, Double(min(openAlexFailureStreak, 5) - 1)))
            openAlexRetryAt = now.addingTimeInterval(offline ? 5 * 60 : backoff)
            oa.lastError = error.localizedDescription
        }
        state.openAlex = oa
        save()
    }

    /// Scholar answered again and is the source of truth from here on. A run
    /// still in flight is dropped (its events would postdate this snapshot
    /// and be credited against the next one); the next outage starts a new
    /// period with a fresh baseline.
    private func endBackup() {
        abandonOpenAlex()
        openAlexRetryAt = nil
        openAlexFailureStreak = 0
        guard state.openAlex != nil else { return }
        state.openAlex?.active = false
        state.openAlex?.lastError = nil
    }

    /// One entry per OpenAlex work, for its most cited Scholar paper: two
    /// Scholar rows matched to one work would otherwise report each rise twice.
    nonisolated static func trackedWorks(_ papers: [Paper], workIDs: [String: String]) -> [(work: String, paper: Paper)] {
        var seen = Set<String>()
        return papers.compactMap { p in
            guard let w = workIDs[p.id], seen.insert(w).inserted else { return nil }
            return (w, p)
        }
    }

    /// Fresh OpenAlex counts against the previous check. `previous` nil (a
    /// new period): everything becomes the baseline, no events. A work with
    /// no baseline yet (newly matched) and drops are baselined silently, and
    /// so is a jump too big to be new citations (OpenAlex merging records).
    /// Works missing from the reply keep their old baseline.
    nonisolated static func openAlexChanges(previous: [String: Int]?, counts: [String: Int],
                                            works: [(work: String, paper: Paper)], at date: Date)
        -> (events: [CitationEvent], baseline: [String: Int]) {
        var baseline: [String: Int] = [:]
        var events: [CitationEvent] = []
        for (work, paper) in works {
            guard let count = counts[work] else {
                if let old = previous?[work] { baseline[work] = old }
                continue
            }
            baseline[work] = count
            guard let old = previous?[work], count > old else { continue }
            let rise = count - old
            guard rise <= max(10, old / 4) else {
                NSLog("ScholarBar: OpenAlex \(work) jumped \(old) → \(count); re-baselining without an event")
                continue
            }
            events.append(CitationEvent(date: date, paperID: paper.id, title: paper.title, delta: rise,
                                        newCount: count, citesURL: nil, source: .openAlex, openAlexWorkID: work))
        }
        return (events.sorted { $0.delta > $1.delta }, baseline)
    }

    // MARK: - Launch at login

    private static var loginItemRegistered: Bool {
        let s = SMAppService.mainApp.status
        return s == .enabled || s == .requiresApproval
    }

    private func applyLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            launchAtLoginError = nil
        } catch {
            NSLog("ScholarBar launch-at-login: \(error)")
            launchAtLoginError = (on ? "无法设为登录时启动：" : "无法取消登录时启动：") + error.localizedDescription
        }
        if on && service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        syncLaunchAtLogin()
    }

    /// Re-reads the login item (it can change in System Settings) so the
    /// toggle shows what is actually in effect.
    func syncLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        if status == .requiresApproval { launchAtLoginError = Self.approvalNote }
        else if launchAtLoginError == Self.approvalNote { launchAtLoginError = nil }
        let on = status == .enabled || status == .requiresApproval
        guard on != launchAtLogin else { return }
        syncingLoginItem = true
        launchAtLogin = on
        syncingLoginItem = false
    }

    // MARK: - Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys] // stable bytes, so unchanged state isn't rewritten
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func loadState() -> (state: PersistedState, problem: String?, canSave: Bool) {
        let url = stateURL
        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) {
                return (PersistedState(), "无法读取 state.json，本次运行不会覆盖它", false)
            }
            return (PersistedState(), nil, true) // first run
        }
        do {
            return (try decoder.decode(PersistedState.self, from: data), nil, true)
        } catch {
            // Don't let the next save silently replace the history: keep a copy.
            NSLog("ScholarBar: state.json unreadable: \(error)")
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("state.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try data.write(to: backup, options: .atomic)
                return (PersistedState(), "state.json 无法解析，已另存为 \(backup.lastPathComponent)", true)
            } catch {
                return (PersistedState(), "state.json 无法解析，本次运行不会覆盖它", false)
            }
        }
    }

    private func save() {
        guard !saveDisabled else { return }
        do {
            let data = try Self.encoder.encode(state)
            guard data != lastSavedData else { return }
            do {
                try data.write(to: Self.stateURL, options: .atomic)
            } catch {
                // The folder may have been removed while running.
                try FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: Self.stateURL, options: .atomic)
            }
            lastSavedData = data
            if persistErrorIsSave {
                persistError = nil
                persistErrorIsSave = false
            }
        } catch {
            NSLog("ScholarBar: saving state failed: \(error)")
            persistError = "保存数据失败：\(error.localizedDescription)"
            persistErrorIsSave = true
        }
    }
}
