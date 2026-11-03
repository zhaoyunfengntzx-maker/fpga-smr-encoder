"""命令与采集控制：把界面上的一次点击变成"发一批寄存器/起一次抓包"。

设计约束（改这个文件前先读）：
1. **这里不发串口帧**。所有真正碰串口的事都在 `tasks.py` 的任务函数里，本模块只负责
   "参数校验 -> 挑任务 -> 排进 TaskRunner -> 忙态置位"。想加一条新命令，照这个顺序加，
   不要在界面回调里直接 `worker.write_reg(...)`（会阻塞 GUI 线程，还会和 tick 抢串口）。
2. **同一条命令在忙的时候必须拒绝第二次**（`if self.busy: return`）。串口是单主人、
   应答按顺序配对的，两笔命令交错就会把结果配错对（老版本"写生效却报失败"就是这么来的）。
3. **每个 `_done_xxx` 都要能处理 `None` 与异常结果**：任务失败时 result 是 Exception 对象
   （见 taskrunner），界面必须亮错误而不是干等。异常分支的清理与成功分支同等重要。
4. 所有回读值原样进面板，不在这里做单位换算（换算在 regs.py，显示在 panel_*）。

依赖的宿主属性：`worker`、`busy`、`task`、`log_line()`、`_set_state()`、`capture`、`lut`、
`board_status`、`record`、`speed`、`interp`、`abz`、`_stream`、`busy` 等。
"""

from __future__ import annotations

import os
import queue
import socket
import subprocess
import sys
import threading
import time

from PySide6.QtCore import Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QMessageBox

import abz as az
import alarm as sg
import capture as cap
import export_png as ep
import link as lk
import panel_capture as pc
import panel_lut as plut
import panel_status as pst
import ports as pm
import regs
import replay as rp
import stream_capture
import theme as th
import ui_kit as uk
import udp_capture as udp
from ui_consts import STREAM_POINTS, TAG_TEXT, cfg_from_regs
import tasks as ts
from tasks import (SQUARE_POINTS, output_write_value, square_pair, task_apply_inter_div,
                   task_clear_latch, task_lut_dump, task_lut_upload, task_read_all,
                   task_read_board_status, task_read_status, task_set_bias_track,
                   task_write_advanced, task_write_pairs)

C = th.C


