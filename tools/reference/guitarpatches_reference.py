"""Python model of Core/GuitarPatches.swift, for checking its regexes here."""

import html as html_lib
import re
from urllib.parse import parse_qsl, urljoin, urlparse

UNIT = "KATANAMKII"
LISTING = f"https://guitarpatches.com/patches.php?unit={UNIT}"
LINK = re.compile(r"""<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>""", re.I | re.S)
ENTITIES = [("&amp;", "&"), ("&quot;", '"'), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")]


def decode(text):
    for entity, value in ENTITIES:
        text = text.replace(entity, value)
    return re.sub(r"&#(x?[0-9a-fA-F]+);", lambda m: chr(int(m.group(1)[1:], 16) if m.group(1)[0] in "xX" else int(m.group(1))), text)


def plain(text):
    return re.sub(r"\s+", " ", decode(re.sub(r"<[^>]+>", " ", text))).strip()


BARE = re.compile(r"""(?:https?://[^"'\s<>]*?/)?[\w./-]*patches\.php\?[^"'\s<>)\\]+""", re.I)


def links(page):
    """(href, text, trailing, is_anchor) for every anchor, then every bare URL."""
    matches = list(LINK.finditer(page))
    out = []
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else min(len(page), m.end() + 400)
        out.append((decode(m.group(1)), plain(m.group(2)), plain(page[m.end():min(end, m.end() + 400)]), True))
    for m in BARE.finditer(page):
        tag_end = page.find(">", m.end())
        start = m.end() if tag_end == -1 else tag_end + 1
        after = page[start:start + 600]
        cell = after.split("</")[0]
        out.append((decode(m.group(0)), plain(cell)[:80], plain(after[len(cell):]), False))
    return out


def query(url):
    return {k.lower(): v for k, v in parse_qsl(urlparse(url).query, keep_blank_values=True)}


def parse_listing(page, base=LISTING):
    patches, order, pages, titled = {}, [], [], set()
    for href, text, trailing, is_anchor in links(page):
        url = urljoin(base, href)
        q = query(url)
        is_unit = q.get("unit", "").lower() == UNIT.lower()
        if is_unit and q.get("mode", "").lower() == "show" and q.get("id", "").isdigit():
            pid = int(q["id"])
            if pid in patches:
                existing = patches[pid]
                if is_anchor and text and (len(text) > len(existing["title"]) or pid not in titled):
                    existing["title"] = text
                    titled.add(pid)
                elif not existing["title"]:
                    existing["title"] = text
            else:
                patches[pid] = {"id": pid, "title": text, "url": url, "details": trailing[:80].strip(" -|·:,")}
                order.append(pid)
                if is_anchor and text:
                    titled.add(pid)
        elif is_unit and "mode" not in q and any(k in q for k in ("page", "start", "p", "pg", "offset", "pagina")) and url not in pages:
            pages.append(url)
    return [patches[i] for i in order], pages


def download_candidates(page, base):
    scored = []
    for href, text, _, _ in links(page):
        url = urljoin(base, href)
        if not url.startswith("http"):
            continue
        h, t = href.lower(), text.lower()
        score = (4 if urlparse(url).path.lower().endswith(".tsl") or ".tsl" in h else 0) + (3 if "download" in h else 0) + (2 if "download" in t else 0)
        if "mode=show" in h or "login" in h or "register" in h:
            score -= 5
        if score > 0 and url not in [u for u, _ in scored]:
            scored.append((url, score))
    return [u for u, _ in sorted(scored, key=lambda x: -x[1])]
