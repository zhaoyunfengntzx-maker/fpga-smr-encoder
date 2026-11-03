"""实时页转速冒烟：拿实测 .bin 回灌「转速与位置」卡，看读数对不对。

用法（PowerShell）：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_speed_page.py [记录.bin]

不传路径就用 %TEMP%\\stable_*.bin 里最新的那份（30 s 实测记录）。
这么做的原因：板子的 COM4 常被界面自己占着，离线回灌也能验证转速口径。
"""

import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))
sys.path.insert(0, HERE)

from PySide6.QtWidgets import QApplication

import main_window as mw
import replay as rp


def main(argv):
    path = argv[1] if len(argv) > 1 else sorted(
        glob.glob(os.path.join(os.environ.get("TEMP", "."), "stable_*.bin")))[-1]
    frames, _ = rp.load_all(path)
    app = QApplication(sys.argv[:1])
    win = mw.MainWindow()
    win.resize(1600, 1000)
    win.show()
    win.show_page("live")
    snap = None
    for k in range(0, len(frames), 1000):
        snap = win.speed.feed(frames[k:k + 1000], t_now=1000.0 + k / 10000.0)
    app.processEvents()
    out = os.path.join(os.environ.get("TEMP", "."), "speed_page.png")
    win.grab().save(out)
    print("[pairs] %d  （界面输入框）" % win.speed.sp_pairs.value())
    print("[f] %s" % win.speed.v_f.text())
    print("[rpm] %s" % win.speed.v_rpm.text())
    print("[turns] %s" % win.speed.v_turns.text())
    print("[dir] %s" % win.speed.v_dir.text())
    print("[note] %s" % win.speed.lab_note.text())
    print("[png] %s" % out)
    print("SMOKE OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
