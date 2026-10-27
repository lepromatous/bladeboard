import SwiftUI

struct RootView: View {
    @Environment(AmpSession.self) private var session

    var body: some View {
        TabView {
            Tab("Board", systemImage: "rectangle.3.group") { BoardView() }
            Tab("Library", systemImage: "books.vertical") { LibraryView() }
            Tab("Get Tones", systemImage: "globe") { GetTonesView() }
            Tab("Amp", systemImage: "dot.radiowaves.left.and.right") { ConnectionView() }
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) { NoticeBanner() }
    }
}

/// Short messages from the session ("Saved to slot 3"), shown for a moment.
private struct NoticeBanner: View {
    @Environment(AmpSession.self) private var session

    var body: some View {
        if let notice = session.notice {
            Text(notice)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                .padding(.horizontal)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { session.notice = nil }
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { if session.notice == notice { session.notice = nil } }
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
