#!/usr/bin/env python3
"""Builds the Katana MkII effect catalog the app runs on.

Every pedal, effect type and parameter the app can show comes from one file:
Core/Generated/catalog.json. This script produces it (and the Swift file that
embeds it) from the MkII MIDI implementation that ships with Colin Willcocks'
KATANA-MK2-FxFloorBoard editor (midi.xml, GPL-2.0). That file is not checked
in; point this script at a copy of it:

    python3 tools/build_catalog.py path/to/midi.xml path/to/default.syx

midi.xml says *where* each parameter lives and what its values mean. It does
not say which parameters belong to which effect type, or how the amp's blocks
map to pedals on a board. That knowledge is the BLOCKS table below.

Addresses are stored as one integer per parameter: section * 128 + index,
which is the offset inside the patch image. On the wire that is
60 00 <section> <index> for the live (temporary) patch.
"""

import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_JSON = ROOT / "Core" / "Generated" / "catalog.json"
OUT_SWIFT = ROOT / "Core" / "Generated" / "CatalogData.swift"

# Bytes of real data in each of the patch's 16 sections. Sections 07 and 0F
# are short; the rest are full 128-byte pages.
SECTION_SIZES = [128] * 7 + [68] + [128] * 7 + [72]


# ----------------------------------------------------------------- midi.xml

class Leaf:
    """One raw parameter as midi.xml describes it."""

    def __init__(self, section, index, node):
        self.section = section
        self.index = index
        self.node = node
        self.group = (node.attrib.get("desc") or "").strip()
        self.label = (node.attrib.get("customdesc") or "").strip()
        self.children = list(node)

    @property
    def offset(self):
        return self.section * 128 + self.index


def load_leaves(path):
    root = ET.parse(path).getroot()
    leaves = {}
    for page in root.find("Structure"):
        section = int(page.attrib["value"], 16)
        for node in page[0]:
            index = int(node.attrib["value"], 16)
            leaves[(section, index)] = Leaf(section, index, node)
    return leaves


def number(text):
    return float(text.replace("+", ""))


def decimals_of(*texts):
    return max((len(t.split(".")[1]) if "." in t else 0) for t in texts)


def clean(text):
    return re.sub(r"\s+", " ", text or "").strip()


def describe(leaf, name):
    """Turns one midi.xml leaf into a catalog parameter."""
    kids = leaf.children
    param = {"id": f"{leaf.offset:03X}", "name": name, "offset": leaf.offset, "size": 1}

    # Two-byte values (delay times, pre-delays): nested DATA pages, one per
    # MSB, each holding a range for the LSB. The value is MSB * 128 + LSB and
    # is displayed as itself (milliseconds, rpm).
    if kids and kids[0].tag == "DATA":
        first = kids[0][0].attrib["name"].split("/")
        low = int(first[0], 16)
        assert int(number(first[2])) == low, f"{name}: two-byte display must be identity"
        last_page = kids[-1]
        last_msb = int(last_page.attrib["value"], 16)
        top = 0
        unit = clean(kids[0][0].attrib.get("desc"))
        for entry in last_page:
            value = entry.attrib["value"]
            if value == "range":
                top = max(top, int(entry.attrib["name"].split("/")[1], 16))
            else:
                top = max(top, int(value, 16))
        high = last_msb * 128 + top
        param.update(size=2, min=low, max=high, kind="range",
                     lin=lin(low, high, low, high, 0, unit))
        return param

    ranges = [k for k in kids if k.attrib.get("value") == "range"]
    named = [k for k in kids if k.attrib.get("value") != "range"]

    if ranges:
        spec = ranges[0].attrib["name"].split("/")
        r0, r1 = int(spec[0], 16), int(spec[1], 16)
        unit = clean(ranges[0].attrib.get("desc"))
        if unit == "m":
            unit = "ms"
        param.update(kind="range", min=r0, max=r1,
                     lin=lin(r0, r1, number(spec[2]), number(spec[3]), decimals_of(spec[2], spec[3]), unit))
        specials = []
        for k in named:
            raw = int(k.attrib["value"], 16)
            if raw < r0 or raw > r1:
                specials.append({"raw": raw, "label": clean(k.attrib.get("name"))})
        if specials:
            param["special"] = specials
            param["min"] = min([r0] + [s["raw"] for s in specials])
            param["max"] = max([r1] + [s["raw"] for s in specials])
        return param

    options = [{"raw": int(k.attrib["value"], 16), "label": clean(k.attrib.get("name"))} for k in named]
    labels = [o["label"] for o in options]

    # midi.xml spells Drive/Gain as 121 odd strings; the amp and Tone Studio
    # show them as a plain 0-120.
    if len(options) == 121 and name in ("Drive", "Gain"):
        param.update(kind="range", min=0, max=120, lin=lin(0, 120, 0, 120, 0, ""))
        return param

    if labels == ["Off", "On"]:
        param.update(kind="toggle", min=0, max=1)
        return param

    param.update(kind="enum", options=options,
                 min=min(o["raw"] for o in options), max=max(o["raw"] for o in options))
    return param


