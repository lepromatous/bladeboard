import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// BOSS Tone Studio patch files. Declared in Info.plist.
    static let katanaTSL = UTType(importedAs: "com.lepromatous.bladeboard.tsl", conformingTo: .json)
}

/// Tones shared as a .tsl file through the share sheet.
struct TSLExport: Transferable {
    let tones: [Tone]
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .katanaTSL) { export in
            let name = export.fileName.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathExtension("tsl")
            let entries = export.tones.map { TSL.Entry(name: $0.name, memo: $0.memo, patch: $0.patch) }
            try TSL.write(entries, fileName: name).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// The librarian: the amp's nine stored patches and the user's own tones.
struct LibraryView: View {
    @Environment(AmpSession.self) private var session
    @State private var search = ""
    @State private var importing = false
    @State private var renaming: Tone?
    @State private var draftName = ""
    @State private var replacing: Int?
    @State private var showFavoritesOnly = false

    var body: some View {
        NavigationStack {
            List {
                ampSection
                tonesSection
            }
            .searchable(text: $search, prompt: "Search my tones")
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down.on.square") }
                    Menu {
                        Button { session.saveCurrentTone() } label: { Label("Save the live sound", systemImage: "plus") }
                        Toggle(isOn: $showFavoritesOnly) { Label("Favorites only", systemImage: "star") }
                        if !session.tones.isEmpty {
                            ShareLink(item: TSLExport(tones: session.tones, fileName: "My Katana Tones"),
                                      preview: SharePreview("My Katana Tones")) {
                                Label("Export all as .tsl", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.katanaTSL, .json], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach { session.importFile(at: $0) } }
            }
            .alert("Rename tone", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $draftName)
                Button("Rename") {
                    if var tone = renaming {
                        tone.name = String(draftName.prefix(PatchData.nameLength))
                        session.update(tone)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Replace slot \((replacing ?? 0) + 1) on the amp?",
                                isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                                titleVisibility: .visible) {
                Button("Write \"\(session.patchName)\" there", role: .destructive) {
                    if let slot = replacing { session.saveToMemory(slot) }
                }
            } message: {
                Text("The sound that's playing now is stored in this slot, replacing \"\(session.memory[replacing ?? 0].name ?? "what's there")\".")
            }
        }
    }

    private var ampSection: some View {
        Section {
            if session.state.isLive {
                ForEach(session.memory) { slot in
                    Menu {
                        Button { Task { await session.audition(slot.index) } } label: { Label("Play it now", systemImage: "play") }
                        Button { Task { await session.backUp(slot.index) } } label: { Label("Back up to My Tones", systemImage: "tray.and.arrow.down") }
                        Button(role: .destructive) { replacing = slot.index } label: { Label("Save the live sound here", systemImage: "square.and.arrow.down") }
                    } label: {
                        HStack {
                            Text("\(slot.index + 1)")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Theme.rail))
                            Text(slot.name ?? "…")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "ellipsis").foregroundStyle(.secondary)
                        }
                    }
                }
                Button { Task { await session.readMemoryNames() } } label: { Label("Read names from the amp", systemImage: "arrow.clockwise") }
                Button { Task { await session.backUpAll() } } label: { Label("Back up all nine", systemImage: "externaldrive.badge.plus") }
            } else {
                Text("Connect to the amp to see and back up what's stored on it.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("On the amp")
                Spacer()
                if let activity = session.activity {
                    ProgressView().controlSize(.small)
                    Text(activity).textCase(nil)
                }
            }
        }
    }

    private var filteredTones: [Tone] {
        session.tones.filter { tone in
            (!showFavoritesOnly || tone.favorite)
                && (search.isEmpty || tone.name.localizedCaseInsensitiveContains(search)
                    || tone.source.localizedCaseInsensitiveContains(search) || tone.memo.localizedCaseInsensitiveContains(search))
        }
    }

    private var tonesSection: some View {
        Section {
            if session.tones.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No tones yet").font(.headline)
                    Text("Save the sound you're playing, back up the amp, import .tsl files from Tone Studio, or download tones in the Get Tones tab.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            ForEach(filteredTones) { tone in
                Button { session.load(tone) } label: { ToneRow(tone: tone) }
                    .swipeActions(edge: .leading) {
                        Button {
                            var updated = tone
                            updated.favorite.toggle()
                            session.update(updated)
                        } label: { Label("Favorite", systemImage: tone.favorite ? "star.slash" : "star") }
                            .tint(.yellow)
                    }
                    .contextMenu {
                        Button { session.load(tone) } label: { Label("Load on the amp", systemImage: "play") }
                        Button {
                            draftName = tone.name
                            renaming = tone
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button {
                            session.addTones([Tone(name: tone.name, memo: tone.memo, patch: tone.patch, source: tone.source)])
                        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        ShareLink(item: TSLExport(tones: [tone], fileName: tone.name), preview: SharePreview(tone.name)) {
                            Label("Share as .tsl", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) { session.delete([tone.id]) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            .onDelete { offsets in session.delete(Set(offsets.map { filteredTones[$0].id })) }
        } header: {
            Text("My tones")
        } footer: {
            if !session.tones.isEmpty { Text("Tap a tone to play it on the amp. Long-press for more.") }
        }
    }
}

private struct ToneRow: View {
    let tone: Tone

    var body: some View {
        let amp = KatanaCatalog.shared.block("amp")
        let ampName = amp?.typeParameter.flatMap { amp?.effectType(raw: tone.patch.raw($0))?.name }
        HStack(spacing: 12) {
            Image(systemName: tone.favorite ? "star.fill" : "guitars")
                .foregroundStyle(tone.favorite ? .yellow : Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(tone.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text([ampName, tone.source.isEmpty ? nil : tone.source].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
