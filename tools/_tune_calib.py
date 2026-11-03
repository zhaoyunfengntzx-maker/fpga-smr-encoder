"""按实测残余误差，微调板上的 sc_correct 六参数（只动 0x0510..0x051A）。

用法（PowerShell）：
    python -X utf8 tools\\_tune_calib.py COM4                 # 只看：读系数 + 测一次残余
    python -X utf8 tools\\_tune_calib.py COM4 --apply off      # 先只补偏置（最大的一项）
    python -X utf8 tools\\_tune_calib.py COM4 --apply all      # 偏置+增益+正交一起补
    python -X utf8 tools\\_tune_calib.py COM4 --restore        # 回滚到上一次 --apply 之前

为什么这么写（改之前先读）：
1. 板上的 sc_correct 是**三级流水**：
       s1 = s - ofs_s
       c1 = c - ofs_c
       c2 = c1 - ((s1*phase_k) >>> 15)
       s_out = (s1*gain_s) >> (15-shift_s)
       c_out = (c2*gain_c) >> (15-shift_c)
   我们测到的是**校正之后**的残余，所以新系数必须**叠加**在旧系数上，不能覆盖。
2. 每一项都先读旧值、写后回读、并重新实测；任何一步让误差变大就立刻回滚。
3. 旧值全部存 `%TEMP%\\calib_backup.json`，`--restore` 一键回去。
4. 一次只改一项（--apply off 先做），这样出问题知道是谁。
"""

import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "host"))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import numpy as np

import analysis as an
import link as lk
import ports as pm
import uart_scope as us

CPR = 2048
CAP_S = 6.0
BACKUP = os.path.join(os.environ.get("TEMP", "."), "calib_backup.json")

CAL = {
    "ofs_s": 0x0510,
    "ofs_c": 0x0512,
    "gain_s": 0x0514,
    "gain_c": 0x0516,
    "phase_k": 0x0518,
}
SHIFT_ADDR = 0x051A


def u16(lo, hi):
    return (lo & 0xFF) | ((hi & 0xFF) << 8)


def s16(v):
    return v - 65536 if v >= 32768 else v


def pick_port(want=None):
    if want:
        return want
    for d, s, h in pm.list_serial_ports():
        if pm.looks_like_board(d, s, h):
            return d
    raise SystemExit("没有可用串口")


def read_cal(w):
    out = {}
    for k, a in CAL.items():
        out[k] = u16(w.read_reg8(a), w.read_reg8(a + 1))
    out["shift"] = w.read_reg8(SHIFT_ADDR) & 0x0F
    return out


def write_cal(w, k, value):
    a = CAL[k]
    v = value & 0xFFFF
    w.write_reg(a, v & 0xFF, verify=True)
    w.write_reg(a + 1, (v >> 8) & 0xFF, verify=True)
    got = u16(w.read_reg8(a), w.read_reg8(a + 1))
    if got != v:
        raise RuntimeError("%s 回读不一致：写 0x%04X 读到 0x%04X" % (k, v, got))


def measure(port):
    """直连串口抓 CAP_S 秒（调用前必须把 SerialWorker 停掉：一条串口只能有一个主人）。"""
    import serial

    ser = serial.Serial(port, 2000000, timeout=0.05)
    buf = b""
    fr = []
    try:
        t0 = time.monotonic()
        while time.monotonic() - t0 < CAP_S:
            buf += ser.read(8192)
            frames, _st = us.parse_stream(buf)
            if frames:
                fr.extend(frames)
                buf = buf[-64:]
    finally:
        ser.close()
    s = np.array([f["s"] for f in fr], float)
    c = np.array([f["c"] for f in fr], float)
    ang = np.array([f["angle_deg"] for f in fr], float)
    p = an.fit_quadrature(s, c, theta_deg=ang)
    e = an.front_end_error(p)
    return p, e, len(fr)


def with_worker(port, fn):
    """开 worker → 干活 → 停（保证离开时串口是干净的）。"""
    w = lk.SerialWorker(port)
    w.start()
    time.sleep(0.9)            # ★ 读太早 read_reg8 会返回 None（板子首帧要 ~0.3 s）
    try:
        return fn(w)
    finally:
        w.stop()


