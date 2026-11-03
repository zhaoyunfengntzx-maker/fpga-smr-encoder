# -*- coding: utf-8 -*-
"""寄存器快照 / “恢复默认”前后对比探针。

用途：定位「点完恢复默认 OK 之后，逻辑时序页卡死」这个故障。
它只读寄存器、不写任何东西（除了你自己在屏上点按钮），所以可以随便跑。

用法：
    python _boardtest/ui_restore_probe.py COM7            # 交互：读一次 → 你去点“恢复默认” → 回车 → 再读一次
    python _boardtest/ui_restore_probe.py COM7 now        # 只读当前一次（做 snapshot 用）

读的寄存器（全是有文档的只读/回读项）：
    0x0100 UVW_CFG   [4:0] pairs     [7] uvwph？
    0x0101 INTER0    倍频（应 32）
    0x0102 INTER1    分频（应 0）
    0x0106 ABLIMIT
    0x0109 OUTPUT    bit0 apol / bit6 abzen / bit7 uwven
    0x0514/15 GAIN_S 0x0516/17 GAIN_C 0x051A SHIFT
    0x0404 STAT_VAL  0x0405 STAT_LATCH  0x053A STAT_FLAGS
"""
import sys
import time

sys.path.insert(0, "host")
import link as lk  # noqa: E402

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
MODE = sys.argv[2] if len(sys.argv) > 2 else "interactive"

ADDRS = [
    0x0100, 0x0101, 0x0102, 0x0106, 0x0109,
    0x0514, 0x0515, 0x0516, 0x0517, 0x051A,
    0x0404, 0x0405, 0x053A,
]


def _val(d):
    """read_reg 的返回可能是 dict / int / None，统一取整数。"""
    if d is None:
        return None
    if isinstance(d, dict):
        v = d.get("value", d.get("val"))
        return None if v is None else int(v) & 0xFFFF
    try:
        return int(d) & 0xFFFF
    except Exception:
        return None


def snap(w):
    out = {}
    for a in ADDRS:
        out[a] = _val(w.read_reg(a))
    return out


def decode(s):
    g = s.get
    p = g(0x0100)
    i0 = g(0x0101)
    i1 = g(0x0102)
    ab = g(0x0106)
    op = g(0x0109)
    # 0x0514/0x0515 是两个独立 8 位寄存器（低/高字节），不是同址高低字节
    gs = None
    if g(0x0514) is not None and g(0x0515) is not None:
        gs = (g(0x0515) << 8) | g(0x0514)
    gc = None
    if g(0x0516) is not None and g(0x0517) is not None:
        gc = (g(0x0517) << 8) | g(0x0516)
    sh = g(0x051A)
    st = g(0x0404)
    lt = g(0x0405)
    fl = g(0x053A)

    def bit(v, n):
        return None if v is None else (v >> n) & 1

    print("  UVW_CFG=0x%04X  pairs=%s" % (p, None if p is None else (p & 0x1F) or 32))
    print("  INTER0=%s  INTER1=%s" % (i0, i1))
    print("  ABLIMIT=0x%04X  OUTPUT=0x%04X (apol=%s abzen=%s uwven=%s)"
          % (ab or 0, op or 0, bit(op, 0), bit(op, 6), bit(op, 7)))
    print("  GAIN_S=%s  GAIN_C=%s  SHIFT=%s" % (gs, gc, sh))
    print("  STAT_VAL=0x%04X  STAT_LATCH=0x%04X  STAT_FLAGS=0x%04X"
          % (st or 0, lt or 0, fl or 0))
    if fl is not None:
        print("    flags: lag_limit=%d amp_low=%d amp_high=%d otr=%d calib_done=%d calib_busy=%d"
              % (fl & 1, (fl >> 1) & 1, (fl >> 2) & 1, (fl >> 3) & 1, (fl >> 4) & 1, (fl >> 5) & 1))


def main():
    w = lk.SerialWorker(PORT)
    w.start()
    time.sleep(0.5)
    try:
        print("== 第一次读数（现在）==")
        a = snap(w)
        decode(a)

        if MODE == "now":
            return

        print("")
        print("现在请在屏幕上操作：P6 设置 → 「恢复默认」→ 弹窗点 OK。")
        try:
            input("做完（并等 2 秒）后按回车继续…")
        except EOFError:
            time.sleep(10)

        time.sleep(1.5)
        print("== 第二次读数（恢复之后）==")
        b = snap(w)
        decode(b)

        print("")
        print("== 差异 ==")
        any_diff = False
        for addr in ADDRS:
            if a.get(addr) != b.get(addr):
                any_diff = True
                print("  0x%04X : 0x%04X -> 0x%04X" % (addr, a.get(addr) or 0, b.get(addr) or 0))
        if not any_diff:
            print("  没有任何寄存器变化 —— 说明恢复默认没写进去，卡死是显示侧状态机（ui_state）问题。")
        else:
            print("")
            print("判读：若 0x0109 掉了 abzen/uwven 位 ⇒ 假说 A（修 ui_restore 的恢复表）；")
            print("      若 0x0100/0x0101 变了 ⇒ 假说 C（恢复表写错地址/值）；")
            print("      若带 ABZ/UVW 输出的寄存器都没变 ⇒ 看假说 B（ui_state 卡在进行中）。")
    finally:
        try:
            w.stop()
        except Exception:
            pass


if __name__ == "__main__":
    main()
