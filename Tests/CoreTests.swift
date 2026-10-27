import XCTest

final class SysExTests: XCTestCase {
    func testPatchRequestMatchesCapturedBytes() {
        // Captured from FxFloorBoard talking to a MkII.
        let request = RolandMessage.request(.memory(0), size: PatchData.requestSize)
        XCTAssertEqual(request.bytes, [0xF0, 0x41, 0x00, 0x00, 0x00, 0x00, 0x33, 0x11,
                                       0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x48, 0x19, 0xF7])
    }

    func testEditorModeMessage() {
        XCTAssertEqual(RolandMessage.dataSet(.editorMode, [0x01]).bytes,
                       [0xF0, 0x41, 0x00, 0x00, 0x00, 0x00, 0x33, 0x12, 0x7F, 0x00, 0x00, 0x01, 0x01, 0x7F, 0xF7])
    }

    func testParseRoundTripsAndRejectsBadChecksum() {
        let message = RolandMessage.dataSet(KatanaAddress.temporary.patchOffset(0x22), [0x40])
        XCTAssertEqual(RolandMessage(bytes: message.bytes), message)
        var corrupt = message.bytes
        corrupt[corrupt.count - 2] ^= 0x01
        XCTAssertNil(RolandMessage(bytes: corrupt))
    }

    func testRepliesFromAnyDeviceIDAreAccepted() {
        let reply = RolandMessage(command: .dataSet, address: .temporary, data: Array("Clean".utf8), device: 0x10)
        XCTAssertEqual(reply.bytes[2], 0x10)
        XCTAssertEqual(RolandMessage(bytes: reply.bytes)?.device, 0x10)
        XCTAssertEqual(RolandMessage(bytes: reply.bytes)?.data, Array("Clean".utf8))
        XCTAssertEqual(reply.bytes(device: 0x00)[2], 0x00)
    }

    func testAddressArithmetic() {
        let address = KatanaAddress.temporary.patchOffset(5 * 128 + 0x42)
        XCTAssertEqual(address.bytes, [0x60, 0x00, 0x05, 0x42])
        XCTAssertEqual(address.offsetInPatch, 5 * 128 + 0x42)
        XCTAssertEqual(KatanaAddress(value: address.value), address)
        XCTAssertEqual(address.patchBase, .temporary)
    }
}

final class PatchDataTests: XCTestCase {
    func testInitialPatchIsAFullPatch() {
        XCTAssertEqual(PatchData.initial.stream.count, 1932)
        XCTAssertEqual(PatchData(stream: PatchData.initial.stream), PatchData.initial)
    }

    func testNameIsSixteenPaddedCharacters() {
        var patch = PatchData.initial
        patch.name = "Brown Sound Extra Long"
        XCTAssertEqual(patch.name, "Brown Sound Extr")
        patch.name = "Clean"
        XCTAssertEqual(patch.name, "Clean")
        XCTAssertEqual(patch[5], 0x20)
    }

    func testTwoByteValuesSplitIntoSevenBitHalves() throws {
        let delay = try XCTUnwrap(KatanaCatalog.shared.block("delay1"))
        let time = try XCTUnwrap(delay.effectType(raw: 0)?.params.first { $0.name == "Time" })
        var patch = PatchData.initial
        XCTAssertEqual(patch.set(time, raw: 2000), [0x0F, 0x50])
        XCTAssertEqual(patch.raw(time), 2000)
        patch.set(time, raw: 99_999)
        XCTAssertEqual(patch.raw(time), 2000, "values clamp to the parameter's range")
    }

    func testWholePatchIsSixteenSectionWrites() {
        let messages = PatchData.initial.messages(to: .memory(3))
        XCTAssertEqual(messages.map(\.data.count), PatchData.sectionSizes)
        XCTAssertEqual(messages[7].address.bytes, [0x10, 0x03, 0x07, 0x00])
    }

    func testCodableUsesHex() throws {
        let data = try JSONEncoder().encode([PatchData.initial])
        XCTAssertEqual(try JSONDecoder().decode([PatchData].self, from: data), [PatchData.initial])
    }
}

