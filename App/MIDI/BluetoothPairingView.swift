import CoreAudioKit
import SwiftUI

/// Apple's Bluetooth MIDI device picker. Connecting the AIRSTEP Kat here makes
/// it an ordinary CoreMIDI device; MIDIConnection then finds it by name.
struct BluetoothPairingView: UIViewControllerRepresentable {
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let picker = CABTMIDICentralViewController()
        picker.title = "Bluetooth MIDI"
        picker.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { _ in onDone() })
        return UINavigationController(rootViewController: picker)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