def show(tag, p, e):
    print("%-6s R_s %8.2f  R_c %8.2f ｜ 增益 %+.4f dB ｜ 正交 %+.4f° ｜ 偏置 %+7.1f / %+7.1f ｜ "
          "折算 gain %.2f″ orth %.2f″ off %.2f″ 合计 %.2f″"
          % (tag, p["r_s"], p["r_c"], p["gain_dB"], p["eps_deg"], p["off_s"], p["off_c"],
             e["gain_deg"] / CPR * 3600, e["orth_deg"] / CPR * 3600,
             e["off_deg"] / CPR * 3600, e["total_deg"] / CPR * 3600))


def main(argv):
    port = pick_port(argv[1] if len(argv) > 1 and not argv[1].startswith("-") else None)
    mode = "none"
    if "--apply" in argv:
        mode = argv[argv.index("--apply") + 1]
    if "--restore" in argv:
        mode = "restore"
    print("端口 %s ｜ 模式 %s" % (port, mode))

    old = with_worker(port, read_cal)
    print("当前系数 ofs_s %+6d  ofs_c %+6d  gain_s %5d  gain_c %5d  phase_k %+6d  shift %d"
          % (s16(old["ofs_s"]), s16(old["ofs_c"]), old["gain_s"], old["gain_c"],
             s16(old["phase_k"]), old["shift"]))

    if mode == "restore":
        if not os.path.exists(BACKUP):
            raise SystemExit("没有备份文件，无法回滚")
        bak = json.load(open(BACKUP, encoding="utf-8"))

        def _restore(w):
            for k in ("ofs_s", "ofs_c", "gain_s", "gain_c", "phase_k"):
                write_cal(w, k, bak[k])

        with_worker(port, _restore)
        print("已回滚到", bak)
        p, e, _n = measure(port)
        show("回滚后", p, e)
        return

    p0, e0, n0 = measure(port)
    show("改前", p0, e0)
    print("      （%.1f s / %d 帧）" % (CAP_S, n0))
    if n0 == 0:
        raise SystemExit("没收到帧：检查板子是否在流（或端口被别的程序占着）")

    if mode == "none":
        print("只读模式：加 --apply off 才会写偏置")
        return

    if not os.path.exists(BACKUP):
        json.dump(old, open(BACKUP, "w", encoding="utf-8"))
        print("旧系数已备份 →", BACKUP)

    def clamp(v):
        return max(-32768, min(32767, int(v)))

    plan = {}
    # ① 偏置：残余就是"还差多少没减掉"，直接叠加
    plan["ofs_s"] = clamp(s16(old["ofs_s"]) + round(p0["off_s"]))
    plan["ofs_c"] = clamp(s16(old["ofs_c"]) + round(p0["off_c"]))
    if mode == "all":
        ratio = p0["r_c"] / p0["r_s"]
        # ② 增益：把 s 乘上 R_c/R_s，使两路等幅（gain 是无符号 Q1.15）
        plan["gain_s"] = max(1, min(65535, int(round(old["gain_s"] * ratio))))
        # ③ 正交：残余 eps 是"c 超前 s"，要再减 c 里的 s 分量
        dk = int(round(-ratio * np.sin(np.radians(p0["eps_deg"])) * 32768.0))
        plan["phase_k"] = clamp(s16(old["phase_k"]) + dk)

    def _apply(w):
        for k, v in plan.items():
            write_cal(w, k, v)

    with_worker(port, _apply)
    print("已写：" + "；".join("%s → %d" % (k, v) for k, v in plan.items()))

    p1, e1, n1 = measure(port)
    show("改后", p1, e1)
    better = e1["total_deg"] < e0["total_deg"]
    print("结论：合计误差 %.2f″ → %.2f″（%s，%d 帧）"
          % (e0["total_deg"] / CPR * 3600, e1["total_deg"] / CPR * 3600,
             "变好" if better else "变差", n1))
    if not better:
        print("提示：`python -X utf8 tools\\_tune_calib.py %s --restore` 回滚" % port)


if __name__ == "__main__":
    main(sys.argv)