def lin(r0, r1, v0, v1, dec, unit):
    return {"r0": r0, "r1": r1, "v0": v0, "v1": v1, "dec": dec, "unit": unit}


# ------------------------------------------------------------- pedal layout

# The 31 types the MOD and FX slots can each hold, in midi.xml order, with the
# parameter group prefix each type's settings live under, a short name for
# the pedal face, and the category the pedal case files it under.
MODFX_TYPES = [
    (0x00, "TW", "Touch Wah", "T.WAH", "Filter"),
    (0x01, "AW", "Auto Wah", "A.WAH", "Filter"),
    (0x02, "SWAH", "Pedal Wah", "WAH", "Filter"),
    (0x03, "ACS", "Compressor", "COMP", "Dynamics"),
    (0x04, "LM", "Limiter", "LIMIT", "Dynamics"),
    (0x06, "GEQ", "Graphic EQ", "GEQ", "EQ"),
    (0x07, "PEQ", "Parametric EQ", "PEQ", "EQ"),
    (0x09, "GS", "Guitar Sim", "G.SIM", "Synth & Sim"),
    (0x0A, "SG", "Slow Gear", "SLOW", "Dynamics"),
    (0x0C, "WSY", "Wave Synth", "SYNTH", "Synth & Sim"),
    (0x0E, "OC", "Octave", "OCT", "Pitch"),
    (0x0F, "PS", "Pitch Shifter", "PITCH", "Pitch"),
    (0x10, "HR", "Harmonist", "HARM", "Pitch"),
    (0x12, "AC", "Acoustic Processor", "AC.PRO", "Synth & Sim"),
    (0x13, "PH", "Phaser", "PHASE", "Modulation"),
    (0x14, "FL", "Flanger", "FLANG", "Modulation"),
    (0x15, "TR", "Tremolo", "TREM", "Modulation"),
    (0x16, "RT", "Rotary", "ROTARY", "Modulation"),
    (0x17, "UV", "Uni-V", "UNI-V", "Modulation"),
    (0x19, "SL", "Slicer", "SLICE", "Modulation"),
    (0x1A, "VB", "Vibrato", "VIB", "Modulation"),
    (0x1B, "RM", "Ring Mod", "RING", "Synth & Sim"),
    (0x1C, "HU", "Humanizer", "HUMAN", "Filter"),
    (0x1D, "2CE", "2x2 Chorus", "CHORUS", "Modulation"),
    (0x1F, "AGS", "Acoustic Guitar Sim", "AC.SIM", "Synth & Sim"),
    (0x23, "PH90", "Phaser 90E", "PH-90E", "Modulation"),
    (0x24, "FL117", "Flanger 117E", "FL-117E", "Modulation"),
    (0x25, "WAH95", "Wah 95E", "WAH-95E", "Filter"),
    (0x26, "DC30", "Delay Chorus DC-30", "DC-30", "Modulation"),
    (0x27, "HOC", "Heavy Octave", "H.OCT", "Pitch"),
    (0x28, "PBEND", "Pedal Bend", "BEND", "Pitch"),
]

BOOSTER_CATEGORY = {
    0x00: "Boost", 0x01: "Boost", 0x02: "Boost",
    0x13: "Fuzz", 0x14: "Fuzz", 0x09: "Fuzz",
}

