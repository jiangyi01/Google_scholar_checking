import Foundation

struct Paper: Codable, Identifiable, Hashable {
    /// Scholar's per-profile article id (the `citation_for_view` value).
    let id: String
    var title: String
    var authors: String
    var venue: String
    var year: Int?
    var citations: Int
    /// "Cited by" search URL (scholar?cites=...), nil when the paper has no citations yet.
    var citesURL: String?

    /// Cited-by list sorted newest first, so a click shows who just cited it.
    var newestCitersURL: URL? { ScholarLink.newestFirst(citesURL) }
}

struct YearCount: Codable, Hashable {
    let year: Int
    let count: Int
}

struct ProfileSnapshot: Codable {
    var fetchedAt: Date
    var name: String
    var affiliation: String
    var totalCitations: Int
    var citationsSince: Int
    var sinceLabel: String
    var hIndex: Int
    var hIndexSince: Int
    var i10Index: Int
    var i10IndexSince: Int
    var yearly: [YearCount]
    var papers: [Paper]
}

/// Where a logged gain came from. Scholar is the source of truth; OpenAlex
/// only stands in while Scholar refuses automatic access.
enum EventSource: String, Codable { case scholar, openAlex }

struct CitationEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    let paperID: String
    let title: String
    /// For OpenAlex events, the rise in OpenAlex's own count (never mixed
    /// with Scholar's absolute numbers).
    let delta: Int
    /// The source's count after the change (OpenAlex's count for OpenAlex
    /// events, which can differ from Scholar's).
    let newCount: Int
    let citesURL: String?
    /// Paper wasn't on the profile in the previous snapshot.
    var isNewPaper = false
    /// nil == .scholar (every event written before OpenAlex existed).
    var source: EventSource? = nil
    /// Part of this Scholar gain that an OpenAlex event already announced
    /// during the outage, so it isn't counted (badge, notification) twice.
    var creditedByOpenAlex: Int? = nil
    /// The OpenAlex work behind an OpenAlex event (row click → citing works).
    var openAlexWorkID: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, date, paperID, title, delta, newCount, citesURL, isNewPaper
        case source, creditedByOpenAlex, openAlexWorkID
    }

    var newestCitersURL: URL? { ScholarLink.newestFirst(citesURL) }
    var isFromOpenAlex: Bool { source == .openAlex }
    /// What counts toward the badge and notifications: the gain minus what
    /// OpenAlex already reported.
    var newDelta: Int { delta - (creditedByOpenAlex ?? 0) }
}

extension CitationEvent {
    /// Lenient about the fields that have defaults (synthesized Decodable
    /// would reject a record missing them).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        paperID = try c.decode(String.self, forKey: .paperID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        delta = try c.decode(Int.self, forKey: .delta)
        newCount = try c.decode(Int.self, forKey: .newCount)
        citesURL = try c.decodeIfPresent(String.self, forKey: .citesURL)
        isNewPaper = try c.decodeIfPresent(Bool.self, forKey: .isNewPaper) ?? false
        // try?: an unknown source (newer version) or a malformed value
        // degrades to the default instead of dropping the event.
        source = try? c.decodeIfPresent(EventSource.self, forKey: .source)
        // Kept within 0...delta so newDelta can never go negative or exceed the gain.
        creditedByOpenAlex = (try? c.decodeIfPresent(Int.self, forKey: .creditedByOpenAlex))
            .map { min(max(0, $0), max(0, delta)) }
        openAlexWorkID = try? c.decodeIfPresent(String.self, forKey: .openAlexWorkID)
    }
}

/// The OpenAlex backup's bookkeeping. Every key is optional on decode.
struct OpenAlexState: Codable {
    /// Scholar paper id → OpenAlex work id ("W…").
    var workIDs: [String: String] = [:]
    /// Scholar paper id → when a title search found no confident match;
    /// not searched again for 30 days (a search costs 10× a count check).
    var unmatchedAt: [String: Date] = [:]
    /// The profile owner's OpenAlex author ids: listing their works is the
    /// cheap way to match papers.
    var authorIDs: [String] = []
    /// Work id → cited_by_count at the last OpenAlex check (the baseline that
    /// rises are measured against).
    var counts: [String: Int] = [:]
    var lastCheckedAt: Date?
    /// Inside a continuous backup period, i.e. `counts` is a valid baseline.
    var active: Bool = false
    var lastError: String?
    /// Daily budget used up (HTTP 429): no OpenAlex requests before this.
    var budgetRetryAt: Date?
    /// Title searches are capped per day; this counts them in a 24h window
    /// starting at `searchWindowStart`.
    var searchWindowStart: Date?
    var searchesInWindow: Int = 0

    enum CodingKeys: String, CodingKey {
        case workIDs, unmatchedAt, authorIDs, counts, lastCheckedAt, active, lastError, budgetRetryAt
        case searchWindowStart, searchesInWindow
    }
}

