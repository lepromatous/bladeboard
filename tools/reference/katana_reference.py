"""A line-for-line Python model of Core/, for checking it without Xcode.

The Swift in Core/ is the real implementation. This mirrors the parts with
arithmetic in them (addresses, checksums, the patch image, the chain, .tsl
blocks, UMP SysEx) so test_katana_reference.py can run the same cases as
Tests/CoreTests.swift anywhere Python runs.
"""

import json
import pathlib

CATALOG = json.loads((pathlib.Path(__file__).resolve().parents[2] / "Core" / "Generated" / "catalog.json").read_text())
SECTION_SIZES = [128] * 7 + [68] + [128] * 7 + [72]
BYTE_COUNT = sum(SECTION_SIZES)
REQUEST_SIZE = 15 * 128 + 72
HEADER = [0xF0, 0x41, 0x00, 0x00, 0x00, 0x00, 0x33]


# ------------------------------------------------------------------ SysEx

def address_bytes(value):
    return [(value >> 21) & 0x7F, (value >> 14) & 0x7F, (value >> 7) & 0x7F, value & 0x7F]


def address_value(b):
    return (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3]


def checksum(data):
    total = 0
    for byte in data:
        total = (total + byte) & 0x7F
    return (128 - total) & 0x7F


def message(command, address, data):
    body = list(address) + list(data)
    return HEADER + [command] + body + [checksum(body), 0xF7]


def request(address, size):
    return message(0x11, address, address_bytes(size))


def data_set(address, data):
    return message(0x12, address, data)


def parse(raw):
    if len(raw) < 15 or raw[-1] != 0xF7 or raw[:7] != HEADER or raw[7] not in (0x11, 0x12):
        return None
    address, data = raw[8:12], raw[12:-2]
    if checksum(address + data) != raw[-2]:
        return None
    return raw[7], address, data


def patch_offset(base, offset):
    return [base[0], base[1], offset >> 7, offset & 0x7F]


# ------------------------------------------------------------ patch image

def is_stored(offset):
    section = offset >> 7
    return 0 <= section < 16 and (offset & 0x7F) < SECTION_SIZES[section]


class Patch:
    def __init__(self, image=None):
        self.bytes = list(image) if image else [0] * (16 * 128)

    @classmethod
    def from_stream(cls, stream):
        assert len(stream) >= BYTE_COUNT
        patch, cursor = cls(), 0
        for section, size in enumerate(SECTION_SIZES):
            for index in range(size):
                patch.bytes[section * 128 + index] = stream[cursor] & 0x7F
                cursor += 1
        return patch

    @classmethod
    def initial(cls):
        hex_text = CATALOG["defaultPatch"]
        return cls.from_stream([int(hex_text[i:i + 2], 16) for i in range(0, len(hex_text), 2)])

    def stream(self):
        out = []
        for section, size in enumerate(SECTION_SIZES):
            out += self.bytes[section * 128:section * 128 + size]
        return out

    def __getitem__(self, offset):
        return self.bytes[offset]

    def __setitem__(self, offset, value):
        if is_stored(offset):
            self.bytes[offset] = value & 0x7F

    def write(self, data, offset):
        for i, byte in enumerate(data):
            self[offset + i] = byte

    def raw(self, p):
        if p["size"] == 2:
            return self.bytes[p["offset"]] * 128 + self.bytes[p["offset"] + 1]
        return self.bytes[p["offset"]]

    def set(self, p, raw):
        value = min(max(raw, p["min"]), p["max"])
        encoded = [(value >> 7) & 0x7F, value & 0x7F] if p["size"] == 2 else [value & 0x7F]
        self.write(encoded, p["offset"])
        return encoded

    @property
    def name(self):
        return "".join(chr(b) if 0x20 <= b <= 0x7E else " " for b in self.bytes[:16]).strip()

    @name.setter
    def name(self, text):
        ascii_bytes = [ord(c) if 0x20 <= ord(c) <= 0x7E else 0x20 for c in text]
        for i, byte in enumerate((ascii_bytes + [0x20] * 16)[:16]):
            self.bytes[i] = byte

    def messages(self, base):
        return [data_set(patch_offset(base, s * 128), self.bytes[s * 128:s * 128 + size])
                for s, size in enumerate(SECTION_SIZES)]


# -------------------------------------------------------------- catalog

def block(block_id):
    return next(b for b in CATALOG["blocks"] if b["id"] == block_id)


def block_by_chain(chain_id):
    return next((b for b in CATALOG["blocks"] if b["chainID"] == chain_id), None)


