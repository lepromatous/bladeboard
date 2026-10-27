import Foundation
import Observation
import WebKit

/// guitarpatches.com's Katana MkII listing, fetched by the app itself so
/// patches can be added to the library with one tap.
///
/// Pages are read through a hidden web view rather than a plain download, so
/// the site sees a real browser: cookie and bot checks pass, and anything
/// the page builds with scripts is there to read. Patch files are fetched
/// from inside that page too, with the same cookies (and any sign-in made in
/// the Website view).
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
    /// The last listing page read, for sharing when nothing was found in it.
    private(set) var lastPage: PageLoader.Page?

    @ObservationIgnored let loader = PageLoader()
    @ObservationIgnored private var pending: [URL] = []
    @ObservationIgnored private var visited: Set<URL> = []

    init() {
        added = Set(UserDefaults.standard.array(forKey: "guitarpatches.added") as? [Int] ?? [])
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
            let loaded = try await loader.load(url)
            lastPage = loaded
            let page = GuitarPatches.parseListing(loaded.html, baseURL: loaded.url)
            let known = Set(patches.map(\.id))
            patches += page.patches.filter { !known.contains($0.id) }
            for next in page.pages where !visited.contains(next) && !pending.contains(next) {
                pending.append(next)
            }
            if patches.isEmpty {
                let title = loaded.title.isEmpty ? "an untitled page" : "\"\(loaded.title)\""
                problem = "No patches found. guitarpatches.com returned \(title) (\(loaded.html.count) characters). Share the page source below so the reader can be fixed; the Website view still works."
            }
        } catch {
            problem = "Couldn't load guitarpatches.com: \(error.localizedDescription)"
        }
    }

    /// Downloads one patch's .tsl. Throws `.noPatchFile` when the page has
    /// no file the app can find (for example when the site wants a login).
    func download(_ patch: GuitarPatches.Patch) async throws -> Data {
        working.insert(patch.id)
        defer { working.remove(patch.id) }
        let page = try await loader.load(patch.url)
        for candidate in GuitarPatches.downloadCandidates(page.html, baseURL: page.url).prefix(6) {
            guard let data = await loader.fetch(candidate), (try? TSL.read(data)) != nil else { continue }
            added.insert(patch.id)
            UserDefaults.standard.set(Array(added), forKey: "guitarpatches.added")
            return data
        }
        throw Failure.noPatchFile(patch.url)
    }
}

/// A browser with no window of its own, for reading pages the way Safari
/// would load them.
@MainActor
final class PageLoader: NSObject, WKNavigationDelegate {
    struct Page {
        let html: String
        let url: URL
        let title: String
    }

    let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws -> Page {
        continuation?.resume(throwing: CancellationError())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 30))
        }
        // Bot checks ("Just a moment…") reload the page once they pass, and
        // some lists are filled in by scripts after the page loads.
        for _ in 0..<30 {
            let title = (webView.title ?? "").lowercased()
            let checking = title.contains("just a moment") || title.contains("attention required") || title.contains("checking your browser")
            if !checking && !webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        try await Task.sleep(for: .milliseconds(300))
        let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
        return Page(html: html, url: webView.url ?? url, title: webView.title ?? "")
    }

    /// Fetches a URL from inside the loaded page, so it carries the page's
    /// cookies. Returns nil when the server says no.
    func fetch(_ url: URL) async -> Data? {
        let script = """
        const response = await fetch(address, { credentials: 'include' });
        if (!response.ok) { return null; }
        const bytes = new Uint8Array(await response.arrayBuffer());
        let binary = '';
        for (let i = 0; i < bytes.length; i += 0x8000) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return btoa(binary);
        """
        if let result = try? await webView.callAsyncJavaScript(script, arguments: ["address": url.absoluteString],
                                                                 in: nil, contentWorld: .defaultClient),
           let base64 = result as? String, let data = Data(base64Encoded: base64) {
            return data
        }
        // Cross-site links can't be fetched from the page; try directly.
        return try? await URLSession.shared.data(from: url).0
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // This view only reads pages; files are fetched with fetch(_:).
        response.canShowMIMEType ? .allow : .cancel
    }

    private func finish(with error: Error) {
        // A page that redirects cancels its own first load; the redirect's
        // didFinish will follow.
        if (error as NSError).code == NSURLErrorCancelled { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
