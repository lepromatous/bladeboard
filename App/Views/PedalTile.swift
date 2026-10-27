import SwiftUI

/// One block of the amp, drawn as a stompbox on the board.
struct PedalTile: View {
    @Environment(AmpSession.self) private var session
    let block: BlockDef
    let position: Int
    let onEdit: () -> Void

    static let width: CGFloat = 158
    static let height: CGFloat = 244

    var body: some View {
        let paint = session.paint(block)
        let ink = Theme.ink(for: paint)
        let isOn = session.isOn(block)

        VStack(spacing: 6) {
            HStack {
                Text("\(position)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(ink.opacity(0.6))
                Spacer()
                if block.variation != nil { VariationDot(block: block) }
                LED(isOn: isOn)
            }

            Button(action: onEdit) {
                VStack(spacing: 1) {
                    Text(block.name.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(1.5)
                        .foregroundStyle(ink.opacity(0.65))
                    Text(title)
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .frame(height: 42)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens every setting for this pedal")

            HStack(alignment: .top, spacing: 2) {
                ForEach(featured, id: \.offset) { parameter in
                    KnobView(parameter: parameter, raw: session.value(parameter), size: 32, ink: ink) {
                        session.set(parameter, raw: $0)
                    }
                }
            }
            .frame(height: 78)

            Spacer(minLength: 0)

            if block.onOff != nil {
                Footswitch(isOn: isOn) { session.toggle(block) }
            } else {
                Image(systemName: block.id == "amp" ? "speaker.wave.3.fill" : "chevron.compact.down")
                    .font(.title3)
                    .foregroundStyle(ink.opacity(0.5))
                    .frame(height: 38)
            }
        }
        .padding(10)
        .frame(width: Self.width, height: Self.height)
        .background(PedalBody(color: Theme.color(for: paint), isAmp: block.id == "amp"))
        .saturation(isOn ? 1 : 0.35)
        .brightness(isOn ? 0 : -0.12)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }

    private var title: String {
        if let type = session.currentType(block) {
            return block.id == "amp" ? type.name : type.name.uppercased()
        }
        return block.name.uppercased()
    }

    /// The knobs printed on the pedal face: its first three continuous controls.
    private var featured: [ParameterDef] {
        Array(session.parameters(block).filter { $0.kind == .range }.prefix(3))
    }
}

struct PedalBody: View {
    let color: Color
    var isAmp = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.12), color, color.mix(with: .black, by: 0.25)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if isAmp {
                    // Speaker grille cloth.
                    RoundedRectangle(cornerRadius: 10)
                        .fill(ImagePaint(image: Image(systemName: "circle.grid.cross.fill"), scale: 0.12))
                        .opacity(0.08)
                        .padding(8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isAmp ? Color(red: 0.8, green: 0.65, blue: 0.3) : .white.opacity(0.18), lineWidth: isAmp ? 2 : 1))
            .shadow(color: .black.opacity(0.6), radius: 8, y: 6)
    }
}

/// Which of the three stored variations the pedal is on.
struct VariationDot: View {
    @Environment(AmpSession.self) private var session
    let block: BlockDef

    var body: some View {
        if let variation = block.variation {
            let raw = session.value(variation)
            let color = Theme.variations.first { $0.raw == raw }?.color ?? .gray
            Circle().fill(color).frame(width: 9, height: 9)
                .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                .accessibilityLabel("\(Theme.variations.first { $0.raw == raw }?.name ?? "") variation")
        }
    }
}
