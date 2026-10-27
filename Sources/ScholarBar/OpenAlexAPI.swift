import Foundation

/// Backup citation source for while Google Scholar blocks automatic access.
/// OpenAlex (openalex.org) is a free scholarly index that is meant to be
/// queried by programs, so unlike Scholar it is fine to poll. Its counts
/// differ from Scholar's (other coverage, preprints counted apart), so the
/// app only uses its *changes*, never its absolute numbers.
///
/// Budget: without a key everyone behind the same IP shares one free daily
/// allowance (1000 credits). A title search costs 10 credits, while one page
/// of a list or a batch of ≤100 ids costs 1 — so matching leans on listing the
/// owner's works and keeps searches for the leftovers.
enum OpenAlexAPI {
    enum OAError: LocalizedError {
        /// HTTP 429: today's budget is used up (or requests came too fast).
        case budgetExhausted(retryAfter: TimeInterval?)
        case http(Int)
        case parse(String)

        var errorDescription: String? {
            switch self {
            case .budgetExhausted(let after):
                var s = OpenAlexAPI.hasKey ? "OpenAlex 今日额度已用完" : "OpenAlex 今日免费额度已用完（与同一网络共享）"
                if let after, after > 0 {
                    s += after < 3600 ? "，约 \(max(1, Int((after / 60).rounded(.up)))) 分钟后恢复"
                                      : "，约 \(Int((after / 3600).rounded(.up))) 小时后恢复"
                }
                return s
            case .http(let c) where (c == 401 || c == 403) && OpenAlexAPI.hasKey:
                return "OpenAlex 拒绝了请求（HTTP \(c)），检查设置里的 API key"
            case .http(let c): return "OpenAlex HTTP \(c)"
            case .parse(let m): return "OpenAlex 返回内容解析失败：\(m)"
            }
        }
    }

    struct Work: Codable, Hashable {
        /// Short form, e.g. "W4321015480".
        let id: String
        let title: String
        let year: Int?
        let citedBy: Int
    }

