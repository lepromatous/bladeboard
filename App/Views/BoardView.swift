import SwiftUI

/// The pedalboard: every block of the amp in signal order. Drag a pedal onto
/// another to move it in front of it; drop it on the output jack to send it
/// to the end of the chain.
struct BoardView: View {
    @Environment(AmpSession.self) private var session
    @State private var editing: BlockDef?
    @State private var showingCase = false
    @State private var showingArrange = false
    @State private var showingSave = false
    @AppStorage("showBypassed") private var showBypassed = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    PatchHeader()
                    board
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 32)
            }
            .background(BoardBackground().ignoresSafeArea())
            .navigationTitle("Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { await session.refresh() }
            .sheet(item: $editing) { PedalEditorView(block: $0) }
            .sheet(isPresented: $showingCase) { PedalCaseView() }
            .sheet(isPresented: $showingArrange) { ArrangeChainView() }
            .sheet(isPresented: $showingSave) { SaveToneView() }
        }
    }

    private var board: some View {
        let blocks = session.boardBlocks
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: PedalTile.width), spacing: 12)], spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                if showBypassed || session.isOn(block) {
                    PedalTile(block: block, position: index + 1) { editing = block }
                        .draggable(block.id) {
                            Text(block.name).font(.headline).padding(10)
                                .background(Capsule().fill(Theme.color(for: session.paint(block))))
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let moved = items.first, moved != block.id else { return false }
                            withAnimation(.snappy) { session.move(moved, before: block.id) }
                            return true
                        }
                }
            }
            OutputJack()
                .dropDestination(for: String.self) { items, _ in
                    guard let moved = items.first else { return false }
                    withAnimation(.snappy) { session.move(moved, before: nil) }
                    return true
                }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ConnectionBadge()
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showingCase = true } label: { Label("Pedals", systemImage: "plus.square.on.square") }
            Menu {
                Button { showingSave = true } label: { Label("Save tone…", systemImage: "square.and.arrow.down") }
                Button { showingArrange = true } label: { Label("Arrange chain…", systemImage: "arrow.up.arrow.down") }
                Toggle(isOn: $showBypassed) { Label("Show bypassed pedals", systemImage: "eye") }
                Button { Task { await session.refresh() } } label: { Label("Reload from amp", systemImage: "arrow.clockwise") }
                    .disabled(!session.state.isLive)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Patch name and the amp's channel buttons.
struct PatchHeader: View {
    @Environment(AmpSession.self) private var session
    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 10) {
            Button {
                draftName = session.patchName
                renaming = true
            } label: {
                HStack {
                    Text(session.patchName.isEmpty ? "Untitled" : session.patchName)
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8).padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rail, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Patch name, \(session.patchName)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(AmpSession.channels.enumerated()), id: \.offset) { index, name in
                        Button(name) { session.selectChannel(index) }
                            .font(.caption.weight(.bold))
                            .buttonStyle(.bordered)
                            .tint(name == "PANEL" ? .gray : Theme.accent)
                    }
                }
            }
            .disabled(!session.state.isLive)
        }
        .padding(.top, 8)
        .alert("Patch name", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Rename") { session.patchName = String(draftName.prefix(PatchData.nameLength)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Up to 16 characters, as the amp shows it.")
        }
    }
}

struct ConnectionBadge: View {
    @Environment(AmpSession.self) private var session

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(session.state.label).font(.caption).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .demo: return .blue
        case .offline: return .red
        }
    }
}

/// The end of the chain, where the amp's output is.
struct OutputJack: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cable.connector.horizontal").font(.largeTitle)
            Text("OUTPUT").font(.caption.weight(.heavy)).tracking(2)
            Text("Drop a pedal here to move it to the end").font(.caption2).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(width: PedalTile.width, height: PedalTile.height)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            .foregroundStyle(Theme.rail))
    }
}

/// A board's rails: dark aluminium with the slots between them.
struct BoardBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.board))
            var y: CGFloat = 40
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 26)), with: .color(Theme.rail))
                y += 88
            }
        }
    }
}

/// A plain list for reordering precisely, or with VoiceOver.
struct ArrangeChainView: View {
    @Environment(AmpSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.boardBlocks) { block in
                        HStack {
                            Image(systemName: Theme.symbol(for: session.paint(block)))
                                .foregroundStyle(Theme.color(for: session.paint(block)))
                                .frame(width: 28)
                            VStack(alignment: .leading) {
                                Text(block.name)
                                Text(session.currentType(block)?.name ?? (session.isOn(block) ? "On" : "Off"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { from, to in
                        var order = session.boardBlocks.map(\.id)
                        order.move(fromOffsets: from, toOffset: to)
                        session.arrange(order)
                    }
                } footer: {
                    Text("Guitar in at the top, amp output at the bottom. Pedals above the Amp run into its input.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Signal chain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Saves the live sound into the library or one of the amp's memories.
struct SaveToneView: View {
    @Environment(AmpSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmSlot: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Tone name", text: $name)
                }
                Section {
                    Button {
                        session.saveCurrentTone(named: name)
                        dismiss()
                    } label: { Label("Save to My Tones", systemImage: "books.vertical") }
                }
                Section {
                    ForEach(session.memory) { slot in
                        Button {
                            confirmSlot = slot.index
                        } label: {
                            HStack {
                                Text("Slot \(slot.index + 1)")
                                Spacer()
                                Text(slot.name ?? "—").foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Write to the amp")
                } footer: {
                    Text("Replaces what's stored in that slot on the Katana.")
                }
                .disabled(!session.state.isLive)
            }
            .navigationTitle("Save tone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { name = session.patchName }
            .confirmationDialog("Replace slot \((confirmSlot ?? 0) + 1)?", isPresented: Binding(
                get: { confirmSlot != nil }, set: { if !$0 { confirmSlot = nil } }), titleVisibility: .visible) {
                Button("Write \"\(name)\" to the amp", role: .destructive) {
                    if let slot = confirmSlot {
                        if !name.isEmpty { session.patchName = String(name.prefix(PatchData.nameLength)) }
                        session.saveToMemory(slot)
                    }
                    dismiss()
                }
            }
        }
    }
}