# How the amp's own chain identifiers map to blocks. Identifiers not listed
# here (the split/merge points, the second amp channel, the cab and USB taps)
# are plumbing: they keep their slot and never appear on the board.
CHAIN_IDS = {
    "booster": 0x0F, "mod": 0x05, "fx": 0x06, "delay1": 0x07, "delay2": 0x08,
    "reverb": 0x09, "pedalfx": 0x0B, "eq1": 0x04, "eq2": 0x0A, "ns": 0x0D,
    "sendreturn": 0x01, "footvolume": 0x0C, "amp": 0x02,
}


def leaf_param(leaves, section, index, name=None):
    leaf = leaves[(section, index)]
    return describe(leaf, name or leaf.label)


def run(leaves, section, first, last, renames=None, skip=()):
    """Every named parameter from first..last inclusive in one section."""
    params = []
    for index in range(first, last + 1):
        leaf = leaves.get((section, index))
        if leaf is None or not leaf.children or index in skip:
            continue
        if "(NIU)" in leaf.group or not leaf.label:
            continue
        name = (renames or {}).get(index, leaf.label)
        params.append(describe(leaf, name))
    return params


def number_duplicates(params, mapping=None):
    """Two-voice effects repeat names (Pitch, Pitch); tell them apart."""
    seen = {}
    for p in params:
        seen[p["name"]] = seen.get(p["name"], 0) + 1
    counters = {}
    for p in params:
        if seen[p["name"]] > 1:
            counters[p["name"]] = counters.get(p["name"], 0) + 1
            n = counters[p["name"]]
            if mapping:
                p["name"] = f"{mapping[n - 1]} {p['name']}"
            else:
                p["name"] = f"{p['name']} {n}"
    return params


def modfx_block(leaves, block_id, name, base_section, variation_index, prefix):
    """MOD (sections 1-2) or FX (sections 3-4): 31 types over 256 bytes."""
    # Group every parameter in both pages by its prefix ("MOD PH:").
    groups = {}
    order = []
    for section in (base_section, base_section + 1):
        for index in range(128):
            leaf = leaves.get((section, index))
            if leaf is None or not leaf.children or not leaf.label:
                continue
            group = leaf.group
            if group.startswith("Voice "):
                group = f"{prefix} HR:SCALE"
            if group not in groups:
                groups[group] = []
                order.append(group)
            groups[group].append(leaf)

    def by_prefix(code):
        key = f"{prefix} {code}:"
        # midi.xml labels the MOD side's acoustic guitar sim "ACS" (the same
        # code as the compressor); its FX side says "AGS". Use the page.
        if code == "AGS" and key not in groups:
            return [l for l in groups.get(f"{prefix} ACS:", []) if l.section == base_section + 1]
        if code == "ACS":
            return [l for l in groups.get(key, []) if l.section == base_section]
        return groups.get(key, [])

    types = []
    for raw, code, type_name, short, category in MODFX_TYPES:
        params = [describe(l, l.label) for l in by_prefix(code)]
        if code in ("PS", "HR"):
            for p in params:
                p["name"] = {"Voice 1": "Level 1", "Voice 2": "Level 2"}.get(p["name"], p["name"])
            params = number_duplicates(params)
            for p in params:
                if p["name"] in ("FeedBack", "Feedback"):
                    p["name"] = "Feedback"
        if code == "HR":
            for leaf in groups.get(f"{prefix} HR:SCALE", []):
                voice = "V1" if leaf.group.startswith("Voice 1") else "V2"
                note = leaf.group.split("Scale", 1)[1].strip().replace(" flat", "b")
                params.append(describe(leaf, f"{voice} Scale {note}"))
        if code == "2CE":
            params = number_duplicates(params, ["Low", "High"])
            for p in params:
                p["name"] = {"Low": "Low Level", "High": "High Level"}.get(p["name"], p["name"])
        if code == "DC30":
            params = number_duplicates(params, ["Chorus", "Echo"])
        types.append({"raw": raw, "name": type_name, "short": short, "category": category, "params": params})

    return {
        "id": block_id, "name": name, "category": "Effects", "chainID": CHAIN_IDS[block_id],
        "switch": leaf_param(leaves, base_section, 0x00, "On/Off"),
        "type": leaf_param(leaves, base_section, 0x01, "Type"),
        "variation": leaf_param(leaves, 6, variation_index, "Color"),
        "common": [], "types": types,
    }


