"""诊断页「板上运行状态」卡截图（含偏置慢跟踪按钮）。"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

from PySide6.QtCore import QPoint
from PySide6.QtWidgets import QApplication

import main_window as mw
import regs

FAKE = {
    regs.REG_LOCK_STATE: 1, regs.REG_LOCK_STICKY: 0x05,
    regs.REG_LOST_CNT0: 3, regs.REG_LOST_CNT1: 0,
    regs.REG_BAD_RUN0: 2, regs.REG_BAD_RUN1: 0,
    regs.REG_TAU0: 0x00, regs.REG_TAU1: 0x09,
    regs.REG_FF_CFG: 0x03, regs.REG_FF_STAT: 0x03,
    regs.REG_FF_SPEED0: 0x24, regs.REG_FF_SPEED1: 0x12, regs.REG_FF_SPEED2: 0x00,
    regs.REG_FF_CORR0: 0xFF, regs.REG_FF_CORR1: 0xFF, regs.REG_FF_CORR2: 0xFF,
    regs.REG_BIAS_S0: 54, regs.REG_BIAS_S1: 0,
    regs.REG_BIAS_C0: 0x0C, regs.REG_BIAS_C1: 0x03,
    regs.REG_BIAS_ST: 0x01,
    regs.REG_LUT_CTRL: 0x00,
    regs.REG_AB_HYST: 3, regs.REG_UVW_HYST: 0x1F, regs.REG_ABLIMIT: 0x40,
    regs.REG_ZERO1: 2, regs.REG_ZPHASE: 0x40, regs.REG_UVWPH: 0x00,
    regs.REG_PHASE_LSB: 0x0A,
}


def main(argv):
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.show_page("diag")
    win.board_status.set_raw(FAKE)
    win.board_status.set_bias_done(True, "偏置慢跟踪已打开：0x013C bit0=1，学到的 bias_s 54 / bias_c 780 LSB")
    app.processEvents()
    inner = win.scroll.widget()
    y = win.board_status.mapTo(inner, QPoint(0, 0)).y()
    sb = win.scroll.verticalScrollBar()
    sb.setValue(max(0, min(sb.maximum(), y - 40)))
    app.processEvents()
    out = argv[1] if len(argv) > 1 else os.path.join(
        os.environ.get("TEMP", "."), "bias_card.png")
    win.grab().save(out)
    print("[png]", out)
    print("SMOKE OK")


if __name__ == "__main__":
    main(sys.argv)