class CmdsMixin(object):
    """界面命令 -> 任务 -> 回填。"""

    def _on_check(self):
        if self.worker is None or self.busy:
            return
        self._set_busy(True)
        self.lab_check.setText("正在读取设备信息与倍频配置…")
        w = self.worker
        self.task.run(lambda: task_read_all(w), "check")

    # --------------------------------------------------------- 倍频与极对数

    def _on_apply_inter_div(self, spec):
        if self.worker is None or self.busy:
            return
        inter, div = spec["inter"], spec["div"]
        self._set_busy(True)
        self.log_line("写入倍频：inter=%d div=%d（等效 ×%.3f）" % (inter, div, inter / div))
        w = self.worker
        self.task.run(lambda: task_apply_inter_div(w, inter, div), "apply")

    def _on_write_pairs(self, pairs):
        if self.worker is None or self.busy:
            return
        self._set_busy(True)
        self.log_line("写入极对数 0x0100 = %d" % pairs)
        w = self.worker
        self.task.run(lambda: task_write_pairs(w, pairs), "pairs")

    def _on_apply_advanced(self, writes):
        if self.worker is None or self.busy:
            return
        if not writes:
            self.log_line("高级参数没有改动，无需写入")
            return
        self._set_busy(True)
        self.log_line("写入高级参数 %d 个寄存器：%s"
                      % (len(writes), "、".join("0x%04X" % a for a in sorted(writes))))
        w = self.worker
        self.task.run(lambda: task_write_advanced(w, writes), "adv")

    def _on_set_output(self, bits):
        """⑨ 卡的「ABZ 使能 / UVW 使能」一键按钮：读-改-写 0x0109 的 bit6/bit7。

        为什么按钮放在 ⑨ 卡而写命令在窗口里做：写寄存器要"有串口、不忙、有板上现值"三个条件，
        这些状态只有窗口知道；面板只管发"想要的目标位"，被拒时窗口回调 `restore_output()`
        把按钮拨回板上实际值 —— 不会出现"界面显示已开、板上其实还关着"。
        """
        if self.worker is None or self.busy:
            self._log_notice("输出使能未写入：%s"
                             % ("串口未连接" if self.worker is None
                                else "正在执行其它读写，稍后再点"), "warn")
            self.abz.restore_output()
            return
        cur = (self.interp.regs_raw or {}).get(regs.REG_OUTPUT)
        val = output_write_value(cur, bits)
        if val is None:
            self._log_notice("输出使能未写入：还没读回 0x0109（先点顶栏「设备自检」）",
                             "warn")
            self.abz.restore_output()
            return
        want = "、".join("%s=%d" % (k, 1 if v else 0) for k, v in sorted(bits.items()))
        if val == (int(cur) & 0xFFFF):
            self.log_line("输出使能已是目标值（%s）：0x0109 = 0x%04X（%s）"
                          % (want, cur, regs.output_text(cur)))
            self.abz.set_output(regs.decode_output(cur) or {}, cur)
            return
        self._set_busy(True)
        self.log_line("一键设输出使能：%s → 写 0x0109 = 0x%04X（%s）"
                      % (want, val, regs.output_text(val)))
        w = self.worker
        self.task.run(lambda: task_write_advanced(w, {regs.REG_OUTPUT: val}), "adv")

    # ------------------------------------------------- ⑨卡「方波可看」预设
    def _on_square_preset(self):
        """⑨ 卡的「方波可看」：把 分箱 / inter 配成"每箱跨 ≤1/16 个 A/B 周期"的组合。

        为什么是这两件事：图上的 A/B 是"每角度箱里 A/B 为高的平均占比"，一箱跨 `inter/箱数`
        个 A/B 周期 —— 跨满一个周期时箱内高低各半、均值恒 ~0.5，画出来既没有 0 也没有 1
        （真机 inter=256/256 箱时 97% 的箱落在 0.05~0.95，这就是"不是方波"的唯一原因）。
        目标值由纯函数 `square_pair()` 算：优先保住 inter（不改板上 AB 输出频率），只把箱数
        提到够用的最小档；inter 实在太大才降 inter。写 0x0101/0x0102 走既有「应用倍频」路径
        （`task_apply_inter_div`），`_done_apply` 会回灌 ⑥ 卡与 ⑨ 卡；分箱先在本地改好。
        """
        if self.worker is None or self.busy:
            self._log_notice("「方波可看」未执行：%s"
                             % ("串口未连接" if self.worker is None
                                else "正在执行其它读写，稍后再点"), "warn")
            return
        raw = self.interp.regs_raw or {}
        inter, div = regs.decode_inter_div(raw.get(regs.REG_INTER0),
                                          raw.get(regs.REG_INTER1))
        if inter is None or div is None:
            self._log_notice("「方波可看」未执行：还没读回 0x0101/0x0102"
                             "（先点顶栏「设备自检」）", "warn")
            return
        bins0 = self.abz.bins()
        bins, inter2 = square_pair(inter, bins0)
        if bins == bins0 and inter2 == inter:
            self.log_line("「方波可看」：现在就是能看方波的组合（分箱 %d ≥ %d×inter=%d），不用改"
                          % (bins0, SQUARE_POINTS, SQUARE_POINTS * inter))
            self.abz.set_bins(bins0)
            self._sync_abz_bins(bins0)
            return
        # 记下按下之前的值，供「还原」；只有真改了才记（重复按不会把"原值"覆盖成预设值）。
        # 除了解出来的 (inter, div)，还把**原始寄存器字节**一起记下来：decode→encode 不是恒等
        # （原始 0x0000/0x0000 解成 256/1，再编回去是 0x0000/0x0001），只有把当初读到的值原样
        # 写回，才能保证「还原」逐字节回到按下之前的状态。
        if self._sq_saved is None:
            self._sq_saved = {"inter": inter, "bins": bins0, "div": div,
                              "raw": {regs.REG_INTER0: raw.get(regs.REG_INTER0),
                                      regs.REG_INTER1: raw.get(regs.REG_INTER1)}}
        self.abz.set_bins(bins)
        self._sync_abz_bins(bins)
        if inter2 == inter:
            self.log_line("「方波可看」：分箱 %d → %d（inter 不变 %d，每箱跨 %.4f 个 A/B 周期）"
                          % (bins0, bins, inter, inter / float(bins)))
            return                                  # 不用写板子
        self._set_busy(True)
        self.log_line("「方波可看」：inter %d → %d、分箱 %d → %d（每箱跨 %.4f 个 A/B 周期，"
                      "每周期 %.0f 点）——注意这会改板上 AB 输出频率"
                      % (inter, inter2, bins0, bins, inter2 / float(bins),
                         bins / float(inter2)))
        w = self.worker
        self.task.run(lambda: task_apply_inter_div(w, inter2, div), "apply")

    def _on_square_restore(self):
        """⑨ 卡的「还原」：把 inter / 分箱改回按「方波可看」之前的值。"""
        if self._sq_saved is None:
            self._log_notice("「还原」没做什么：还没按过「方波可看」（或已经还原过了）", "info")
            return
        if self.worker is None or self.busy:
            self._log_notice("「还原」未执行：%s"
                             % ("串口未连接" if self.worker is None
                                else "正在执行其它读写，稍后再点"), "warn")
            return
        sv = dict(self._sq_saved)
        raw_now = self.interp.regs_raw or {}
        cur_inter, cur_div = regs.decode_inter_div(raw_now.get(regs.REG_INTER0),
                                                   raw_now.get(regs.REG_INTER1))
        # 优先逐字节写回当初读到的原始值（写 0x0101 在现板上是 16 位对写，一次就能把
        # inter/div 通道还原）；没有原始值（例如 regs_raw 里缺字节）才退回按 (inter, div) 重编
        raw = {a: v for a, v in (sv.get("raw") or {}).items() if v is not None}
        bins_now = self.abz.bins()
        self._sq_saved = None
        self.abz.set_bins(sv["bins"])
        self._sync_abz_bins(sv["bins"])
        # "已经是原值"的判据要看**原始字节**：decode→encode 不是恒等（0x0000/0x0000 与
        # 0x0000/0x0001 解出来都是 256/1），只看解出来的 (inter, div) 会漏掉字节级差异
        raw_same = len(raw) != 2 or all(raw[a] == raw_now.get(a) for a in raw)
        if cur_inter == sv["inter"] and bins_now == sv["bins"] and raw_same:
            self.log_line("「还原」：已经是原值（inter=%d、分箱 %d），无需写板子"
                          % (sv["inter"], sv["bins"]))
            return
        self._set_busy(True)
        if len(raw) == 2:
            self.log_line("「还原」：原样写回 0x0101=0x%04X、0x0102=0x%04X（按下之前读到的值），"
                          "分箱 %d → %d"
                          % (raw[regs.REG_INTER0], raw[regs.REG_INTER1], bins_now, sv["bins"]))
            w = self.worker
            self.task.run(lambda: task_write_advanced(w, dict(raw)), "adv")
            return
        self.log_line("「还原」：inter %s → %d、div %s → %d、分箱 %d → %d"
                      % (cur_inter, sv["inter"], cur_div, sv["div"], bins_now, sv["bins"]))
        w = self.worker
        self.task.run(lambda: task_apply_inter_div(w, sv["inter"], sv["div"]), "apply")

    # ---------------------------------------------------- 告警/幅值状态 M7
    def _on_read_status(self):
        if self.worker is None or self._status_busy:
            return
        self._status_busy = True
        w = self.worker
        self.task.run(lambda: task_read_status(w), "status")

    def _on_clear_latch(self):
        if self.worker is None or self.busy:
            return
        # 危险操作二次确认（需求 §界面要求）：这是往板子写寄存器，先问一句
        btn = QMessageBox.question(
            self, "清除锁存告警",
            "将向板子写入 0x0405 = 0x%02X 清除锁存告警位。\n"
            "如果故障此刻仍然存在，下一拍会重新锁存告警。\n\n确定要清除吗？"
            % sg.LATCH_CLEAR_VALUE,
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
        if btn != QMessageBox.Yes:
            self.log_line("清除锁存告警：已取消")
            return
        self._set_busy(True)
        self.log_line("清除锁存告警：写 0x0405 = 0x%02X（W1C；写 bit0 同拍发 clr_otr 脉冲）"
                      % sg.LATCH_CLEAR_VALUE)
        w = self.worker
        self.task.run(lambda: task_clear_latch(w), "clear")

    # ------------------------------------------------ 板上运行状态镜像（只读）
    def _on_read_board_status(self):
        w = self.worker
        if w is None or not w.is_alive() or self._bstatus_busy:
            return
        self._bstatus_busy = True
        self.board_status.set_reading(True)
        self.task.run(lambda: task_read_board_status(w), "bstatus")

    def _on_bias_track(self, on=True):
        """打开板端偏置慢跟踪。这是"零基准标定"里唯一一项纯软件就能拿到的精度。"""
        w = self.worker
        if w is None or not w.is_alive() or self._bstatus_busy:
            return
        self._bstatus_busy = True
        self.board_status.set_reading(True)
        self.log_line("板上状态：写 0x0122 bit1（%s偏置慢跟踪）" % ("打开" if on else "关闭"))
        self.task.run(lambda: task_set_bias_track(w, bool(on)), "biastrack")

    # ------------------------------------------------------- 全周补偿表
    def _on_lut_upload(self, words, verify, enable):
        w = self.worker
        if w is None or not w.is_alive():
            self.lut.set_error("串口没连上")
            return
        if self.lut.busy():
            return
        self.log_line("补偿表：开始写 %d 点（回读校验=%s，启用=%s）"
                      % (len(words), "开" if verify else "关", "是" if enable else "否"))
        self.task.run(lambda: task_lut_upload(w, list(words), bool(verify), bool(enable)),
                      "lutup")

    def _on_lut_zeros(self):
        w = self.worker
        if w is None or not w.is_alive():
            self.lut.set_error("串口没连上")
            return
        self.log_line("补偿表：清零整表并关闭")
        self.task.run(lambda: task_lut_upload(w, [0] * regs.LUT_N, False, False), "lutup")

    def _on_lut_dump(self, step):
        w = self.worker
        if w is None or not w.is_alive():
            self.lut.set_error("串口没连上")
            return
        self.log_line("补偿表：回读板上表（每 %d 点一个）" % int(step))
        self.task.run(lambda: task_lut_dump(w, step), "lutdump")

    def _done_lut_upload(self, res):
        self.lut.set_uploaded(res.get("bad", 0), res.get("ctrl", 0), res.get("t", 0.0))
        self.log_line("补偿表：写 %d 点，回读不符 %d，0x0145=0x%02X"
                      % (res.get("n", 0), res.get("bad", 0), res.get("ctrl", 0)),
                      "fault" if res.get("bad") else "ok")

    def _done_lut_dump(self, res):
        self.lut.set_dump(res.get("pts", {}))
        self.log_line("补偿表：回读 %d 点，0x0145=0x%02X"
                      % (len(res.get("pts", {})), res.get("ctrl", 0)))

    def _done_bias_track(self, res):
        self._bstatus_busy = False
        self.board_status.set_reading(False)
        if isinstance(res, Exception):
            self.board_status.set_bias_done(False, "写 0x0122 失败：%s" % res)
            self.log_line("板上状态：写 0x0122 失败：%s" % res, "err")
            return
        if not res.get("ok"):
            self.board_status.set_bias_done(False, res.get("why") or "没生效")
            self.log_line("板上状态：偏置慢跟踪没生效 —— %s" % (res.get("why") or ""), "warn")
            return
        self.board_status.set_bias_done(
            True, "偏置慢跟踪已打开：0x013C bit0=%s，学到的 bias_s %s / bias_c %s LSB"
            % (res.get("valid"), res.get("s"), res.get("c")))
        self.log_line("板上状态：偏置慢跟踪已打开（0x0122=0x%02X，0x013C bit0=%s）"
                      % (res.get("cfg"), res.get("valid")), "ok")

    def _done_board_status(self, raw):
        self.board_status.set_raw(raw or {})
        got = len(raw or {})
        self.log_line("板上状态：读了 %d/%d 个地址（前馈/锁定/偏置/补偿表）"
                      % (got, len(regs.STATUS_ADDRS)))

    # ------------------------------------------------------- 任务结果分发
    def _on_capture_requested(self, params):
        """抓包页点了「抓一次」：参数已经过界面校验，这里只管调度。"""
        p = dict(params)
        chan = p.get("transport", "serial")
        if chan == "stream":
            if self.busy:                       # 复查 P5：抓包进行中不许切去开流
                self.capture.set_stream_error("设备正忙（有别的命令在跑），稍后再开连续流")
                return
            self._toggle_stream(p)
            return
        if self.worker is None:
            self.capture.set_error("串口没连上")
            return
        if self.busy:
            self.capture.set_error("设备正忙（有别的命令在跑），稍后再抓")
            return
        if self._stream is not None:
            # 流开着时板子不放抓包（eth_udp_start_g 被 stream_en 门掉），
            # 直接抓会等成超时 —— 先把流停干净再抓。
            self.log_line("抓包：先停掉正在跑的连续流")
            self._stop_stream()
        w = self.worker
        self._set_busy(True)
        self.capture.set_busy(True)
        self.log_line("抓包：源=%s 抽取=×%d 点数=%d 触发=%d 电平=%d 预触发=%d 通道=%s"
                      % ("校正" if p.get("src") else "原始", 1 << p.get("dec_log2", 0),
                         p.get("length", 0), p.get("trig", 0), p.get("level", 0),
                         p.get("pre", 0),
                         "网口 UDP" if chan == "udp" else "串口回读"))
        # p 来自面板，额外带一个 UI 用的 "transport" 键；两个 capture_once 都
        # 不接受它（transport 由后端自己写进 meta）。不过滤会
        # TypeError: capture_once() got an unexpected keyword argument
        # 'transport'，抓包按钮直接失效（2026-10-22 修）。
        p = dict(p)
        p.pop("transport", None)
        if chan == "udp":
            def job():
                # ★ 端口由上位机选并写进设备：`0x070C` 复位是 5000，而本机 5000
                #   常被 lkcitdl 占用；不写就会“设备发到 5000、上位机听别的端口”。
                port = self._pick_udp_port()
                if port is None:
                    raise RuntimeError("本机 %d..%d 的 UDP 端口都被占用，先关掉占端口的程序"
                                       % (int(os.environ.get("FPGA_UDP_PORT", "5000")),
                                          int(os.environ.get("FPGA_UDP_PORT", "5000")) + 20))
                self._warm_arp(w)
                if w.write_reg(lk.REG_ETH_PORT, port, verify=False) is None:
                    raise RuntimeError("端口寄存器 0x070C 写入失败（%d）" % port)
                uc = udp.UdpCapture(port=port, bind_ip=self._udp_bind_ip())
                try:
                    # 刚烧完/链路刚起来时，第一次 UDP 抓包常丢中间一段（实测固定丢
                    # 44/82 包，第二次就干净）。这里最多重试一次，取缺块更少的那次；
                    # 串口路径不受影响。
                    best = None
                    for attempt in range(2):
                        res = uc.capture_once(w, **p)
                        miss = len(getattr(res, 'missing', None) or ())
                        if best is None or miss < len(getattr(best, 'missing', None) or ()):
                            best = res
                        if miss == 0:
                            break
                        if attempt == 0:
                            self.log_line("UDP 抓包缺 %d 块，自动重试一次" % miss, "warn")
                            time.sleep(0.3)
                    return best
                finally:
                    uc.close()
            self.task.run(job, tag="capture")
        else:
            self.task.run(lambda: cap.capture_once(w, **p), tag="capture")

    # ------------------------------------------------------------ 二期：连续流
    def _toggle_stream(self, p):
        """在「抓包」页开/停连续流（同一个按钮）。

        ★ 复查 P1（2026-10-22）：这里原来在 GUI 线程里 ping（最多 4×3.3 s）+ 两次
          verify 写寄存器，点一下窗口就"未响应"十秒级，期间 _tick 不跑、遥测只进
          不出。现在"选端口 / 催 ARP / 写 0x070C"整套进任务线程（tag="stream"），
          GUI 线程只改一行提示；结果回来后再起 socket 与定时器（毫秒级）。
        """
        # ★ 只有"在跑"才算正在跑：_stream 可能在但线程已死（异常退出 / 上一条
        #   开流半途失败 / 断开重连后残留）。原来只看 is not None，点「网口」会
        #   执行"停流"直接返回，表现就是"连接、断开、再连接之后再也起不来"。
        _r = getattr(self, "_stream", None)
        if _r is not None and getattr(_r, "running", False):
            self._stop_stream()
            return
        if _r is not None:
            self._stop_stream()          # 清掉残留（不会发流命令之外的多余动作）
        if self.worker is None:
            self.capture.set_error("串口没连上")
            return
        if self.busy:                       # 复查 P5：抓包/自检进行中不许开流
            self.capture.set_stream_error("设备正忙（有别的命令在跑），稍后再开连续流")
            return
        dec = int(p.get("dec_log2", 2))
        if dec < 2:
            # 50 MSPS × 4 B/点 @×2 = 800 Mbps，加上包间隙/以太网开销会顶爆千兆，
            # 所以连续流最低 ×4（12.5 MSPS ≈ 400 Mbps）。
            dec = 2
            self.log_line("连续流：抽取自动提到 ×4（×2 需要 800 Mbps，超出千兆余量）")
        params = dict(p)
        params["dec_log2"] = dec            # ★ P2：修正后的抽取必须跟着走，否则时间轴差 2 倍
        self._stream_params = dict(params)
        w = self.worker
        self._set_busy(True)
        self.capture.set_stream_error("正在打开连续流…（选端口 / 等板子学主机 MAC）")

        def job():
            # ★ 端口不再在这里"探测"：先绑 socket 再把它真正绑到的端口写给设备，
            #   彻底避免 TOCTOU（审计 P1-10）。这里只负责把主机 ARP 表催热。
            self._warm_arp(w, quiet=True)
            return True

        self.task.run(job, tag="stream")

    def _done_stream(self, port):
        """开流任务回来：先绑 socket（拿到真实端口）→ 再让设备开到那个端口。

        ★ 审计 P1-10：原来是"先探测空闲端口 → 关掉 → 稍后再绑"，中间有 TOCTOU
          窗口；现在直接绑（首选 FPGA_UDP_PORT，被占就让系统分配），绑完读回
          真实端口再写 0x070C，不存在"告诉设备的端口和自己监听的不一样"。
        ★ 审计 B5：`stream_start()` 要串口往返（最坏 ~5 s），交给任务线程做。
        """
        params = dict(self._stream_params or {})
        dec = int(params.get("dec_log2", 2))
        # ★ 基准采样率：raw 通道 50 MSPS，校正通道 12.5 MSPS（与 _done_stream_go /
        #   _on_stream_tick_body 口径一致）。少了这行 socket 建起来后会 NameError。
        src = int(params.get("src", 0))
        try:
            pref = int(os.environ.get("FPGA_UDP_PORT", "5000"))
        except ValueError:
            pref = 5000
        r = None
        last = None
        for cand in (pref, 0):                   # 0 = 系统分配临时端口
            try:
                r = stream_capture.StreamReceiver(
                    port=cand, bind_ip=self._udp_bind_ip(),
                    history=1 << 19, bufsize=64 << 20,
                    base_fs=(50e6 if not src else 12.5e6))
                r.start()
                break
            except stream_capture.StreamError as exc:
                last = exc
                r = None
        if r is None:
            self.capture.set_error("网口连续流打不开：%s" % last)
            return
        port = int(r.port)
        self._stream = r
        self._stream_p = params
        self._stream_p["udp_port"] = port
        w = self.worker
        self.task.run(lambda: self._stream_open_device(w, port, dec), tag="stream_go")

    def _stream_open_device(self, w, port, dec):
        """[任务线程] 把端口写进 0x070C 并回读核对，再让设备开流。"""
        if w is None:
            return (False, "串口已断开")
        d = w.write_reg(lk.REG_ETH_PORT, port, verify=True)
        if d is None:
            return (False, "端口寄存器 0x070C 写入失败（%d）" % port)
        got = int(d.get("value", -1)) & 0xFFFF
        if got != (port & 0xFFFF):
            return (False, "端口寄存器 0x070C 回读不符：写 %d，读 %d" % (port, got))
        # ★ 2026-11-02 上板实测：0x0710 bit2（host_known）=0 时，板子 TX 计数照涨
        #   但主机一个包都收不到，界面上就是"开流成功、没数据"。原因它不知道
        #   主机的目的 MAC。先教会它（ping 一次），再开流。
        if not self._host_known(w, tries=4):
            return (False, "板端还没记住主机 MAC（0x0710 bit2=0）："
                           "确认 PC 网口是 192.168.1.100/24、网线直连板子")
        ok, err = w.stream_start(dec)
        if not ok:
            return (ok, err)
        # 开流后再验一次"真的收到包"，收不到就补一次 warm + 重开
        for _ in range(2):
            time.sleep(0.6)
            if getattr(self, "_stream", None) is not None and self._stream.packets > 0:
                return (True, "")
            self._warm_arp(w, quiet=True)
            w.stream_stop()
            time.sleep(0.2)
            ok2, err2 = w.stream_start(dec)
            if not ok2:
                return (False, err2)
        if getattr(self, "_stream", None) is not None and self._stream.packets > 0:
            return (True, "")
        return (False, "开流后 1.2 s 没收到包（板端 host_known 掉了 / 防火墙拦 UDP）")

    def _host_known(self, w, tries=4):
        """确认板子记住了主机 MAC（0x0710 bit2），必要时 ping 它。"""
        for i in range(max(1, int(tries))):
            st = w.read_reg(lk.REG_ETH_STATUS)
            if isinstance(st, dict) and (int(st.get("value") or 0) & 0x4):
                return True
            self._warm_arp(w, quiet=True)
            time.sleep(0.25)
        return False

    def _abort_stream(self, err):
        """开流失败/异常的统一收尾：关 socket、停定时器、界面回错误态。"""
        self._stream_timer.stop()
        r, self._stream = self._stream, None
        if r is not None:
            try:
                r.stop()
            except Exception:                           # noqa: BLE001
                pass
        self.capture.set_error(err)

    def _done_stream_go(self, result):
        """设备开流命令回来（后台线程已完成串口往返）。"""
        ok, err = result if isinstance(result, tuple) else (False, str(result))
        if not ok:
            self._abort_stream(err)
            return
        params = dict(self._stream_p or {})
        dec = int(params.get("dec_log2", 2))
        src = int(params.get("src", 0))
        port = int(params.get("udp_port", 0))
        self._stream_timer.start(300)
        # 顶栏「数据源」等着的：流一起来就把界面切到网口
        if getattr(self, "_net_want", False):
            self._net_want = False
            self._net_on()
        self.capture.set_streaming(True)
        self.log_line("连续流：开始（抽取 ×%d，%.3f MSPS，UDP 端口 %d）"
                      % (1 << dec, stream_capture.fs_for_dec(
                          50e6 if not src else 12.5e6, dec) / 1e6, port))


    def _stop_stream(self):
        """停连续流：先停界面定时器，再关 socket，最后让设备停发。"""
        self._stream_timer.stop()
        r, self._stream = self._stream, None
        if r is not None:
            try:
                r.stop()
            except Exception:                                     # noqa: BLE001
                pass
        if self.worker is not None:
            # ★ 审计 2 #2：停流命令要串口往返（最坏几百毫秒），原来留在 GUI 线程，
            #   断开/关窗会卡一下。交给任务线程，界面立刻恢复。
            w = self.worker
            try:
                self.task.run(lambda: w.stream_stop(), "stream_stop")
            except Exception:                                     # noqa: BLE001
                pass
        self.capture.set_streaming(False)
        self.log_line("连续流：已停止")

    def _done_stream_stop(self, result):
        """连续流停止命令回来（后台线程）：失败只记日志，不打断界面。"""
        if isinstance(result, Exception):
            self.log_line("连续流：停止命令异常（%s）" % result, "warn")

    def _on_stream_tick(self):
        """定时器槽：任何异常都不许穿到 excepthook（否则每 300 ms 弹一个模态框）。"""
        try:
            self._on_stream_tick_body()
        except Exception as exc:                          # noqa: BLE001
            self._stream_timer.stop()
            self.capture.set_stream_error("刷新出错：%s（已停流）" % exc)
            self._stop_stream()

    def _on_stream_tick_body(self):
        """每 300 ms 取一次最近 STREAM_POINTS 点刷新波形。

        ★ 为什么敢从 1024 点加到 4096 点：当年"画 4096 点要几十毫秒"是指实时页
          **matplotlib** 那条路（`_redraw` 里 set_data 四条线 + 重算刻度）。抓包页
          的 `CapturePlot` 是 QPainter，按像素列取 min/max 包络（
          `filters.downsample_for_display`），4096 点进 1000 列只在 numpy 里走一遍，
          实测 <2 ms。窗口从 0.29 ms 拉到 1.15 ms，20 kHz 信号从"只够看两个周期"
          变成能看二十多个周期，李萨如和相位关系才有意义。
        ★ 页面不可见时**整段跳过**：连续流开着但人在别的页，没有理由每 300 ms
          拷一次数组再触发一次重绘（切回来第一帧就是最新数据，不损失任何东西）。
        """
        r = self._stream
        if r is None:
            return
        if not r.running:
            # 复查 P9：收包线程死了以前界面永远显示"运行中"、波形冻住且无提示
            self.capture.set_stream_error(r.last_error or "收包线程已退出（网卡或驱动异常）")
            self._stop_stream()
            return
        p = self._stream_p
        src = int(p.get("src", 0))
        dec = int(p.get("dec_log2", 2))
        base = 12.5e6 if src else 50e6
        if not self.capture.isVisible():
            # 后台流继续收（环形缓冲自己滚），只是不往界面上搬
            return
        snap = r.snapshot(STREAM_POINTS)
        if snap["n"] == 0:
            # 连续流模式下只改状态文字：set_error 会清 busy、把按钮变回"抓一次"，
            # 而流还占着端口，再点会双绑抢包（见 panel_capture.set_stream_error）。
            self.capture.set_stream_error("还没收到连续流数据（检查网线 / IP / 端口）")
            return
        meta = {"src": src, "dec_log2": dec,
                "fs": stream_capture.fs_for_dec(base, dec),
                "trig_idx": 0, "elapsed_s": 0.0, "stream": True,
                "pkts": r.packets, "lost": r.lost, "rate": r.rate_sps}
        res = cap.CaptureResult(snap["s"], snap["c"], meta)
        self.capture.set_result(res)
        self.capture.lab_sum.setText(
            "连续流运行中 ｜ 已收 %d 包（%.2f MSPS）｜ 丢 %d 点 ｜ 最近 %d 点"
            % (r.packets, r.rate_sps / 1e6, r.lost, snap["n"]))

    def _udp_bind_ip(self):
        """抓包走网口时监听哪个本机地址。

        默认 ""（监听全部网卡）。需要只认某块网卡时，设环境变量
        FPGA_UDP_BIND_IP=192.168.1.100（直连 PC 的固定 IP），
        避免 Windows 多网卡下收不到包。
        """
        return os.environ.get("FPGA_UDP_BIND_IP", "") or ""

    def _guide_path(self):
        """找指南文件：源码树在 <repo>/docs，打包后在 _internal/docs。"""
        here = os.path.dirname(os.path.abspath(__file__))
        for cand in (os.path.join(here, "docs", "22_ethernet_host_guide.md"),
                     os.path.join(here, os.pardir, "docs", "22_ethernet_host_guide.md")):
            path = os.path.normpath(cand)
            if os.path.exists(path):
                return path
        return None

    def _open_guide(self):
        """打开以太网通道使用指南（docs/22_ethernet_host_guide.md）。"""
        path = self._guide_path()
        if not path:
            self.capture.set_net_status("没找到指南文件 docs/22_ethernet_host_guide.md")
            self.log_line("!! 没找到 docs/22_ethernet_host_guide.md", "warn")
            return
        self.log_line("打开指南：%s" % path)
        QDesktopServices.openUrl(QUrl.fromLocalFile(path))

    def _net_check(self):
        """网络自检：读链路/ARP/ICMP 状态、端口，并 ping 一次板子。"""
        if self.busy:
            # 复查 P3/P10：自检以前不受 busy 约束，抓包中连点会与 dump 抢串口
            self.capture.set_net_status("设备正忙，等当前任务结束再自检")
            return
        if self.worker is None:
            self.capture.set_net_status("串口没连上，无法自检（配置仍然走串口）")
            return
        w = self.worker
        self.capture.set_net_status("自检中…")
        self._set_busy(True)

        def job():
            def rd(a):
                r = w.read_reg(a)
                return None if not isinstance(r, dict) else int(r['value']) & 0xFFFF

            ip_lo, ip_hi = rd(lk.REG_ETH_IP), rd(lk.REG_ETH_IP_HI)
            dev_ip = None
            if ip_lo is not None and ip_hi is not None:
                dev_ip = "%d.%d.%d.%d" % ((ip_hi >> 8) & 0xFF, ip_hi & 0xFF,
                                          (ip_lo >> 8) & 0xFF, ip_lo & 0xFF)
            ping_ok = False
            if dev_ip and dev_ip != "0.0.0.0":
                try:
                    r = subprocess.run(['ping', '-n', '1', '-w', '700', dev_ip],
                                       capture_output=True, timeout=3)
                    ping_ok = (r.returncode == 0)
                except Exception:                       # noqa: BLE001
                    ping_ok = False
            # ★ 先 ping 再读状态：0x0710 的 arp/icmp 位是"收到过"就置位，
            #   先读的话永远显示上一次的状态（第一次自检必然是 ✗）。
            time.sleep(0.15)
            st = rd(lk.REG_ETH_STATUS)
            port = rd(lk.REG_ETH_PORT)
            return {"ip": dev_ip, "status": st, "port": port, "ping": ping_ok}

        self.task.run(job, tag="netcheck")

    def _done_netcheck(self, res):
        st = res.get("status")
        st = 0 if st is None else int(st)
        txt = "网口 %s ｜ ARP %s ｜ ICMP %s ｜ 主机 MAC %s ｜ UDP 端口 %s ｜ ping %s" % (
            res.get("ip") or "?",
            "✓" if st & 0x1 else "✗",
            "✓" if st & 0x2 else "✗",
            "✓" if st & 0x4 else "✗",
            res.get("port") if res.get("port") is not None else "?",
            "通" if res.get("ping") else "不通")
        self.capture.set_net_status(txt)
        self.log_line("网络自检：" + txt)

    def _warm_arp(self, w, quiet=False):
        """让板子先学到主机 MAC（UDP 包的目的 MAC 来自 host_mac）。

        重新烧写后 `host_mac` 是 0，板子发的 UDP 目的 MAC 全 0，网卡直接丢；
        表现为“抓包缺一半包/连续流一包收不到”，而串口一切正常。这里先 ping
        一次设备（板子回 ARP/ICMP 时就学到了主机 MAC）。
        """
        ip = self._device_ip(w)
        if not ip or ip == "0.0.0.0":
            return
        # 已经学到主机 MAC 就直接走（省掉一次 0.5 s 的等待）
        try:
            st0 = w.read_reg(lk.REG_ETH_STATUS)
            if isinstance(st0, dict) and (int(st0['value']) & 0x4):
                return
        except Exception:
            pass
        # 最多试 4 次：ping → 等 0.3 s → 读 0x0710 bit2（host_known）。
        # 刚烧完的第一次抓包最容易丢包，等板子真的学到主机 MAC 再往下走。
        for _ in range(4):
            try:
                src = self._udp_bind_ip() or "192.168.1.100"
                subprocess.run(['ping', '-n', '1', '-w', '600',
                                '-S', src, ip],
                               capture_output=True, timeout=3)
            except Exception as exc:
                if not quiet:
                    self.log_line("ping %s 失败：%s" % (ip, exc), "warn")
                return
            time.sleep(0.3)
            st = w.read_reg(lk.REG_ETH_STATUS)
            if isinstance(st, dict) and (int(st['value']) & 0x4):
                return
        if not quiet:
            self.log_line("板子还没学到主机 MAC（0x0710 bit2=0），抓包可能丢包；"
                          "确认 PC 网口是 192.168.1.100/24、网线直连", "warn")

    @staticmethod
    def _device_ip(w):
        """从 0x0704/0x0706 拼出设备 IP（低字在前）。读不到返回 None。"""
        try:
            lo = w.read_reg(lk.REG_ETH_IP)
            hi = w.read_reg(lk.REG_ETH_IP_HI)
        except Exception:                               # noqa: BLE001
            return None
        if not (isinstance(lo, dict) and isinstance(hi, dict)):
            return None
        ilo, ihi = int(lo["value"]) & 0xFFFF, int(hi["value"]) & 0xFFFF
        return "%d.%d.%d.%d" % ((ihi >> 8) & 0xFF, ihi & 0xFF,
                                (ilo >> 8) & 0xFF, ilo & 0xFF)

    def _pick_udp_port(self, quiet=False):
        """选一个本机能绑的 UDP 端口。

        默认 5000（`FPGA_UDP_PORT` 可改）。本机 5000 常被 Vivado 许可证
        服务 lkcitdl 占着（装过 Vivado 的机器几乎必中），这时向后找一个
        能绑的端口。返回选中的端口，调用方负责把它写进设备 0x070C。
        """
        # 复查 P16：0 或 >65535 都会让 bind 成功绑到随机端口 / 抛 OverflowError
        try:
            base = int(os.environ.get("FPGA_UDP_PORT", "5000"))
        except ValueError:
            base = 5000
        base = max(1024, min(65515, base))
        bind_ip = self._udp_bind_ip()
        for cand in [base] + [base + i for i in range(1, 21)]:
            if cand <= 0 or cand > 65535:
                continue
            so = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                so.bind((bind_ip, cand))
            except (OSError, OverflowError):
                so.close()
                continue
            so.close()
            if cand != base and not quiet:
                self.log_line("UDP 端口 %d 被占用，改用 %d（已写 0x070C）"
                              % (base, cand), "warn")
            return cand
        if not quiet:
            self.log_line("UDP 端口 %d..%d 全被占用" % (base, base + 20), "warn")
        return None

    def _done_capture(self, res):
        """抓包结果回来：交给面板画图，日志里留一行摘要。"""
        self.capture.set_busy(False)
        if res is None:
            self.capture.set_error("没有拿到数据")
            return
        self.capture.set_result(res)
        self.log_line("抓包完成：%s" % res.summary(), "ok")
        if res.missing:
            # 复查 P14：UDP 路径不走串口数据通道，不能一律提示"串口丢字节"
            tport = res.meta.get("transport") or "serial"
            why = ("网口丢包（检查网线/防火墙/RCVBUF，或板端流被抢占）"
                   if tport == "udp" else "串口丢字节（掉电/波特率/干扰）")
            self.log_line("抓包：缺 %d 块（%s），缺的位置补 0"
                          % (len(res.missing), why), "warn")
        b = res.meta.get("build")
        if b is not None and b not in (lk.EXPECT_RTL_V13,):
            self.log_line("抓包：固件构建号 0x%04X，期望 0x%04X（0x071C 协议以 v13 为准）"
                          % (b, lk.EXPECT_RTL_V13), "warn")

    def _on_capture_export(self, kind):
        path = self.capture.save(kind, self)
        if path:
            self.log_line("抓包已导出：%s" % path, "ok")

    def _on_task_done(self, payload):
        tag, result = payload.get("tag"), payload.get("result")
        # ★ 无论走哪条路，最后都必须把"忙碌"标志清掉。老实现里"清除锁存告警"任务抛异常时
        #   只清了 _status_busy，self.busy 永远是 True ⇒ 所有按钮全灰、界面卡死只能关窗口。
        try:
            if isinstance(result, Exception):
                self.log_line("!! %s 异常：%s" % (TAG_TEXT.get(tag, tag), result), "fault")
                if tag == "check":
                    self.lab_check.setText("自检异常：%s" % result)
                # ★ 抓包任务抛异常时必须把抓包页从"抓包中…"解出来：set_busy(False)
                #   只在 _done_capture 里调，异常分支直接 return 会让按钮永久禁用。
                if tag == "capture":
                    self.capture.set_error(str(result))
                if tag == "netcheck":
                    self.capture.set_net_status("网络自检失败：%s" % result)
                if tag == "stream":
                    self.capture.set_stream_error("打开失败：%s" % result)
                if tag in ("lutup", "lutdump"):
                    self.lut.set_error(str(result))
                if tag == "stream_go":
                    # 设备开流命令抛异常：socket 已起，必须收掉，否则下次绑定冲突
                    self._abort_stream("开流命令异常：%s" % result)
                return
            try:
                handler = {"check": self._done_check, "apply": self._done_apply,
                           "pairs": self._done_pairs, "adv": self._done_adv,
                           "status": self._done_status, "clear": self._done_clear,
                           "capture": self._done_capture,
                           "netcheck": self._done_netcheck,
                           "stream": self._done_stream,
                           "stream_go": self._done_stream_go,
                           "stream_stop": self._done_stream_stop,
                           "nolimit": self._done_nolimit,
                           "bstatus": self._done_board_status,
                           "biastrack": self._done_bias_track,
                           "lutup": self._done_lut_upload,
                           "lutdump": self._done_lut_dump}[tag]
            except KeyError:
                self.log_line("未知任务：%s" % tag, "warn")
                return
            handler(result)
        except Exception as exc:                        # noqa: BLE001
            self.log_line("!! 处理 %s 的结果时出错：%s"
                          % (TAG_TEXT.get(tag, tag), exc), "fault")
        finally:
            if tag == "biastrack":
                self._bstatus_busy = False
                self.board_status.set_reading(False)
            elif tag == "bstatus":
                self._bstatus_busy = False
                self.board_status.set_reading(False)
            elif tag in ("lutup", "lutdump"):
                self.lut.set_busy(False)
            elif tag == "status":
                self._status_busy = False        # 轮询任务不占用按钮的忙碌状态
            elif tag == "stream":
                # 流已经开起来了：清 busy 但保留"停止连续流"文案（set_busy 会改写文案）
                self.busy = False
                self._refresh_buttons()
                if self._stream is not None:
                    self.capture.set_streaming(True)
            elif tag == "stream_go":
                # 开流命令的后台往返结束：忙碌标志在 "stream" 那一步已经清了，这里只刷新文案
                self.busy = False
                self._refresh_buttons()
            elif tag == "stream_stop":
                pass          # 停流是后台收尾，不动忙碌标志（可能正被别的任务占用）
            else:
                self._set_busy(False)

    def _done_nolimit(self, res):
        """连上后自动关 AB 限频的结果（静默：只在真的改了/真失败时留一行日志）。"""
        try:
            if isinstance(res, Exception):
                self.log_line("自动关 AB 限频失败：%s: %s"
                              % (type(res).__name__, res), "warn")
                return
            if not res.get("ok"):
                self.log_line("自动关 AB 限频没做：%s" % res.get("why"), "warn")
                return
            wr = res.get("writes") or {}
            if wr:
                self.log_line("已自动关掉 AB 限频：%s（上限 50 MHz，边沿率再高也不被压）"
                              % "、".join("0x%04X=%d" % (a, v) for a, v in sorted(wr.items())),
                              "info")
        except Exception:                        # noqa: BLE001
            pass

    def _done_check(self, result):
        info = result["info"]
        self.info = info
        d, r, b = info["device_id"], info["rev"], info["rtl_build"]
        self.v_device.setText(("0x%02X" % d) if d is not None else "读失败")
        self.v_rev.setText(("0x%02X" % r) if r is not None else "读失败")
        self.v_build.setText(("0x%04X" % b) if b is not None else "读失败")
        for key, val in info["raw"].items():
            self.log_line("读 %s -> %s" % (key, val))

        # 倍频/相位/极性等配置：把原始应答与解码结果都打出来
        for addr in regs.CFG_ADDRS:
            val = result["regs"].get(addr)
            self.log_line("读 0x%04X -> %s = %s"
                          % (addr, result["hexes"].get(addr) or "超时",
                             "读失败" if val is None else "0x%04X" % val))
        self.interp.set_regs(result["regs"])
        self.abz.set_regs(cfg_from_regs(result["regs"]))
        self.abz.set_output(regs.decode_output(result["regs"].get(regs.REG_OUTPUT)) or {},
                            result["regs"].get(regs.REG_OUTPUT))
        inter, div = regs.decode_inter_div(result["regs"].get(regs.REG_INTER0),
                                           result["regs"].get(regs.REG_INTER1))
        if inter is not None:
            self.log_line("倍频：inter=%d div=%d（等效 ×%.3f）；AB 边沿率 = 4×inter/div×输入频率"
                          % (inter, div, inter / div))
        pairs, _raw = regs.decode_pairs(result["regs"].get(regs.REG_PAIRS))
        if pairs is not None:
            # ★ 0x0100 是「电机极对数 P」，只给板上 uv w 生成用；它不是"每转正弦周期数"。
            #   以前这里顺手 set_pairs(pairs) ⇒ 一连上就把转速口径改成 4，EI58（2048 周期/转）
            #   的转速因此差 512 倍。现在只记日志，速度口径由界面那个框（默认 2048）决定。
            self.log_line("电机极对数 0x0100 = %d（只影响 UVW 电频率 = %d × 输入频率）；"
                          "转速按「每转 %d 个正弦周期」折算"
                          % (pairs, pairs, int(getattr(self.speed.est, "pairs", 0) or 0)))
        self.log_line("输出配置 0x0109 = %s"
                      % regs.output_text(result["regs"].get(regs.REG_OUTPUT)))
        # ★ 用户的明确要求（m04317「直接完全删掉限频」）：一连上就把 AB 限频写成 0，
        #   免得"边沿被压掉 ⇒ 0x0405 bit3 锁存 ⇒ 清了又亮"这套来回折腾。
        #   不占按钮忙态（后台悄悄做），失败只在日志里留一行。
        try:
            w0 = self.worker
            if w0 is not None and not self.busy:
                self.task.run(lambda: ts.task_set_ablimit(w0, 0), "nolimit")
        except Exception:                        # noqa: BLE001
            pass

        notes = []
        if d is not None:
            notes.append("设备型号 0x%02X %s" % (d, "✓" if d == lk.EXPECT_DEVICE_ID else "≠预期"))
        if b is not None:
            name = {lk.EXPECT_RTL_V13: "v13（以太网 + 抓包 v3）",
                    lk.EXPECT_RTL_V12: "v12（帧布局 v2）",
                    lk.EXPECT_RTL_V11: "v11（帧布局 v1）"}.get(b, "未知版本")
            notes.append("固件 %s" % name)
        for e in info["errors"]:
            notes.append("!! " + e)
        for w in info["warnings"]:
            notes.append("? " + w)
        self.lab_check.setText("　".join(notes) or "自检完成")
        level = "ok" if info["ok"] and not info["warnings"] else "warn"
        self.log_line("设备自检：%s" % ("、".join(notes) or "完成"), level)

    def _done_apply(self, result):
        for addr, val, hexs in result["writes"]:
            self.log_line("写 0x%04X = 0x%04X -> %s" % (addr, val, hexs or "超时"))
        # ★ `readback` 是 {地址: 值}（只有 2 个），原始应答在 `hexes` 里；曾经在这里写成
        #   `for addr, val, hexs in result["readback"].items()` —— 每次应用都抛
        #   "not enough values to unpack (expected 3, got 2)"，被 `_on_task_done` 兜住只留
        #   一条 fault 日志，于是**寄存器写进去了、界面却从不刷新**（真机 2026-10-14 抓到）。
        for addr, val in result["readback"].items():
            hexs = (result.get("hexes") or {}).get(addr)
            self.log_line("回读 0x%04X -> %s = %s"
                          % (addr, hexs or "超时",
                             "读失败" if val is None else "0x%04X" % val))
        want, got = result["want"], result["got"]
        if result["ok"]:
            self.log_line("倍频应用成功：inter=%d div=%d（回读一致）" % want, "ok")
        else:
            self.log_line("!! 倍频回读不符：想写 inter=%s div=%s，读到 inter=%s div=%s"
                          % (want[0], want[1], got[0], got[1]), "fault")
        rb = dict(self.interp.regs_raw)
        rb.update({a: v for a, v in result["readback"].items() if v is not None})
        self.interp.set_regs(rb)
        # 倍频变了，等效采样的相位-时间关系跟着变 ⇒ 让 ABZ/UVW 面板重新起算
        self.abz.set_regs(cfg_from_regs(rb))
        self.abz.set_output(regs.decode_output(rb.get(regs.REG_OUTPUT)) or {},
                            rb.get(regs.REG_OUTPUT))

    def _done_pairs(self, result):
        addr, val, hexs = regs.REG_PAIRS, result["write"][0], result["write"][1]
        self.log_line("写 0x%04X = 0x%04X -> %s" % (addr, val, hexs or "超时"))
        self.log_line("回读 0x%04X -> %s = %s"
                      % (addr, result["hex"] or "超时",
                         "读失败" if result["readback"] is None
                         else "0x%04X" % result["readback"]))
        if result["ok"]:
            self.log_line("极对数已写入并回读一致：%d" % result["want"], "ok")
            # ★ 极对数变了，板上 UVW 电角度（以及 ⑨ 卡的 UVW 分箱）跟着变：
            # 不刷新 ⑨ 卡的话，等效采样图还按旧极对数分箱画（要等下次自检才对）
            rb = dict(self.interp.regs_raw)
            if result["readback"] is not None:
                rb[regs.REG_PAIRS] = result["readback"]
            self.interp.set_regs(rb)
            self.abz.set_regs(cfg_from_regs(rb))
            self.speed.set_pairs(result["want"])
        else:
            self.log_line("!! 极对数回读不符：想写 %s，读到 %s"
                          % (result["want"], result["got"]), "fault")

    def _done_adv(self, result):
        for addr, val, hexs in result["writes"]:
            self.log_line("写 0x%04X = 0x%04X -> %s" % (addr, val, hexs or "超时"))
        # 同 `_done_apply`：`readback` 只有 {地址: 值}，原始应答在 `hexes`（真机抓到的 2/3 元解包 bug）
        for addr, val in result["readback"].items():
            hexs = (result.get("hexes") or {}).get(addr)
            self.log_line("回读 0x%04X -> %s = %s"
                          % (addr, hexs or "超时",
                             "读失败" if val is None else "0x%04X" % val))
        if result["ok"]:
            self.log_line("高级参数已写入并回读一致（%d 个寄存器）"
                          % len(result["writes"]), "ok")
        else:
            for addr, want, got in result["bad"]:
                self.log_line("!! 0x%04X 回读不符：想写 0x%04X，读到 %s"
                              % (addr, want, "读失败" if got is None
                                 else "0x%04X" % got), "fault")
        rb = dict(self.interp.regs_raw)
        rb.update({a: v for a, v in result["readback"].items() if v is not None})
        self.interp.set_regs(rb)
        self.abz.set_regs(cfg_from_regs(rb))
        self.abz.set_output(regs.decode_output(rb.get(regs.REG_OUTPUT)) or {},
                            rb.get(regs.REG_OUTPUT))

    def _status_signature(self, result):
        """告警状态的"指纹"：只有值真变了，才值得用「信息」级别打一条。

        ★ 故意**不**包含幅值（amp_low_sq/amp_high_sq/stat_amp_sq）—— 它们每 2 秒都在
        小幅波动，算进去就等于每 2 秒一条信息，又变回刷屏了。
        """
        return tuple((k, (result or {}).get(k))
                     for k in ("ok", "val0404", "latch0405", "flags053a", "flags053b"))

    def _done_status(self, result):
        self.alarm.set_status(result)
        self.wave.set_status(result)
        if self._wave_win is not None:
            self._wave_win.set_status(result)
        sig = self._status_signature(result)
        changed = (sig != self._status_sig)
        self._status_sig = sig
        # ★ R5：轮询结果默认只进「调试」。状态真的有变化（或第一次读到）时才用
        #   信息/警告级别打一条 —— 既不刷屏，又不漏掉告警变化。
        if not result.get("ok"):
            self.log_line("告警状态：部分寄存器读失败（看日志里的原始应答）",
                          "warn" if changed else "debug")
        elif changed:
            self.log_line("告警状态：%s" % sg.status_summary(result), "info")
        else:
            self.log_line("告警状态：%s" % sg.status_summary(result), "debug")

    def _done_clear(self, result):
        before = result.get("before") or {}
        after = result.get("after") or {}
        self.alarm.set_status(after)
        self.wave.set_status(after)
        if self._wave_win is not None:
            self._wave_win.set_status(after)
        self.log_line("0x0405 清位应答：%s" % (result.get("write_hex") or "无应答"), "ok")
        self.log_line("0x0405 前=0x%02X 后=0x%02X；0x053A 前=0x%02X 后=0x%02X"
                      % (before.get("latch0405") or 0, after.get("latch0405") or 0,
                         before.get("flags053a") or 0, after.get("flags053a") or 0), "ok")
        self._status_t = time.monotonic()
        remain = (after.get("latch0405") or 0)
        if not remain:
            self.log_line("✓ 锁存告警已清干净（0x0405 = 0x00）", "ok")
            return
        names = "、".join("%s(bit%d)" % (cn, idx)
                         for idx, _n, cn in sg.VAL_BITS if (remain >> idx) & 1)
        self.log_line("还有锁存位没清掉：0x%02X（%s）。这些故障此刻仍然存在 —— 写 0x0405 是 W1C 清位，"
                      "但之后每一拍都会拿实时状态重新锁存（rtl/reg_file.v:411-416），"
                      "所以要先消除原因再清："
                      "① 幅度超出 0.6~1.2 满量程 ⇒ 把输入调到 ≤0.9 满量程（本模块 10 Vpp ⇒ 8 Vpp，"
                      "见 docs/07 第 1.9 条）；"
                      "② 限频/相位滞后 ⇒ 降低等效倍率或放宽「AB 限频」(0x0106)。"
                      % (remain, names or "未命名位"), "warn")

    # ------------------------------------------------------------ 导出 PNG
