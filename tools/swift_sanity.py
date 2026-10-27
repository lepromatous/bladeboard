#!/usr/bin/env python3
"""Static sanity checks on the Swift sources.

There is no Swift toolchain where this app was written, so this stands in
for the compiler on the mistakes careful reading misses: unbalanced
brackets, a type used but never defined or imported, tabs, trailing
whitespace, a file missing an import. It is not a type checker; Xcode is
the authority.

    python3 tools/swift_sanity.py
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = sorted(p for base in ("App", "Core", "Tests") for p in (ROOT / base).rglob("*.swift"))
problems: list[str] = []


def strip_noise(text: str) -> str:
    """Blanks out comments and string literals so the scanners do not trip on
    braces or capitalised words inside them."""
    out = []
    index = 0
    length = len(text)
    while index < length:
        two = text[index:index + 2]
        if two == "//":
            end = text.find("\n", index)
            end = length if end == -1 else end
            out.append(" " * (end - index))
            index = end
        elif two == "/*":
            end = text.find("*/", index + 2)
            end = length if end == -1 else end + 2
            out.append("".join(c if c == "\n" else " " for c in text[index:end]))
            index = end
        elif text[index:index + 4] == '#"""':
            end = text.find('"""#', index + 4)
            end = length if end == -1 else end + 4
            out.append("".join(c if c == "\n" else " " for c in text[index:end]))
            index = end
        elif text[index:index + 2] == '#"':
            end = text.find('"#', index + 2)
            end = length if end == -1 else end + 2
            out.append("".join(c if c == "\n" else " " for c in text[index:end]))
            index = end
        elif text[index:index + 3] == '"""':
            end = text.find('"""', index + 3)
            end = length if end == -1 else end + 3
            out.append("".join(c if c == "\n" else " " for c in text[index:end]))
            index = end
        elif text[index] == '"':
            # Blank the literal, but keep the inside of any \( ... )
            # interpolation, which is real code and may contain its own string
            # literals. Treating it as string text produced false positives.
            out.append(" ")
            index += 1
            while index < length and text[index] != '"':
                if text[index] == "\\" and text[index:index + 2] == "\\(":
                    depth = 1
                    start = index + 2
                    scan = start
                    while scan < length and depth > 0:
                        if text[scan] == "(":
                            depth += 1
                        elif text[scan] == ")":
                            depth -= 1
                        scan += 1
                    out.append("  " + strip_noise(text[start:scan - 1]) + " ")
                    index = scan
                    continue
                if text[index] == "\\":
                    out.append("  ")
                    index += 2
                    continue
                out.append("\n" if text[index] == "\n" else " ")
                index += 1
            if index < length:
                out.append(" ")
                index += 1
        else:
            out.append(text[index])
            index += 1
    return "".join(out)


# Types the project defines itself are discovered; everything else has to be a
# known platform type or it is almost certainly a typo.
PLATFORM = set("""
Int Double Float Bool String Array Set Dictionary Optional Result Void Any AnyObject Character
UInt UInt8 UInt32 UInt64 Int32 Int64 Range ClosedRange Substring Sequence Collection Comparable
Equatable Hashable Codable Encodable Decodable CodingKey CodingKeys Decoder Encoder Identifiable
CaseIterable RawRepresentable Sendable Error LocalizedError CustomStringConvertible Task Never
MainActor Observable Self Swift CheckedContinuation UUID Data Date URL URLRequest URLResponse
HTTPURLResponse JSONEncoder JSONDecoder JSONSerialization UserDefaults Foundation NSObject NSNumber
FileManager DecodingError DispatchQueue Duration ObjectIdentifier Unmanaged UnsafePointer
UnsafeMutablePointer UnsafeMutableRawPointer UnsafeRawPointer UnicodeScalar MemoryLayout
Observation ObservationIgnored ArraySlice CFString DarwinBoolean OSAllocatedUnfairLock Logger
CoreMIDI MIDIClientRef MIDIPortRef MIDIEndpointRef MIDIEntityRef MIDIUniqueID MIDIEventList
MIDIEventPacket MIDISysexSendRequest MIDIClientCreateWithBlock MIDIInputPortCreateWithProtocol
MIDIOutputPortCreate MIDIGetNumberOfSources MIDIGetSource MIDIGetNumberOfDestinations
MIDIGetDestination MIDIEndpointGetEntity MIDIObjectGetIntegerProperty MIDIObjectGetStringProperty
MIDIPortConnectSource MIDIPortDisconnectSource MIDISendSysex MIDIEventListInit MIDIEventListAdd
MIDISendEventList CoreAudioKit CABTMIDICentralViewController UIViewControllerRepresentable
UIViewRepresentable UINavigationController UIBarButtonItem UIAction UniformTypeIdentifiers UTType
CoreTransferable Transferable TransferRepresentation FileRepresentation SentTransferredFile
SharePreview ShareLink WebKit WKWebView WKWebViewConfiguration WKNavigationDelegate
WKDownloadDelegate WKDownload WKNavigation WKNavigationAction WKNavigationResponse
WKNavigationActionPolicy WKNavigationResponsePolicy
SwiftUI View App Scene WindowGroup NavigationStack NavigationLink List Section Text Image Button
Label Toggle Picker Stepper Slider ForEach VStack HStack ZStack LazyVStack LazyVGrid GridItem
Spacer Divider ScrollView TabView Tab Group Color Circle Capsule Rectangle RoundedRectangle Path
Binding State Bindable Environment ViewBuilder ToolbarContentBuilder ToolbarContent ToolbarItem
ToolbarItemGroup Menu ProgressView CGFloat CGRect Font Animation Form TextField Canvas Shape
Gesture DragGesture StrokeStyle LinearGradient RadialGradient ImagePaint AppStorage Content
Context XCTest XCTestCase
""".split())


