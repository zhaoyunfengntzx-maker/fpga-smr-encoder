"""连续流（B3）长稳验收：开流 → 收包 → 统计丢包/速率，并回读板端计数器。

用法:
    python tools/stream_longrun.py --port 47234 --dur 30

注意:
    - 设备的目的端口由 0x070C 决定，复位后是 5000；PC 的 5000 常被
      Vivado 许可证服务（lkcitdl）占用，所以默认用 47234。
    - 重新烧写后先 ping 一次，让板子学到主机 MAC（连续流用 host_mac 作目的 MAC）。
"""

import argparse
import subprocess
import sys
import time

sys.path.insert(0, '.')
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

from host.link import SerialWorker            # noqa: E402
from host.stream_capture import StreamReceiver  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description='连续流长稳验收')
    ap.add_argument('--port', type=int, default=47234, help='主机监听端口（与 0x070C 一致）')
    ap.add_argument('--dur', type=float, default=30.0, help='采集时长（秒）')
    ap.add_argument('--com', default='COM6', help='串口')
    ap.add_argument('--host-ip', default='192.168.1.100', help='PC 网口 IP（用于 ping 预热）')
    ap.add_argument('--dev-ip', default='192.168.1.10', help='板子 IP')
    ap.add_argument('--no-ping', action='store_true', help='跳过 ping 预热')
    ap.add_argument('--dec', type=int, default=None, choices=[0, 1, 2, 3],
                    help='抽取档（0=÷1 50MSPS…3=÷8 6.25MSPS）；不填则保持板上现值。'
                         '满速流会占满 1GbE、把 ping/自检挤掉，长时间浸泡建议 --dec 3')
    args = ap.parse_args()

    if not args.no_ping:
        subprocess.run(['ping', '-S', args.host_ip, '-n', '1', '-w', '600', args.dev_ip],
                       capture_output=True)

    w = SerialWorker(args.com)
    w.start()
    t0 = time.time()
    while not w.connected and time.time() - t0 < 3:
        time.sleep(0.05)
    if not w.connected:
        print('串口连接失败:', args.com)
        return 1

    def rd(a):
        r = w.read_reg(a)
        return -1 if not isinstance(r, dict) else int(r['value']) & 0xFFFF

    def rd32(lo, hi):
        return rd(lo) | (rd(hi) << 16)

    r = StreamReceiver(port=args.port, history=1 << 20)
    r.start()
    time.sleep(0.3)
    w.write_reg(0x070C, args.port, verify=False)
    if args.dec is not None:
        w.write_reg(0x0742, args.dec, verify=False)
        time.sleep(0.1)
    dec_now = rd(0x0742)
    print('抽取档 0x0742=%d（÷%d，%.2f MSPS 有效）'
          % (dec_now, 1 << dec_now, 50.0 / (1 << dec_now)))
    p0, d0, u0 = rd32(0x0746, 0x0748), rd32(0x074A, 0x074C), rd(0x074F)

    w.write_reg(0x0740, 1, verify=False)
    time.sleep(args.dur)
    w.write_reg(0x0740, 0, verify=False)
    time.sleep(0.5)

    p1, d1, u1 = rd32(0x0746, 0x0748), rd32(0x074A, 0x074C), rd(0x074F)
    pkts, lost, rate = r.packets, r.lost, r.rate_sps
    err = r.last_error
    r.stop()
    w.stop()

    total = p1 - p0
    print('板端: pkts +%d  drop +%d  underflow %d->%d  lag=%d' % (total, d1 - d0, u0, u1, rd(0x074E)))
    print('主机: pkts=%d  lost=%d  有效 %.2f MSPS  端到端 %.2f%%' %
          (pkts, lost, rate / 1e6, (100.0 * pkts / total) if total else 0.0))
    if err:
        print('错误:', err)
    ok = total > 0 and pkts > 0 and (100.0 * pkts / total) > 95.0
    print('结论:', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