def all_parameters():
    seen, out = set(), []
    for b in CATALOG["blocks"]:
        params = [b.get(k) for k in ("switch", "type", "variation", "position")]
        params += b.get("layers") or []
        params += b["common"] + b["advanced"]
        for t in b["types"]:
            params += t["params"]
        for p in params:
            if p and p["offset"] not in seen:
                seen.add(p["offset"])
                out.append(p)
    return out


def display(p, raw):
    for s in p.get("special") or []:
        if s["raw"] == raw:
            return s["label"]
    if p["kind"] == "toggle":
        return "Off" if raw == 0 else "On"
    if p["kind"] == "enum":
        return next((o["label"] for o in p["options"] if o["raw"] == raw), str(raw))
    lin = p["lin"]
    value = lin["v0"] if lin["r1"] == lin["r0"] else lin["v0"] + (raw - lin["r0"]) * (lin["v1"] - lin["v0"]) / (lin["r1"] - lin["r0"])
    text = f"{value:.{lin['dec']}f}"
    if lin["v0"] < 0 and value > 0:
        text = "+" + text
    if text == "-0":
        text = "0"
    if not lin["unit"]:
        return text
    return text + "%" if lin["unit"] == "%" else text + " " + lin["unit"]


def normalized(p, raw):
    if p["kind"] == "enum":
        index = next(i for i, o in enumerate(p["options"]) if o["raw"] == raw)
        return index / (len(p["options"]) - 1) if len(p["options"]) > 1 else 0
    if p["max"] <= p["min"]:
        return 0
    return (min(max(raw, p["min"]), p["max"]) - p["min"]) / (p["max"] - p["min"])


def raw_at(p, t):
    t = min(max(t, 0), 1)
    if p["kind"] == "enum":
        return p["options"][round(t * (len(p["options"]) - 1))]["raw"]
    return min(max(p["min"] + round(t * (p["max"] - p["min"])), p["min"]), p["max"])


# ---------------------------------------------------------------- chain

CHAIN_OFFSET = 6 * 128
FACTORY_CHAIN = [0x11, 0x0B, 0x0F, 0x05, 0x06, 0x0D, 0x04, 0x02, 0x0A, 0x0C,
                 0x01, 0x07, 0x08, 0x09, 0x12, 0x00, 0x03, 0x13, 0x0E, 0x10]


class Chain:
    def __init__(self, ids):
        self.ids = list(ids) if len(ids) == 20 and set(ids) == set(range(20)) else list(FACTORY_CHAIN)

    def block_ids(self):
        return [b["id"] for b in (block_by_chain(i) for i in self.ids) if b]

    def arrange(self, order):
        current = self.block_ids()
        wanted = [i for i in order if i in current]
        wanted += [i for i in current if i not in wanted]
        queue = [block(i)["chainID"] for i in wanted]
        self.ids = [queue.pop(0) if block_by_chain(i) and queue else i for i in self.ids]

    def move(self, moved, before):
        order = self.block_ids()
        if moved not in order or moved == before:
            return
        order.remove(moved)
        if before in order:
            order.insert(order.index(before), moved)
        else:
            order.append(moved)
        self.arrange(order)

    def write(self, patch):
        patch.write(self.ids, CHAIN_OFFSET)
        amp = self.ids.index(0x02)
        reverb = self.ids.index(0x09)
        for block_id in ("eq1", "eq2", "pedalfx"):
            b = block(block_id)
            patch.set(b["position"], 1 if self.ids.index(b["chainID"]) > amp else 0)
        loop = block("sendreturn")
        patch.set(loop["position"], 1 if self.ids.index(loop["chainID"]) > reverb else 0)


# ------------------------------------------------------------------ TSL

TSL_BLOCKS = [
    ("PatchName", 0x000, 16, None, None), ("Patch_0", 0x010, 72, None, None),
    ("Eq(2)", 0x060, 24, None, None), ("Fx(1)", 0x080, 225, 128, 0x100), ("Fx(2)", 0x180, 225, 128, 0x200),
    ("Delay(1)", 0x280, 26, None, None), ("Delay(2)", 0x2A0, 26, None, None),
    ("Patch_1", 0x2C0, 91, 64, 0x300), ("Patch_2", 0x320, 36, None, None), ("Status", 0x350, 18, None, None),
    ("KnobAsgn", 0x380, 34, None, None), ("ExpPedalAsgn", 0x400, 34, None, None),
    ("ExpPedalAsgnMinMax", 0x430, 78, None, None), ("GafcExp1Asgn", 0x480, 34, None, None),
    ("GafcExp1AsgnMinMax", 0x4B0, 78, None, None), ("GafcExp2Asgn", 0x500, 34, None, None),
    ("GafcExp2AsgnMinMax", 0x530, 78, None, None), ("FsAsgn", 0x788, 2, None, None),
    ("Patch_Mk2V2", 0x790, 22, None, None), ("Contour(1)", 0x7AE, 2, None, None),
    ("Contour(2)", 0x7B6, 2, None, None), ("Contour(3)", 0x7BE, 2, None, None),
]