extension OpenAlexState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workIDs = (try? c.decodeIfPresent([String: String].self, forKey: .workIDs)) ?? [:]
        unmatchedAt = (try? c.decodeIfPresent([String: Date].self, forKey: .unmatchedAt)) ?? [:]
        authorIDs = (try? c.decodeIfPresent([String].self, forKey: .authorIDs)) ?? []
        counts = (try? c.decodeIfPresent([String: Int].self, forKey: .counts)) ?? [:]
        lastCheckedAt = try? c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        // A missing/odd flag means "no valid baseline": the next period re-baselines.
        active = (try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? false
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        budgetRetryAt = try? c.decodeIfPresent(Date.self, forKey: .budgetRetryAt)
        searchWindowStart = try? c.decodeIfPresent(Date.self, forKey: .searchWindowStart)
        searchesInWindow = max(0, (try? c.decodeIfPresent(Int.self, forKey: .searchesInWindow)) ?? 0)
    }
}

struct TotalPoint: Codable, Hashable {
    let date: Date
    let total: Int
}

/// Everything persisted to disk between launches.
struct PersistedState: Codable {
    var profileID: String?
    var snapshot: ProfileSnapshot?
    var events: [CitationEvent] = []
    var totalHistory: [TotalPoint] = []
    var lastSeenAt: Date = .distantPast
    /// Newest event when the popover was last closed; everything appended
    /// after it is unseen. Unlike `lastSeenAt` this survives clock changes.
    var lastSeenEventID: UUID?
    var lastAttemptAt: Date?
    var blockedUntil: Date?
    /// When the last CAPTCHA/429 hit; drives the backoff streak's decay.
    var lastBlockedAt: Date?
    var blockCount: Int = 0
    /// OpenAlex backup bookkeeping; nil until the backup is first used (and
    /// then left out of state.json entirely).
    var openAlex: OpenAlexState?

    enum CodingKeys: String, CodingKey {
        case profileID, snapshot, events, totalHistory, lastSeenAt, lastSeenEventID
        case lastAttemptAt, blockedUntil, lastBlockedAt, blockCount
        case openAlex
    }
}

extension PersistedState {
    /// Every key is optional and bad records are skipped, so files written by
    /// older (or newer) versions still load instead of resetting the history.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try? c.decodeIfPresent(String.self, forKey: .profileID)
        // A snapshot that no longer decodes only costs one baseline fetch.
        snapshot = try? c.decodeIfPresent(ProfileSnapshot.self, forKey: .snapshot)
        events = (try? c.decodeIfPresent([Lossy<CitationEvent>].self, forKey: .events))?.compactMap(\.value) ?? []
        totalHistory = (try? c.decodeIfPresent([Lossy<TotalPoint>].self, forKey: .totalHistory))?.compactMap(\.value) ?? []
        lastSeenAt = (try? c.decodeIfPresent(Date.self, forKey: .lastSeenAt)) ?? .distantPast
        lastSeenEventID = try? c.decodeIfPresent(UUID.self, forKey: .lastSeenEventID)
        lastAttemptAt = try? c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        blockedUntil = try? c.decodeIfPresent(Date.self, forKey: .blockedUntil)
        lastBlockedAt = try? c.decodeIfPresent(Date.self, forKey: .lastBlockedAt)
        blockCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .blockCount)) ?? 0)
        // Unreadable OpenAlex state only costs a re-match and a fresh baseline.
        openAlex = try? c.decodeIfPresent(OpenAlexState.self, forKey: .openAlex)
    }
}

/// Decodes one array element, yielding nil instead of failing the whole array.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum ScholarLink {
    /// A "Cited by" link re-sorted newest first (`scisbd=1`). Tolerates a
    /// relative href and an existing `scisbd`.
    static func newestFirst(_ citesURL: String?) -> URL? {
        guard let citesURL, var c = URLComponents(string: citesURL) else { return nil }
        if c.host == nil {
            c.scheme = "https"
            c.host = "scholar.google.com"
        }
        var items = (c.queryItems ?? []).filter { $0.name != "scisbd" }
        items.append(URLQueryItem(name: "scisbd", value: "1"))
        c.queryItems = items
        return c.url
    }
}

enum Fmt {
    static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func n(_ v: Int) -> String { number.string(from: NSNumber(value: v)) ?? "\(v)" }

    /// Chinese on purpose: it is spliced into the (Chinese) UI strings.
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ d: Date) -> String {
        // Also covers slightly-future dates (clock adjusted since the fetch).
        if d.timeIntervalSinceNow > -60 { return "刚刚" }
        return relative.localizedString(for: d, relativeTo: Date())
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        // Fixed format: POSIX locale so the user's 12/24-hour setting can't rewrite "HH".
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
