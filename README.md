# Katana Board

An iPhone and iPad editor and librarian for the **BOSS Katana MkII**, laid out
like a real pedalboard. It reaches the amp wirelessly through the **XSONIC
AIRSTEP Kat**'s Bluetooth, or over a USB cable.

- **A board, not a form.** Every block of the amp is a stompbox on a dark
  board, in the order the signal runs through it. Each pedal is painted by
  the kind of effect it holds (green overdrive, orange distortion, blue
  modulation, violet pitch…), with an LED, its three main knobs, and a
  footswitch that turns it on and off.
- **Move pedals to change the sound.** Drag a pedal onto another to put it in
  front of that one, or onto the output jack to send it to the end. Put the
  delay before the drive, the EQ after the amp, the wah after the
  modulation. The amp's 20-slot signal chain is rewritten to match.
- **Every effect, every setting.** Tap a pedal to open all of its settings:
  23 boosters, 30 amp models, 31 MOD/FX types, 11 delays, 7 reverbs, pedal
  wah/bend, both EQs, noise suppressor, send/return and foot volume. Over
  750 parameters in all, including the Harmonist's user scales, the dual
  delay lines, SDE-3000 vintage options and the Custom amp and booster
  settings.
- **A pedal case.** Browse every effect by category (Boost, Overdrive,
  Distortion, Fuzz, Dynamics, Filter, Modulation, Pitch, Synth & Sim, EQ,
  delays, reverbs) and drop one into a slot. The amp has one MOD and one FX
  slot, so a phaser asks which of the two it should take.
- **Green, red, yellow.** Pedals with the MkII's three color variations show
  which one is active and let you switch.
- **Librarian.** See the names of the nine patches stored on the amp, play
  any of them, back them up, write the live sound into a slot, and keep your
  own library of tones on the phone. Import and export BOSS Tone Studio
  `.tsl` files, from Files, Mail, AirDrop or Safari.
- **Get Tones.** The app pulls guitarpatches.com's Katana MkII listing in
  by itself (scroll and it keeps loading more). Tap + to add a patch to your
  library, swipe to add it and play it on the amp at once, or add a whole
  page at once. The site itself is one tap away too, and anything you
  download there also lands in your library.
- **Demo mode.** Everything works without an amp, on a copy in the app.

## Requirements

- iOS or iPadOS 18 or later.
- Xcode 16 or later (the project uses folder-synchronized groups).
- A Katana MkII (50, 100, Head or Artist) on **firmware 2.x**.
- To go wireless: an **AIRSTEP Kat Edition** (or Kat EX) connected to the
  Katana's USB port with its USB cable. A USB cable from the phone to the
  amp (Lightning/USB-C camera adapter) works too.

## Building

1. Open `KatanaBoard.xcodeproj`.
2. Select the **KatanaBoard** target → Signing & Capabilities → choose your
   team. Change the bundle identifier if Xcode asks.
3. Pick your iPhone and press Run.

Bluetooth MIDI doesn't work in the simulator. Use a real device, or use demo
mode in the simulator.

## Connecting through the AIRSTEP Kat

1. Plug the AIRSTEP Kat into the Katana's USB port and switch both on.
2. Close Katana Librarian, BOSS Tone Studio and the AIRSTEP app. The AIRSTEP
   talks to one app at a time.
3. In Katana Board, open the **Amp** tab → **Pair AIRSTEP Kat (Bluetooth)…**,
   tap "AIRSTEP Kat" in the list, wait for *Connected*, and tap Done.
4. It appears under Devices and the app connects to it. The app turns on the
   amp's editor mode and reads the patch it's playing. From then on the board
   follows the amp: turn a knob on the amp, or switch channels with the
   AIRSTEP, and the board updates.

Next time, the app reconnects to the same device by itself.

## Using it

**Board tab.** Knobs: drag up or right to turn up. Footswitch: on/off. Tap
the pedal's name for all of its settings. The channel buttons (A1–A4, PANEL,
B1–B4) switch the amp's channel. **More → Save tone…** stores the live
sound in your library or writes it into one of the amp's slots. **More →
Arrange chain…** is a plain list for precise reordering (and for VoiceOver).
The pedal case (⊞) holds every effect.

Edits go to the amp's live patch, as in Tone Studio. The amp forgets them
when you change channel unless you save them to a slot.

**Library tab.** *On the amp* lists the nine stored patches. Tap one to play
it now, back it up, or write the live sound over it. *My tones* is your
library: tap to play, swipe right to favorite, long-press to rename,
duplicate, share as `.tsl` or delete. Import takes `.tsl` files and this
app's own exports.

