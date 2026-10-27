import SwiftUI

/// Every setting of one pedal: type, variation, all knobs and switches.
struct PedalEditorView: View {
    @Environment(AmpSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let block: BlockDef

    var body: some View {
        let paint = session.paint(block)
        let parameters = session.parameters(block)
        let knobs = parameters.filter { $0.kind == .range }
        let choices = parameters.filter { $0.kind != .range }

        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    faceplate(paint: paint, knobs: knobs)

                    if !choices.isEmpty {
                        SettingsCard(title: "Switches & modes") {
                            ForEach(choices, id: \.offset) { ParameterRow(parameter: $0) }
                        }
                    }

                    if !knobs.isEmpty {
                        SettingsCard(title: "Fine tune") {
                            ForEach(knobs, id: \.offset) { ParameterRow(parameter: $0) }
                        }
                    }

                    if block.id == "reverb", let layers = block.layers, let variation = block.variation {
                        let layer = layers[Theme.variations.firstIndex { $0.raw == session.value(variation) } ?? 0]
                        SettingsCard(title: "Rev/Delay knob") {
                            ParameterRow(parameter: layer, title: "Knob controls")
                        }
                    }

                    if !block.advanced.isEmpty {
                        SettingsCard(title: "Custom (advanced)") {
                            Text("Settings for the amp's Custom models. They only change the sound when a custom type is in use.")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(block.advanced, id: \.offset) { ParameterRow(parameter: $0) }
                        }
                    }
                }
                .padding()
            }
            .background(Theme.board.ignoresSafeArea())
            .navigationTitle(block.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func faceplate(paint: String, knobs: [ParameterDef]) -> some View {
        let ink = Theme.ink(for: paint)
        return VStack(spacing: 14) {
            HStack {
                if let typeParameter = block.typeParameter {
                    TypeMenu(block: block, typeParameter: typeParameter, ink: ink)
                } else {
                    Text(block.name.uppercased()).font(.title3.weight(.black)).foregroundStyle(ink)
                }
                Spacer()
                LED(isOn: session.isOn(block))
            }

            if block.variation != nil { VariationPicker(block: block) }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 12) {
                ForEach(knobs, id: \.offset) { parameter in
                    KnobView(parameter: parameter, raw: session.value(parameter), size: 46, ink: ink) {
                        session.set(parameter, raw: $0)
                    }
                }
            }

            if block.onOff != nil {
                Footswitch(isOn: session.isOn(block), size: 52) { session.toggle(block) }
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(PedalBody(color: Theme.color(for: paint), isAmp: block.id == "amp"))
    }
}

/// The type selector printed at the top of the pedal.
struct TypeMenu: View {
    @Environment(AmpSession.self) private var session
    let block: BlockDef
    let typeParameter: ParameterDef
    let ink: Color

    var body: some View {
        let current = session.currentType(block)
        let groups = Dictionary(grouping: block.types, by: \.category)
        let order = Theme.categoryOrder.filter { groups[$0] != nil } + groups.keys.filter { !Theme.categoryOrder.contains($0) }.sorted()
        Menu {
            ForEach(order, id: \.self) { category in
                Section(category) {
                    ForEach(groups[category] ?? []) { type in
                        Button {
                            session.setType(block, raw: type.raw)
                        } label: {
                            if type.raw == current?.raw { Label(type.name, systemImage: "checkmark") } else { Text(type.name) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text((current?.name ?? block.name).uppercased())
                    .font(.title3.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold))
            }
            .foregroundStyle(ink)
        }
        .accessibilityLabel("Type, \(current?.name ?? "")")
    }
}

struct VariationPicker: View {
    @Environment(AmpSession.self) private var session
    let block: BlockDef

    var body: some View {
        if let variation = block.variation {
            let raw = session.value(variation)
            HStack(spacing: 10) {
                ForEach(Theme.variations, id: \.raw) { option in
                    Button {
                        session.setVariation(block, raw: option.raw)
                    } label: {
                        Text(option.name)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(option.color.opacity(raw == option.raw ? 1 : 0.25)))
                            .foregroundStyle(raw == option.raw ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(raw == option.raw ? .isSelected : [])
                }
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
    }
}

/// A parameter as a list row: picker, switch, or slider with steppers.
struct ParameterRow: View {
    @Environment(AmpSession.self) private var session
    let parameter: ParameterDef
    var title: String?

    var body: some View {
        let raw = session.value(parameter)
        let name = title ?? parameter.name
        switch parameter.kind {
        case .toggle:
            Toggle(name, isOn: Binding(get: { raw != 0 }, set: { session.set(parameter, raw: $0 ? 1 : 0) }))
        case .enumeration:
            Picker(name, selection: Binding(get: { raw }, set: { session.set(parameter, raw: $0) })) {
                ForEach(parameter.options ?? [], id: \.raw) { Text($0.label).tag($0.raw) }
            }
            .pickerStyle(.menu)
        case .range:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                    Spacer()
                    Text(parameter.display(raw)).monospacedDigit().foregroundStyle(.secondary)
                    Stepper(name, onIncrement: { session.set(parameter, raw: raw + 1) },
                            onDecrement: { session.set(parameter, raw: raw - 1) })
                        .labelsHidden()
                }
                Slider(value: Binding(get: { Double(raw) }, set: { session.set(parameter, raw: Int($0.rounded())) }),
                       in: Double(parameter.min)...Double(max(parameter.max, parameter.min + 1)))
                    .tint(Theme.accent)
                    .accessibilityLabel(name)
                    .accessibilityValue(parameter.display(raw))
            }
        }
    }
}
