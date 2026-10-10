"""Regenerate the Wolf Leader installer artwork in this folder.

Usage:  python installer/assets/render.py      (needs `pip install playwright pillow`; uses Edge, else `python -m playwright install chromium`)

Each image is a small HTML page built in memory, screenshotted by headless Chromium at 2x
(or 4x for the large PNG), then saved as PNG or converted to 24-bit BMP for Inno Setup.
Styling follows the Halo look: cream paper, warm ink, pastel squircle icon chips, borderless
cards with the warm double shadow, Nunito, Lucide line icons from ./icons.

app-icon.png, mac-icon.png, wolfleader.ico and wizard-small.bmp belong to make_icons.py;
this script only reads app-icon.png and never writes any of those four.
"""

from __future__ import annotations

import base64
import io
import re
import sys
import tempfile
from functools import lru_cache
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

ASSETS = Path(__file__).resolve().parent
ICONS = ASSETS / "icons"

FONT_LINK = (
    '<link rel="preconnect" href="https://fonts.googleapis.com">'
    '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
    '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Nunito:wght@400;600;700;800;900&display=block">'
)

TOKENS = """
:root {
  --cream-50:#FBF8F3; --cream-100:#F5F1E9; --cream-200:#F0EBE2; --cream-300:#EAE3DA; --cream-400:#DDD5CB;
  --ink-900:#1D1916; --ink-700:#3A342E; --ink-500:#6E675E; --ink-300:#9A9287;
  --lilac-200:#D8DFF6; --lilac-700:#6C7FD1;
  --mint-200:#D4EEE1;  --mint-700:#47997A;
  --butter-200:#F8E9C9; --butter-700:#C79A2E;
  --blush-200:#FBDCE5; --blush-700:#D9647F;
  --surface-page:var(--cream-300); --surface-card:var(--cream-100);
  --text-strong:var(--ink-900); --text-body:var(--ink-700); --text-muted:var(--ink-500); --text-faint:var(--ink-300);
  --shadow-card:0 2px 10px rgba(29,25,22,0.035), 0 12px 28px rgba(29,25,22,0.045);
  --radius-sm:10px; --radius-md:16px; --radius-lg:24px; --radius-xl:28px;
  --font:"Nunito","SF Pro Rounded",ui-rounded,"Avenir Next","Segoe UI",system-ui,sans-serif;
}
* { box-sizing:border-box; margin:0; padding:0; }
html, body { width:100%; height:100%; }
body { font-family:var(--font); color:var(--text-body); background:var(--surface-page);
       -webkit-font-smoothing:antialiased; text-rendering:geometricPrecision; overflow:hidden; }
.chip { display:inline-flex; align-items:center; justify-content:center; flex:0 0 auto; }
.chip svg { display:block; }
.lilac  { background:var(--lilac-200);  color:var(--lilac-700); }
.mint   { background:var(--mint-200);   color:var(--mint-700); }
.butter { background:var(--butter-200); color:var(--butter-700); }
.blush  { background:var(--blush-200);  color:var(--blush-700); }
.wordmark { font-weight:800; color:var(--text-strong); letter-spacing:-0.02em; line-height:1.02; }
.meta { font-weight:400; color:var(--text-muted); }
"""

CARDS = [
    {
        "hue": "lilac", "icon": "history",
        "title": "That chat from three weeks ago? Still here.",
        "body": "Open any new chat and ask what you worked on, in any project, on any day. "
                "Your agent gets the whole story in seconds.",
        "meta": "every chat · every project · any day",
    },
    {
        "hue": "mint", "icon": "check",
        "title": "Remembers while you work",
        "body": "Decisions, fixes and next steps save themselves as you go. No commands to type.",
        "meta": "auto-save · one line when it does",
    },
    {
        "hue": "butter", "icon": "laptop",
        "title": "Pick up on any machine",
        "body": "Howl on one computer, eat on another. Same project, same context, "
                "same git history on your own share.",
        "meta": "/wolfhowl · /wolfeat · your share",
    },
    {
        "hue": "blush", "icon": "heart",
        "title": "Everything you love about v1",
        "body": "Shared memory for every agent, typed memories, briefs, handoffs, the vault and the wiki. "
                "All still here, all better connected.",
        "meta": "built on v1",
    },
]


def icon(name: str, size: float) -> str:
    svg = (ICONS / f"{name}.svg").read_text(encoding="utf-8")
    inner = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1)
    inner = re.sub(r"<metadata>.*?</metadata>", "", inner, flags=re.S).strip()
    return (
        f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
        f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{inner}</svg>'
    )


def chip(hue: str, name: str, box: float, glyph: float, radius: float, extra: str = "") -> str:
    return (
        f'<span class="chip {hue}" style="width:{box}px;height:{box}px;border-radius:{radius}px;{extra}">'
        f"{icon(name, glyph)}</span>"
    )