final class CatalogTests: XCTestCase {
    let catalog = KatanaCatalog.shared

    func testEveryParameterLivesInStoredBytes() {
        for parameter in catalog.allParameters {
            for byte in 0..<parameter.size {
                XCTAssertTrue(PatchData.isStored(offset: parameter.offset + byte), "\(parameter.name) at \(parameter.id)")
            }
            XCTAssertLessThanOrEqual(parameter.min, parameter.max, parameter.name)
        }
    }

    func testBlocksMapToDistinctChainSlots() {
        let ids = catalog.blocks.map(\.chainID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(catalog.blocks.count, 13)
    }

    func testModAndFXOfferEveryType() {
        XCTAssertEqual(catalog.block("mod")?.types.count, 31)
        XCTAssertEqual(catalog.block("fx")?.types.count, 31)
        XCTAssertEqual(catalog.block("booster")?.types.count, 23)
        XCTAssertEqual(catalog.block("amp")?.types.count, 30)
    }

    func testDisplayMatchesTheAmp() throws {
        let booster = try XCTUnwrap(catalog.block("booster"))
        let bottom = try XCTUnwrap(booster.common.first { $0.name == "Bottom" })
        XCTAssertEqual(bottom.display(0x32), "0")
        XCTAssertEqual(bottom.display(0x64), "+50")
        XCTAssertEqual(bottom.display(0), "-50")

        let reverb = try XCTUnwrap(catalog.block("reverb")?.effectType(raw: 0))
        let time = try XCTUnwrap(reverb.params.first { $0.name == "Time" })
        XCTAssertEqual(time.display(0), "0.1 sec")
        XCTAssertEqual(time.display(99), "10.0 sec")

        let phaser = try XCTUnwrap(catalog.block("mod")?.effectType(raw: 0x13))
        let step = try XCTUnwrap(phaser.params.first { $0.name == "Step Rate" })
        XCTAssertEqual(step.display(0), "Off")
        XCTAssertEqual(step.display(1), "0")
        XCTAssertEqual(step.display(101), "100")
    }

    func testKnobPositionsRoundTrip() throws {
        for parameter in catalog.allParameters where parameter.kind != .toggle {
            for raw in [parameter.min, parameter.max] {
                XCTAssertEqual(parameter.raw(normalized: parameter.normalized(raw)), raw, parameter.name)
            }
        }
    }
}

final class SignalChainTests: XCTestCase {
    func testFactoryChainShowsThirteenPedals() {
        let chain = SignalChain(ids: SignalChain.factory)
        XCTAssertEqual(chain.blockIDs(), ["pedalfx", "booster", "mod", "fx", "ns", "eq1", "amp", "eq2",
                                          "footvolume", "sendreturn", "delay1", "delay2", "reverb"])
    }

    func testInvalidChainFallsBackToFactory() {
        XCTAssertEqual(SignalChain(ids: [UInt8](repeating: 0, count: 20)).ids, SignalChain.factory)
    }

    func testMovingAPedalLeavesPlumbingInPlace() {
        var chain = SignalChain(ids: SignalChain.factory)
        chain.move("reverb", before: "booster")
        XCTAssertEqual(chain.blockIDs().prefix(3), ["pedalfx", "reverb", "booster"])
        let plumbing: Set<UInt8> = [0x11, 0x12, 0x00, 0x03, 0x13, 0x0E, 0x10]
        for (index, id) in SignalChain.factory.enumerated() where plumbing.contains(id) {
            XCTAssertEqual(chain.ids[index], id)
        }
        XCTAssertEqual(Set(chain.ids), Set(SignalChain.factory))
    }

