"""The cases in Tests/CoreTests.swift, run against the Python model.

    python3 -m pytest tools/reference

Set KATANA_TSL_DIR to a folder of real MkII .tsl files to also check that
every one of them imports and survives an export/import round trip.
"""

import glob
import json
import os

import pytest

from katana_reference import (BYTE_COUNT, CATALOG, FACTORY_CHAIN, REQUEST_SIZE, SECTION_SIZES, Chain,
                              DumpAssembler, Patch, UMPDecoder, address_bytes, address_value, all_parameters,
                              block, data_set, display, is_stored, normalized, parse, patch_offset, raw_at,
                              request, tsl_read, tsl_write, ump_encode_sysex)

TEMP = [0x60, 0x00, 0x00, 0x00]


def memory(slot):
    return [0x10, slot, 0x00, 0x00]


def test_patch_request_matches_captured_bytes():
    assert request(memory(0), REQUEST_SIZE) == [0xF0, 0x41, 0x00, 0x00, 0x00, 0x00, 0x33, 0x11,
                                                0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x48, 0x19, 0xF7]


def test_editor_mode_message():
    assert data_set([0x7F, 0, 0, 1], [1]) == [0xF0, 0x41, 0x00, 0x00, 0x00, 0x00, 0x33, 0x12,
                                              0x7F, 0x00, 0x00, 0x01, 0x01, 0x7F, 0xF7]


def test_parse_round_trips_and_rejects_bad_checksum():
    raw = data_set(patch_offset(TEMP, 0x22), [0x40])
    assert parse(raw) == (0x12, [0x60, 0x00, 0x00, 0x22], [0x40])
    raw[-2] ^= 1
    assert parse(raw) is None


def test_address_arithmetic():
    address = patch_offset(TEMP, 5 * 128 + 0x42)
    assert address == [0x60, 0x00, 0x05, 0x42]
    assert address_bytes(address_value(address)) == address


def test_initial_patch_is_full():
    assert len(Patch.initial().stream()) == 1932
    assert Patch.from_stream(Patch.initial().stream()).bytes == Patch.initial().bytes


def test_name_is_sixteen_padded_characters():
    patch = Patch.initial()
    patch.name = "Brown Sound Extra Long"
    assert patch.name == "Brown Sound Extr"
    patch.name = "Clean"
    assert patch.name == "Clean" and patch[5] == 0x20


def test_two_byte_values():
    time = next(p for p in block("delay1")["types"][0]["params"] if p["name"] == "Time")
    patch = Patch.initial()
    assert patch.set(time, 2000) == [0x0F, 0x50]
    assert patch.raw(time) == 2000
    patch.set(time, 99999)
    assert patch.raw(time) == 2000


def test_whole_patch_is_sixteen_section_writes():
    messages = Patch.initial().messages(memory(3))
    assert [len(m) - 14 for m in messages] == SECTION_SIZES
    assert messages[7][8:12] == [0x10, 0x03, 0x07, 0x00]


def test_every_parameter_lives_in_stored_bytes():
    for p in all_parameters():
        for byte in range(p["size"]):
            assert is_stored(p["offset"] + byte), p
        assert p["min"] <= p["max"], p


def test_blocks():
    ids = [b["chainID"] for b in CATALOG["blocks"]]
    assert len(set(ids)) == len(ids) == 13
    assert len(block("mod")["types"]) == len(block("fx")["types"]) == 31
    assert len(block("booster")["types"]) == 23
    assert len(block("amp")["types"]) == 30


def test_display_matches_the_amp():
    bottom = next(p for p in block("booster")["common"] if p["name"] == "Bottom")
    assert (display(bottom, 0x32), display(bottom, 0x64), display(bottom, 0)) == ("0", "+50", "-50")
    time = next(p for p in block("reverb")["types"][0]["params"] if p["name"] == "Time")
    assert (display(time, 0), display(time, 99)) == ("0.1 sec", "10.0 sec")
    phaser = next(t for t in block("mod")["types"] if t["raw"] == 0x13)
    step = next(p for p in phaser["params"] if p["name"] == "Step Rate")
    assert (display(step, 0), display(step, 1), display(step, 101)) == ("Off", "0", "100")


def test_knob_positions_round_trip():
    for p in all_parameters():
        if p["kind"] == "toggle":
            continue
        for raw in (p["min"], p["max"]):
            assert raw_at(p, normalized(p, raw)) == raw, p["name"]


def test_every_enum_value_has_a_label():
    for p in all_parameters():
        if p["kind"] == "enum":
            assert all(o["label"] for o in p["options"]) or p["name"].startswith("V"), p