def delay_block(leaves, block_id, name, start, variation_index):
    """Delay 1 (05 00) or Delay 2 (05 20). Dual types swap in two lines."""
    def p(index, label=None):
        return leaf_param(leaves, 5, start + index, label)

    single = [p(0x02, "Time"), p(0x04, "Feedback"), p(0x05, "High Cut"),
              p(0x06, "Effect Level"), p(0x07, "Direct Mix"), p(0x08, "Tap Time")]
    dual = [p(0x09, "D1 Time"), p(0x0B, "D1 Feedback"), p(0x0C, "D1 High Cut"), p(0x0D, "D1 Level"),
            p(0x0E, "D2 Time"), p(0x10, "D2 Feedback"), p(0x11, "D2 High Cut"), p(0x12, "D2 Level"),
            p(0x07, "Direct Mix")]
    modulate = [p(0x13, "Mod Rate"), p(0x14, "Mod Depth")]
    vintage = [p(0x15, "Vintage LPF"), p(0x16, "Filter"), p(0x17, "Feedback Phase"),
               p(0x18, "Effect Phase"), p(0x19, "Modulation")]

    type_param = p(0x01, "Type")
    types = []
    for option in type_param["options"]:
        raw = option["raw"]
        if raw in (0x03, 0x04, 0x05):
            params = dual
        elif raw == 0x09:
            params = single + modulate
        elif raw == 0x0A:
            params = single + modulate + vintage
        else:
            params = single
        category = {0x07: "Analog", 0x08: "Tape", 0x0A: "Vintage"}.get(raw, "Digital")
        types.append({"raw": raw, "name": option["label"], "short": option["label"].upper()[:8],
                      "category": category, "params": params})
    block = {
        "id": block_id, "name": name, "category": "Delay", "chainID": CHAIN_IDS[block_id],
        "switch": p(0x00, "On/Off"), "type": type_param, "common": [], "types": types,
    }
    if variation_index is not None:
        block["variation"] = leaf_param(leaves, 6, variation_index, "Color")
    return block


