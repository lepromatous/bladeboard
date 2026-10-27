import Foundation

/// Reads guitarpatches.com's Katana MkII section.
///
/// The site has no API, so this works from its HTML, as loosely as it can:
/// a patch is any link of the form patches.php?mode=show&unit=KATANAMKII&ID=n,
/// further pages are links back to the listing with a page-like parameter,
/// and a patch file is a link on the patch page that ends in .tsl or says
/// "download". Whatever comes back is checked by parsing it as a .tsl, so a
/// wrong guess fails cleanly instead of importing junk.
public enum GuitarPatches {
    public static let unit = "KATANAMKII"
    public static let listing = URL(string: "https://guitarpatches.com/patches.php?unit=\(unit)")!

    public struct Patch: Hashable, Identifiable, Sendable {
        public let id: Int
        public var title: String
        public let url: URL
        /// Whatever short facts the listing row showed (author, date, genre).
        public var details: String
    }

    public struct Page: Sendable {
        public var patches: [Patch]
        /// Further listing pages linked from this one, in page order.
        public var pages: [URL]
    }

    struct Link {
        let href: String
        let text: String
        /// The text between this link and the next one, where listing rows
        /// put authors and dates.
        let trailing: String
        /// False for a URL found outside an <a href> (an onclick, a script).
        var isAnchor = true
    }

    /// Every <a href> in a page with its text, then every patches.php URL
    /// that appears anywhere else (row onclick handlers, data attributes,
    /// scripts), titled by the text that follows it.
    static func links(in html: String) -> [Link] {
        anchors(in: html) + bareURLs(in: html)
    }

    static func bareURLs(in html: String) -> [Link] {
        let pattern = #"(?:https?://[^"'\s<>]*?/)?[\w./-]*patches\.php\?[^"'\s<>)\\]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let text = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: text.length)).map { match in
            // The visible text after the tag this URL sits in.
            let tagEnd = text.range(of: ">", options: [], range: NSRange(location: match.range.upperBound, length: text.length - match.range.upperBound))
            let start = tagEnd.location == NSNotFound ? match.range.upperBound : tagEnd.upperBound
            let after = text.substring(with: NSRange(location: start, length: min(600, text.length - start)))
            let cell = after.components(separatedBy: "</").first ?? after
            return Link(href: decodeEntities(text.substring(with: match.range)),
                        text: String(plainText(cell).prefix(80)),
                        trailing: plainText(String(after.dropFirst(cell.count))),
                        isAnchor: false)
        }
    }

    static func anchors(in html: String) -> [Link] {
        let pattern = #"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let text = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: text.length))
        return matches.enumerated().map { index, match in
            let end = index + 1 < matches.count ? matches[index + 1].range.location : min(text.length, match.range.upperBound + 400)
            let trailingRange = NSRange(location: match.range.upperBound, length: max(0, min(end, match.range.upperBound + 400) - match.range.upperBound))
            return Link(href: decodeEntities(text.substring(with: match.range(at: 1))),
                        text: plainText(text.substring(with: match.range(at: 2))),
                        trailing: plainText(text.substring(with: trailingRange)))
        }
    }

    public static func parseListing(_ html: String, baseURL: URL = listing) -> Page {
        var patches: [Int: Patch] = [:]
        var order: [Int] = []
        var pages: [URL] = []
        var titledByAnchor = Set<Int>()
        for link in links(in: html) {
            guard let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL,
                  let query = queryItems(url) else { continue }
            let isUnit = query["unit"]?.caseInsensitiveCompare(unit) == .orderedSame
            if isUnit, query["mode"]?.lowercased() == "show", let id = query["id"].flatMap(Int.init) {
                if var existing = patches[id] {
                    // Anchor text beats text guessed from around a bare URL.
                    if link.isAnchor, link.text.count > existing.title.count || !titledByAnchor.contains(id), !link.text.isEmpty {
                        existing.title = link.text
                        titledByAnchor.insert(id)
                    } else if existing.title.isEmpty {
                        existing.title = link.text
                    }
                    patches[id] = existing
                } else {
                    patches[id] = Patch(id: id, title: link.text, url: url, details: summarize(link.trailing))
                    order.append(id)
                    if link.isAnchor, !link.text.isEmpty { titledByAnchor.insert(id) }
                }
            } else if isUnit, query["mode"] == nil,
                      query.keys.contains(where: { ["page", "start", "p", "pg", "offset", "pagina"].contains($0) }),
                      !pages.contains(url) {
                pages.append(url)
            }
        }
        let list = order.compactMap { patches[$0] }.map { patch -> Patch in
            var patch = patch
            if patch.title.isEmpty { patch.title = "Patch \(patch.id)" }
            return patch
        }
        return Page(patches: list, pages: pages)
    }

    /// Links on a patch page that could be the patch file, most likely first.
    public static func downloadCandidates(_ html: String, baseURL: URL) -> [URL] {
        var scored: [(URL, Int)] = []
        for link in links(in: html) {
            guard let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL,
                  url.scheme?.hasPrefix("http") == true else { continue }
            let href = link.href.lowercased()
            let text = link.text.lowercased()
            var score = 0
            if url.pathExtension.lowercased() == "tsl" || href.contains(".tsl") { score += 4 }
            if href.contains("download") { score += 3 }
            if text.contains("download") { score += 2 }
            if href.contains("mode=show") || href.contains("login") || href.contains("register") { score -= 5 }
            if score > 0, !scored.contains(where: { $0.0 == url }) { scored.append((url, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func queryItems(_ url: URL) -> [String: String]? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems else { return nil }
        var result: [String: String] = [:]
        for item in items { result[item.name.lowercased()] = item.value ?? "" }
        return result
    }

    static func plainText(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(noTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summarize(_ text: String) -> String {
        String(text.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " -|·:,"))
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        let numeric = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);")
        let ns = out as NSString
        var result = ""
        var cursor = 0
        for match in numeric?.matches(in: out, range: NSRange(location: 0, length: ns.length)) ?? [] {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let code = ns.substring(with: match.range(at: 1))
            let value = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            result += value.flatMap { UnicodeScalar($0) }.map { String(Character($0)) } ?? ns.substring(with: match.range)
            cursor = match.range.upperBound
        }
        result += ns.substring(from: cursor)
        return result
    }
}
