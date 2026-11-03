"""上板：串口 dump 端到端自检（验证 0x072E 的 dump_req 锁存修复）。

用法（仓库根目录）：
    python tools/board_dump_test.py [COM6]

流程：起 worker -> 读设备信息 -> 配置 -> 立即触发采集 28672 点 -> dump 448 块
     -> 打印样点摘要。只验串口链路；ping/UDP 用 tools/board_eth_check.py。
"""
import os
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import host.link as link
import host.capture as capture

args = [a for a in sys.argv[1:] if a not in ("--port", "-p")]
port = args[0] if args else "COM6"

w = link.SerialWorker(port)
w.start()
t0 = time.time()
while not w.connected and time.time() - t0 < 5:
    time.sleep(0.05)
print("connected:", w.connected)
if not w.connected:
    sys.exit(1)

info = w.read_device_info()
print("device_info:", {k: info.get(k) for k in ("device_id", "rev", "rev2", "rtl_build")})
for rg in (0x0700, 0x0704, 0x0706, 0x0708, 0x070A, 0x070C, 0x0724, 0x0728, 0x072C,
           0x072E, 0x0730, 0x0732, 0x0734):
    r = w.read_reg(rg)
    print("  0x%04X = %s" % (rg, None if r is None else "0x%04X" % r["value"]))

ok, err = w.capture_configure(src=0, dec_log2=1, length=28672, trig=0)
print("configure:", ok, err)
if not ok:
    sys.exit(1)

time.sleep(0.2)
for rg in (0x0724, 0x0728, 0x0732):
    r = w.read_reg(rg)
    print("  after arm 0x%04X = %s" % (rg, None if r is None else "0x%04X" % r["value"]))

t = time.time()
try:
    payload = w.capture_dump(448)
    print("dump: %d bytes in %.2f s" % (len(payload), time.time() - t))
except Exception as exc:  # noqa: BLE001
    print("dump FAILED:", type(exc).__name__, exc)
    sys.exit(1)

try:
    res = capture.capture_once(w, src=0, dec_log2=1, length=28672, trig=0)
    print("capture_once: n=%d ok=%s duration=%.6f s dt=%.6f s" %
          (res.n, res.ok, res.duration_s, res.dt_s))
    print("summary:", res.summary())
except Exception as exc:  # noqa: BLE001
    # 上板实测：dump 之后紧接着再写 0x0718 偶尔会超时（桥要等遥测行边界），
    # 这一步只是"顺带再验一次采集"，失败不影响 dump 本身的结论。
    print("capture_once skipped after dump:", type(exc).__name__, exc)
w.stop()
