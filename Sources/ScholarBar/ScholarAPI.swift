import Foundation

/// Reads a public Google Scholar profile page. There is no official API, so
/// this parses the same HTML a browser gets. Keep requests rare: Scholar
/// answers aggressive clients with a CAPTCHA / 429.
enum ScholarAPI {
    enum FetchError: LocalizedError {
        case invalidProfile
        case blocked
        case consent
        case shifted
        case http(Int)
        case parse(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile: return "没找到这个 Scholar 主页（检查链接或 user ID）"
            case .blocked: return "Google Scholar 暂时要求验证（CAPTCHA），稍后自动重试"
            case .consent: return "Google 跳到了 cookie 同意页（consent.google.com），读不到主页"
            case .shifted: return "抓取途中论文列表有变动，稍后自动重试"
            case .http(let c): return "HTTP \(c)"
            case .parse(let m): return "页面解析失败：\(m)"
            }
        }
    }

    /// Scholar serves at most 100 rows per page.
    static let pageSize = 100
    /// Requests per refresh are capped to stay polite. Past the cap only the
    /// least-cited tail is missing (the list is sorted by citations).
    static let maxPages = 20
    static var maxPapers: Int { pageSize * maxPages }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieAcceptPolicy = .always
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ]
        return URLSession(configuration: cfg)
    }()

    /// Where `blocks.log` goes (set by AppModel); nil: don't log.
    static var diagnosticsDir: URL?

    /// Accepts a full profile URL (any Scholar mirror, any parameter order,
    /// with or without scheme, even HTML-escaped or percent-encoded), an
    /// article link of the profile, or a bare user ID.
    static func extractProfileID(_ input: String) -> String? {
        // Pasted from chat / markdown / HTML: drop wrapping quotes, brackets, punctuation.
        let wrap = CharacterSet(charactersIn: "\"'`“”‘’<>()[]{}.,;:!?。，；：！？、「」『』（）【】《》〈〉").union(.whitespacesAndNewlines)
        let s = input.trimmingCharacters(in: wrap).replacingOccurrences(of: "&amp;", with: "&")
        if s.range(of: #"^[A-Za-z0-9_-]{12}$"#, options: .regularExpression) != nil {
            return s
        }
        // Redirect links can be percent-encoded twice (%253D).
        let once = s.removingPercentEncoding ?? s
        for candidate in [s, once, once.removingPercentEncoding ?? once] {
            // IDs are exactly 12 characters (as for the bare form above); a cut-off
            // paste must be rejected, not saved as a new profile.
            if let user = first(#"(?:^|[?&#;/\s])user=([A-Za-z0-9_-]{12})(?![A-Za-z0-9_-])"#, in: candidate) {
                return user
            }
            // Article page: citation_for_view=<owner>:<article>
            if let owner = first(#"citation_for_view=([A-Za-z0-9_-]{12}):"#, in: candidate) {
                return owner
            }
        }
        return nil
    }

    static func profileURL(_ id: String) -> URL {
        var comps = URLComponents(string: "https://scholar.google.com/citations")!
        comps.queryItems = [.init(name: "user", value: id), .init(name: "hl", value: "en")]
        return comps.url!
    }

    /// Fetches the whole profile (all paper pages). Throws rather than
    /// returning a damaged list, so a failed page never looks like lost citations.
    static func fetchProfile(id: String) async throws -> ProfileSnapshot {
        var snapshot: ProfileSnapshot?
        var papers: [Paper] = []
        var seen = Set<String>()
        var lastPageFull = false
        for page in 0..<maxPages {
            if page > 0 {
                // Pause between pages like a person clicking "Show more".
                try await Task.sleep(nanoseconds: UInt64.random(in: 3_000_000_000...6_000_000_000))
            }
            try Task.checkCancellation()
            let html = try await fetchPage(id: id, cstart: page * pageSize)
            if page == 0 { snapshot = try parseHeader(html) }
            let (rows, rowCount) = parseRows(html)
            // Markup changed: saving an empty list would make every paper
            // come back later as a "new paper" with all its citations.
            // (Cited profiles always list papers, so no rows at all is the same failure.)
            if (rowCount > 0 && rows.isEmpty)
                || (page == 0 && rowCount == 0 && (snapshot?.totalCitations ?? 0) > 0) {
                throw FetchError.parse("第 \(page + 1) 页的论文列表")
            }
            // The list is sorted by citations, so a cited profile's first page
            // always has a cited paper; all zeros means the count column changed.
            if page == 0, (snapshot?.totalCitations ?? 0) > 0, !rows.isEmpty,
               rows.allSatisfy({ $0.citations == 0 }) {
                throw FetchError.parse("论文引用数")
            }
            // "Articles 101–200" is printed after the rows. A body cut short loses
            // it and the closing tag: retry rather than take it for the last page.
            let listed = listedRowCount(html)
            if listed == nil && !html.contains("</html>") {
                throw FetchError.parse("第 \(page + 1) 页不完整")
            }
            if let listed, listed != rowCount {
                NSLog("ScholarBar: page \(page + 1) lists \(listed) rows, \(rowCount) matched the row pattern")
            }
            if rows.count < rowCount {
                NSLog("ScholarBar: skipped \(rowCount - rows.count) unreadable rows on page \(page + 1)")
            }
            // A paper seen twice means the ranking moved between pages, so
            // another paper slipped through the gap. Retry instead of losing it.
            for p in rows {
                guard seen.insert(p.id).inserted else { throw FetchError.shifted }
            }
            papers.append(contentsOf: rows)
            // Page by raw rows: an odd row must not look like the last page.
            // Page by what the page says it holds too: a row the pattern missed
            // must not look like the last page (it is skipped like an unreadable row).
            lastPageFull = max(rowCount, listed ?? 0) >= pageSize
            if !lastPageFull { break }
        }
        guard var snap = snapshot else { throw FetchError.parse("empty") }
        if lastPageFull {
            NSLog("ScholarBar: profile has more than \(maxPapers) papers; keeping the \(maxPapers) most cited")
        }
        snap.papers = papers
        return snap
    }

    private static func fetchPage(id: String, cstart: Int) async throws -> String {
        var comps = URLComponents(string: "https://scholar.google.com/citations")!
        comps.queryItems = [
            .init(name: "user", value: id),
            .init(name: "hl", value: "en"),
            .init(name: "cstart", value: "\(cstart)"),
            .init(name: "pagesize", value: "\(pageSize)"),
        ]
        let (data, resp) = try await session.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse else { throw FetchError.http(0) }
        let html = String(decoding: data, as: UTF8.self)
        do {
            try checkPage(html, finalURL: http.url ?? comps.url!, status: http.statusCode, cstart: cstart)
        } catch FetchError.blocked {
            logBlock(status: http.statusCode, url: http.url ?? comps.url!, html: html)
            throw FetchError.blocked
        }
        return html
    }

    /// One line per block in blocks.log (time, status, page, visible text),
    /// to see later how often it happens and whether it was a CAPTCHA or a 429.
    private static func logBlock(status: Int, url: URL, html: String) {
        guard let dir = diagnosticsDir else { return }
        let text = clean(html.replacingOccurrences(of: #"<(script|style)\b.*?</\1>"#, with: " ",
                                                   options: [.regularExpression, .caseInsensitive]))
        let line = "\(ISO8601DateFormatter().string(from: Date()))\tHTTP \(status)\t\(url.host ?? "")\(url.path)\t\(text.prefix(200))\n"
        let file = dir.appendingPathComponent("blocks.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    /// Throws unless the response is a readable profile page.
    static func checkPage(_ html: String, finalURL: URL, status: Int, cstart: Int) throws {
        // Every page (not only the first) carries the profile header. Only
        // look for CAPTCHA words on non-profile pages: a paper titled
        // "…unusual traffic…" must not trigger a day-long back-off.
        let isProfile = html.contains(#"id="gsc_prf_in""#)
        if !isProfile {
            let lower = html.lowercased()
            if finalURL.path.hasPrefix("/sorry")
                || ["gs_captcha", "g-recaptcha", "unusual traffic", "not a robot", "automated queries"]
                    .contains(where: { lower.contains($0) }) {
                throw FetchError.blocked
            }
            // EU visitors can be redirected to Google's cookie wall first.
            if finalURL.host?.lowercased().hasPrefix("consent.") == true
                || lower.contains("consent.google.com") {
                throw FetchError.consent
            }
        }
        switch status {
        case 200: break
        case 403, 429, 503: throw FetchError.blocked
        case 404 where cstart == 0: throw FetchError.invalidProfile
        case let c: throw FetchError.http(c)
        }
        if !isProfile {
            // Page 1 already proved the profile exists; a later odd page is a glitch.
            if cstart == 0 { throw FetchError.invalidProfile }
            throw FetchError.parse("第 \(cstart / pageSize + 1) 页不是主页内容")
        }
    }

    // MARK: - Parsing

    static func parseHeader(_ html: String) throws -> ProfileSnapshot {
        let name = clean(first(#"<div\b[^>]*\bid="gsc_prf_in"[^>]*>(.*?)</div>"#, in: html) ?? "")
        let affiliation = clean(first(#"<div class="gsc_prf_il">(.*?)</div>"#, in: html) ?? "")
        let stats = all(#"<td\b[^>]*\bclass="gsc_rsb_std"[^>]*>([^<]*)</td>"#, in: html).map { number($0) ?? 0 }
        guard stats.count >= 6 else {
            // Brand-new profiles with zero citations have no stats table. If the
            // table is there but unreadable, fail instead of reporting 0 citations.
            if !name.isEmpty && !html.contains(#"id="gsc_rsb_st""#) {
                return ProfileSnapshot(fetchedAt: Date(), name: name, affiliation: affiliation,
                                       totalCitations: 0, citationsSince: 0, sinceLabel: "",
                                       hIndex: 0, hIndexSince: 0, i10Index: 0, i10IndexSince: 0,
                                       yearly: [], papers: [])
            }
            throw FetchError.parse("stats table")
        }
        // Column headers are "", "All", "Since 2021"; keep just the year so
        // the label survives a non-English page.
        let headers = all(#"<th\b[^>]*\bclass="gsc_rsb_sth"[^>]*>(.*?)</th>"#, in: html).map(clean)
        let sinceLabel = headers.last.flatMap { first(#"((?:19|20)\d\d)"#, in: $0) } ?? ""

        // Citations-per-year histogram. Bars for zero-count years are omitted;
        // each bar's z-index is its position counted from the newest year.
        let hist = histogramBlock(html)
        let years = all(#"<span\b[^>]*\bclass="gsc_g_t"[^>]*>\s*(\d+)\s*</span>"#, in: hist).compactMap { Int($0) }
        var counts = Array(repeating: 0, count: years.count)
        for bar in allGroups(#"<a\b([^>]*\bclass="gsc_g_a"[^>]*)>(.*?)</a>"#, in: hist) {
            if let z = first(#"z-index:\s*(\d+)"#, in: bar[0]).flatMap({ Int($0) }),
               let c = first(#"class="gsc_g_al"[^>]*>([^<]*)<"#, in: bar[1]).flatMap(number),
               z >= 1, z <= counts.count {
                counts[counts.count - z] = c
            }
        }
        let yearly = zip(years, counts).map { YearCount(year: $0, count: $1) }

        return ProfileSnapshot(
            fetchedAt: Date(), name: name, affiliation: affiliation,
            totalCitations: stats[0], citationsSince: stats[1], sinceLabel: sinceLabel,
            hIndex: stats[2], hIndexSince: stats[3], i10Index: stats[4], i10IndexSince: stats[5],
            yearly: yearly, papers: []
        )
    }

    /// Scholar has rendered both a sidebar and a pop-up histogram before;
    /// mixing their labels would scramble the years. Use the fullest one.
    private static func histogramBlock(_ html: String) -> String {
        let blocks = html.components(separatedBy: #"class="gsc_md_hist_b""#).dropFirst()
        func yearCount(_ s: String) -> Int { s.components(separatedBy: #"class="gsc_g_t""#).count }
        return blocks.max { yearCount($0) < yearCount($1) } ?? html
    }

    static func parsePapers(_ html: String) -> [Paper] {
        parseRows(html).papers
    }

    /// Papers on one page, plus how many paper rows the page had, so the
    /// caller can tell a short last page from rows that failed to parse.
    private static func parseRows(_ html: String) -> (papers: [Paper], rowCount: Int) {
        let rows = all(#"<tr\b[^>]*\bclass="(?:[^"]*\s)?gsc_a_tr(?:\s[^"]*)?"[^>]*>(.*?)</tr>"#, in: html)
            .filter { !$0.contains(#"class="gsc_a_e""#) } // "There are no articles in this profile."
        let papers: [Paper] = rows.compactMap { row in
            guard let pid = first(#"citation_for_view=([^"&#\s]+)"#, in: row),
                  let title = first(#"<a\b[^>]*\bclass="(?:[^"]*\s)?gsc_a_at(?:\s[^"]*)?"[^>]*>(.*?)</a>"#, in: row)
            else { return nil }
            let grays = all(#"<div\b[^>]*\bclass="gs_gray"[^>]*>(.*?)</div>"#, in: row)
            var venue = grays.count > 1 ? grays[1] : ""
            venue = venue.replacingOccurrences(of: #"<span\b[^>]*\bclass="gs_oph"[^>]*>.*?</span>"#, with: "", options: .regularExpression)
            // Uncited papers have an empty link: <a href="" class="gsc_a_ac gs_ibl"></a>
            let citeLink = allGroups(#"<a\b([^>]*\bclass="(?:[^"]*\s)?gsc_a_ac[^"]*"[^>]*)>(.*?)</a>"#, in: row).first
            var citesURL = citeLink.flatMap { first(#"\bhref="([^"]*)""#, in: $0[0]) }.map(decodeEntities)
            if let u = citesURL, u.hasPrefix("/") { citesURL = "https://scholar.google.com" + u }
            if citesURL?.contains("cites=") != true { citesURL = nil }
            let year = first(#"<span\b[^>]*\bclass="(?:[^"]*\s)?gsc_a_h(?:\s[^"]*)?"[^>]*>\s*(\d{4})\s*</span>"#, in: row)
                .flatMap { Int($0) }
            return Paper(
                id: pid,
                title: clean(title),
                authors: clean(grays.first ?? ""),
                venue: clean(venue),
                year: year,
                citations: citeLink.flatMap { number(clean($0[1])) } ?? 0,
                citesURL: citesURL
            )
        }
        return (papers, rows.count)
    }

    // MARK: - Regex helpers

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators])
    }

    /// Rows the page says it holds ("Articles 801–839" → 39); nil if absent.
    private static func listedRowCount(_ html: String) -> Int? {
        guard let g = allGroups(#"<span\b[^>]*\bid="gsc_a_nn"[^>]*>[^<\d]*(\d+)[^<\d]+(\d+)\s*</span>"#, in: html).first,
              let lo = Int(g[0]), let hi = Int(g[1]), hi >= lo else { return nil }
        return hi - lo + 1
    }

    private static func allGroups(_ pattern: String, in s: String) -> [[String]] {
        let ns = s as NSString
        return regex(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func all(_ pattern: String, in s: String) -> [String] {
        allGroups(pattern, in: s).compactMap(\.first)
    }

    private static func first(_ pattern: String, in s: String) -> String? {
        all(pattern, in: s).first
    }

    /// Digits only ("1,234" → 1234); nil when there are none.
    private static func number(_ s: String) -> Int? {
        Int(s.filter { $0.isASCII && $0.isNumber })
    }

    /// Strip tags, decode entities, collapse whitespace.
    static func clean(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(noTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static let entityRegex = regex("&(#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z][A-Za-z0-9]{1,31});")

    private static let namedEntities: [String: String] = [
        "amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "middot": "·", "times": "×",
    ]

    /// One pass, so `&amp;#39;` stays the literal text `&#39;`; unknown or
    /// invalid entities are kept as written instead of being dropped.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in entityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            result += decodeEntity(body) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func decodeEntity(_ body: String) -> String? {
        guard body.hasPrefix("#") else { return namedEntities[body] ?? namedEntities[body.lowercased()] }
        let digits = body.dropFirst()
        let code = digits.first == "x" || digits.first == "X"
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits, radix: 10)
        return code.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
    }
}