def build(leaves):
    blocks = []

    # Booster: section 00, 0x10-0x1E.
    booster_type = leaf_param(leaves, 0, 0x11, "Type")
    blocks.append({
        "id": "booster", "name": "Booster", "category": "Drive", "chainID": CHAIN_IDS["booster"],
        "switch": leaf_param(leaves, 0, 0x10, "On/Off"),
        "type": booster_type,
        "variation": leaf_param(leaves, 6, 0x39, "Color"),
        "common": [
            leaf_param(leaves, 0, 0x12, "Drive"), leaf_param(leaves, 0, 0x14, "Tone"),
            leaf_param(leaves, 0, 0x17, "Level"), leaf_param(leaves, 0, 0x13, "Bottom"),
            leaf_param(leaves, 0, 0x18, "Direct Mix"),
            leaf_param(leaves, 0, 0x15, "Solo"), leaf_param(leaves, 0, 0x16, "Solo Level"),
        ],
        "advanced": [
            leaf_param(leaves, 0, 0x19, "Custom Type"), leaf_param(leaves, 0, 0x1A, "Custom Bottom"),
            leaf_param(leaves, 0, 0x1B, "Custom Top"), leaf_param(leaves, 0, 0x1C, "Custom Low"),
            leaf_param(leaves, 0, 0x1D, "Custom High"), leaf_param(leaves, 0, 0x1E, "Custom Character"),
        ],
        "types": [
            {"raw": o["raw"], "name": o["label"], "short": o["label"].upper()[:9],
             "category": BOOSTER_CATEGORY.get(o["raw"], "Overdrive" if "OD" in o["label"] or "drive" in o["label"].lower() or "screamer" in o["label"].lower() else "Distortion"),
             "params": []}
            for o in booster_type["options"]
        ],
    })

    # Amp: section 00, 0x20-0x3A, plus the panel-wide bits that shape it.
    amp_type = leaf_param(leaves, 0, 0x21, "Type")
    blocks.append({
        "id": "amp", "name": "Amp", "category": "Amp", "chainID": CHAIN_IDS["amp"],
        "type": amp_type,
        "common": [
            leaf_param(leaves, 0, 0x22, "Gain"), leaf_param(leaves, 0, 0x24, "Bass"),
            leaf_param(leaves, 0, 0x25, "Middle"), leaf_param(leaves, 0, 0x26, "Treble"),
            leaf_param(leaves, 0, 0x27, "Presence"), leaf_param(leaves, 0, 0x28, "Volume"),
            leaf_param(leaves, 0, 0x29, "Bright"), leaf_param(leaves, 0, 0x2A, "Gain SW"),
            leaf_param(leaves, 0, 0x2B, "Solo"), leaf_param(leaves, 0, 0x2C, "Solo Level"),
            leaf_param(leaves, 6, 0x43, "Cab Resonance"),
            leaf_param(leaves, 6, 0x16, "Contour"), leaf_param(leaves, 6, 0x17, "Contour Type"),
            leaf_param(leaves, 6, 0x1A, "Contour Freq"),
            leaf_param(leaves, 5, 0x70, "Patch Level"), leaf_param(leaves, 5, 0x71, "Key"),
        ],
        "advanced": [
            leaf_param(leaves, 0, 0x33, "Custom Type"), leaf_param(leaves, 0, 0x34, "Custom Bottom"),
            leaf_param(leaves, 0, 0x35, "Custom Edge"), leaf_param(leaves, 0, 0x36, "Custom Bass Freq"),
            leaf_param(leaves, 0, 0x37, "Custom Treble Freq"), leaf_param(leaves, 0, 0x38, "Custom Pre Low"),
            leaf_param(leaves, 0, 0x39, "Custom Pre High"), leaf_param(leaves, 0, 0x3A, "Custom Character"),
        ],
        "types": [
            {"raw": o["raw"], "name": o["label"], "short": o["label"].upper()[:12], "category": "Amp", "params": []}
            for o in amp_type["options"]
        ],
    })

    blocks.append(modfx_block(leaves, "mod", "MOD", 1, 0x3A, "MOD"))
    blocks.append(modfx_block(leaves, "fx", "FX", 3, 0x3B, "FX"))
    blocks.append(delay_block(leaves, "delay1", "Delay 1", 0x00, 0x3C))
    blocks.append(delay_block(leaves, "delay2", "Delay 2", 0x20, None))

    reverb_type = leaf_param(leaves, 5, 0x41, "Type")
    reverb_common = [
        leaf_param(leaves, 5, 0x42, "Time"), leaf_param(leaves, 5, 0x43, "Pre Delay"),
        leaf_param(leaves, 5, 0x48, "Effect Level"), leaf_param(leaves, 5, 0x49, "Direct Mix"),
        leaf_param(leaves, 5, 0x45, "Low Cut"), leaf_param(leaves, 5, 0x46, "High Cut"),
        leaf_param(leaves, 5, 0x47, "Density"),
    ]
    blocks.append({
        "id": "reverb", "name": "Reverb", "category": "Reverb", "chainID": CHAIN_IDS["reverb"],
        "switch": leaf_param(leaves, 5, 0x40, "On/Off"), "type": reverb_type,
        "variation": leaf_param(leaves, 6, 0x3D, "Color"),
        # Which of Delay 2 / Reverb the REVERB knob drives, per color.
        "layers": [leaf_param(leaves, 6, 0x36 + i, f"Layer ({c})") for i, c in enumerate(("Green", "Red", "Yellow"))],
        "common": [],
        "types": [
            {"raw": o["raw"], "name": o["label"], "short": o["label"].upper(), "category": "Reverb",
             "params": reverb_common + ([leaf_param(leaves, 5, 0x4B, "Spring Color")] if o["raw"] == 0x05 else [])}
            for o in reverb_type["options"]
        ],
    })

    pedal_type = leaf_param(leaves, 5, 0x51, "Type")
    pedal_params = {
        0x00: run(leaves, 5, 0x52, 0x57, {0x53: "Pedal Pos", 0x54: "Pedal Min", 0x55: "Pedal Max"}),
        0x01: run(leaves, 5, 0x58, 0x5B, {0x5A: "Effect Level"}),
        0x02: run(leaves, 5, 0x5C, 0x60),
    }
    blocks.append({
        "id": "pedalfx", "name": "Pedal FX", "category": "Filter", "chainID": CHAIN_IDS["pedalfx"],
        "switch": leaf_param(leaves, 5, 0x50, "On/Off"), "type": pedal_type,
        "position": leaf_param(leaves, 6, 0x23, "Position"),
        "common": [],
        "types": [
            {"raw": o["raw"], "name": o["label"].title() if o["raw"] == 0 else o["label"],
             "short": o["label"].upper()[:8], "category": "Filter", "params": pedal_params[o["raw"]]}
            for o in pedal_type["options"]
        ],
    })

    for block_id, name, start, position_index in (("eq1", "EQ 1", 0x40, 0x22), ("eq2", "EQ 2", 0x60, 0x19)):
        eq_type = leaf_param(leaves, 0, start + 1, "Type")
        eq_type["options"] = [{"raw": 0, "label": "Parametric"}, {"raw": 1, "label": "Graphic"}]
        blocks.append({
            "id": block_id, "name": name, "category": "EQ", "chainID": CHAIN_IDS[block_id],
            "switch": leaf_param(leaves, 0, start, "On/Off"), "type": eq_type,
            "position": leaf_param(leaves, 6, position_index, "Position"),
            "common": [],
            "types": [
                {"raw": 0, "name": "Parametric EQ", "short": "PEQ", "category": "EQ",
                 "params": run(leaves, 0, start + 2, start + 0x0C, {start + 0x0C: "Level", start + 2: "Low Cut"})},
                {"raw": 1, "name": "Graphic EQ", "short": "GEQ", "category": "EQ",
                 "params": run(leaves, 0, start + 0x0D, start + 0x17)},
            ],
        })

    blocks.append({
        "id": "ns", "name": "Noise Suppressor", "category": "Utility", "chainID": CHAIN_IDS["ns"],
        "switch": leaf_param(leaves, 5, 0x66, "On/Off"),
        "common": [leaf_param(leaves, 5, 0x67, "Threshold"), leaf_param(leaves, 5, 0x68, "Release")],
        "types": [],
    })
    blocks.append({
        "id": "sendreturn", "name": "Send/Return", "category": "Utility", "chainID": CHAIN_IDS["sendreturn"],
        "switch": leaf_param(leaves, 5, 0x62, "On/Off"),
        "position": leaf_param(leaves, 6, 0x21, "Position"),
        "common": [leaf_param(leaves, 5, 0x63, "Mode"), leaf_param(leaves, 5, 0x64, "Send Level"),
                   leaf_param(leaves, 5, 0x65, "Return Level")],
        "types": [],
    })
    blocks.append({
        "id": "footvolume", "name": "Foot Volume", "category": "Utility", "chainID": CHAIN_IDS["footvolume"],
        "common": [leaf_param(leaves, 5, 0x61, "Level")],
        "types": [],
    })

    for block in blocks:
        block.setdefault("advanced", [])
    return blocks