@lru_cache(maxsize=None)
def app_icon_uri(px: int = 512) -> str:
    img = Image.open(ASSETS / "app-icon.png").convert("RGBA").resize((px, px), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def app_icon(size: float, cls: str = "appicon") -> str:
    return f'<img class="{cls}" src="{app_icon_uri()}" width="{size}" height="{size}" alt="">'


def nobreak_last(text: str) -> str:
    """Glue the last two words so a line never ends on a lone short word."""
    head, _, last = text.rpartition(" ")
    return f"{head}&nbsp;{last}" if head else text


def page(css: str, body: str, transparent: bool = False) -> str:
    bg = "html,body{background:transparent}" if transparent else ""
    return (
        f'<!doctype html><html><head><meta charset="utf-8">{FONT_LINK}'
        f"<style>{TOKENS}{bg}{css}</style></head><body>{body}</body></html>"
    )


# ---------------------------------------------------------------- wizard-side (164x314 @2x)
def wizard_side() -> str:
    css = """
    .wrap { height:100%; padding:20px 16px 34px; display:flex; flex-direction:column;
            align-items:center; justify-content:center; text-align:center; }
    .appicon { display:block; filter:drop-shadow(0 3px 10px rgba(29,25,22,0.08)) drop-shadow(0 14px 24px rgba(29,25,22,0.10)); }
    .wordmark { font-size:25px; margin-top:22px; }
    .tag { font-size:12.5px; margin-top:8px; }
    """
    return page(css, f'<div class="wrap">{app_icon(100)}<div class="wordmark">Wolf<br>Leader</div>'
                     f'<div class="meta tag">now on autopilot</div></div>')


# ---------------------------------------------------------------- whatsnew cards (417x237)
def whatsnew_cards() -> str:
    css = """
    .grid { height:100%; padding:6px 9px 9px; display:flex; flex-direction:column; gap:6px; }
    .row { display:flex; gap:7px; flex:1 1 auto; }
    .card { background:var(--surface-card); border-radius:20px; box-shadow:var(--shadow-card);
            padding:8px 12px 7px; display:flex; flex-direction:column; min-width:0; }
    .head { display:flex; align-items:center; gap:8px; }
    .title { font-weight:800; color:var(--text-strong); font-size:12px; line-height:1.12; letter-spacing:-0.01em; }
    .body { font-size:10px; line-height:1.25; margin-top:4px; color:var(--text-body); }
    .card .meta { font-size:9.5px; margin-top:auto; padding-top:3px; white-space:nowrap; }
    .hero .title { font-size:13.5px; }
    """
    out = []
    for i, c in enumerate(CARDS):
        cls = "card hero" if i == 0 else "card"
        box = 28 if i == 0 else 24
        out.append(
            f'<div class="{cls}" style="flex:{SPLITS[i]}"><div class="head">'
            f'{chip(c["hue"], c["icon"], box, box * 0.56, box * 0.38)}'
            f'<div class="title">{nobreak_last(c["title"])}</div></div>'
            f'<div class="body">{nobreak_last(c["body"])}</div><div class="meta">{c["meta"]}</div></div>'
        )
    rows = f'<div class="row">{out[0]}{out[1]}</div><div class="row">{out[2]}{out[3]}</div>'
    return page(css, f'<div class="grid">{rows}</div>')


SPLITS = [58, 42, 48, 52]


# name, builder, css width, css height, scale, transparent, output formats
JOBS = [
    ("wizard-side", wizard_side, 164, 314, 2, False, ["bmp"]),
    ("whatsnew-cards", whatsnew_cards, 417, 237, 2, False, ["bmp"]),
    ("whatsnew-cards", whatsnew_cards, 417, 237, 4, False, ["png"]),
]

OVERFLOW_JS = """() => {
  const bad = [];
  if (document.documentElement.scrollHeight > innerHeight + 1 || document.documentElement.scrollWidth > innerWidth + 1)
    bad.push('page ' + document.documentElement.scrollWidth + 'x' + document.documentElement.scrollHeight);
  document.querySelectorAll('.card, .wrap').forEach((el, i) => {
    if (el.scrollHeight > el.clientHeight + 1) bad.push(el.className + '#' + i + ' +' + (el.scrollHeight - el.clientHeight) + 'px');
  });
  const pad = 4;
  document.querySelectorAll('body *:not(svg):not(svg *)').forEach((el) => {
    const leaf = el.classList.contains('chip') || [...el.children].every(c => c.tagName === 'BR');
    if (!leaf) return;
    const r = el.getBoundingClientRect();
    if (r.width && (r.bottom > innerHeight - pad || r.right > innerWidth - pad || r.top < pad || r.left < pad))
      bad.push(el.className || el.tagName + ' near edge (' + Math.round(r.left) + ',' + Math.round(r.top) + ','
               + Math.round(r.right) + ',' + Math.round(r.bottom) + ')');
  });
  return bad;
}"""


def launch(p):
    try:
        return p.chromium.launch(channel="msedge")
    except Exception:
        return p.chromium.launch()


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="wl-art-"))
    problems = 0
    with sync_playwright() as p:
        browser = launch(p)
        for name, build, w, h, scale, transparent, formats in JOBS:
            ctx = browser.new_context(viewport={"width": w, "height": h}, device_scale_factor=scale)
            pg = ctx.new_page()
            pg.set_content(build(), wait_until="networkidle")
            loaded = pg.evaluate(
                "Promise.all(['400 12px Nunito','600 12px Nunito','800 20px Nunito'].map(f => document.fonts.load(f)))"
                ".then(() => document.fonts.ready).then(() => document.fonts.check('800 20px Nunito'))"
            )
            if not loaded:
                print(f"  ! {name}: Nunito did not load, fallback font used", file=sys.stderr)
                problems += 1
            for issue in pg.evaluate(OVERFLOW_JS):
                print(f"  ! {name}@{scale}x overflow: {issue}", file=sys.stderr)
                problems += 1
            shot = tmp / f"{name}@{scale}.png"
            pg.screenshot(path=str(shot), omit_background=transparent)
            ctx.close()
            img = Image.open(shot)
            for fmt in formats:
                out = ASSETS / f"{name}.{fmt}"
                if fmt == "bmp":
                    img.convert("RGB").save(out, "BMP")
                else:
                    (img if transparent else img.convert("RGB")).save(out, "PNG", optimize=True)
                print(f"  {out.name:22} {img.width}x{img.height}")
        browser.close()
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
