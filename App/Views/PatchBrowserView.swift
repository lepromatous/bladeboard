import SwiftUI
import WebKit

/// guitarpatches.com inside the app. Browse it as normal (sign in if the
/// site asks); any .tsl you download goes straight into My Tones, ready to
/// play on the amp.
struct PatchBrowserView: View {
    @Environment(AmpSession.self) private var session
    @State private var browser = PatchBrowser()
    @State private var lastAdded: String?

    static let home = URL(string: "https://guitarpatches.com/patches.php?unit=KATANAMKII")!

    var body: some View {
        NavigationStack {
            WebView(webView: browser.webView)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if browser.isLoading { ProgressView().padding(8) }
                }
                .overlay(alignment: .bottom) {
                    if let lastAdded {
                        Label(lastAdded, systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(.thinMaterial))
                            .padding(.bottom, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .navigationTitle("Get tones")
                .navigationBarTitleDisplayMode(.inline)
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
                        Button { browser.load(Self.home) } label: { Image(systemName: "house") }
                            .accessibilityLabel("Katana MkII patches")
                    }
                }
        }
        .onAppear {
            browser.onDownload = { data, fileName, page in
                let source = page.map { "guitarpatches.com: \($0)" } ?? "guitarpatches.com"
                let added = session.importData(data, fileName: fileName, source: source)
                guard added > 0 else { return }
                withAnimation { lastAdded = added == 1 ? "Added to My Tones" : "Added \(added) tones to My Tones" }
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation { lastAdded = nil }
                }
            }
            if browser.webView.url == nil { browser.load(Self.home) }
        }
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
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return ext == "tsl"
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload || Self.isPatchFile(action.request.url) { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isAttachment = disposition.lowercased().contains("attachment")
        if isAttachment || !response.canShowMIMEType || Self.isPatchFile(response.response.url)
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