    func testWritingSetsPrePostAmpSwitches() throws {
        var patch = PatchData.initial
        var chain = SignalChain(ids: SignalChain.factory)
        chain.move("eq1", before: nil)
        chain.write(into: &patch)
        let eq1 = try XCTUnwrap(KatanaCatalog.shared.block("eq1")?.position)
        XCTAssertEqual(patch.raw(eq1), 1, "EQ 1 now sits after the amp")
        XCTAssertEqual(SignalChain(patch: patch), chain)
    }
}

final class TSLTests: XCTestCase {
    func testWriteThenReadKeepsThePatch() throws {
        var patch = PatchData.initial
        patch.name = "Round Trip"
        patch[0x21] = 0x12
        patch[0x100 + 0x40] = 0x33
        patch[0x300 + 0x05] = 0x07
        let data = TSL.write([TSL.Entry(name: "Round Trip", memo: "memo", patch: patch)], fileName: "Test")
        let entries = try TSL.read(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Round Trip")
        XCTAssertEqual(entries[0].memo, "memo")
        XCTAssertEqual(entries[0].patch[0x21], 0x12)
        XCTAssertEqual(entries[0].patch[0x140], 0x33)
        XCTAssertEqual(entries[0].patch[0x305], 0x07)
    }

    func testRejectsGen3Files() {
        let json = #"{"device":"KATANA Gen3","data":[[{"paramSet":{"PATCH%AMP":["00"]}}]]}"#
        XCTAssertThrowsError(try TSL.read(Data(json.utf8)))
    }

    func testReadsOldShortBlocks() throws {
        // formatRev 0001 files carry a 50-byte Patch_1 that fits one section.
        let bytes = (0..<50).map { String(format: "\"%02X\"", $0) }.joined(separator: ",")
        let json = #"{"device":"KATANA MkII","data":[[{"memo":"","paramSet":{"UserPatch%Patch_1":[\#(bytes)]}}]]}"#
        let patch = try TSL.read(Data(json.utf8))[0].patch
        XCTAssertEqual(patch[0x2C0 + 49], 49)
    }
}

final class MIDIInboundTests: XCTestCase {
    func testUMPSysExRoundTrip() {
        var decoder = UMPDecoder()
        for length in [0, 1, 5, 6, 7, 12, 13, 250] {
            let message = [0xF0] + (0..<length).map { UInt8($0 & 0x7F) } + [0xF7]
            XCTAssertEqual(decoder.decode(UMPDecoder.encodeSysex(message)), [.sysex(message)], "length \(length)")
        }
    }

    func testProgramChange() {
        var decoder = UMPDecoder()
        XCTAssertEqual(decoder.decode([0x20C0_0400]), [.programChange(channel: 0, program: 4)])
    }

    func testDumpReassemblesFromAmpSizedChunks() {
        var assembler = DumpAssembler()
        let stream = PatchData.initial.stream
        var events: [DumpAssembler.Event] = []
        var cursor = 0
        while cursor < stream.count {
            let end = min(cursor + 241, stream.count)
            let message = RolandMessage.dataSet(KatanaAddress(value: KatanaAddress.temporary.value + cursor),
                                                Array(stream[cursor..<end]))
            if let event = assembler.handle(message) { events.append(event) }
            cursor = end
        }
        XCTAssertEqual(events, [.patch(base: .temporary, PatchData.initial)])
    }

    func testSectionSizedRepliesApplyByAddress() {
        var assembler = DumpAssembler()
        let section = Array(PatchData.initial.stream.prefix(128))
        let message = RolandMessage.dataSet(.temporary, section)
        XCTAssertEqual(assembler.handle(message), .bytes(address: .temporary, section))
    }

