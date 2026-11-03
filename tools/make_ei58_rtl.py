#!/usr/bin/env python3
"""Generate the ENC_EI58 RTL variant by preprocessing the `ifdef blocks.

Why: Vivado 2026.1 non-project mode rejects `read_verilog -define` unless the
source fileset is in compile-unit mode, and `synth_design -verilog_define` is
too late for files already read by `read_verilog`.  This script resolves the
only macro we need (`ENC_EI58`) and writes a complete copy of rtl/*.v to
_synth_work_ei58/rtl_ei58/, so tools/impl_check_ei58.tcl can read it as plain
Verilog with no defines.

Usage:
    python tools/make_ei58_rtl.py
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(r"C:\Users\zhaoy\Desktop\FPGA")
SRC = ROOT / "rtl"
DST = ROOT / "_synth_work_ei58" / "rtl_ei58"
DEFINES = {"ENC_EI58"}


def preprocess(text: str) -> str:
    """Resolve `ifdef/`ifndef/`else/`endif for the DEFINES set.

    The files only use the simple two-branch form; nested blocks are handled
    by the stack.  Directive lines are dropped, everything else is kept
    verbatim (including comments), so line numbers stay close to the source.
    """
    out: list[str] = []
    stack: list[bool] = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("`ifdef"):
            macro = s.split()[1] if len(s.split()) > 1 else ""
            stack.append(macro in DEFINES)
        elif s.startswith("`ifndef"):
            macro = s.split()[1] if len(s.split()) > 1 else ""
            stack.append(macro not in DEFINES)
        elif s.startswith("`elsif"):
            macro = s.split()[1] if len(s.split()) > 1 else ""
            if stack:
                # only the first matching branch was tracked; this project
                # does not use `elsif, so treat it as an error rather than
                # silently generating wrong RTL.
                raise SystemExit(f"`elsif is not supported: {line!r}")
            stack.append(macro in DEFINES)
        elif s.startswith("`else"):
            if not stack:
                raise SystemExit(f"`else without `ifdef: {line!r}")
            stack[-1] = not stack[-1]
        elif s.startswith("`endif"):
            if not stack:
                raise SystemExit(f"`endif without `ifdef: {line!r}")
            stack.pop()
        elif s.startswith("`define") or s.startswith("`undef"):
            # keep macro definitions out of the generated copy; they are not
            # needed by the two files we preprocess, and dropping them avoids
            # surprising the downstream reader.
            continue
        else:
            if all(stack):
                out.append(line)
    if stack:
        raise SystemExit("unterminated `ifdef block")
    return "\n".join(out) + "\n"


def main() -> int:
    if not SRC.is_dir():
        print(f"ERROR: source dir not found: {SRC}", file=sys.stderr)
        return 1
    DST.mkdir(parents=True, exist_ok=True)
    count = 0
    for f in sorted(SRC.glob("*.v")):
        text = f.read_text(encoding="utf-8")
        if f.name in {"enc_top.v", "reg_file.v"}:
            text = preprocess(text)
        (DST / f.name).write_text(text, encoding="utf-8", newline="\n")
        count += 1
    print(f"wrote {count} files to {DST}")
    # quick self-check of the two edited files
    top = (DST / "enc_top.v").read_text(encoding="utf-8")
    reg = (DST / "reg_file.v").read_text(encoding="utf-8")
    checks = [
        ("parameter integer POLE_BITS = 11", top),
        ("localparam integer ST_BITS_L = POLE_BITS + AW", top),
        ("localparam integer MT_BITS_L = CYCLE_BITS - POLE_BITS", top),
        ("16'h0100", top),
        ("r_st_bits    <= 8'd27", reg),
        ("r_mt_bits    <= 8'd5", reg),
    ]
    bad = [needle for needle, hay in checks if needle not in hay]
    if bad:
        print("ERROR: preprocessed output missing:", bad, file=sys.stderr)
        return 1
    print("self-check OK: POLE_BITS=11, ST/MT derived, BUILD_ID=0x0100, reg_file 27/5")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
