import SwiftUI

/// A pedal knob. Drag up or right to turn it up; VoiceOver can adjust it
/// step by step.
struct KnobView: View {
    let parameter: ParameterDef
    let raw: Int
    var size: CGFloat = 44
    var ink: Color = .white
    var showsValue = true
    let onChange: (Int) -> Void

    @State private var dragOrigin: Double?

    private static let sweep = 270.0

    var body: some View {
        let position = parameter.normalized(raw)
        VStack(spacing: 3) {
            ZStack {
                arc(from: 0, to: 1).stroke(ink.opacity(0.22), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                valueArc(position).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle()
                    .fill(RadialGradient(colors: [Theme.cream, Color(white: 0.62)], center: .init(x: 0.35, y: 0.3),
                                         startRadius: 1, endRadius: size * 0.7))
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
                Capsule()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: max(2.5, size * 0.07), height: size * 0.34)
                    .offset(y: -size * 0.27)
                    .rotationEffect(.degrees(-Self.sweep / 2 + Self.sweep * position))
            }
            .frame(width: size + 12, height: size + 12)
            .contentShape(Circle())
            .highPriorityGesture(drag(from: position))

            Text(parameter.name)
                .font(.system(size: max(9, size * 0.22), weight: .semibold))
                .foregroundStyle(ink.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if showsValue {
                Text(parameter.display(raw))
                    .font(.system(size: max(9, size * 0.22)).monospacedDigit())
                    .foregroundStyle(ink.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(minWidth: size + 14)
        .accessibilityElement()
        .accessibilityLabel(parameter.name)
        .accessibilityValue(parameter.display(raw))
        .accessibilityAdjustableAction { direction in
            onChange(step(direction == .increment ? 1 : -1))
        }
    }

    private func drag(from position: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { gesture in
                let origin = dragOrigin ?? position
                if dragOrigin == nil { dragOrigin = position }
                let travel = (gesture.translation.width - gesture.translation.height) / 220
                let next = parameter.raw(normalized: origin + travel)
                if next != raw { onChange(next) }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// One click up or down: the next option, or the next raw value.
    private func step(_ delta: Int) -> Int {
        if parameter.kind == .enumeration, let options = parameter.options,
           let index = options.firstIndex(where: { $0.raw == raw }) {
            return options[min(max(index + delta, 0), options.count - 1)].raw
        }
        return parameter.clamp(raw + delta)
    }

    private func arc(from start: Double, to end: Double) -> some Shape {
        Circle()
            .trim(from: start * Self.sweep / 360, to: end * Self.sweep / 360)
            .rotation(.degrees(90 + (360 - Self.sweep) / 2))
    }

    private func valueArc(_ position: Double) -> some Shape {
        if parameter.isBipolar {
            return arc(from: min(0.5, position), to: max(0.5, position))
        }
        return arc(from: 0, to: position)
    }
}

/// The metal stomp switch at the bottom of a pedal.
struct Footswitch: View {
    let isOn: Bool
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.45)],
                                             startPoint: .top, endPoint: .bottom))
                Circle().inset(by: size * 0.16)
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.9)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 3)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: isOn)
        .accessibilityLabel(isOn ? "Switch off" : "Switch on")
    }
}

struct LED: View {
    let isOn: Bool
    var color: Color = Theme.led

    var body: some View {
        Circle()
            .fill(isOn ? color : Color(white: 0.25))
            .frame(width: 9, height: 9)
            .shadow(color: isOn ? color.opacity(0.9) : .clear, radius: 5)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
            .accessibilityHidden(true)
    }
}