def test_factory_chain():
    assert Chain(FACTORY_CHAIN).block_ids() == ["pedalfx", "booster", "mod", "fx", "ns", "eq1", "amp", "eq2",
                                                "footvolume", "sendreturn", "delay1", "delay2", "reverb"]
    assert Chain([0] * 20).ids == FACTORY_CHAIN


def test_move_leaves_plumbing():
    chain = Chain(FACTORY_CHAIN)
    chain.move("reverb", "booster")
    assert chain.block_ids()[:3] == ["pedalfx", "reverb", "booster"]
    for index, chain_id in enumerate(FACTORY_CHAIN):
        if chain_id in (0x11, 0x12, 0x00, 0x03, 0x13, 0x0E, 0x10):
            assert chain.ids[index] == chain_id
    assert sorted(chain.ids) == sorted(FACTORY_CHAIN)


def test_every_single_move_keeps_a_valid_chain():
    for moved in Chain(FACTORY_CHAIN).block_ids():
        for target in Chain(FACTORY_CHAIN).block_ids() + [None]:
            chain = Chain(FACTORY_CHAIN)
            chain.move(moved, target)
            assert sorted(chain.ids) == list(range(20))
            order = chain.block_ids()
            if target and target != moved:
                assert order.index(moved) == order.index(target) - 1
            elif target is None:
                assert order[-1] == moved


def test_write_sets_pre_post_switches():
    patch = Patch.initial()
    chain = Chain(FACTORY_CHAIN)
    chain.move("eq1", None)
    chain.write(patch)
    assert patch.raw(block("eq1")["position"]) == 1
    assert Chain([patch[6 * 128 + i] for i in range(20)]).ids == chain.ids


def test_tsl_round_trip():
    patch = Patch.initial()
    patch[0x21], patch[0x140], patch[0x305] = 0x12, 0x33, 0x07
    entries = tsl_read(tsl_write([("Round Trip", "memo", patch)], "Test"))
    name, memo, back = entries[0]
    assert (name, memo) == ("Round Trip", "memo")
    assert (back[0x21], back[0x140], back[0x305]) == (0x12, 0x33, 0x07)


def test_tsl_rejects_gen3():
    with pytest.raises(ValueError):
        tsl_read('{"device":"KATANA Gen3","data":[[{"paramSet":{"PATCH%AMP":["00"]}}]]}')


def test_ump_round_trip():
    decoder = UMPDecoder()
    for length in (0, 1, 5, 6, 7, 12, 13, 250):
        msg = [0xF0] + [i & 0x7F for i in range(length)] + [0xF7]
        assert decoder.decode(ump_encode_sysex(msg)) == [("sysex", msg)]
    assert decoder.decode([0x20C00400]) == [("pc", 0, 4)]


def test_dump_reassembles():
    assembler = DumpAssembler()
    stream = Patch.initial().stream()
    events = []
    for start in range(0, len(stream), 241):
        chunk = stream[start:start + 241]
        address = address_bytes(address_value(TEMP) + start)
        event = assembler.handle(address, chunk)
        if event:
            events.append(event)
    assert len(events) == 1 and events[0][0] == "patch"
    assert events[0][2].bytes == Patch.initial().bytes
    assert assembler.handle([0x60, 0, 0, 0x22], [0x50]) == ("bytes", [0x60, 0, 0, 0x22], [0x50])


TSL_DIR = os.environ.get("KATANA_TSL_DIR")


@pytest.mark.skipif(not TSL_DIR, reason="set KATANA_TSL_DIR to check real .tsl files")
def test_real_tsl_files():
    files = glob.glob(os.path.join(TSL_DIR, "**", "*.tsl"), recursive=True)
    assert files
    checked = 0
    for path in files:
        text = open(path, encoding="utf-8").read()
        root = json.loads(text)
        if "gen3" in root.get("device", "").lower():
            with pytest.raises(ValueError):
                tsl_read(text)
            continue
        for name, memo, patch in tsl_read(text):
            # The amp type every Tone Studio patch carries must be a known model.
            amp = block("amp")
            assert any(o["raw"] == patch.raw(amp["type"]) for o in amp["type"]["options"]), (path, name)
            assert Chain([patch[6 * 128 + i] for i in range(20)]).ids, (path, name)
            again = tsl_read(tsl_write([(name, memo, patch)], "x"))[0][2]
            assert again.bytes == patch.bytes, (path, name)
            checked += 1
    assert checked
