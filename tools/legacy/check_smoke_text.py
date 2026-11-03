"""Turn the P1 smoke test's WIN-B pixels back into characters and check them.

Why this exists
---------------
`disp/sim/smoke_p1.v` dumps a 1:1 window of the real raster (224x42 px) covering
the large value glyphs of P1 card 1.  A human can read it, but a human cannot be
part of the regression.  This script decodes that window back into text and
asserts it equals the string `val_format` actually wrote -- i.e. it checks the
whole chain "format -> RAM -> font ROM -> shift register -> raster" end to end
against the formatter's own output.

The value font is the 5x7 base glyph scaled 6x into a 32x64 cell.  Cell pitch
(32) is not a multiple of the glyph pixel size (6), so sampling every 6th pixel
would drift out of phase across cells; sample the centre of each glyph pixel
instead.

Exit code 0 = the screen text matches, 1 = it does not.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from gen_font_rom import ASCII_CHARS, G  # noqa: E402  (guarded by __main__ in that module)

LOG = ROOT / "_disp_work" / ("smoke_p6.log" if "--page6" in sys.argv else "smoke_p1.log")
CELL = 32          # value-layer cell pitch in px
GPS = 6            # one glyph pixel is 6x6 px
NCH = 7            # characters visible in WIN-B
X0 = 160           # WIN-B left edge, a value-cell boundary
Y0 = 139           # first row of the value glyph band (cell y=128 + y_off 11)
GLYPH_W, GLYPH_H = 5, 7


def load_win_b():
    rows = {}
    for line in open(LOG, encoding="utf-8", errors="replace"):
        line = line.rstrip("\r\n")
        if len(line) > 2 and line[0] == "B" and "|" in line:
            key, val = line.split("|", 1)
            val = val.rstrip("|")
            if key[1:].isdigit() and val and set(val) <= set(".#"):
                rows[int(key[1:])] = val
    return rows


def decode_cell(rows, cell):
    """Sample one 5x7 glyph out of the pixel window; return its character."""
    art = []
    for gy in range(GLYPH_H):
        y = Y0 + GPS * gy + GPS // 2
        s = rows[y]
        art.append("".join("#" if s[cell * CELL + GPS * gx + GPS // 2] == "#" else "."
                           for gx in range(GLYPH_W)))
    # 只在 ASCII 字表里找：val 平面按设计只放数值/单位（码位 0..43）。
    # 汉字码位 44..109 在这块 ROM 里根本不存在，拿全表去查会 KeyError。
    hits = [ch for ch in ASCII_CHARS if G[ch] == art]
    if not hits:
        return None, art
    if len(hits) > 1:
        return "?" + hits[0], art          # ambiguous glyph art is a real defect
    return hits[0], art


def main():
    if not LOG.exists():
        print("FAIL: smoke log not found: %s" % LOG)
        return 1
    rows = load_win_b()
    if not rows:
        print("FAIL: no WIN-B rows in %s" % LOG)
        return 1

    # What the formatter wrote (9 chars, right aligned in its field window).
    text = LOG.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"fld0 row=2 col=3\s*:\s*\[(.{9})\]", text)
    if not m:
        print("FAIL: the smoke log does not contain val_format's fld0 capture")
        return 1
    wrote = m.group(1)
    expected = wrote[-NCH:]

    got = ""
    for cell in range(NCH):
        ch, art = decode_cell(rows, cell)
        if ch is None:
            print("FAIL: cell %d is not any known glyph:" % cell)
            for r in art:
                print("      %s" % r)
            return 1
        got += ch

    print("val_format wrote : [%s]" % wrote)
    print("screen shows     : [%s]  (WIN-B x%d..%d, %d cells decoded)"
          % (got, X0, X0 + NCH * CELL - 1, NCH))
    if got != expected:
        print("FAIL: screen text %r != written text %r" % (got, expected))
        return 1
    print("PASS: the P1 value text on the raster matches what val_format wrote")
    return 0


if __name__ == "__main__":
    sys.exit(main())
