import Foundation
import Observation
import WebKit

/// guitarpatches.com's Katana MkII listing, fetched by the app itself so
/// patches can be added to the library with one tap.
@MainActor
@Observable
final class GuitarPatchesFeed {
    enum Failure: LocalizedError {
        case noPatchFile(URL)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noPatchFile: return "Couldn't find the patch file on that page. Opening it in the browser instead."
            case .unreadable: return "guitarpatches.com sent something that isn't a page."
            }
        }
    }

    private(set) var patches: [GuitarPatches.Patch] = []
    private(set) var isLoading = false
    private(set) var hasMore = false
    private(set) var working: Set<Int> = []
    private(set) var problem: String?
    /// Patches already in the library, remembered between launches.
    private(set) var added: Set<Int>

    @ObservationIgnored private var pending: [URL] = []
    @ObservationIgnored private var visited: Set<URL> = []
    @ObservationIgnored private let session: URLSession

    init() {
        added = Set(UserDefaults.standard.array(forKey: "guitarpatches.added") as? [Int] ?? [])
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"]
        session = URLSession(configuration: configuration)
    }

    func reload() async {
        patches = []
        pending = [GuitarPatches.listing]
        visited = []
        await loadMore()
    }

    /// Fetches the next listing page the site linked to.
    func loadMore() async {
        guard !isLoading, let url = pending.first else { return }
        pending.removeFirst()
        visited.insert(url)
        isLoading = true
        problem = nil
        defer {
            isLoading = false
            hasMore = !pending.isEmpty
        }
        do {
            let page = GuitarPatches.parseListing(try await html(url), baseURL: url)
            let known = Set(patches.map(\.id))
            patches += page.patches.filter { !known.contains($0.id) }
            for next in page.pages where !visited.contains(next) && !pending.contains(next) {
                pending.append(next)
            }
            if patches.isEmpty {
                problem = "No patches found on guitarpatches.com. The site may have changed; the Website view still works."
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Downloads one patch's .tsl. Throws `.noPatchFile` when the page has
    /// no file the app can find (for example when the site wants a login).
    func download(_ patch: GuitarPatches.Patch) async throws -> Data {
        working.insert(patch.id)
        defer { working.remove(patch.id) }
        await shareBrowserCookies()
        let page = try await html(patch.url)
        for candidate in GuitarPatches.downloadCandidates(page, baseURL: patch.url).prefix(6) {
            guard let response = try? await session.data(from: candidate) else { continue }
            if (try? TSL.read(response.0)) != nil {
                added.insert(patch.id)
                UserDefaults.standard.set(Array(added), forKey: "guitarpatches.added")
                return response.0
            }
        }
        throw Failure.noPatchFile(patch.url)
    }

    /// A sign-in made in the Website view carries over to these downloads.
    private func shareBrowserCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies where cookie.domain.contains("guitarpatches") {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    private func html(_ url: URL) async throws -> String {
        let (data, _) = try await session.data(from: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw Failure.unreadable
        }
        return text
    }
}
