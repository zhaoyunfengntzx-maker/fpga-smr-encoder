"""正交质量卡的界面冒烟：造已知误差的帧 → 看读数是否说得对。

用法（PowerShell）：
    $env:QT_QPA_PLATFORM="offscreen"
    python -X utf8 tools\\_smoke_quality_panel.py

造的是"3% 增益失配 + 0.5° 正交误差 + 50/−30 LSB 偏置 + 1 LSB 噪声"，
覆盖 2.2 个电周期。期望读数：R_s≈1000、R_c≈1030、ε≈+0.5°、偏置≈50/−30、
折算角度误差≈3.4°（偏置主导，这是 50 LSB 偏置在 1000 LSB 幅值上的必然结果）。
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "host"))

import numpy as np

from PySide6.QtWidgets import QApplication, QWidget, QVBoxLayout

import panel_quality as pq


def make_frames(n=1500, r_s=1000.0, r_c=1030.0, eps_deg=0.5, o_s=50.0, o_c=-30.0,
                noise=1.0, turns=2.2, seed=7):
    rng = np.random.default_rng(seed)
    th = np.linspace(0.0, 2.0 * np.pi * turns, n, endpoint=False)
    s = r_s * np.sin(th) + o_s + rng.normal(0.0, noise, n)
    c = r_c * np.cos(th + np.radians(eps_deg)) + o_c + rng.normal(0.0, noise, n)
    out = []
    for k in range(n):
        out.append({"s": int(round(s[k])), "c": int(round(c[k])),
                    "angle": int(round((th[k] / (2.0 * np.pi) % 1.0) * 65536.0)) % 65536})
    return out


def main():
    app = QApplication(sys.argv[:1])
    win = QWidget()
    win.resize(460, 560)
    lay = QVBoxLayout(win)
    card = pq.QualityPanel()
    lay.addWidget(card)

    frames = make_frames()
    res = card.feed(frames, force=True)
    print("[verdict]", card.lab_verdict.text())
    print("[level]", card.verdict())
    if res.get("ok"):
        p, fe = res["params"], res["error"]
        print("[fit] R_s=%.2f R_c=%.2f eps=%.4f° off=(%.1f,%.1f) res=%.2f LSB"
              % (p["r_s"], p["r_c"], p["eps_deg"], p["off_s"], p["off_c"],
                 p["res_rms"]))
        print("[折角] gain=%.4f° orth=%.4f° off=%.4f° total=%.4f°"
              % (fe["gain_deg"], fe["orth_deg"], fe["off_deg"], fe["total_deg"]))
        print("[覆盖] %.1f%% 空箱 %d 缺口 %.1f°"
              % (res["coverage"]["coverage_pct"], res["coverage"]["empty_bins"],
                 res["coverage"]["gap_deg"]))
        # 判据：读数必须落在真值附近，否则界面在骗人
        assert abs(p["r_s"] - 1000.0) < 3.0, p["r_s"]
        assert abs(p["r_c"] - 1030.0) < 3.0, p["r_c"]
        assert abs(p["eps_deg"] - 0.5) < 0.02, p["eps_deg"]
        assert abs(p["off_s"] - 50.0) < 3.0, p["off_s"]
        assert abs(p["off_c"] + 30.0) < 3.0, p["off_c"]

    # 半圈：覆盖度必须报缺口，而不是给个好看的百分比
    res2 = card.feed(make_frames(turns=0.5), force=True)
    print("[半圈]", card.lab_verdict.text())
    if res2.get("ok"):
        print("[半圈覆盖] %.1f%% 缺口 %.1f°"
              % (res2["coverage"]["coverage_pct"], res2["coverage"]["gap_deg"]))
        assert res2["coverage"]["gap_deg"] > 100.0

    # 帧太少：不给结论
    res3 = card.feed(make_frames(n=100), force=True)
    print("[少帧]", card.lab_verdict.text())
    assert not res3.get("ok")

    card.feed(make_frames(), force=True)
    win.show()
    app.processEvents()
    out = os.path.join(os.environ.get("TEMP", "."), "quality.png")
    win.grab().save(out)
    print("[png]", out)
    print("SMOKE OK")


if __name__ == "__main__":
    main()