    /// Optional key from Settings; nil = shared anonymous budget.
    /// Written on the main thread (Settings) but read by requests running on
    /// the cooperative pool, so it sits behind a lock.
    static var apiKey: String? {
        get { lock.lock(); defer { lock.unlock() }; return _apiKey }
        set { lock.lock(); _apiKey = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    private static var _apiKey: String?
    private static var _creditsUsed = 0
    private static var _remainingCredits: Int?

    /// Credits OpenAlex reported spending this launch (x-ratelimit-credits-used), for logs.
    static var creditsUsed: Int { lock.lock(); defer { lock.unlock() }; return _creditsUsed }
    /// Credits left today as of the last response; nil before the first one.
    static var remainingCredits: Int? { lock.lock(); defer { lock.unlock() }; return _remainingCredits }

    /// Test seam: when set, requests go here instead of the network.
    static var transport: ((URL) async throws -> (Data, HTTPURLResponse))?

    // MARK: - Limits

    /// Author listings per resolve call (each ≤ `maxPagesPerAuthor` credits):
    /// enough for the owner's split ids plus a close co-author or two.
    static var maxAuthorListings = 6
    static let maxPagesPerAuthor = 5
    /// Author ids handed back for next time (known ones first).
    static let maxAuthorIDs = 8
    private static let listPageSize = 200
    private static let searchPageSize = 5
    private static let batchSize = 100
    /// Spacing between requests, so a resolve burst stays gentle.
    private static let requestGap: TimeInterval = 0.15
    private static let base = "https://api.openalex.org/works"
    private static let listFields = "id,title,publication_year,cited_by_count,authorships"

    private static var hasKey: Bool { !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    private static let session: URLSession = {
        // Ephemeral: no cookies or cache to keep — every request is a plain API call.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        // A 200-work page with author lists can be a few MB on a slow link.
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpAdditionalHeaders = [
            // Say who we are: OpenAlex is built for automated clients.
            "User-Agent": "ScholarBar/1.0 (macOS menu-bar citation tracker)",
            "Accept": "application/json",
        ]
        return URLSession(configuration: cfg)
    }()

    private static let pacer = Pacer()

    // MARK: - Public API

    /// Map Scholar papers to OpenAlex works by title (+ year ±1). Cheap first:
    /// list works of known/discovered author IDs (1 credit/page) and match
    /// locally; title search (10 credits) only for leftovers, at most
    /// `maxSearches` per call. Returns matches keyed by Scholar paper id,
    /// the author ids seen on matched works, and the paper ids that were
    /// searched without a confident match.
    ///
    /// Papers neither matched nor in `unmatched` were not tried yet (search
    /// cap reached, or the run stopped early) and are worth retrying later.
    /// A failure after some progress (e.g. 429 halfway) returns the progress
    /// instead of throwing it away — the credits are already spent; the next
    /// request (citedByCounts) reports the 429 again. It throws only when
    /// nothing was settled.
    static func resolve(_ papers: [Paper], knownAuthorIDs: [String], maxSearches: Int)
        async throws -> (matches: [String: Work], authorIDs: [String], unmatched: Set<String>)
    {
        let r = Resolution(papers: papers, knownAuthorIDs: knownAuthorIDs)
        var listings = 0, searches = 0
        let creditsBefore = creditsUsed
        do {
            while r.hasRemaining {
                // (1) Listing an author's works is 10–50× cheaper than a search.
                if listings < maxAuthorListings, let author = r.nextAuthor() {
                    listings += 1
                    try await listWorks(of: author, into: r)
                    continue
                }
                // (2) Most-cited leftover by title; a match can reveal new author ids for (1).
                guard searches < maxSearches, let item = r.nextToSearch() else { break }
                if item.norm.tokens.count < 3 {
                    // "Editorial", "Preface": a title search would find someone else's
                    // paper. Such titles only match through the owner's own works.
                    r.giveUp(item)
                    continue
                }
                searches += 1
                let found = try await fetch([
                    .init(name: "filter", value: "title.search:\(item.norm.text)"),
                    .init(name: "select", value: listFields),
                    .init(name: "per-page", value: "\(searchPageSize)"),
                ])
                r.settleSearch(item, results: found.results.compactMap(\.value))
            }
        } catch {
            if Task.isCancelled || error is CancellationError || !r.madeProgress { throw error }
            NSLog("ScholarBar: OpenAlex resolve stopped early (\(error.localizedDescription)); keeping \(r.matches.count) matches")
        }
        if r.total > 0 {
            NSLog("ScholarBar: OpenAlex matched \(r.matches.count)/\(r.total) papers, \(r.unmatched.count) unmatched (\(listings) listings, \(searches) searches, \(creditsUsed - creditsBefore) credits)")
        }
        return (r.matches, r.ownerAuthorIDs, r.unmatched)
    }

    /// Current cited_by_count for works (batched ≤100 IDs per request, 1 credit each).
    /// Works OpenAlex no longer returns (deleted or merged into another id)
    /// are absent from the result — no data, not zero.
    static func citedByCounts(_ workIDs: [String]) async throws -> [String: Int] {
        var seen = Set<String>()
        let ids = workIDs.compactMap { shortID($0, "W") }.filter { seen.insert($0).inserted }
        var out: [String: Int] = [:]
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let chunk = ids[start..<min(start + batchSize, ids.count)]
            let page = try await fetch([
                .init(name: "filter", value: "openalex_id:" + chunk.joined(separator: "|")),
                .init(name: "select", value: "id,cited_by_count"),
                .init(name: "per-page", value: "\(batchSize)"),
            ])
            for w in page.results.compactMap(\.value) {
                if let id = shortID(w.id, "W"), let c = w.citedByCount { out[id] = c }
            }
        }
        return out
    }

    /// Normalized-title equality / near-equality used by resolve (exposed for tests).
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        Norm(a).matches(Norm(b))
    }

    /// Web page listing works that cite `workID`, newest first (for row clicks).
    static func citingWorksURL(_ workID: String) -> URL {
        guard let id = shortID(workID, "W") else { return URL(string: "https://openalex.org/works")! }
        return URL(string: "https://openalex.org/works?filter=cites:\(id)&sort=publication_date:desc")!
    }

    // MARK: - Title normalization

    /// Lowercased, HTML tags/entities and diacritics removed, apostrophes
    /// dropped ("Agents' Last" = "Agents Last"), other punctuation turned into
    /// single spaces. Both sides go through the same steps.
    static func normalize(_ title: String) -> String {
        let folded = ScholarAPI.clean(title)
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        var out = ""
        out.reserveCapacity(folded.utf8.count)
        var gap = false
        for ch in folded {
            if apostrophes.contains(ch) { continue }
            if ch.isLetter || ch.isNumber {
                if gap && !out.isEmpty { out.append(" ") }
                gap = false
                out.append(ch)
            } else {
                gap = true
            }
        }
        return out
    }

    private static let apostrophes: Set<Character> = ["'", "’", "‘", "`", "´", "ʼ"]

    /// Same year give or take one (online-first vs issue year); unknown passes.
    static func yearsCompatible(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= 1
    }

    /// "https://openalex.org/W123" / "w123" / "W123" → "W123"; nil unless it
    /// is `prefix` + digits (so nothing odd ends up inside a filter).
    static func shortID(_ s: String?, _ prefix: String) -> String? {
        guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if let slash = t.lastIndex(of: "/") { t = String(t[t.index(after: slash)...]) }
        t = t.uppercased()
        guard t.hasPrefix(prefix), t.count > prefix.count,
              t.dropFirst(prefix.count).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return t
    }

    /// A title in comparable form, computed once per paper / work.
    struct Norm {
        let text: String
        let tokens: Set<String>
        let length: Int

        init(_ title: String) {
            text = OpenAlexAPI.normalize(title)
            tokens = Set(text.split(separator: " ").map(String.init))
            length = text.count
        }

        /// Equal; or one is a prefix of the other covering ≥ 90% of it (Scholar
        /// cuts long titles off, sometimes mid-word); or ≥ 90% of the words shared.
        func matches(_ o: Norm) -> Bool {
            guard !text.isEmpty, !o.text.isEmpty else { return false }
            if text == o.text { return true }
            let (short, long) = length <= o.length ? (self, o) : (o, self)
            if long.text.hasPrefix(short.text), Double(short.length) >= 0.9 * Double(long.length) { return true }
            let union = tokens.union(o.tokens).count
            return union > 0 && Double(tokens.intersection(o.tokens).count) >= 0.9 * Double(union)
        }
    }

    // MARK: - Requests

    /// Pages of one author's works, matched as they arrive; stops once
    /// nothing is left to match. Only years the leftovers could match are asked for.
    private static func listWorks(of author: String, into r: Resolution) async throws {
        var filter = "author.id:\(author)"
        if let years = r.yearRange {
            filter += ",from_publication_date:\(years.lowerBound)-01-01,to_publication_date:\(years.upperBound)-12-31"
        }
        var cursor = "*"
        // Without a key OpenAlex refuses cursor paging past page 1 (HTTP 401
        // "API key required for cursor paging"); page 1 is sorted by citations,
        // so it already holds the works most worth matching.
        for _ in 0..<(hasKey ? maxPagesPerAuthor : 1) {
            let page = try await fetch([
                .init(name: "filter", value: filter),
                .init(name: "select", value: listFields),
                .init(name: "sort", value: "cited_by_count:desc"),
                .init(name: "per-page", value: "\(listPageSize)"),
                .init(name: "cursor", value: cursor),
            ])
            let works = page.results.compactMap(\.value)
            r.absorb(works)
            guard r.hasRemaining, works.count >= listPageSize,
                  let next = page.meta?.nextCursor, !next.isEmpty else { return }
            cursor = next
        }
    }

    private static func fetch(_ items: [URLQueryItem]) async throws -> Page {
        var comps = URLComponents(string: base)!
        var query = items
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            query.append(.init(name: "api_key", value: key))
        }
        comps.queryItems = query
        // URLComponents leaves "+" alone, which servers read as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw OAError.parse("URL") }

        try await pacer.wait(requestGap)
        try Task.checkCancellation()
        let data: Data
        let http: HTTPURLResponse
        do {
            if let transport {
                (data, http) = try await transport(url)
            } else {
                let (d, resp) = try await session.data(from: url)
                guard let h = resp as? HTTPURLResponse else { throw OAError.http(0) }
                (data, http) = (d, h)
            }
        } catch let e as URLError {
            // Drop userInfo: the failing URL in it carries the API key.
            throw URLError(e.code)
        }
        noteUsage(http)
        switch http.statusCode {
        case 200: break
        case 429: throw OAError.budgetExhausted(retryAfter: retryAfter(http))
        case let c:
            // What was asked (key removed) and what OpenAlex said, for diagnosis.
            var shown = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let kept = shown?.queryItems?.filter { $0.name != "api_key" }
            shown?.queryItems = kept
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            NSLog("ScholarBar: OpenAlex HTTP \(c) for \(shown?.url?.absoluteString ?? "?"): \(body)")
            throw OAError.http(c)
        }
        do {
            return try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw OAError.parse(String(describing: error).prefix(160).description)
        }
    }

