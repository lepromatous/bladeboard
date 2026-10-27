"""The GuitarPatchesTests cases from Tests/CoreTests.swift."""

from guitarpatches_reference import download_candidates, parse_listing, plain

LISTING = """
<table><tr><td><a href="patches.php?mode=show&amp;unit=KATANAMKII&amp;ID=12485">Gilmour Comfortably Numb</a></td>
<td>by jsmith</td><td>2021-03-12</td></tr>
<tr><td><a href='patches.php?mode=show&unit=KATANAMKII&ID=12724'><b>Any Colour You Like</b></a> - floydfan</td></tr>
<tr><td><a href="patches.php?mode=show&unit=KATANAMKII&ID=12724"><img src="x.png"></a></td></tr></table>
<a href="patches.php?unit=KATANAMKII&amp;page=2">2</a> <a href="patches.php?unit=KATANAMKII&page=3">Next &raquo;</a>
<a href="patches.php?mode=show&unit=katana&ID=14054">A MkI patch</a>
<a href="index.php">Home</a>
"""


def test_listing():
    patches, pages = parse_listing(LISTING)
    assert [p["id"] for p in patches] == [12485, 12724]
    assert [p["title"] for p in patches] == ["Gilmour Comfortably Numb", "Any Colour You Like"]
    assert patches[0]["url"] == "https://guitarpatches.com/patches.php?mode=show&unit=KATANAMKII&ID=12485"
    assert "jsmith" in patches[0]["details"]
    assert pages == ["https://guitarpatches.com/patches.php?unit=KATANAMKII&page=2",
                     "https://guitarpatches.com/patches.php?unit=KATANAMKII&page=3"]


def test_download_candidates():
    page = """<a href="login.php">Log in</a> <a href="download.php?id=12485">Download patch</a>
    <a href="/files/12485/Gilmour.tsl">Gilmour.tsl</a> <a href="patches.php?mode=show&unit=KATANAMKII&ID=1">Other</a>"""
    base = "https://guitarpatches.com/patches.php?mode=show&unit=KATANAMKII&ID=12485"
    assert download_candidates(page, base) == ["https://guitarpatches.com/download.php?id=12485",
                                               "https://guitarpatches.com/files/12485/Gilmour.tsl"]


def test_entities():
    assert plain("AC&#47;DC &amp; <i>Back</i> in&nbsp;Black &#x2013; live") == "AC/DC & Back in Black – live"


ROWS = """
<table class="patches">
<tr onclick="document.location='patches.php?mode=show&amp;unit=KATANAMKII&amp;ID=13001'"><td>Comfortably Numb Solo</td><td>gilmourfan</td><td>2022-05-01</td></tr>
<tr onclick="window.location.href='https://guitarpatches.com/patches.php?mode=show&unit=KATANAMKII&ID=13002';"><td><b>Thunderstruck</b></td><td>acdc</td></tr>
<tr data-href="/patches.php?unit=KATANAMKII&amp;mode=show&amp;ID=13003"><td>Edge of Breakup</td></tr>
</table>
<script>var next = "patches.php?unit=KATANAMKII&start=40";</script>
"""


def test_listing_from_row_handlers():
    patches, pages = parse_listing(ROWS)
    assert [p["id"] for p in patches] == [13001, 13002, 13003]
    assert [p["title"] for p in patches] == ["Comfortably Numb Solo", "Thunderstruck", "Edge of Breakup"]
    assert pages == ["https://guitarpatches.com/patches.php?unit=KATANAMKII&start=40"]