**Get Tones tab.** *Discover* lists the Katana MkII patches on
guitarpatches.com, newest pages first as the site orders them. It loads more
as you scroll; pull down to refresh. Tap + to add a patch to *My tones* (a
check mark means it's already there), swipe right to add it and play it on
the amp, or **Add all** to take everything shown. If a patch page has no
file the app can find (say the site wants you signed in), it opens that page
in *Website*. Sign in there once and Discover's downloads use the same
login. Anything you download in *Website* goes into *My tones* as well.

## How it talks to the amp

All of this is Roland SysEx, on MIDI channel 1:

| What | Message |
|---|---|
| Header | `F0 41 00 00 00 00 33` |
| Write (DT1) | `… 12 <address:4> <data> <checksum> F7` |
| Read (RQ1) | `… 11 <address:4> <size:4> <checksum> F7` |
| Editor mode on | `F0 41 00 00 00 00 33 12 7F 00 00 01 01 7F F7` |
| Live patch | `60 00 <section> <index>` |
| Stored patch *n* (0–8) | `10 0n <section> <index>` |
| Signal chain | `60 00 06 00`–`13`, 20 block IDs in signal order |
| Channel select | Program Change 0–8 (A1–A4, PANEL, B1–B4) |

A patch is 16 sections, 1932 bytes. The amp answers a whole-patch read with
about 241-byte chunks, which `DumpAssembler` puts back together. Writes are
coalesced: dragging a knob sends at most one message per ~35 ms, and queued
messages go out with a short gap so the Bluetooth link keeps up.

Every block, type and parameter is in `Core/Generated/catalog.json`.
`tools/build_catalog.py` generates it from the MkII MIDI map that ships with
Colin Willcocks' KATANA-MK2-FxFloorBoard editor (`midi.xml`, GPL-2.0). That
map isn't checked in. The `.tsl` block offsets follow FxFloorBoard's
converter.

## Project layout

```
App/         SwiftUI app: board, pedal editor, pedal case, library, browser,
             CoreMIDI and Bluetooth pairing, AmpSession (the live model)
Core/        Foundation-only: SysEx, patch image, catalog, signal chain,
             .tsl import/export, UMP decoding, tone store
Tests/       XCTest for Core (runs as a macOS bundle, no simulator needed)
Config/      Info.plist additions (.tsl document type)
tools/       catalog generator, project generator, Swift sanity check,
             Python reference model of Core with its own tests
```

## Tests

```
xcodebuild test -project KatanaBoard.xcodeproj -scheme KatanaBoardTests -destination 'platform=macOS'
```

Without Xcode, the Python model of `Core/` runs the same cases:

```
pip install pytest
python3 -m pytest tools/reference
KATANA_TSL_DIR=~/Downloads/tones python3 -m pytest tools/reference   # also checks your own .tsl files
python3 tools/swift_sanity.py
```

## Status and caveats

This was written without a Mac or an amp to hand. Check these on real
hardware first:

- **It has not been compiled yet.** The Swift was checked by hand and with
  `tools/swift_sanity.py`. The protocol logic is mirrored in Python, and those
  tests pass, including an import/export round trip of about 140 real MkII
  Tone Studio patches. Expect a few compile fixes in Xcode, and possibly
  some for the strict-concurrency warnings of newer Swift versions.
- **The AIRSTEP route** relies on the AIRSTEP Kat passing SysEx between a
  Bluetooth MIDI app and the amp. Katana Librarian works the same way.
- **Slot numbers.** The app reads the nine stored patches by memory address
  and labels them Slot 1–9 with their names. It doesn't assume which slot is
  which channel button, so check the names before writing over one.
- **Chains in older patches.** About a third of the downloaded patches tested
  store an all-zero chain, which leaves the amp on its built-in order. The board
  shows those in the standard order, and a real chain is written only if you
  move a pedal.
- **guitarpatches.com** has no API, so Discover reads its HTML loosely (see
  `Core/GuitarPatches.swift`): patches are links to
  `patches.php?mode=show&unit=KATANAMKII&ID=…`, and the file is whichever
  link on the patch page turns out to be a valid `.tsl`. The site couldn't be
  reached from where this was written, so the parser was tested against
  sample HTML only. If the real markup differs, it fails visibly and
  *Website* still works. Zip downloads aren't unpacked yet.
- Not covered yet: the expression pedal, GA-FC and knob assigns (sections
  07–0F), tap tempo, and the global (system) settings.

Not affiliated with BOSS, Roland or XSONIC.
