import AppKit
import Charts
import SwiftUI

/// Popover state the status item also drives: the right-click menu's 设置…,
/// a clock for relative times, and the hovered row.
@MainActor
final class PopoverUI: ObservableObject {
    @Published var showSettings = false
    /// One hovered row at a time. Cleared on close: the row under the cursor
    /// never gets its hover-exit when the popover closes, and would still be
    /// highlighted next time.
    @Published var hoveredRow: String?
    /// SwiftUI only re-renders on model changes, so without this clock the
    /// footer would say "更新于 刚刚" for hours and the refresh button would
    /// stay disabled long after its 5-minute gap. Ticks only while open.
    @Published private(set) var now = Date()
    private var clock: Timer?
    private var closedAt: Date?

    func willShow() {
        now = Date()
        hoveredRow = nil
        // Settings left open and dismissed by clicking away shouldn't greet
        // the user next time; a quick trip to the browser to copy the link
        // still finds them open.
        if let closedAt, now.timeIntervalSince(closedAt) > 120 { showSettings = false }
        clock?.invalidate()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    func didClose() {
        clock?.invalidate()
        clock = nil
        closedAt = Date()
        hoveredRow = nil
    }
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: PopoverUI
    @State private var tab = Tab.recent

    enum Tab: String, CaseIterable { case recent = "最新引用", papers = "全部论文" }

    private static let maxRecent = 100

    var body: some View {
        let now = ui.now
        VStack(alignment: .leading, spacing: 0) {
            if ui.showSettings || model.state.profileID == nil {
                SettingsView(model: model, onDone: { ui.showSettings = false })
            } else if let snap = model.snapshot {
                header(snap)
                Divider()
                if model.backupActive { backupBanner }
                stats(snap)
                if snap.yearly.count > 1 && snap.yearly.contains(where: { $0.count > 0 }) {
                    yearlyChart(snap).padding(.horizontal, 14).padding(.bottom, 8)
                }
                Divider()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .onChange(of: tab) { ui.hoveredRow = nil }
                list(snap, now: now)
            } else {
                loadingView
            }
            Divider()
            footer(now: now)
        }
        .frame(width: 400)
    }

    // MARK: - Sections

    private func header(_ s: ProfileSnapshot) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name.isEmpty ? "Google Scholar" : s.name).font(.headline).lineLimit(2)
                if !s.affiliation.isEmpty {
                    Text(s.affiliation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(s.affiliation)
                }
            }
            Spacer()
            Button { ui.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .keyboardShortcut(",")
                .help("设置（⌘,）")
        }
        .padding(14)
    }

    /// While Scholar refuses automatic access, new-citation rows may come
    /// from OpenAlex instead. Say so up front: the total above the list is
    /// still Scholar's last number, and OpenAlex counts differ from Scholar's.
    private var backupBanner: some View {
        let status = model.openAlexStatus
        var tip = "Google Scholar 暂时限制了自动访问。在此期间 ScholarBar 用 OpenAlex（免费开放的学术数据库）检查哪些论文有新引用。"
            + "OpenAlex 的计数与 Scholar 不完全一致，总引用仍以 Scholar 为准；Scholar 恢复后已提示过的引用不会重复计入。"
        if model.scholarPaperCount > 0 {
            tip += "\n已在 OpenAlex 找到 \(model.openAlexMatchedCount)/\(model.scholarPaperCount) 篇论文。"
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lifepreserver").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scholar 暂时受限 · 正在用 OpenAlex 补位").font(.caption)
                if let status {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .help(tip)
    }

    private func stats(_ s: ProfileSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("总引用").font(.caption).foregroundStyle(.secondary)
                Text(Fmt.n(s.totalCitations))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    // 7-digit totals shrink instead of wrapping ("1,234," / "567").
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 8) {
                    // Young history: label the span actually covered ("5天 +8").
                    if let c = model.totalChange(days: 7) {
                        deltaBadge(c.days >= 6.65 ? "7天" : "\(Int(c.days))天", c.delta)
                    }
                    deltaBadge("30天", model.totalDelta(days: 30))
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            metric("h-index", s.hIndex, s.hIndexSince, s.sinceLabel)
            metric("i10", s.i10Index, s.i10IndexSince, s.sinceLabel)
            if !s.sinceLabel.isEmpty {
                metric("\(s.sinceLabel)起", s.citationsSince, nil, "")
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func deltaBadge(_ label: String, _ v: Int?) -> some View {
        if let v {
            Text("\(label) \(v >= 0 ? "+" : "")\(Fmt.n(v))")
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(v > 0 ? Color.green : Color.secondary)
        }
    }

    private func metric(_ title: String, _ v: Int, _ since: Int?, _ sinceLabel: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Text(Fmt.n(v)).font(.title3.monospacedDigit().weight(.medium)).lineLimit(1).fixedSize()
            if let since, !sinceLabel.isEmpty {
                // Same wording as the "2021起" column, not a vague "近期".
                Text("\(sinceLabel)起 \(Fmt.n(since))").font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    private func yearlyChart(_ s: ProfileSnapshot) -> some View {
        let data = Array(s.yearly.suffix(12))
        // Scholar's newest bar (the running year) rather than the calendar
        // year, which Scholar may not have added yet in early January.
        let latest = data.last?.year
        let peak = data.map(\.count).max() ?? 0
        return Chart(data, id: \.year) { y in
            BarMark(x: .value("年", String(y.year)), y: .value("引用", y.count))
                .foregroundStyle(y.year == latest ? Color.accentColor : Color.accentColor.opacity(0.45))
                .annotation(position: .top, spacing: 1) {
                    if y.count > 0 && (y.year == latest || y.count == peak) {
                        Text(Fmt.n(y.count)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
        }
        // Headroom so the label over the tallest bar stays inside the chart.
        .chartYScale(domain: 0...max(1, peak + peak / 5 + 1))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { v in
                AxisValueLabel {
                    if let s = v.as(String.self) { Text("'" + s.suffix(2)).font(.system(size: 9)) }
                }
            }
        }
        .frame(height: 70)
    }

    /// Newest refresh first; within one refresh, biggest jump first.
    private var recentEvents: [CitationEvent] {
        model.state.events.filter { $0.delta > 0 }
            .sorted { ($0.date, $0.delta) > ($1.date, $1.delta) }
    }

    private func list(_ s: ProfileSnapshot, now: Date) -> some View {
        let events = recentEvents
        let rows = max(s.papers.count, min(events.count, Self.maxRecent))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch tab {
                case .recent: recentList(events, now: now)
                case .papers: paperList(s, now: now)
                }
            }
        }
        // Each tab starts at the top instead of inheriting the other tab's
        // scroll offset.
        .id(tab)
        .frame(height: listHeight(rows: rows))
    }

    /// One height for both tabs (switching never resizes the popover), sized
    /// to the bigger list so a small profile doesn't get a mostly empty box,
    /// and capped so the popover still fits on short (scaled) screens.
    private func listHeight(rows: Int) -> CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        let cap = min(320, max(160, screen - 400))
        return min(cap, max(120, CGFloat(rows) * 56))
    }

    @ViewBuilder
    private func recentList(_ events: [CitationEvent], now: Date) -> some View {
        if events.isEmpty {
            emptyText(model.state.events.isEmpty
                      ? "还没有记录到新引用。\n首次抓取作为基准，之后每篇论文的引用增加都会出现在这里。"
                      : "暂无新增")
        } else {
            // Same rule as the menu bar's "+N" (whatever the model uses to
            // decide what's unseen), so the dots and the badge agree.
            let unseen = Set(model.unseenEvents.map(\.id))
            ForEach(Array(events.prefix(Self.maxRecent))) { e in
                EventRow(event: e, unseen: unseen.contains(e.id), now: now,
                         hoveredRow: $ui.hoveredRow)
                Divider().padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private func paperList(_ s: ProfileSnapshot, now: Date) -> some View {
        if s.papers.isEmpty {
            emptyText("这个 Scholar 主页还没有公开的论文")
        } else {
            let cutoff = now.addingTimeInterval(-30 * 86400)
            // newDelta, like the badge: a gain OpenAlex reported during a
            // Scholar outage and Scholar later confirmed counts once.
            let recent = Dictionary(grouping: model.state.events.filter { $0.date > cutoff }, by: \.paperID)
                // Scholar's own deltas, plus OpenAlex rises Scholar hasn't seen yet
                // (logged after this snapshot); once Scholar has fetched again its
                // delta covers them, and OpenAlex's rise may be bigger.
                .mapValues { $0.reduce(0) { sum, e in
                    sum + (e.isFromOpenAlex ? (e.date > s.fetchedAt ? e.delta : 0) : e.delta)
                } }
            ForEach(s.papers) { p in
                PaperRow(paper: p, recentDelta: recent[p.id] ?? 0, hoveredRow: $ui.hoveredRow)
                Divider().padding(.leading, 14)
            }
        }
    }

    private func emptyText(_ s: String) -> some View {
        Text(s)
            .font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(24)
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            switch model.health {
            case .error(let m):
                Image(systemName: "exclamationmark.triangle").font(.title)
                Text(m).font(.callout).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("修改主页链接") { ui.showSettings = true }
            case .blocked:
                Image(systemName: "hand.raised").font(.title)
                Text(statusText(now: ui.now)).font(.callout).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Scholar 暂时限制了来自这台电脑网络的自动访问，通常几小时到一天会自己解除。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle where model.state.lastAttemptAt != nil:
                // E.g. relaunched after a failed first fetch: nothing is
                // loading until the next scheduled attempt, so no spinner.
                Image(systemName: "clock").font(.title)
                Text("还没有读取到数据").font(.callout).foregroundStyle(.secondary)
                Button("立即读取") { model.refreshNow() }
                    .disabled(!model.canManualRefresh)
                    .help(refreshHelp)
            default:
                ProgressView()
                Text("正在读取 Scholar 主页…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }

    private func footer(now: Date) -> some View {
        let status = statusText(now: now)
        return HStack(spacing: 10) {
            statusDot
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(status)
            Spacer(minLength: 0)
            if let id = model.state.profileID {
                Button { NSWorkspace.shared.open(ScholarAPI.profileURL(id)) } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless).help("打开 Scholar 主页")
            }
            Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .keyboardShortcut("r")
                .disabled(!model.canManualRefresh)
                .help(refreshHelp)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
                .help("退出（⌘Q）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusDot: some View {
        let color: Color = {
            switch model.health {
            case .ok: return .green
            case .fetching, .idle: return .gray
            case .blocked: return .orange
            case .error: return .red
            }
        }()
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private func statusText(now: Date) -> String {
        switch model.health {
        case .fetching: return "正在刷新…"
        case .blocked(let until): return "Scholar 要求验证，\(Fmt.time.string(from: until)) 后重试"
        case .error(let m): return model.snapshot == nil ? m : "刷新失败：\(m)"
        case .ok, .idle:
            if let t = model.snapshot?.fetchedAt {
                return "更新于 \(relativeTime(t, now: now)) · 每 \(Int(model.effectiveIntervalHours)) 小时"
                    + (model.slowedByBlocks ? "（已放慢）" : "")
            }
            return ""
        }
    }

    /// Why the refresh button is disabled, not always "5 minutes".
    private var refreshHelp: String {
        if model.canManualRefresh { return "立即刷新（⌘R）" }
        switch model.health {
        case .fetching: return "正在刷新…"
        case .blocked: return "Scholar 要求验证，到时间后会自动重试"
        default:
            return model.state.profileID == nil
                ? "先设置 Scholar 主页"
                : "为避免触发 Scholar 验证，两次刷新至少间隔 5 分钟"
        }
    }
}

/// `Fmt.ago` against an explicit clock (`PopoverUI.now`), so relative times
/// age while the popover stays open. A date slightly ahead of the clock
/// (fetched since the last tick) is "刚刚", never "N 秒后".
private func relativeTime(_ d: Date, now: Date) -> String {
    now.timeIntervalSince(d) < 60 ? "刚刚" : Fmt.relative.localizedString(for: d, relativeTo: now)
}

// MARK: - Rows

/// A list row that opens `url`: a real Button (VoiceOver / full keyboard
/// access can activate it, unlike onTapGesture), hover highlight and pressed
/// feedback. Without a URL it's plain content with no hover, so it doesn't
/// look clickable.
private struct RowButton<Content: View>: View {
    let id: String
    let url: URL?
    let tooltip: String
    @Binding var hoveredRow: String?
    let content: Content

    init(id: String, url: URL?, tooltip: String, hoveredRow: Binding<String?>,
         @ViewBuilder content: () -> Content) {
        self.id = id
        self.url = url
        self.tooltip = tooltip
        _hoveredRow = hoveredRow
        self.content = content()
    }

    var body: some View {
        if let url {
            Button { NSWorkspace.shared.open(url) } label: { padded }
                .buttonStyle(RowButtonStyle(hovered: hoveredRow == id))
                .onHover { inside in
                    if inside { hoveredRow = id } else if hoveredRow == id { hoveredRow = nil }
                }
                .help(tooltip)
        } else {
            padded
        }
    }

    private var padded: some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct RowButtonStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0))
    }
}

private struct EventRow: View {
    let event: CitationEvent
    let unseen: Bool
    let now: Date
    @Binding var hoveredRow: String?

    /// OpenAlex events open OpenAlex's citing-works list: Scholar is the
    /// site that's refusing us right now, and its list may not have the
    /// new citation yet anyway.
    private var url: URL? {
        if event.isFromOpenAlex { return event.openAlexWorkID.map(OpenAlexAPI.citingWorksURL) }
        return event.newestCitersURL
    }

    private var tooltip: String {
        event.isFromOpenAlex
            ? "在 OpenAlex 查看引用这篇的论文（OpenAlex 的计数可能与 Scholar 略有不同）"
            : "查看最新引用这篇的论文"
    }

    /// Part of this Scholar gain was already announced by OpenAlex while
    /// Scholar was blocked. "+N" stays Scholar's own delta; this explains
    /// why it didn't count toward the badge or notify again.
    private var creditNote: String? {
        guard !event.isFromOpenAlex, let c = event.creditedByOpenAlex, c > 0 else { return nil }
        return c >= event.delta ? "已由 OpenAlex 提前提示" : "其中 \(Fmt.n(c)) 次已由 OpenAlex 提示"
    }

    var body: some View {
        RowButton(id: "e:" + event.id.uuidString, url: url,
                  tooltip: tooltip, hoveredRow: $hoveredRow) {
            HStack(alignment: .top, spacing: 10) {
                Text("+\(Fmt.n(event.delta))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 48, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.callout).lineLimit(2)
                    HStack(spacing: 6) {
                        if event.isFromOpenAlex { OpenAlexTag() }
                        if event.isNewPaper { Text("新收录").foregroundStyle(.orange) }
                        // For an OpenAlex event this is OpenAlex's count
                        // (the tag beside it says so), not Scholar's.
                        Text("现 \(Fmt.n(event.newCount)) 次")
                        Text(relativeTime(event.date, now: now))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    if let creditNote {
                        Text(creditNote).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if unseen {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(.top, 5)
                        .accessibilityLabel("未读")
                }
            }
        }
    }
}

/// Small secondary badge marking a row whose numbers come from OpenAlex.
private struct OpenAlexTag: View {
    var body: some View {
        Text("OpenAlex")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
    }
}

private struct PaperRow: View {
    let paper: Paper
    let recentDelta: Int
    @Binding var hoveredRow: String?

    var body: some View {
        RowButton(id: "p:" + paper.id, url: paper.newestCitersURL,
                  tooltip: "查看引用这篇的论文（按时间排序）", hoveredRow: $hoveredRow) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.n(paper.citations))
                        .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if recentDelta > 0 {
                        Text("+\(Fmt.n(recentDelta))").font(.caption2.monospacedDigit()).foregroundStyle(.green)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                .frame(width: 48, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.title).font(.callout).lineLimit(2)
                    Text([paper.venue, paper.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    let onDone: () -> Void
    @State private var input = ""
    @State private var error: String?
    @State private var retried = false
    @FocusState private var fieldFocused: Bool
    /// The OpenAlex key being edited. Committed to the model (which writes
    /// the Keychain) on Return or 保存, not per keystroke.
    @State private var keyDraft = ""
    /// What the Keychain holds as far as this view knows; nil until loaded.
    /// Lets a commit skip the Keychain write when nothing changed, and keeps
    /// a reopened popover from clobbering an unsaved draft.
    @State private var savedKey: String?

    private static let openAlexKeyPage = URL(string: "https://openalex.org/settings/api")!

    private var openAlexSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Scholar 受限时用 OpenAlex 补位", isOn: $model.openAlexEnabled)
            HStack(spacing: 6) {
                SecureField("OpenAlex API key（可选）", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitKey)
                // The user signs up on openalex.org themselves; the app never
                // creates accounts or keys.
                Button("获取免费 key") { NSWorkspace.shared.open(Self.openAlexKeyPage) }
                    .fixedSize()
                    .help("在浏览器中打开 openalex.org 的 API key 页面")
            }
            .disabled(!model.openAlexEnabled)
            Text("不填也能用（与同一网络共享每日免费额度）；在 openalex.org 免费申请后粘贴到这里可获得独立额度")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let s = model.openAlexStatus {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(s)
            }
        }
    }

    private func commitKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard savedKey != nil, key != savedKey else { return }
        model.openAlexKey = key
        savedKey = key
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google Scholar 引用监控").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Scholar 个人主页链接").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("https://scholar.google.com/citations?user=…", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit(save)
                    Button("粘贴") {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            input = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("刷新频率", selection: $model.intervalHours) {
                ForEach(AppModel.intervalOptions, id: \.self) { Text("每 \(Int($0)) 小时").tag($0) }
            }
            if model.slowedByBlocks {
                Text("最近 Scholar 要求过验证，这一周内自动放慢为每 \(Int(AppModel.slowIntervalHours)) 小时一次；凌晨 1–7 点也不自动刷新。")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("有新引用时发通知", isOn: $model.notifyEnabled)
            Toggle("登录时自动启动", isOn: $model.launchAtLogin)
            if let e = model.launchAtLoginError {
                Text(e).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.persistError {
                Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            openAlexSection
            Text("Scholar 没有官方 API，本工具读取公开主页。抓得太勤会被要求验证（CAPTCHA），所以最快每小时一次；Scholar 自身的引用数据通常也是每隔几天才更新一批。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if model.state.profileID != nil { Button("取消", action: onDone) }
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            model.syncLaunchAtLogin()
            // Don't clobber a draft if the popover is reopened over it.
            if input.isEmpty, let id = model.state.profileID {
                input = ScholarAPI.profileURL(id).absoluteString
            }
            // One Keychain read per visit of the settings page, not per render.
            if savedKey == nil {
                let key = model.openAlexKey
                savedKey = key
                keyDraft = key
            }
            // First run: ready for ⌘V without clicking into the field.
            if model.state.profileID == nil {
                DispatchQueue.main.async { fieldFocused = true }
            }
        }
        // A stale "请粘贴…" shouldn't sit under a link the user is fixing.
        .onChange(of: input) { error = nil }
    }

    private func save() {
        // Independent of the profile link, so kept even if the link is rejected.
        commitKey()
        let id = ScholarAPI.extractProfileID(input)
        let sameProfile = id != nil && id == model.state.profileID
        error = model.setProfile(input)
        guard error == nil else { return }
        // setProfile ignores an unchanged ID, so saving the same link again
        // after a failure would just drop back to the error screen. Retry
        // instead (refreshNow keeps the 5-minute gap; once per visit, in case
        // Return fires both onSubmit and the default button).
        if sameProfile, !retried, case .error = model.health {
            retried = true
            model.refreshNow()
        }
        onDone()
    }
}
