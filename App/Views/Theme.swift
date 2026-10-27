import SwiftUI

/// Colors and finishes for the board. Each pedal takes its color from what
/// kind of effect it currently holds, the way real pedals are color-coded.
enum Theme {
    static let board = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let rail = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let cream = Color(red: 0.95, green: 0.92, blue: 0.84)
    static let led = Color(red: 1.0, green: 0.18, blue: 0.12)
    static let accent = Color(red: 1.0, green: 0.55, blue: 0.1)

    static func color(for category: String) -> Color {
        switch category {
        case "Boost": return Color(red: 0.93, green: 0.77, blue: 0.20)
        case "Overdrive": return Color(red: 0.16, green: 0.62, blue: 0.36)
        case "Distortion": return Color(red: 0.93, green: 0.45, blue: 0.13)
        case "Fuzz": return Color(red: 0.70, green: 0.20, blue: 0.33)
        case "Amp": return Color(red: 0.16, green: 0.15, blue: 0.14)
        case "Modulation": return Color(red: 0.18, green: 0.48, blue: 0.86)
        case "Filter": return Color(red: 0.86, green: 0.33, blue: 0.58)
        case "Dynamics": return Color(red: 0.21, green: 0.69, blue: 0.74)
        case "Pitch": return Color(red: 0.47, green: 0.36, blue: 0.86)
        case "EQ": return Color(red: 0.70, green: 0.72, blue: 0.75)
        case "Synth & Sim": return Color(red: 0.93, green: 0.60, blue: 0.16)
        case "Digital": return Color(red: 0.27, green: 0.66, blue: 0.62)
        case "Analog": return Color(red: 0.47, green: 0.31, blue: 0.19)
        case "Tape": return Color(red: 0.77, green: 0.64, blue: 0.41)
        case "Vintage": return Color(red: 0.36, green: 0.39, blue: 0.44)
        case "Reverb": return Color(red: 0.14, green: 0.25, blue: 0.52)
        default: return Color(red: 0.36, green: 0.38, blue: 0.41)
        }
    }

    /// Black or white text, whichever reads on the pedal's paint.
    static func ink(for category: String) -> Color {
        switch category {
        case "Boost", "EQ", "Tape", "Synth & Sim": return Color.black.opacity(0.85)
        default: return .white
        }
    }

    static let categoryOrder = ["Boost", "Overdrive", "Distortion", "Fuzz", "Dynamics", "Filter",
                                "Modulation", "Pitch", "Synth & Sim", "EQ", "Digital", "Analog",
                                "Tape", "Vintage", "Reverb", "Utility"]

    static func symbol(for category: String) -> String {
        switch category {
        case "Boost", "Overdrive", "Distortion", "Fuzz": return "flame"
        case "Modulation": return "water.waves"
        case "Filter": return "waveform.path"
        case "Dynamics": return "rectangle.compress.vertical"
        case "Pitch": return "arrow.up.arrow.down"
        case "EQ": return "slider.vertical.3"
        case "Synth & Sim": return "pianokeys"
        case "Digital", "Analog", "Tape", "Vintage": return "repeat"
        case "Reverb": return "dot.radiowaves.left.and.right"
        default: return "switch.2"
        }
    }

    /// The three color variations the MkII stores per effect knob.
    static let variations: [(raw: Int, name: String, color: Color)] = [
        (1, "Green", Color(red: 0.2, green: 0.85, blue: 0.35)),
        (0, "Red", Color(red: 0.95, green: 0.2, blue: 0.2)),
        (2, "Yellow", Color(red: 0.98, green: 0.82, blue: 0.15)),
    ]
}

extension AmpSession {
    /// The category a block's pedal is painted as right now.
    func paint(_ block: BlockDef) -> String {
        switch block.id {
        case "amp": return "Amp"
        case "ns", "sendreturn", "footvolume": return "Utility"
        default: return currentType(block)?.category ?? block.category
        }
    }
}
