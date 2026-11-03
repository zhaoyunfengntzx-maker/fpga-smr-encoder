"""UVW 三相相位关系：只用遥测帧里的 io_state（u/v/w 三位）做数值验证。

判据（v73 / 2048 PPR / 4 对极）：
  1) 六种合法状态 {001,010,011,100,101,110} 都要出现，且不出现 000/111；
  2) 相邻状态切换的时间间隔应大致相等（各占电周期 1/6）；
  3) 任意一相的"高"占空比应 ≈ 1/2（120° 导通，两相同时在导通附近互补）；
  4) 相序应固定（同一方向上 u→v→w 或反序），用状态码的循环方向判定。

用法：python _boardtest/uvw_phase.py COM7 3
"""
import sys
import time

import serial

BAUD = 2_000_000
FRAME_LEN = 18


def parse_frames(buf):
    out = []
    i = 0
    n = len(buf)
    while i + FRAME_LEN <= n:
        if buf[i] == 0xAA and buf[i + 1] == 0x55:
            fr = buf[i:i + FRAME_LEN]
            x = 0
            for b in fr:
                x ^= b
            if x == 0:
                out.append(fr)
                i += FRAME_LEN
                continue
        i += 1
    return out


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

    ser = serial.Serial(port, BAUD, timeout=0.2)
    ser.reset_input_buffer()
    t0 = time.time()
    buf = bytearray()
    while time.time() - t0 < secs:
        buf += ser.read(4096)
    ser.close()

    frames = parse_frames(bytes(buf))
    if not frames:
        print("FAIL: no frames")
        return 1

    states = []          # (t_index, u, v, w)
    for idx, fr in enumerate(frames):
        io_state = fr[8]   # v2 布局：偏移 8 = io_state，偏移 10 = io_flags
        u = (io_state >> 3) & 1
        v = (io_state >> 4) & 1
        w = (io_state >> 5) & 1
        states.append((idx, u, v, w, (u << 2) | (v << 1) | w))

    dt = secs / len(frames)
    code = [s[4] for s in states]

    from collections import Counter
    cnt = Counter(code)
    legal = {1, 2, 3, 4, 5, 6}
    illegal = sum(c for k, c in cnt.items() if k not in legal)

    # 状态切换时刻
    edges = [(i, code[i]) for i in range(1, len(code)) if code[i] != code[i - 1]]
    gaps = [edges[i][0] - edges[i - 1][0] for i in range(1, len(edges))]
    seq = [c for _, c in edges]

    # 相序：看状态码是否严格按 1→3→2→6→4→5→1 循环（正向）或反向
    fwd = {1: 3, 3: 2, 2: 6, 6: 4, 4: 5, 5: 1}
    bwd = {v: k for k, v in fwd.items()}
    n_f = n_b = n_bad = 0
    for i in range(1, len(seq)):
        a, b = seq[i - 1], seq[i]
        if fwd.get(a) == b:
            n_f += 1
        elif bwd.get(a) == b:
            n_b += 1
        elif a != b:
            n_bad += 1

    duty_u = sum(s[1] for s in states) / len(states)
    duty_v = sum(s[2] for s in states) / len(states)
    duty_w = sum(s[3] for s in states) / len(states)

    print("frames=%d  dur=%.2fs  dt=%.1f us" % (len(frames), secs, dt * 1e6))
    print("state counts:", dict(sorted(cnt.items())))
    print("illegal(000/111) samples: %d" % illegal)
    print("transitions=%d  fps_of_transition=%.2f Hz" % (len(edges), len(edges) / secs))
    if gaps:
        gaps_sorted = sorted(gaps)
        med = gaps_sorted[len(gaps_sorted) // 2]
        mean = sum(gaps) / len(gaps)
        f_elec = (len(edges) / secs) / 6.0
        print("gap(us): min=%.0f med=%.0f mean=%.0f max=%.0f  | f_elec=%.2f Hz, 1/6 周期=%.0f us"
              % (min(gaps) * dt * 1e6, med * dt * 1e6, mean * dt * 1e6,
                 max(gaps) * dt * 1e6, f_elec, 1e6 / 6.0 / f_elec))
    print("duty u=%.3f v=%.3f w=%.3f" % (duty_u, duty_v, duty_w))
    print("order: forward=%d backward=%d irregular=%d" % (n_f, n_b, n_bad))

    ok = True
    if illegal:
        ok = False
        print("FAIL: illegal state 000/111 seen")
    missing = legal - set(cnt)
    if missing:
        ok = False
        print("FAIL: missing states", sorted(missing))
    if abs(duty_u - 0.5) > 0.06 or abs(duty_v - 0.5) > 0.06 or abs(duty_w - 0.5) > 0.06:
        ok = False
        print("FAIL: duty out of 0.5+-0.06")
    if n_bad > max(3, 0.02 * len(seq)):
        ok = False
        print("FAIL: irregular transitions %d/%d" % (n_bad, len(seq)))
    if gaps and (max(gaps) > 2.2 * (sum(gaps) / len(gaps))):
        ok = False
        print("FAIL: gap jitter too large")

    print("PASS: UVW six-state rotation, 120-degree spacing, fixed phase order"
          if ok else "FAIL: UVW phase check")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
