import SwiftUI

/// Every effect the Katana can run, filed by kind like a pedal case. The amp
/// has a fixed set of slots, so picking a pedal puts it into one of them:
/// a phaser can go in the MOD or FX slot, a drive in the Booster, and so on.
struct PedalCaseView: View {
    @Environment(AmpSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var choosing: CaseItem?

    struct Slot: Hashable {
        let block: BlockDef
        let type: EffectType
    }

    struct CaseItem: Identifiable, Hashable {
        let name: String
        let category: String
        var slots: [Slot]
        var id: String { category + "/" + name }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22, pinnedViews: .sectionHeaders) {
                    ForEach(sections, id: \.category) { section in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                                ForEach(section.items) { item in
                                    Button { pick(item) } label: { MiniPedal(item: item, inUse: inUse(item)) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        } header: {
                            Label(section.category, systemImage: Theme.symbol(for: section.category))
                                .font(.headline)
                                .padding(.horizontal).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.bar)
                        }
                    }
                }
                .padding(.vertical)
            }
            .background(Theme.board.ignoresSafeArea())
            .searchable(text: $search, prompt: "Phaser, Blues Drive, Tape…")
            .navigationTitle("Pedal case")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Where should \(choosing?.name ?? "it") go?",
                                isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                                titleVisibility: .visible, presenting: choosing) { item in
                ForEach(item.slots, id: \.self) { slot in
                    Button(slotLabel(slot)) { place(slot) }
                }
            } message: { _ in
                Text("The Katana runs one effect per slot, so this replaces what the slot holds now.")
            }
        }
    }

    private func pick(_ item: CaseItem) {
        if item.slots.count == 1 { place(item.slots[0]) } else { choosing = item }
    }

    private func place(_ slot: Slot) {
        session.place(slot.type, in: slot.block)
        session.notice = "\(slot.type.name) is now in the \(slot.block.name) slot."
        dismiss()
    }

    private func slotLabel(_ slot: Slot) -> String {
        let current = session.currentType(slot.block)
        let state = session.isOn(slot.block) ? (current?.name ?? "on") : "off"
        return "\(slot.block.name) slot (now \(state))"
    }

    private func inUse(_ item: CaseItem) -> Bool {
        item.slots.contains { session.currentType($0.block)?.raw == $0.type.raw && session.isOn($0.block) }
    }

    private var sections: [(category: String, items: [CaseItem])] {
        var items: [String: CaseItem] = [:]
        for block in session.catalog.blocks {
            for type in block.types {
                let category = block.id == "amp" ? "Amp" : type.category
                let key = category + "/" + type.name
                items[key, default: CaseItem(name: type.name, category: category, slots: [])]
                    .slots.append(Slot(block: block, type: type))
            }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = items.values.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query) }
        let grouped = Dictionary(grouping: filtered, by: \.category)
        let order = ["Amp"] + Theme.categoryOrder
        return grouped.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            .map { category in (category, (grouped[category] ?? []).sorted { $0.name < $1.name }) }
    }
}

private struct MiniPedal: View {
    let item: PedalCaseView.CaseItem
    let inUse: Bool

    var body: some View {
        let ink = Theme.ink(for: item.category)
        VStack(spacing: 6) {
            HStack {
                Spacer()
                LED(isOn: inUse)
            }
            Text(item.name.uppercased())
                .font(.system(size: 12, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .foregroundStyle(ink)
                .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { _ in
                    Circle().fill(Theme.cream).frame(width: 14, height: 14)
                }
            }
            Circle().fill(Color(white: 0.7)).frame(width: 20, height: 20)
        }
        .padding(8)
        .frame(height: 140)
        .background(PedalBody(color: Theme.color(for: item.category), isAmp: item.category == "Amp"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name + (inUse ? ", in use" : ""))
        .accessibilityAddTraits(.isButton)
    }
}
