"""诊断页冒烟：主窗口 → 「诊断」页 → 给状态表塞一组假数据 → 出图。

用法（PowerShell）：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_diag_page.py [输出.png]
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

from PySide6.QtWidgets import QApplication

import main_window as mw
import regs

FAKE = {
    regs.REG_LOCK_STATE: 1,
    regs.REG_LOCK_STICKY: 0x05,
    regs.REG_LOST_CNT0: 3, regs.REG_LOST_CNT1: 0,
    regs.REG_BAD_RUN0: 2, regs.REG_BAD_RUN1: 0,
    regs.REG_TAU0: 0x00, regs.REG_TAU1: 0x09,
    regs.REG_FF_CFG: 0x01, regs.REG_FF_STAT: 0x01,
    regs.REG_FF_SPEED0: 0x24, regs.REG_FF_SPEED1: 0x12, regs.REG_FF_SPEED2: 0x00,
    regs.REG_FF_CORR0: 0xFF, regs.REG_FF_CORR1: 0xFF, regs.REG_FF_CORR2: 0xFF,
    regs.REG_BIAS_S0: 0xF6, regs.REG_BIAS_S1: 0xFF,
    regs.REG_BIAS_C0: 0x0A, regs.REG_BIAS_C1: 0x00,
    regs.REG_BIAS_ST: 0x01,
    regs.REG_LUT_CTRL: 0x00,
    regs.REG_AB_HYST: 0x03, regs.REG_UVW_HYST: 0x1F, regs.REG_ABLIMIT: 0x40,
    regs.REG_ZERO1: 0x02, regs.REG_ZPHASE: 0x40, regs.REG_UVWPH: 0x00,
    regs.REG_PHASE_LSB: 0x0A,
}


def main(argv):
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.show_page("diag")
    win.board_status.set_raw(FAKE)
    app.processEvents()
    out = argv[1] if len(argv) > 1 else os.path.join(
        os.environ.get("TEMP", "."), "diag_page.png")
    win.grab().save(out)
    print("[note]", win.board_status.lab_note.text())
    print("[png]", out)
    print("SMOKE OK")


if __name__ == "__main__":
    main(sys.argv)