    private static func noteUsage(_ http: HTTPURLResponse) {
        let used = http.value(forHTTPHeaderField: "x-ratelimit-credits-used").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let left = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        lock.lock(); defer { lock.unlock() }
        if let used { _creditsUsed += used }
        if let left { _remainingCredits = left }
    }

    /// Seconds until requests are welcome again: Retry-After (seconds or an
    /// HTTP date), else x-ratelimit-reset (seconds until the daily reset).
    static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        for name in ["Retry-After", "x-ratelimit-reset"] {
            guard let v = http.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces),
                  !v.isEmpty else { continue }
            if let s = TimeInterval(v), s >= 0 {
                // A Unix timestamp rather than a delay.
                return s > 1_000_000_000 ? max(0, s - Date().timeIntervalSince1970) : s
            }
            if let d = httpDate.date(from: v) { return max(0, d.timeIntervalSinceNow) }
        }
        return nil
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    // MARK: - Response

    fileprivate struct Page: Decodable {
        struct Meta: Decodable {
            let nextCursor: String?
            enum CodingKeys: String, CodingKey { case nextCursor = "next_cursor" }
        }
        let meta: Meta?
        /// One odd record must not sink the whole page.
        let results: [LossyWork]
    }

    fileprivate struct LossyWork: Decodable {
        let value: RawWork?
        init(from decoder: Decoder) throws { value = try? RawWork(from: decoder) }
    }

    fileprivate struct RawWork: Decodable {
        let id: String
        let title: String?
        let publicationYear: Int?
        let citedByCount: Int?
        let authorships: [Authorship]?

        struct Authorship: Decodable {
            let author: Author?
            struct Author: Decodable { let id: String? }
        }

        enum CodingKeys: String, CodingKey {
            case id, title, authorships
            case publicationYear = "publication_year"
            case citedByCount = "cited_by_count"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            publicationYear = try? c.decodeIfPresent(Int.self, forKey: .publicationYear)
            citedByCount = try? c.decodeIfPresent(Int.self, forKey: .citedByCount)
            authorships = (try? c.decodeIfPresent([LossyAuthorship].self, forKey: .authorships))?.compactMap(\.value)
        }

        private struct LossyAuthorship: Decodable {
            let value: Authorship?
            init(from decoder: Decoder) throws { value = try? Authorship(from: decoder) }
        }
    }

    /// A listed or found work, ready to compare.
    fileprivate struct Candidate {
        let work: Work
        let norm: Norm
        let authorIDs: [String]

        init?(_ raw: RawWork) {
            guard let id = OpenAlexAPI.shortID(raw.id, "W"), let t = raw.title else { return nil }
            let title = ScholarAPI.clean(t)
            norm = Norm(title)
            guard !norm.text.isEmpty else { return nil }
            work = Work(id: id, title: title, year: raw.publicationYear, citedBy: max(0, raw.citedByCount ?? 0))
            var seen = Set<String>()
            authorIDs = (raw.authorships ?? []).compactMap { OpenAlexAPI.shortID($0.author?.id, "A") }
                .filter { seen.insert($0).inserted }
        }
    }

    // MARK: - Resolution state

    /// Bookkeeping for one resolve call.
    fileprivate final class Resolution {
        struct Item {
            let paper: Paper
            let norm: Norm
        }

        let total: Int
        /// Not yet settled, most-cited first (the order searches go in).
        private(set) var remaining: [Item] = []
        private(set) var matches: [String: Work] = [:]
        private(set) var unmatched = Set<String>()
        /// A work stands for at most one paper (Scholar duplicates would
        /// otherwise announce the same OpenAlex rise twice).
        private var taken = Set<String>()
        /// Author id → matched works (this call) it appears on.
        private var authorHits: [String: Int] = [:]
        private let known: [String]
        private var listed = Set<String>()

        init(papers: [Paper], knownAuthorIDs: [String]) {
            var seen = Set<String>()
            let unique = papers.filter { seen.insert($0.id).inserted }
            total = unique.count
            let ordered = unique.enumerated()
                .sorted { $0.element.citations != $1.element.citations
                    ? $0.element.citations > $1.element.citations : $0.offset < $1.offset }
                .map(\.element)
            for p in ordered {
                let n = Norm(p.title)
                // Nothing to compare: no search can ever confirm it.
                if n.text.isEmpty { unmatched.insert(p.id) } else { remaining.append(Item(paper: p, norm: n)) }
            }
            var k = Set<String>()
            known = knownAuthorIDs.compactMap { OpenAlexAPI.shortID($0, "A") }.filter { k.insert($0).inserted }
        }

        var hasRemaining: Bool { !remaining.isEmpty }
        var madeProgress: Bool { !matches.isEmpty || !unmatched.isEmpty }

        /// Publication years the leftovers could match (±1); nil if any year is unknown.
        var yearRange: ClosedRange<Int>? {
            let years = remaining.compactMap(\.paper.year)
            guard !years.isEmpty, years.count == remaining.count,
                  let lo = years.min(), let hi = years.max() else { return nil }
            return (lo - 1)...(hi + 1)
        }

        /// Known ids first, then ids on ≥ 2 matched works (the profile owner,
        /// possibly split into several ids, and close co-authors), most frequent first.
        func nextAuthor() -> String? {
            if let k = known.first(where: { !listed.contains($0) }) {
                listed.insert(k)
                return k
            }
            guard let best = authorHits
                .filter({ $0.value >= 2 && !listed.contains($0.key) })
                .max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key
            else { return nil }
            listed.insert(best)
            return best
        }

        func nextToSearch() -> Item? { remaining.first }

        var ownerAuthorIDs: [String] {
            let fresh = authorHits
                .filter { $0.value >= 2 && !known.contains($0.key) }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map(\.key)
            return Array((known + fresh).prefix(OpenAlexAPI.maxAuthorIDs))
        }

        /// Matches every remaining paper it can against `raws`.
        func absorb(_ raws: [RawWork]) {
            let cands = raws.compactMap(Candidate.init)
            guard !cands.isEmpty else { return }
            var left: [Item] = []
            for item in remaining {
                if let c = best(for: item, among: cands) { record(item, c) } else { left.append(item) }
            }
            remaining = left
        }

        /// A searched paper is settled either way: matched, or unmatched (the
        /// caller waits a long while before paying for that search again).
        func settleSearch(_ item: Item, results: [RawWork]) {
            let cands = results.compactMap(Candidate.init)
            remaining.removeAll { $0.paper.id == item.paper.id }
            if let c = best(for: item, among: cands) { record(item, c) } else { unmatched.insert(item.paper.id) }
            // A result can be another leftover of the same author (similar titles).
            absorb(results)
        }

        func giveUp(_ item: Item) {
            remaining.removeAll { $0.paper.id == item.paper.id }
            unmatched.insert(item.paper.id)
        }

        /// Exact title first, then the version with most citations (the
        /// journal article over its preprint, closest to Scholar's merged
        /// count), then the nearest year.
        private func best(for item: Item, among cands: [Candidate]) -> Candidate? {
            var best: Candidate?
            var bestKey = (0, 0, 0)
            for c in cands where !taken.contains(c.work.id)
                && OpenAlexAPI.yearsCompatible(item.paper.year, c.work.year)
                && item.norm.matches(c.norm) {
                let distance = (item.paper.year != nil && c.work.year != nil) ? abs(item.paper.year! - c.work.year!) : 1
                let key = (item.norm.text == c.norm.text ? 1 : 0, c.work.citedBy, -distance)
                if best == nil || key > bestKey { best = c; bestKey = key }
            }
            return best
        }

        private func record(_ item: Item, _ c: Candidate) {
            matches[item.paper.id] = c.work
            taken.insert(c.work.id)
            for a in c.authorIDs { authorHits[a, default: 0] += 1 }
        }
    }
}

/// Spaces requests out, also across concurrent callers (each reserves the next slot).
private actor Pacer {
    private var next = Date.distantPast

    func wait(_ gap: TimeInterval) async throws {
        let now = Date()
        let start = max(now, next)
        next = start.addingTimeInterval(gap)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}
