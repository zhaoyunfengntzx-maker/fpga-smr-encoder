# -*- coding: utf-8 -*-
r"""Generate subtitles for the v3 walkthrough script (3:00).

Source of truth: deliverables/video_script_v3.md section 6.
Cues are hand-split at natural phrase boundaries; each cue's duration is the
character share of its block window, so the SRT stays aligned with the
narration blocks even if a block is re-timed.

Run:  python deliverables\video\tools\make_srt_v3.py
"""
import io
import os

# (block id, start sec, end sec, [cue, ...])  -- "\n" marks a deliberate line break
BLOCKS = [
    ("S1", 0.0, 11.0, [
        "这是我们做的磁编码器，",
        "用磁阻传感器加一块FPGA。",
        "接下来三分钟，从转台一直看到屏幕。",
    ]),
    ("S2", 11.0, 40.0, [
        "现在电机停着。",
        "这圈磁环，磁场是一圈一圈变的。",
        "传感器里两组检测单元错开四分之一周期，",
        "电角度正好差九十度。",
        "所以停住时，输出的不是波形，",
        "是两对固定的电压，",
        "正弦一对、余弦一对。",
        "每路都是正负两根线，",
        "外面的干扰两边一样，一减就没了。",
    ]),
    ("S3", 40.0, 54.0, [
        "让电机转起来。",
        "角度一直在变，",
        "这两对电压就跟着变成正弦和余弦，",
        "始终差着九十度。",
        "谁在前谁在后，就是转的方向。",
    ]),
    ("S4", 54.0, 71.0, [
        "信号出来，先进差分转单端模块，",
        "变成普通正余弦；",
        "再走SMA同轴线，进AD9238。",
        "它双通道、十二位、五十兆，",
        "两路同时采，同一个时钟。",
    ]),
    ("S5", 71.0, 120.0, [
        "进到FPGA，六步。",
        "先把两路采样对齐，负电压换成有符号数；",
        "然后四个点取平均，数据少四分之三，\n噪声小一半；",
        "接着量一遍，两个零点、两个幅度、",
        "两路之间的相位差，",
        "六个数补进去，圆就圆了；",
        "再用CORDIC算反正切，十七级流水线，",
        "每个时钟一个角度；",
        "出来还得稳一下，后面跟个跟踪环，",
        "压抖动、算转速，",
        "顺带把圈数记上；",
        "最后编成ABZ，一圈两千零四十八线，",
        "每转一个Z，",
        "六路UVW换向。",
    ]),
    ("S6", 120.0, 140.0, [
        "结果分五路出去：",
        "ABZ、UVW差分给驱动器，拉几十米没问题；",
        "SPI和两兆波特串口，一秒一万帧；",
        "以太网抓波形，一次两万八千多点，",
        "串口要大半秒，它几毫秒。",
    ]),
    ("S7", 140.0, 152.0, [
        "板子上还有一块七寸触摸屏，",
        "四页：总览、波形、时序、设置。",
        "没有整屏缓存，参数改完当场生效。",
    ]),
    ("S8", 152.0, 165.0, [
        "接上电脑就是上位机，六页：",
        "概览、实时、编码器信号、告警、记录、诊断。",
        "刚才那串数据，就是它在实时收的。",
    ]),
    ("S9", 165.0, 177.5, [
        "一颗FPGA，替掉了进口的细分芯片。",
        "十六位角度、两千零四十八线增量，",
        "时序能过，开源，能复现。",
    ]),
]

CUE_MIN = 0.9   # seconds
CUE_MAX = 6.5   # seconds


def to_ms(sec):
    ms = int(round(max(0.0, sec) * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def nchars(cue):
    return len(cue.replace("\n", ""))


def main():
    rows, warnings = [], []
    for bid, t0, t1, cues in BLOCKS:
        weights = [nchars(c) for c in cues]
        total = sum(weights)
        t = t0
        for i, (cue, w) in enumerate(zip(cues, weights)):
            dur = (t1 - t0) * w / total
            start, end = t, t + dur
            if i == len(cues) - 1:
                end = t1
            rows.append((bid, start, end, cue))
            t = end
            if end - start < CUE_MIN or end - start > CUE_MAX:
                warnings.append(f"{bid} cue {i + 1}: {end - start:.2f}s  {cue!r}")

    out = os.path.join("deliverables", "video", "subs", "narration_v3.srt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    buf = io.StringIO()
    for i, (_, a, b, txt) in enumerate(rows, 1):
        buf.write(f"{i}\r\n{to_ms(a)} --> {to_ms(b)}\r\n{txt}\r\n\r\n")
    with io.open(out, "w", encoding="utf-8", newline="") as f:
        f.write(buf.getvalue())

    print(f"saved {out}  {len(rows)} cues")
    print()
    print(f"{'seg':>4} {'chars':>6} {'sec':>6} {'cps':>5}  window")
    tc = ts = 0.0
    for bid, t0, t1, cues in BLOCKS:
        n = sum(nchars(c) for c in cues)
        tc += n
        ts += t1 - t0
        print(f"{bid:>4} {n:>6} {t1 - t0:>6.1f} {n / (t1 - t0):>5.2f}  {to_ms(t0)} -> {to_ms(t1)}")
    print(f"{'ALL':>4} {int(tc):>6} {ts:>6.1f} {tc / ts:>5.2f}")
    for w in warnings:
        print("WARN", w)


if __name__ == "__main__":
    main()