def main() -> int:
    declared: dict[str, str] = {}
    texts: dict[pathlib.Path, str] = {}

    declaration = re.compile(
        r"\b(?:public\s+|private\s+|internal\s+|fileprivate\s+|final\s+|@\w+\s+)*"
        r"(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w*)"
    )

    for path in SOURCES:
        raw = path.read_text()
        text = strip_noise(raw)
        texts[path] = text

        # --- balance -------------------------------------------------------
        for opener, closer, label in (("{", "}", "braces"), ("(", ")", "parens"), ("[", "]", "brackets")):
            if text.count(opener) != text.count(closer):
                problems.append(
                    f"{path.relative_to(ROOT)}: unbalanced {label} "
                    f"({text.count(opener)} open, {text.count(closer)} close)"
                )

        # --- whitespace hygiene --------------------------------------------
        for number, line in enumerate(raw.splitlines(), 1):
            if "\t" in line:
                problems.append(f"{path.relative_to(ROOT)}:{number}: contains a tab")
            if line.rstrip() != line:
                problems.append(f"{path.relative_to(ROOT)}:{number}: trailing whitespace")

        for name in declaration.findall(text):
            declared[name] = str(path.relative_to(ROOT))

    known = set(declared) | PLATFORM

    # --- capitalised identifiers must resolve -------------------------------
    for path, text in texts.items():
        # Skip member access (.Foo) and labels; only look at bare type positions.
        for match in re.finditer(r"(?<![.\w@])\b([A-Z]\w{2,})\b", text):
            name = match.group(1)
            if name in known or name.startswith("XCTAssert") or name.startswith("XCT"):
                continue
            line = text[:match.start()].count("\n") + 1
            problems.append(f"{path.relative_to(ROOT)}:{line}: unknown type or symbol '{name}'")

    # --- each file imports what it obviously needs --------------------------
    needs = {
        "MIDIUniqueID": "CoreMIDI",
        "MIDIEndpointRef": "CoreMIDI",
        "MIDISend": "CoreMIDI",
        "MIDIClient": "CoreMIDI",
        "CABTMIDI": "CoreAudioKit",
        "WKWebView": "WebKit",
        "XCTAssert": "XCTest",
    }
    for path, text in texts.items():
        imports = set(re.findall(r"^\s*import\s+(\w+)", text, re.M))
        for prefix, module in needs.items():
            if prefix in text and module not in imports:
                problems.append(f"{path.relative_to(ROOT)}: uses {prefix}* but does not import {module}")

    print(f"scanned {len(SOURCES)} swift files, {len(declared)} declared types")
    if problems:
        print(f"\n{len(problems)} PROBLEMS:")
        for problem in problems[:60]:
            print("  -", problem)
        if len(problems) > 60:
            print(f"  ... and {len(problems) - 60} more")
        return 1
    print("no structural problems found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