def tsl_read(text, base=None):
    root = json.loads(text)
    device = root.get("device", "")
    if "gen3" in device.lower() or "gen 3" in device.lower():
        raise ValueError("gen3")
    entries = []
    for group in root.get("data", []):
        for item in (group if isinstance(group, list) else [group]):
            params = item.get("paramSet")
            if params is None:
                continue
            if any(k.startswith("PATCH%") for k in params):
                raise ValueError("gen3")
            patch = Patch((base or Patch.initial()).bytes)
            for name, offset, _, split, continuation in TSL_BLOCKS:
                values = params.get(f"UserPatch%{name}")
                if values is None:
                    continue
                data = [int(v, 16) for v in values]
                if split and len(data) > split:
                    patch.write(data[:split], offset)
                    patch.write(data[split:], continuation)
                else:
                    patch.write(data, offset)
            entries.append((patch.name, item.get("memo", ""), patch))
    if not entries:
        raise ValueError("empty")
    return entries


def tsl_write(entries, file_name):
    patches = []
    for name, memo, patch in entries:
        patch = Patch(patch.bytes)
        patch.name = name
        param_set = {}
        for block_name, offset, length, split, continuation in TSL_BLOCKS:
            first = split or length
            data = [patch[offset + i] for i in range(first)]
            if continuation:
                data += [patch[continuation + i] for i in range(length - first)]
            param_set[f"UserPatch%{block_name}"] = [f"{b:02X}" for b in data]
        patches.append({"memo": memo, "paramSet": param_set})
    return json.dumps({"name": file_name, "formatRev": "0002", "device": "KATANA MkII", "data": [patches]})


# ------------------------------------------------------------------ UMP

def ump_encode_sysex(msg):
    payload = msg[1:-1] if msg and msg[0] == 0xF0 else list(msg)
    chunks = [payload[i:i + 6] for i in range(0, max(len(payload), 1), 6)]
    words = []
    for index, chunk in enumerate(chunks):
        if len(chunks) == 1:
            status = 0
        elif index == 0:
            status = 1
        elif index == len(chunks) - 1:
            status = 3
        else:
            status = 2
        b = chunk + [0] * (6 - len(chunk))
        words.append((0x3 << 28) | (status << 20) | (len(chunk) << 16) | (b[0] << 8) | b[1])
        words.append((b[2] << 24) | (b[3] << 16) | (b[4] << 8) | b[5])
    return words


WORD_COUNTS = {0: 1, 1: 1, 2: 1, 6: 1, 7: 1, 3: 2, 4: 2, 8: 2, 9: 2, 10: 2, 11: 3, 12: 3}


class UMPDecoder:
    def __init__(self):
        self.buffer, self.collecting = [], False

    def decode(self, words):
        out, i = [], 0
        while i < len(words):
            word = words[i]
            kind = word >> 28
            if kind == 2:
                status, channel = (word >> 16) & 0xF0, (word >> 16) & 0x0F
                if status == 0xC0:
                    out.append(("pc", channel, (word >> 8) & 0x7F))
            elif kind == 3 and i + 1 < len(words):
                second = words[i + 1]
                status, count = (word >> 20) & 0xF, (word >> 16) & 0xF
                data = [(word >> 8) & 0xFF, word & 0xFF, second >> 24, (second >> 16) & 0xFF,
                        (second >> 8) & 0xFF, second & 0xFF][:min(count, 6)]
                if status == 0:
                    out.append(("sysex", [0xF0] + data + [0xF7]))
                    self.collecting = False
                elif status == 1:
                    self.buffer, self.collecting = data, True
                elif status == 2 and self.collecting:
                    self.buffer += data
                elif status == 3:
                    if self.collecting:
                        out.append(("sysex", [0xF0] + self.buffer + data + [0xF7]))
                    self.collecting, self.buffer = False, []
            i += WORD_COUNTS.get(kind, 4)
        return out


class DumpAssembler:
    THRESHOLD = 64

    def __init__(self):
        self.base, self.buffer = None, []

    def handle(self, address, data):
        base = address[:2]
        offset = (address[2] << 7) | address[3]
        if self.base == base:
            self.buffer += data
            if len(self.buffer) >= BYTE_COUNT:
                patch, self.base, self.buffer = Patch.from_stream(self.buffer), None, []
                return ("patch", base, patch)
            return None
        if offset == 0 and len(data) > self.THRESHOLD:
            self.base, self.buffer = base, list(data)
            return None
        return ("bytes", address, data)
