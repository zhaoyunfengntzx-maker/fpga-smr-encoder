"""把已存的 stable_*.bin 重新出图（不再采一遍板子，数字与当时打印的报告一致）。"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import numpy as np

import analysis as an
import record_bin as rb
import uart_scope as us

CPR = 2048


def main(argv):
    path = argv[1] if len(argv) > 1 else None
    if not path:
        tmp = os.environ.get("TEMP", ".")
        cands = [os.path.join(tmp, f) for f in os.listdir(tmp)
                 if f.startswith("stable_") and f.endswith(".bin")]
        path = max(cands, key=os.path.getmtime)
    chunks = rb.read_frames(path)
    fr, _st = us.parse_stream(b"".join(chunks))
    s = np.array([f["s"] for f in fr], float)
    c = np.array([f["c"] for f in fr], float)
    ang = np.array([f["angle_deg"] for f in fr], float)
    ref = np.degrees(np.arctan2(s, c))
    err_w = ((ang - ref + 180.0) % 360.0) - 180.0
    p = an.fit_quadrature(s, c, theta_deg=ang)
    err = an.wrap_error_deg(ang - ref)

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False

    fig, ax = plt.subplots(1, 2, figsize=(11, 4.4), dpi=110)
    step = max(1, len(s) // 40000)
    ax[0].plot(s[::step], c[::step], ",", color="#2b7de9", alpha=0.5)
    ax[0].set_title("s-c 点云（%d 帧）  轴比 %.4f" % (len(s), p["r_c"] / p["r_s"]))
    ax[0].set_xlabel("s (LSB)")
    ax[0].set_ylabel("c (LSB)")
    ax[0].set_aspect("equal", adjustable="datalim")
    ax[0].grid(alpha=0.3)
    ax[1].plot(ang[::step], err_w[::step], ",", color="#e8582b", alpha=0.4)
    ax[1].set_title("板上角度 − arctan2(s,c)  均值 %+.2f°  rms %.2f°（电）"
                    % (err["mean"], err["rms"]))
    ax[1].set_xlabel("电角度 (°)")
    ax[1].set_ylabel("差 (°, 电, 已折回 ±180)")
    ax[1].set_ylim(-3.0, 3.0)
    ax[1].grid(alpha=0.3)
    fig.tight_layout()
    out = os.path.join(os.environ.get("TEMP", "."), "stable_report.png")
    fig.savefig(out)
    print("png", out)
    print("frames %d  轴比 %.4f  残差均值 %+.2f°  rms %.2f°"
          % (len(s), p["r_c"] / p["r_s"], err["mean"], err["rms"]))


if __name__ == "__main__":
    main(sys.argv)