def default_patch(path):
    """The 1932 data bytes of FxFloorBoard's default patch, by section."""
    data = path.read_bytes()
    sections = []
    index = 0
    while index < len(data):
        assert data[index] == 0xF0
        end = data.index(0xF7, index)
        frame = data[index:end + 1]
        sections.append(list(frame[12:-2]))
        index = end + 1
    assert [len(s) for s in sections] == SECTION_SIZES, [len(s) for s in sections]
    return "".join(f"{b:02X}" for section in sections for b in section)


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    leaves = load_leaves(argv[1])
    catalog = {
        "source": "KATANA-MK2-FxFloorBoard midi.xml (Colin Willcocks, GPL-2.0), FW2 map",
        "sectionSizes": SECTION_SIZES,
        "defaultPatch": default_patch(pathlib.Path(argv[2])),
        "blocks": build(leaves),
    }
    text = json.dumps(catalog, indent=1, ensure_ascii=True)
    OUT_JSON.write_text(text + "\n")
    swift = (
        "// Generated by tools/build_catalog.py from catalog.json. Do not edit.\n\n"
        "enum CatalogData {\n"
        "    static let json = #\"\"\"\n"
        f"{text}\n"
        "\"\"\"#\n"
        "}\n"
    )
    OUT_SWIFT.write_text(swift)
    count = sum(len(b["common"]) + len(b["advanced"]) + sum(len(t["params"]) for t in b["types"]) for b in catalog["blocks"])
    print(f"{len(catalog['blocks'])} blocks, {count} parameter slots -> {OUT_JSON.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