    func testSmallReportsApplyByAddress() {
        var assembler = DumpAssembler()
        let message = RolandMessage.dataSet(KatanaAddress.temporary.patchOffset(0x22), [0x50])
        XCTAssertEqual(assembler.handle(message), .bytes(address: message.address, [0x50]))
    }
}

final class ToneStoreTests: XCTestCase {
    func testSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ToneStore(url: url)
        let tones = [Tone(name: "Lead", patch: .initial, created: Date(timeIntervalSince1970: 1_700_000_000), source: "test")]
        try store.save(tones)
        XCTAssertEqual(store.load(), tones)
    }
}

final class GuitarPatchesTests: XCTestCase {
    static let listing = """
    <table><tr><td><a href="patches.php?mode=show&amp;unit=KATANAMKII&amp;ID=12485">Gilmour Comfortably Numb</a></td>
    <td>by jsmith</td><td>2021-03-12</td></tr>
    <tr><td><a href='patches.php?mode=show&unit=KATANAMKII&ID=12724'><b>Any Colour You Like</b></a> - floydfan</td></tr>
    <tr><td><a href="patches.php?mode=show&unit=KATANAMKII&ID=12724"><img src="x.png"></a></td></tr></table>
    <a href="patches.php?unit=KATANAMKII&amp;page=2">2</a> <a href="patches.php?unit=KATANAMKII&page=3">Next &raquo;</a>
    <a href="patches.php?mode=show&unit=katana&ID=14054">A MkI patch</a>
    <a href="index.php">Home</a>
    """

    func testListingFindsMkIIPatchesAndPages() {
        let page = GuitarPatches.parseListing(Self.listing)
        XCTAssertEqual(page.patches.map(\.id), [12485, 12724])
        XCTAssertEqual(page.patches.map(\.title), ["Gilmour Comfortably Numb", "Any Colour You Like"])
        XCTAssertEqual(page.patches[0].url.absoluteString,
                       "https://guitarpatches.com/patches.php?mode=show&unit=KATANAMKII&ID=12485")
        XCTAssertTrue(page.patches[0].details.contains("jsmith"))
        XCTAssertEqual(page.pages.map(\.absoluteString), [
            "https://guitarpatches.com/patches.php?unit=KATANAMKII&page=2",
            "https://guitarpatches.com/patches.php?unit=KATANAMKII&page=3",
        ])
    }

    func testDownloadCandidatesPreferFileLinks() {
        let html = """
        <a href="login.php">Log in</a> <a href="download.php?id=12485">Download patch</a>
        <a href="/files/12485/Gilmour.tsl">Gilmour.tsl</a> <a href="patches.php?mode=show&unit=KATANAMKII&ID=1">Other</a>
        """
        let base = URL(string: "https://guitarpatches.com/patches.php?mode=show&unit=KATANAMKII&ID=12485")!
        XCTAssertEqual(GuitarPatches.downloadCandidates(html, baseURL: base).map(\.absoluteString), [
            "https://guitarpatches.com/download.php?id=12485",
            "https://guitarpatches.com/files/12485/Gilmour.tsl",
        ])
    }

    func testListingFromRowHandlers() {
        let html = """
        <table class="patches">
        <tr onclick="document.location='patches.php?mode=show&amp;unit=KATANAMKII&amp;ID=13001'"><td>Comfortably Numb Solo</td><td>gilmourfan</td><td>2022-05-01</td></tr>
        <tr onclick="window.location.href='https://guitarpatches.com/patches.php?mode=show&unit=KATANAMKII&ID=13002';"><td><b>Thunderstruck</b></td><td>acdc</td></tr>
        <tr data-href="/patches.php?unit=KATANAMKII&amp;mode=show&amp;ID=13003"><td>Edge of Breakup</td></tr>
        </table>
        <script>var next = "patches.php?unit=KATANAMKII&start=40";</script>
        """
        let page = GuitarPatches.parseListing(html)
        XCTAssertEqual(page.patches.map(\.id), [13001, 13002, 13003])
        XCTAssertEqual(page.patches.map(\.title), ["Comfortably Numb Solo", "Thunderstruck", "Edge of Breakup"])
        XCTAssertEqual(page.pages.map(\.absoluteString), ["https://guitarpatches.com/patches.php?unit=KATANAMKII&start=40"])
    }

    func testEntities() {
        XCTAssertEqual(GuitarPatches.plainText("AC&#47;DC &amp; <i>Back</i> in&nbsp;Black &#x2013; live"), "AC/DC & Back in Black – live")
    }
}
