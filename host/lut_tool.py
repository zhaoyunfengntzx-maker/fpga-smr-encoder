"""全周角度补偿表（S5）离线工具：误差曲线 → 4096 点表 → 烧进 FPGA。

为什么需要它
------------
`rtl/angle_lut.v` 是一张 4096×16 的表，FPGA 自己不知道该往里填什么 —— 表内容
必须由「外部基准测量」得到：激光干涉仪 / 自准直仪 / 双读数头对比，测出全周
角度误差（机械角 → 误差角秒）后换算成 16 位修正量写进去。本工具做三件事：

1. `--check`  校验 CSV 是否能填表（点数、单调、范围），不碰硬件；
2. `--dump`   把换算结果打印出来（可直接贴进报告核对量级）；
3. `--upload` 通过串口把整表写进 FPGA，可选逐点回读校验。

CSV 格式（UTF-8，`#` 开头为注释，逗号/空格/制表符分隔均可）：

    # 机械角(deg), 误差(arcsec) —— 误差 = 上位机读数 - 基准读数
    0.000,   0.0
    45.000, 12.5
    90.000, -8.0
    ...
    360.000, 0.0

★ 两点铁律（踩过的坑，别改回去）
--------------------------------
1. **一条表记录只需 2 次串口事务**：桥一次事务写两个字节（低字节→addr、
   高字节→addr+1），所以写 0x0141 就同时把地址高 4 位写进 0x0142，写 0x0143
   就同时触发 0x0144 的写脉冲把整条记录推进 BRAM（`host/regs.py:lut_entry_writes`）。
2. **写表期间必须 en=0**（0x0145=0）：表内容上电未定义，边写边用会让角度
   出现随机跳变。写完整表后再置 0x0145=1 启用。

用法
----
    python host\\lut_tool.py --check err.csv
    python host\\lut_tool.py --dump  err.csv
    python host\\lut_tool.py --upload err.csv --port COM7
    python host\\lut_tool.py --upload err.csv --port COM7 --verify --enable
    python host\\lut_tool.py --upload --zeros --port COM7          # 清空并关闭
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import regs  # noqa: E402


def _fatal(msg):
    print("错误：" + msg)
    return 2


def parse_csv(path):
    """读 (deg, arcsec) 对；容忍空行、注释、逗号/空格/制表符分隔。"""
    pairs = []
    with open(path, "r", encoding="utf-8-sig") as f:
        for ln, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            parts = s.replace(",", " ").replace("\t", " ").split()
            if len(parts) < 2:
                raise ValueError("第 %d 行只有 %d 列：%s" % (ln, len(parts), s))
            try:
                deg = float(parts[0])
                err = float(parts[1])
            except ValueError:
                raise ValueError("第 %d 行不是数字：%s" % (ln, s))
            pairs.append((deg, err))
    if len(pairs) < 2:
        raise ValueError("至少需要 2 个点，实际 %d 个" % len(pairs))
    pairs.sort(key=lambda p: p[0])
    for a, b in zip(pairs, pairs[1:]):
        if b[0] <= a[0]:
            raise ValueError("角度必须严格递增：%.3f 与 %.3f 重复" % (a[0], b[0]))
    if pairs[0][0] < -1e-9 or pairs[-1][0] > 360.0 + 1e-9:
        raise ValueError("角度必须落在 0..360，实际 %.3f..%.3f"
                         % (pairs[0][0], pairs[-1][0]))
    return pairs


def check_pairs(pairs):
    """返回 (ok, 报告行列表)。"""
    lines = []
    errs = [p[1] for p in pairs]
    span = max(errs) - min(errs)
    lines.append("点数        : %d" % len(pairs))
    lines.append("角度范围    : %.3f .. %.3f deg" % (pairs[0][0], pairs[-1][0]))
    lines.append("误差范围    : %+.2f .. %+.2f arcsec（峰峰 %.2f）"
                 % (min(errs), max(errs), span))
    ok = True
    if pairs[0][0] > 1.0:
        lines.append("⚠ 起点太晚：第一点在 %.3f°，0..%.0f° 段会被常量外推"
                     % (pairs[0][0], pairs[0][0]))
        ok = False
    if pairs[-1][0] < 359.0:
        lines.append("⚠ 覆盖不足：最后一点 < 359°，359..360 段会被常量外推")
        ok = False
    # 单点跳变检查：相邻两点误差差 > 200″ 基本是测错或漏点
    for (d0, e0), (d1, e1) in zip(pairs, pairs[1:]):
        if abs(e1 - e0) > 200.0:
            lines.append("⚠ 相邻点跳变过大：%.2f°→%.2f° 差 %.1f″（测错或漏点）"
                         % (d0, d1, e1 - e0))
            ok = False
    k = 3600.0 * 360.0 / (2048.0 * (1 << 16))
    lines.append("1 LSB       : %.5f arcsec" % k)
    lines.append("峰峰折算    : %.0f LSB（16 位有符号上限 32767）" % (span / k))
    if span / k > 32767:
        lines.append("⚠ 误差太大，超出表格量程 ±0.088°")
        ok = False
    return ok, lines


def _rd(w, addr, timeout=0.6):
    """读一个寄存器，返回 0..0xFFFF 或 None（link.read_reg 返回 dict）。"""
    r = w.read_reg(addr, timeout=timeout)
    if not r:
        return None
    return int(r.get("value", 0)) & 0xFFFF


def do_upload(words, port, verify, enable, zeros, timeout=0.6):
    import link
    w = link.SerialWorker(port, batch_ms=1.0)
    w.start()
    t0 = time.time()
    while time.time() - t0 < 3.0 and not w.connected:
        if w.error:
            print("打开串口失败：%s" % w.error)
            return 2
        time.sleep(0.05)
    if not w.connected:
        print("串口 %s 未就绪（3 s 超时）" % port)
        return 2

    try:
        # 0) 先关表，避免写一半就用上
        w.write_reg(regs.REG_LUT_CTRL, 0x00, timeout=timeout, verify=False)

        # 1) 整表写入：一条记录 2 次事务
        n = len(words)
        for i, val in enumerate(words):
            for addr, v in regs.lut_entry_writes(i, val):
                w.write_reg(addr, v, timeout=timeout, verify=False)
            if (i + 1) % 512 == 0:
                sys.stdout.write("\r  写入 %d / %d" % (i + 1, n))
                sys.stdout.flush()
        sys.stdout.write("\r  写入 %d / %d 完成\n" % (n, n))

        # 2) 可选：逐点回读校验（0x0145 bit1=1 让读口跟随表地址）
        bad = 0
        if verify:
            for i, val in enumerate(words):
                w.write_reg(regs.REG_LUT_ADDR0, i & 0xFFFF, timeout=timeout, verify=False)
                w.write_reg(regs.REG_LUT_CTRL, 0x02, timeout=timeout, verify=False)
                lo = _rd(w, regs.REG_LUT_READ0, timeout)
                hi = _rd(w, regs.REG_LUT_READ1, timeout)
                if lo is None or hi is None:
                    print("\n  回读失败（串口超时）于点 %d" % i)
                    return 1
                got = (hi << 8) | lo
                if got != (int(val) & 0xFFFF):
                    bad += 1
                    if bad <= 5:
                        print("  ✗ 点 %d 回读 %04X ≠ 写入 %04X"
                              % (i, got, int(val) & 0xFFFF))
                if (i + 1) % 512 == 0:
                    sys.stdout.write("\r  校验 %d / %d（错 %d）" % (i + 1, n, bad))
                    sys.stdout.flush()
            w.write_reg(regs.REG_LUT_CTRL, 0x00, timeout=timeout, verify=False)
            print("\n  校验完成：%d 点，错误 %d" % (n, bad))
            if bad:
                print("★ 表内容不可信，未启用。请重试或改用 --zeros 清空。")
                return 1

        # 3) 启用/关闭
        want = 0x01 if enable else 0x00
        w.write_reg(regs.REG_LUT_CTRL, want, timeout=timeout, verify=False)
        rb = _rd(w, regs.REG_LUT_CTRL, timeout)
        print("  0x0145 = %s（期望 0x%02X）"
              % ("读失败" if rb is None else "0x%02X" % rb, want))
        if zeros:
            print("  已清空：4096 点全 0，表关闭")
    except Exception as exc:                       # noqa: BLE001
        print("\n上传中断：%r" % (exc,))
        return 1
    finally:
        try:
            w.stop()
        except Exception:                          # noqa: BLE001
            pass
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="全周角度补偿表工具（S5）")
    ap.add_argument("csv", nargs="?", help="误差曲线 CSV（角度 deg, 误差 arcsec）")
    ap.add_argument("--check", action="store_true", help="只校验 CSV，不碰硬件")
    ap.add_argument("--dump", action="store_true", help="打印换算后的表（前若干点）")
    ap.add_argument("--upload", action="store_true", help="通过串口写入 FPGA")
    ap.add_argument("--zeros", action="store_true", help="整表填 0（清空）")
    ap.add_argument("--port", help="串口号，如 COM7")
    ap.add_argument("--verify", action="store_true", help="逐点回读校验（较慢）")
    ap.add_argument("--enable", action="store_true", help="写完后启用补偿表")
    a = ap.parse_args(argv)

    if not (a.check or a.dump or a.upload):
        ap.print_help()
        return 2

    if a.zeros:
        pairs = [(0.0, 0.0), (360.0, 0.0)]
    else:
        if not a.csv:
            return _fatal("需要 CSV 文件（或加 --zeros）")
        try:
            pairs = parse_csv(a.csv)
        except (OSError, ValueError) as exc:
            return _fatal(str(exc))

    ok, lines = check_pairs(pairs)
    if a.check:
        print("== CSV 校验 ==")
        for s in lines:
            print("  " + s)
        print("  结论：%s" % ("可以填表" if ok else "有问题，见上面的 ⚠"))
        return 0 if ok else 1

    words = regs.lut_words_from_pairs(pairs)
    if a.dump:
        print("== 表（4096 点，每 256 点采样一次；单位 = 角度 LSB）==")
        for i in range(0, regs.LUT_N, 256):
            print("  点 %4d (%6.2f°) : %6d" % (i, 360.0 * i / regs.LUT_N, words[i]))
        print("  合计非零 %d 点，峰值 %d LSB"
              % (sum(1 for v in words if v), max(abs(v) for v in words)))

    if a.upload:
        if not a.port:
            return _fatal("--upload 需要 --port COMx")
        if not ok:
            print("★ CSV 校验未通过，仍要写入请加 --dump 人工确认后再执行")
            return 1
        print("== 写入 FPGA (%s) ==" % a.port)
        return do_upload(words, a.port, a.verify, a.enable, a.zeros)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
