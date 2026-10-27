import SwiftUI
import WebKit

/// Tones from guitarpatches.com. Discover lists the Katana MkII patches and
/// adds any of them to the library in one tap; Website is the site itself,
/// for signing in or anything Discover can't reach. Downloads from either
/// land in My Tones.
struct GetTonesView: View {
    enum Mode: String, CaseIterable {
        case discover = "Discover"
        case website = "Website"
    }

    @Environment(AmpSession.self) private var session
    @State private var mode = Mode.discover
    @State private var feed = GuitarPatchesFeed()
    @State private var browser = PatchBrowser()
    @State private var banner: String?

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .discover: DiscoverList(feed: feed, add: add)
                case .website: BrowserPane(browser: browser)
                }
            }
            .overlay(alignment: .bottom) {
                if let banner {
                    Label(banner, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.thinMaterial))
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Source", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
        }
        .onAppear {
            browser.onDownload = { data, fileName, page in
                let source = page.map { "guitarpatches.com: \($0)" } ?? "guitarpatches.com"
                show(session.importData(data, fileName: fileName, source: source))
            }
        }
    }

    /// Downloads a patch from the Discover list into the library.
    private func add(_ patch: GuitarPatches.Patch, play: Bool) async {
        do {
            let data = try await feed.download(patch)
            let before = session.tones.count
            let count = session.importData(data, fileName: patch.title, source: "guitarpatches.com: \(patch.title)")
            if play, count > 0, session.tones.count > before, let tone = session.tones.first {
                session.load(tone)
            }
            show(count)
        } catch GuitarPatchesFeed.Failure.noPatchFile(let url) {
            session.notice = GuitarPatchesFeed.Failure.noPatchFile(url).errorDescription
            mode = .website
            browser.load(url)
        } catch {
            session.notice = error.localizedDescription
        }
    }

    private func show(_ added: Int) {
        guard added > 0 else { return }
        withAnimation { banner = added == 1 ? "Added to My Tones" : "Added \(added) tones to My Tones" }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { banner = nil }
        }
    }
}

private struct DiscoverList: View {
    let feed: GuitarPatchesFeed
    let add: (GuitarPatches.Patch, Bool) async -> Void
    @State private var search = ""
    @State private var addingAll = false

    var body: some View {
        List {
            if let problem = feed.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    if let page = feed.lastPage {
                        ShareLink(item: "\(page.url.absoluteString)\n\n\(page.html)",
                                  subject: Text("guitarpatches.com page source"),
                                  preview: SharePreview("guitarpatches.com page source")) {
                            Label("Share page source", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button { Task { await feed.reload() } } label: { Label("Try again", systemImage: "arrow.clockwise") }
                }
            }
            ForEach(filtered) { patch in
                PatchRow(patch: patch, isWorking: feed.working.contains(patch.id), isAdded: feed.added.contains(patch.id)) {
                    Task { await add(patch, false) }
                }
                .swipeActions(edge: .leading) {
                    Button { Task { await add(patch, true) } } label: { Label("Add & play", systemImage: "play.fill") }
                        .tint(Theme.accent)
                }
                .contextMenu {
                    Button { Task { await add(patch, false) } } label: { Label("Add to My Tones", systemImage: "plus") }
                    Button { Task { await add(patch, true) } } label: { Label("Add and play on the amp", systemImage: "play") }
                    Link(destination: patch.url) { Label("Open in Safari", systemImage: "safari") }
                }
            }
            if feed.hasMore || feed.isLoading {
                HStack {
                    Spacer()
                    if feed.isLoading { ProgressView() } else { Button("Load more") { Task { await feed.loadMore() } } }
                    Spacer()
                }
                .onAppear { Task { await feed.loadMore() } }
            }
        }
        .searchable(text: $search, prompt: "Filter these patches")
        .refreshable { await feed.reload() }
        .task { if feed.patches.isEmpty { await feed.reload() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addingAll = true
                    Task {
                        for patch in filtered where !feed.added.contains(patch.id) { await add(patch, false) }
                        addingAll = false
                    }
                } label: { Label("Add all", systemImage: "square.and.arrow.down.on.square") }
                    .disabled(addingAll || filtered.allSatisfy { feed.added.contains($0.id) })
            }
        }
        .overlay {
            if feed.patches.isEmpty, feed.isLoading { ProgressView("Loading guitarpatches.com…") }
        }
        // The page reader's browser lives in the view tree, out of sight, so
        // pages run exactly as they would on screen.
        .background(WebView(webView: feed.loader.webView).frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false))
    }

    private var filtered: [GuitarPatches.Patch] {
        guard !search.isEmpty else { return feed.patches }
        return feed.patches.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.details.localizedCaseInsensitiveContains(search) }
    }
}

private struct PatchRow: View {
    let patch: GuitarPatches.Patch
    let isWorking: Bool
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(patch.title).font(.body.weight(.semibold))
                if !patch.details.isEmpty {
                    Text(patch.details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if isWorking {
                ProgressView()
            } else if isAdded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("In My Tones")
            } else {
                Button(action: onAdd) { Image(systemName: "plus.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .tint(Theme.accent)
                    .accessibilityLabel("Add \(patch.title) to My Tones")
            }
        }
    }
}

private struct BrowserPane: View {
    let browser: PatchBrowser

    var body: some View {
        WebView(webView: browser.webView)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                if browser.isLoading { ProgressView().padding(8) }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { browser.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!browser.canGoBack)
                        .accessibilityLabel("Back")
                    Button { browser.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!browser.canGoForward)
                        .accessibilityLabel("Forward")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload")
                    Button { browser.load(GuitarPatches.listing) } label: { Image(systemName: "house") }
                        .accessibilityLabel("Katana MkII patches")
                }
            }
            .onAppear { if browser.webView.url == nil { browser.load(GuitarPatches.listing) } }
    }
}

private struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Owns the web view and turns patch downloads into data for the library.
@MainActor
@Observable
final class PatchBrowser: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored var onDownload: (Data, String, String?) -> Void = { _, _, _ in }
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private var destinations: [ObjectIdentifier: URL] = [:]

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    private static func isPatchFile(_ url: URL?) -> Bool {
        url?.pathExtension.lowercased() == "tsl"
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload || Self.isPatchFile(action.request.url) { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if disposition.lowercased().contains("attachment") || !response.canShowMIMEType
            || Self.isPatchFile(response.response.url)
            || (response.response.suggestedFilename ?? "").lowercased().hasSuffix(".tsl") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(suggestedFilename)
        destinations[ObjectIdentifier(download)] = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)),
              let data = try? Data(contentsOf: url) else { return }
        let page = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        onDownload(data, url.lastPathComponent, page)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refreshState() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refreshState() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { refreshState() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { refreshState() }

    private func refreshState() {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}
