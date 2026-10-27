import SwiftUI

/// Getting to the amp: pair the AIRSTEP Kat over Bluetooth, pick the device,
/// or explore without an amp.
struct ConnectionView: View {
    @Environment(AmpSession.self) private var session
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        ConnectionBadge()
                        Spacer()
                        if case .connecting = session.state { ProgressView() }
                    }
                    if session.state.isLive {
                        Button { Task { await session.refresh() } } label: { Label("Reload from amp", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { session.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    }
                }

                Section {
                    Button { pairing = true } label: { Label("Pair AIRSTEP Kat (Bluetooth)…", systemImage: "dot.radiowaves.left.and.right") }
                    ForEach(session.devices) { device in
                        Button {
                            Task { await session.connect(device) }
                        } label: {
                            HStack {
                                Image(systemName: device.looksLikeKatana ? "guitars" : "pianokeys")
                                Text(device.name)
                                Spacer()
                                if session.state == .connected(device.name) { Image(systemName: "checkmark").foregroundStyle(.green) }
                            }
                        }
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("A Katana plugged in with a USB cable (through Apple's camera adapter) shows up here too.")
                }

                Section("Setting up the AIRSTEP Kat") {
                    StepRow(number: 1, text: "Connect the AIRSTEP Kat to the Katana's USB port with its USB cable, and switch both on.")
                    StepRow(number: 2, text: "Tap Pair AIRSTEP Kat above, choose \"AIRSTEP Kat\" in the list, and wait for Connected. Then tap Done.")
                    StepRow(number: 3, text: "It appears under Devices and the app connects to it. The board then mirrors whatever the amp is playing.")
                    StepRow(number: 4, text: "Close Katana Librarian, BOSS Tone Studio and the AIRSTEP app first: the AIRSTEP talks to one app at a time.")
                }

                Section {
                    Button { session.startDemo() } label: { Label("Explore without an amp", systemImage: "play.rectangle") }
                } footer: {
                    Text("Every pedal and setting works on a copy in the app. Nothing is sent anywhere.")
                }

                Section("About") {
                    Text("For the BOSS Katana MkII on firmware 2. The parameter map comes from Colin Willcocks' KATANA-MK2-FxFloorBoard. Not affiliated with BOSS, Roland or XSONIC.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Amp")
            .sheet(isPresented: $pairing, onDismiss: { session.devicesChanged() }) {
                BluetoothPairingView { pairing = false }
            }
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accent.opacity(0.3)))
            Text(text).font(.subheadline)
        }
    }
}
