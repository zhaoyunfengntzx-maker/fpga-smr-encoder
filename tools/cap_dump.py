"""台架上单独抓一段波形并落盘（不启动界面）。

用途：
  * 硬件刚焊好/刚烧完位流时，先确认 0x072E dump 通路通不通；
  * 抓到的数据要拿去做算法分析（`--csv` / `--npy` 直接喂 numpy / MATLAB）；
  * 排查"界面显示不对"到底是固件问题还是界面问题。

例：
    python tools/cap_dump.py                       # 自动找板子，抓默认 1.15 ms
    python tools/cap_dump.py --port COM3 --dec 0   # 原始 50 MSPS、0.57 ms
    python tools/cap_dump.py --trig rise --level 400 --pre 2048
    python tools/cap_dump.py --csv cap.csv --png cap.png

退出码：0 成功；1 抓包失败；2 连不上串口。
"""

from __future__ import annotations

import argparse
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_HOST = os.path.join(os.path.dirname(_HERE), "host")
for _p in (_HOST, _HERE):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import capture as cap          # noqa: E402
import link as lk              # noqa: E402


def pick_port(explicit):
    if explicit:
        return explicit
    import ports as pm
    port_list = pm.list_serial_ports()          # [(device, desc, hwid), ...]
    return pm.preferred_port(port_list)


def main(argv=None):
    ap = argparse.ArgumentParser(description="抓一段原始 ADC 波形（0x072E 批量 dump）")
    ap.add_argument("--port", help="串口名（默认自动找 CH340）")
    ap.add_argument("--src", choices=("raw", "cor"), default="raw",
                    help="raw=ADC 原始 50 MSPS；cor=校正通道 12.5 MSPS")
    ap.add_argument("--dec", type=int, default=1, choices=(0, 1, 2, 3),
                    help="抽取 log2：0=×1 1=×2（默认）2=×4 3=×8")
    ap.add_argument("--len", type=int, default=cap.CAP_DEPTH, dest="length",
                    help="窗口点数（64 的倍数，最大 %d）" % cap.CAP_DEPTH)
    ap.add_argument("--trig", choices=("now", "rise", "fall"), default="now",
                    help="触发方式")
    ap.add_argument("--level", type=int, default=0, help="边沿触发门限（有符号码值）")
    ap.add_argument("--pre", type=int, default=1024, help="预触发点数")
    ap.add_argument("--timeout", type=float, default=10.0, help="dump 超时（秒）")
    ap.add_argument("--udp", action="store_true",
                    help="走以太网 UDP 回读（需要网线直连 + 固定 IP），否则走串口 dump")
    ap.add_argument("--udp-port", type=int, default=5000, help="本机 UDP 监听端口")
    ap.add_argument("--udp-bind", default="", help="本机网口 IP（如 192.168.1.100）")
    ap.add_argument("--csv", help="导出 CSV 到这个路径")
    ap.add_argument("--npy", help="导出 NPY 到这个路径")
    ap.add_argument("--png", help="导出 PNG 到这个路径")
    args = ap.parse_args(argv)

    port = pick_port(args.port)
    if not port:
        print("找不到串口：请插上板子，或用 --port 指定")
        return 2
    w = lk.SerialWorker(port)
    w.start()
    # 等线程把口打开（最多 3 s）
    import time
    t0 = time.monotonic()
    while not w.connected and time.monotonic() - t0 < 3.0:
        time.sleep(0.05)
    if not w.connected:
        print("打不开 %s：%s" % (port, w.error or "未知原因"))
        w.stop()
        return 2
    print("已连接 %s" % port)

    trig = {"now": 0, "rise": 1, "fall": 2}[args.trig]
    if args.udp:
        import udp_capture as ucap
        uc = ucap.UdpCapture(port=args.udp_port, bind_ip=args.udp_bind,
                             timeout_s=args.timeout)
        try:
            res = uc.capture_once(
                w, src=(1 if args.src == "cor" else 0), dec_log2=args.dec,
                length=args.length, trig=trig, level=args.level, pre=args.pre,
                progress=lambda f: print("  [%3.0f%%] 收到 UDP 包…" % (f * 100)))
        except (cap.CaptureError, ucap.UdpCaptureError) as exc:
            print("抓包失败：%s" % exc)
            return 1
        finally:
            uc.close()
            w.stop()
    else:
        try:
            res = cap.capture_once(
                w, src=(1 if args.src == "cor" else 0), dec_log2=args.dec,
                length=args.length, trig=trig, level=args.level, pre=args.pre,
                dump_timeout=args.timeout,
                progress=lambda text, frac: print("  [%3.0f%%] %s" % (frac * 100, text)))
        except cap.CaptureError as exc:
            print("抓包失败：%s" % exc)
            return 1
        finally:
            w.stop()

    print(res.summary())
    print("CH1 峰峰值 %d，CH2 峰峰值 %d，耗时 %.2f s"
          % (res.peak_to_peak(0), res.peak_to_peak(1),
             float(res.meta.get("elapsed_s", 0))))
    if args.csv:
        res.to_csv(args.csv)
        print("CSV  -> %s" % args.csv)
    if args.npy:
        res.to_npy(args.npy)
        print("NPY  -> %s" % args.npy)
    if args.png:
        res.to_png(args.png)
        print("PNG  -> %s" % args.png)
    return 0 if res.ok else 1


if __name__ == "__main__":
    sys.exit(main())
