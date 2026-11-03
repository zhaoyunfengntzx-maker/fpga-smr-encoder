"""实时链路：把收到的帧变成界面上的读数（tick / 重放 / 看门狗 / 概览）。

设计约束（改这个文件前先读）：
1. **这条链路只读 worker 的事件队列，不写它**。采集/写入是 link.py 那个线程的事；
   这里只做"取出来 -> 记账 -> 喂面板"。两边都改队列状态就会出现帧重复或丢帧。
2. **喂面板必须过 isVisible() 门**（self.wave / self.abz）。matplotlib 一次重绘
   30~80 ms 期间收包线程拿不到 GIL，是连续流丢 39% 包的主因；门一破，丢包立刻回来。
3. **回放和在线走同一段喂帧代码**（_replay_tick 与 _tick_body 保持同形）：
   现场录的 .bin 在界面上要能"一模一样地重演"，两条路径一分开就必然漂。
4. 界面读数按帧驱动更新而不是挂钟采样，所以断线时读数会停住而不是掉到 0 ——
   这是有意的（停住 = 没数据，掉 0 = 板子跑得慢，两者现场含义不同）。

依赖的宿主属性：worker、speed、wave、quality、alarm、abz、interp、record、capture、
log_line()、_set_state()。
"""

from __future__ import annotations

import os
import queue
import sys
import time

from PySide6.QtCore import Qt, QTimer

import link as lk
import linkctl as lc
import net_frames as nf
from tasks import _hms
import page_overview as ov
import ports as pm
import replay as rp
import theme as th
import ui_kit as uk
import ui_prefs as up

C = th.C
UI_PERIOD_MS = 100            # 界面刷新周期：10 Hz（需求验收：波形刷新 >=10 次/秒）
MAX_EVENTS_PER_TICK = 40      # 一次最多消费多少事件，避免一次 tick 卡住界面
STATUS_PERIOD_S = 2.0         # 告警锁存状态轮询周期（读 8 条寄存器命令，很便宜）


def dev_id_ok(text):
    """设备型号是否就是本次固件的 DEVICE_ID（link.EXPECT_DEVICE_ID = 0x0C）。

    ★ 用户反馈 bug（2026-10-16）：概览页原来写的是 `"0x0C" in dev.upper()`，
      而 `"0x0C".upper()` ⇒ `"0X0C"`，模式里是小写 `x` ⇒ **永远不匹配**，
      所以概览页永远显示「型号未知」。这里改成先按数值比、再退化成大小写无关串比。
    """
    s = (text or "").strip().lower()
    if not s or s in ("—", "-"):
        return False
    try:
        return int(s, 16) == lk.EXPECT_DEVICE_ID
    except ValueError:
        return ("0x%02x" % lk.EXPECT_DEVICE_ID) in s


class LiveMixin(object):
    """实时链路 + 回放 + 链路看门狗 + 概览汇总。"""

    def _lost_frames(self):
        """累计丢掉的帧数（校验错 + 重同步吞掉的）。老版本没有 lost_frames 时退回 crc_err。"""
        c = self._counters or {}
        if "lost_frames" in c:
            return int(c["lost_frames"])
        return int(c.get("crc_err", 0))

    def _tick(self):
        """100 ms 定时器槽：**任何异常都不许逃出去**。

        ★ 为什么必须兜住（自查发现）：逃出 Qt 槽的异常会走 `app.py:171-177` 的
        `sys.excepthook` → 模态 `QMessageBox.exec()`。这个槽每 100 ms 触发一次，
        只要异常源是"数据持续异常"（例如帧字典缺键），就会**每 100 ms 弹一个框**，
        用户既用不了也退不出。这里兜底：记一条日志 + 对同一处异常限频。
        """
        try:
            self._tick_body()
        except Exception as exc:                                  # noqa: BLE001
            sig = "%s: %s" % (type(exc).__name__, exc)
            self._tick_err_n = getattr(self, "_tick_err_n", 0) + 1
            if getattr(self, "_tick_err_sig", None) != sig:
                self._tick_err_sig = sig
                self.log_line("界面刷新出错（已兜住，界面继续跑）：%s" % sig, "fault")
            elif self._tick_err_n % 100 == 1:
                self.log_line("界面刷新仍出错（累计 %d 次）：%s" % (self._tick_err_n, sig),
                              "fault")

    # ---------------------------------------------------------------- 回放
    # 为什么放在主窗口而不是记录卡：只有这里知道波形/正交质量/告警该喂给谁。
    # 回放完全不碰串口与 worker（不连板也能放），所以 _tick_body 一开头就分流。
    def start_replay(self, path):
        """把一份 .bin 按 10 kHz 的节奏重演：波形/质量/告警全部照跑。"""
        self.stop_replay()
        try:
            r = rp.Replayer(path)
        except Exception as exc:                                  # noqa: BLE001
            self.log_line("回放打不开：%s（%s）" % (exc, path), "fault")
            return
        self._replay = r
        meta = (r.info.get("meta") or {}).get("csv") or os.path.basename(path)
        self.log_line("开始回放 %s ｜ %d 帧 ≈ %.1f s"
                      % (meta, r.n_total, r.n_total / 10000.0), "info")
        self.show_page("live")

    def stop_replay(self, why=None):
        r = getattr(self, "_replay", None)
        if r is None:
            return
        self._replay = None
        try:
            st = r.stats()
            r.close()
        except Exception:                                          # noqa: BLE001
            return
        self.log_line("回放结束：%d/%d 帧（%.1f s）%s"
                      % (st["played"], st["total"], st["sec"],
                         ("，跳过坏帧 %d" % st["lost"]) if st["lost"] else ""),
                      "info" if not why else "warn")

    def _replay_tick(self):
        """100 ms 一批：与在线完全相同的喂法（不含记录，避免把回放混进真记录）。"""
        r = self._replay
        if r is None:
            return
        frames = r.next_batch()
        if not frames:
            if r.error:
                self.log_line("回放出错：%s" % r.error, "fault")
            self.stop_replay("done")
            return
        snap = self.speed.feed(frames, n_bad=0)
        self._f_in = snap.get("f_abs")
        self.interp.update_f_in(self._f_in)
        self.wave.set_f_in(self._f_in)
        self.alarm.set_frames(frames)
        if self.wave.isVisible():
            self.wave.feed(frames, force_draw=True)
        self.quality.feed(frames)
        if self._wave_win is not None and self._wave_win.isVisible():
            self._wave_win.set_f_in(self._f_in)
            self._wave_win.feed(frames)
        if self.abz.isVisible():
            self.abz.set_f_in(self._f_in)
            self.abz.feed(frames)

    def _tick_body(self):
        if getattr(self, "_replay", None) is not None:      # 回放接管本 tick
            self._replay_tick()
            return
        w = self.worker
        if w is None:
            return
        # 数据源切换（用户 m02995）：网口模式下所有面板吃连续流，串口只用来读寄存器。
        if getattr(self, "_src", "serial") == "net":
            self._net_tick_body()
            return
        got_batch = False
        new_frames = []
        # 基线用"上次结账时"的累计值（不是本 tick 开始前的 _counters）：新计数是在本 tick
        # 循环里才第一次带上来的，用旧基线会漏掉最后一笔（断开时那笔就永远记不上）
        bad0 = self._acc_lost
        drop0 = self._acc_drop
        for _ in range(MAX_EVENTS_PER_TICK):
            try:
                kind, text, extra = w.events.get_nowait()
            except Exception:                       # queue.Empty
                break
            if kind == "batch":
                got_batch = True
                self._wd.note_rx(time.monotonic())      # 看门狗：有帧就活着（顺带清零重试）
                frames = extra["frames"]
                self._stat_frames += len(frames)
                self._frames_total += len(frames)
                self._counters = extra["counters"]
                if frames:
                    new_frames.extend(frames)
                    self.last_frame = frames[-1]
            elif kind == "stats":
                self._wd.note_rx(time.monotonic())
                self._counters = extra["counters"]
            elif kind == "open":
                self._set_state("已连接", C["ok"])
                self.log_line(text, "ok")
                self._stat_t = None
                self._wd.reset(time.monotonic())
                self._refresh_buttons()
                # 需求 M1：连上后自动自检一次（读设备身份证 + 倍频配置）
                QTimer.singleShot(250, self._on_check)
                # 数据源默认网口（用户 m03198）：连上就顺手开流，
                # 起不来会自己退回串口，不会让界面挂着没数据。
                QTimer.singleShot(1500, self._maybe_auto_net)
                # 勾了"连上就自动记录"就等自检/第一帧稳定后再开表（别把握手乱码记进去）
                if self.record.auto_record():
                    QTimer.singleShot(900, self._auto_start_record)
            elif kind == "closed":
                # 线程结束了（正常断开，或拔线/驱动报错）就彻底复位：把 worker 放掉、
                # 按钮回到"连接"，否则界面会停在"断开"态、点"连接"没反应（验收⑧）。
                if self.worker is w and not w.is_alive():
                    QTimer.singleShot(0, self.disconnect_port)
                else:
                    self._set_state("已断开", C["muted"])
                    self.log_line(text)
                    self._refresh_buttons()
            elif kind == "error":
                self._set_state("故障", C["fault"])
                self.log_line("!! " + text, "fault")
                if self.worker is w and not w.is_alive():
                    QTimer.singleShot(0, self.disconnect_port)
            elif kind == "log":
                self.log_line(text)
        # n_bad：本 tick 里丢掉的帧（校验错 + 重同步吞掉的）算进"板上经过的帧时隙"，
        # 否则少算帧数会把频率读高约 0.8%（见 link.counters() 与 encoder.py 的说明）
        n_bad = max(0, self._lost_frames() - bad0)
        # n_drop：链路事件队列满被丢掉的批（收到慢于 10 kHz 时发生）——记录文件里
        # 同样没有这些帧，所以也要算进记录的"丢帧估计"，否则 CSV 会少一截却不自知
        n_drop = max(0, int((self._counters or {}).get("dropped_frames", 0)) - drop0)
        # 结账：把这一笔记进基线，断开时 _drain_events 再从同一基线往后结
        self._acc_lost = self._lost_frames()
        self._acc_drop = int((self._counters or {}).get("dropped_frames", 0))
        if new_frames:
            snap = self.speed.feed(new_frames, n_bad=n_bad)
            self._f_in = snap.get("f_abs")
            self.interp.update_f_in(self._f_in)
            self.wave.set_f_in(self._f_in)
            self.alarm.set_frames(new_frames)      # 状态机必须跑：告警/概览都靠它
            # A7 可见性门控：不在「实时」页就不画波形。matplotlib 一次重绘 30~80 ms，
            # 期间收包/解析线程拿不到 GIL —— 这就是连续流丢包的主因（实测 39%）。
            # 切回本页时补 150 ms 数据（WaveBuffer 容量 1500 帧）即可恢复。
            if self.wave.isVisible():
                self.wave.feed(new_frames)
            # 正交质量卡：0.5 s 一次拟合（内部自带节流）
            try:
                self.quality.set_pairs(self.speed.pairs())
            except Exception:                                 # noqa: BLE001
                pass
            self.quality.feed(new_frames)
            # ⑧ 独立窗口（阶段 5 C 批）：同一批帧也喂给它；没打开就不花这份力气
            if self._wave_win is not None and self._wave_win.isVisible():
                self._wave_win.set_f_in(self._f_in)
                self._wave_win.feed(new_frames)
            if self.abz.isVisible():               # 同上：ABZ 画布也不在看的页时省掉
                self.abz.set_f_in(self._f_in)
                self.abz.feed(new_frames)
            # ⑨ 独立窗口（阶段 5 续）：先 mirror 板上事实（inter/div、0x0109 输出位），再喂同一批帧
            if self._abz_win is not None and self._abz_win.isVisible():
                self._abz_win.panel.mirror(self.abz)
                self._abz_win.feed(new_frames)
        # 记录卡片：把同一批帧交给 CSV 记录器（n_bad/n_drop 都算进"丢帧估计"）。
        # 放在 if 外面：万一这一 tick 一帧都没到（批全被链路丢了），丢帧数也得记上。
        self.record.feed(new_frames, n_bad=n_bad, n_drop=n_drop)
        # 告警锁存状态轮询：2 s 一次（8 条读命令 ≈ 3 ms 链路时间，对遥测影响可忽略）
        if (self.worker is not None and not self.busy and not self._status_busy
                and (time.monotonic() - self._status_t) > STATUS_PERIOD_S):
            self._status_t = time.monotonic()
            self._on_read_status()
            # 板上状态表也跟着轮（只在诊断页可见、且用户勾了自动读时）
            if (getattr(self, "board_status", None) is not None
                    and self.board_status.auto()
                    and self.board_status.isVisible()):
                self._on_read_board_status()
        if got_batch or self._counters is not None:
            self._update_speed()
        if self.last_frame is not None:
            self._update_live(self.last_frame)
        if w.error and not w.connected:
            self._set_state("故障", C["fault"])
        self._watch_link()

    # ---------------------------------------------- 数据源：网口连续流 / 串口遥测
    def _want_src(self):
        """下拉框里用户选的那一项（偏好），与"当前真正在用的"（_src）是两码事。"""
        w = getattr(self, "cmb_src", None)
        if w is None:
            return "serial"
        return (w.currentData() or "serial")

    def _set_src_combo(self, name):
        w = getattr(self, "cmb_src", None)
        if w is None:
            return
        idx = w.findData(name)
        if idx >= 0 and idx != w.currentIndex():
            w.blockSignals(True)
            w.setCurrentIndex(idx)
            w.blockSignals(False)

    def _on_source_changed(self, _idx=None):
        """下拉框变了：记住选择，能切就切。"""
        name = self._want_src()
        try:
            up.put("data", "src", name)
            up.save()
        except Exception:                       # noqa: BLE001
            pass
        if name == "net":
            self._net_start()
        else:
            self._net_off("用户选了串口遥测")

    def _net_start(self):
        """按偏好开网口：已经在跑就直接切；没跑就开（要串口写 0x070C）。"""
        if self.worker is None:
            # 连上串口后会自动开（见 _tick_body 的 open 分支）
            self.log_line("已选网口：连上串口后自动开连续流", "info")
            return
        r = getattr(self, "_stream", None)
        if r is not None and r.running:
            self._net_on()
            return
        self._net_want = True
        self.log_line("数据源：正在开网口连续流…", "info")
        try:
            # ★ 原来这里写的是 self._on_stream_go() —— 那个方法根本不存在（真正
            #   的开流入口是 cmds_mixin._toggle_stream），异常被下面 except 吞掉，
            #   表现就是选了网口、日志一闪、又跳回串口、一个包都没有。
            self._toggle_stream(dict(self._stream_params or {}))
        except Exception as exc:                # noqa: BLE001
            self._net_want = False
            self.log_line("开连续流失败：%s" % exc, "fault")
            self._set_src_combo("serial")
            return
        # ★ 15 s（原来 6 s 太短）：开流前要 `_host_known()` 唤醒 ARP（最多 4 次
        #   ping）+ 开流后再验 0.6 s，真板上一次完整的开流可以到 5~6 s。6 s 的
        #   超时会在任务还没回调 `_done_stream` 之前就把下拉框退回串口 ——
        #   表现就是"点网口、日志一闪、又跳回串口"，即用户说的"总是起不来"。
        self._net_gen = int(getattr(self, "_net_gen", 0)) + 1
        QTimer.singleShot(15000, lambda g=self._net_gen: self._net_give_up(g))

    def _net_give_up(self, gen=None):
        if gen is not None and gen != int(getattr(self, "_net_gen", 0)):
            return                              # 上一轮尝试的定时器，忽略
        if self._src == "net":
            return
        if not getattr(self, "_net_want", False):
            return
        if getattr(self, "busy", False):
            # 还在开流（ARP 唤醒 + 收包校验）⇒ 再等一轮，别抢在回调之前退回
            QTimer.singleShot(5000, lambda: self._net_give_up(gen))
            return
        self._net_want = False
        self._set_src_combo("serial")
        self.log_line("网口连续流 15 s 没起来：先退回串口遥测（可再切回网口重试）", "warn")

    def _maybe_auto_net(self):
        """连上串口之后调用：如果用户偏好是网口，就自动开流。"""
        if self._want_src() == "net":
            self._net_start()

    def _net_on(self):
        self._src = "net"
        self._synth = None
        self._net_warn_t = 0.0
        self._net_want = False
        self._net_retry_n = 0
        # 记住"进网口时串口在不在"：在线时串口断了要退回串口；离线冒烟测试
        # （本来就没有 worker）不能因为这个直接踢回串口。
        self._net_had_worker = self.worker is not None
        self._set_src_combo("net")
        self.log_line("数据源：网口连续流"
                      "（角度由 s/c 现算，A/B/Z/UVW 为按配置推导）", "ok")
        self.wave.reset()

    def _net_off(self, why=""):
        self._src = "serial"
        self._synth = None
        self._net_want = False
        self.log_line("数据源：串口遥测%s" % ("（%s）" % why if why else ""), "info")

    def _net_tick_body(self):
        """网口模式的 _tick_body：从 10 kHz 抽头取增量 → 造帧 → 走同一套下游。"""
        now = time.monotonic()
        if self.worker is None and getattr(self, "_net_had_worker", False):
            self._net_off("串口已断开")
            return
        r = getattr(self, "_stream", None)
        if r is None or not r.running:
            # ★ 断开重连后 _stream 是空的，串口却已经回来。原来这里直接把下拉框
            #   踢回串口，_maybe_auto_net 就不动弹了 —— 用户看到"网口再也连不上"。
            #   现在：偏好还是网口 + 串口在线 ⇒ 自动重开（3 s 节流，最多 3 次）。
            n = int(getattr(self, "_net_retry_n", 0))
            if (self.worker is not None and self._want_src() == "net" and n < 3
                    and now - getattr(self, "_net_warn_t", 0.0) > 3.0):
                self._net_warn_t = now
                self._net_retry_n = n + 1
                self.log_line("网口连续流不在跑，自动重开（第 %d 次）" % (n + 1), "info")
                self._net_start()
                return
            if now - getattr(self, "_net_warn_t", 0.0) > 3.0:
                self._net_warn_t = now
                self._net_want = False
                self._set_src_combo("serial")
                self._src = "serial"
                self.log_line("网口连续流起不来（已试 %d 次）：切回串口，可再手动切网口"
                              % n, "warn")
            return
        # ★ 波形卡要真波形：直接用连续流原始样点（12.5 MSPS）画，
        #   10 kHz 帧对 1~2 kHz 输入只有 8 个点/周期，怎么画都是折线。
        # ★ 原始样点每 tick 都取：波形要它、**测速也要它**。10 kHz 抽头对 20 kHz
        #   输入每帧转 2 个多周期，用它算转速只会得到混叠残差（实测 20821 Hz 读成
        #   722.9 Hz）。fs_for_dec 是 stream_capture 的模块级函数，不是 receiver
        #   的方法；这里整段包 try，取不到只影响这两样，不许打死整页。
        raw = None
        fs = 0.0
        try:
            raw = r.snapshot(65536)
            if int(raw.get("n") or 0) >= 64:
                fs = float(r.base_fs) / float(1 << int(raw.get("dec") or 0))
            else:
                raw = None
        except Exception as exc:                    # noqa: BLE001
            raw = None
            if now - getattr(self, "_raw_warn_t", 0.0) > 5.0:
                self._raw_warn_t = now
                self.log_line("取原始样点失败：%s: %s" % (type(exc).__name__, exc), "warn")
        if raw is not None:
            if self.wave.isVisible():
                try:
                    self.wave.feed_raw(raw["s"], raw["c"], fs)
                except Exception as exc:            # noqa: BLE001
                    if now - getattr(self, "_raw_warn_t", 0.0) > 5.0:
                        self._raw_warn_t = now
                        self.log_line("真波形取点失败：%s: %s"
                                      % (type(exc).__name__, exc), "warn")
            # ★ 转速/圈数：在 12.5 MSPS 上解回绕后算，绕开 10 kHz 的混叠
            try:
                rs = getattr(self, "_raw_speed", None)
                if rs is None:
                    rs = nf.RawSpeed(pairs=self.speed.pairs())
                    self._raw_speed = rs
                rs.set_pairs(self.speed.pairs())
                # 测速只取最新的 4096 点：丢包严重时 65536 点的窗口里会夹着
                # 环形缓冲的空洞，相位差看着是常数（实测读成 1~57 Hz）。
                sm = r.snapshot_contig(8192)
                sp = rs.feed(sm["s"], sm["c"], fs)
                if sp.get("ok"):
                    self.speed.show_snapshot(sp)
                    self._f_in = sp.get("f_abs")
                    self.interp.update_f_in(self._f_in)
                    self.wave.set_f_in(self._f_in)
                    if getattr(self, "_wave_win", None) is not None \
                            and self._wave_win.isVisible():
                        self._wave_win.set_f_in(self._f_in)
            except Exception as exc:                # noqa: BLE001
                if now - getattr(self, "_raw_warn_t", 0.0) > 5.0:
                    self._raw_warn_t = now
                    self.log_line("原始样点测速失败：%s: %s"
                                  % (type(exc).__name__, exc), "warn")

        snap = r.snapshot_frames(4096)
        n = int(snap.get("n") or 0)
        if n <= 0:
            self._net_ui_tail(now)
            # ★ 上板实测：包停了多半是板端 host_known 掉了（它还在发，但目的 MAC
            #   不知道，主机收不到）。每 3 s 补一次 warm，别让用户以为"卡死了"。
            if now - getattr(self, "_net_heal_t", 0.0) > 3.0:
                self._net_heal_t = now
                pk0 = getattr(r, "packets", 0)
                self._warm_arp(self.worker, quiet=True) if self.worker else None
                self.log_line("网口 3 s 没新包（已补一次 ARP 唤醒；板上 TX=%d）" % pk0,
                              "warn")
            return
        synth = getattr(self, "_synth", None)
        if synth is None:
            synth = nf.FrameSynth(
                pairs=int(getattr(self, "_net_pairs", 2048) or 2048),
                inter=int(getattr(self, "_net_inter", 32) or 32),
                div=int(getattr(self, "_net_div", 1) or 1))
            self._synth = synth
        # ★ 相位必须用 RawSpeed 解出来的（12.5 MSPS），不能让它自己 atan2 解回绕：
        #   20 kHz 输入在 10 kHz 抽头上每帧 2 个多周期，自己解只能得到混叠残差。
        ph = None
        try:
            # 用每个抽头点自己的 atan2 算相位，再靠粗测速率解整圈 —— 线性外推在
            # 0.4 s 窗口里差 1 Hz 就攒几十度，拟合直接判失败（实测残差 6118%）。
            _f = float(self._f_in or 0.0)
            if _f > 0:
                ph = nf.tap_phase(snap["s"], snap["c"], _f)
        except Exception:                           # noqa: BLE001
            ph = None
        frames = synth.make(snap["s"], snap["c"], phase_deg=ph)
        if not frames:
            return
        self.last_frame = frames[-1]
        self._frames_total += len(frames)
        self._stat_frames += len(frames)
        # ★ 「实时数据预览」卡也只能靠这一句刷新：原来只有串口路径的 _tick_body
        #   调 _update_live，网口模式没调 ⇒ 用户看到"这一页完全不刷新"（数值永远
        #   停在切网口之前那一帧）。整段包 try：卡片是装饰性的，不许连累读数。
        try:
            self._update_live(frames[-1])
        except Exception as exc:                    # noqa: BLE001
            if now - getattr(self, "_live_warn_t", 0.0) > 5.0:
                self._live_warn_t = now
                self.log_line("实时预览刷新失败：%s: %s" % (type(exc).__name__, exc),
                              "warn")
        # ★ 转速卡已经在上面用原始样点更新过，这里**不能**再用帧口径喂一遍：
        #   pos_full 是混叠的，会把正确的读数覆盖成错的。
        self.alarm.set_frames(frames)          # 告警状态机必须跑：概览靠它
        # ★ 网口模式下波形卡已经吃原始样点（feed_raw），这里不能再喂 10 kHz 帧：
        #   feed() 里有帧就会清掉 _raw，两种数据混在一张图上互相打架。
        self.quality.feed(frames)
        if getattr(self, "_wave_win", None) is not None and self._wave_win.isVisible():
            self._wave_win.set_f_in(self._f_in)
            self._wave_win.feed(frames)
        if self.abz.isVisible():
            self.abz.set_f_in(self._f_in)
            self.abz.feed(frames)
        if getattr(self, "_abz_win", None) is not None and self._abz_win.isVisible():
            self._abz_win.panel.mirror(self.abz)
            self._abz_win.feed(frames)
        self.record.feed(frames, n_bad=0, n_drop=0)
        self._net_ui_tail(now)

    def _net_ui_tail(self, now):
        """网口模式下的界面刷新尾巴（★ 修"首页卡住不动"）。

        原来 `_refresh_overview()` / 状态栏 / 记录卡片都挂在 `_update_speed()` 末尾，
        而它只在串口路径的 `_tick_body` 里调；网口模式提前 return，概览页的数字
        就永远停在上一次串口时的值 —— 用户看到"首页卡住不动、转速变了也不动"。
        """
        try:
            r = getattr(self, "_stream", None)
            pk = int(getattr(r, "packets", 0) or 0)
            t0 = getattr(self, "_net_ui_t", None)
            if t0 is None:
                self._net_ui_t = now
                self._net_ui_pk = pk
                self._net_ui_fr = self._stat_frames
                self._refresh_overview()
                return
            dt = now - t0
            if dt < 0.5:
                self._refresh_overview()          # 概览很便宜，每 tick 都刷
                return
            fr = (self._stat_frames - getattr(self, "_net_ui_fr", 0)) / dt
            pkt = (pk - getattr(self, "_net_ui_pk", 0)) / dt
            self._net_ui_t = now
            self._net_ui_pk = pk
            self._net_ui_fr = self._stat_frames
            self._fps = fr
            uk.show(self.v_fps, self.st_fps, fr, extra="网口连续流")
            uk.show(self.v_bps, self.st_bps,
                    pkt * 350.0 * 4.0 / 1000.0, extra="UDP 数据报 %d/s" % int(pkt))
            self.v_lost.setText("0 / %d" % int(getattr(r, "lost", 0) or 0))
            self.record.tick(now)
            self._sb_lab.setText("已运行 %s ｜ 网口 %.0f 帧/秒" % (_hms(self._uptime()), fr))
        except Exception:                        # noqa: BLE001
            pass
        try:
            self._refresh_overview()
        except Exception:                        # noqa: BLE001
            pass

    def _uptime(self):
        now = time.monotonic()
        t0 = getattr(self, "_net_t0", None)
        if t0 is None:
            self._net_t0 = now
            return 0.0
        return now - t0

    def _watch_link(self):
        """链路存活看门狗（审计 B3/B4）。

        link.py 的写超时只投一条 error 后 return，而原来只有 "open" 事件能把
        状态改回"已连接" ⇒ 一次链路误码就让状态栏永久停在"故障"，看着像死机
        （实际数据可能还在来）。判定逻辑全在 linkctl.LinkWatchdog 里（可离线自检）：
          · 静默 > 3 s  → 报一次"链路无数据"（故障色），一旦来帧自动恢复"已连接"
          · 静默 > 15 s → 自动重连一次（最多连试 3 次，收到任何帧就复位计数）
        这样"误码"和"真断线"都能自愈，也不需要用户手动点重连。
        """
        w = self.worker
        if w is None or not w.is_alive():
            return
        ev = self._wd.feed(time.monotonic())

        if ev["recovered_s"] is not None:
            self._set_state("已连接", C["ok"])
            self.log_line("链路恢复：又收到数据了（静默 %.1f s）" % ev["recovered_s"], "ok")
        elif ev["warned"]:
            self._set_state("链路无数据", C["fault"])
            self.log_line("!! %.1f s 没收到任何帧（接收线程仍在跑）：先看板子是否复位、"
                          "USB 线/波特率是否正常" % ev["quiet"], "fault")

        if ev["reconnect"]:
            port = getattr(w, "port", None) or self._current_port()
            self.log_line("链路静默 %.0f s，自动重连（第 %d/%d 次）…"
                          % (ev["quiet"], ev["retry_n"], self._wd.max_retry), "warn")
            QTimer.singleShot(200, lambda p=port: self._auto_reconnect(p))
        elif ev["exhausted"] and not self._link_exhaust_logged:
            # 次数用完还在静默：明确告诉用户"别再等了，动手查线"
            self._link_exhaust_logged = True
            self.log_line("自动重连已试满 %d 次仍无数据：请检查 USB 线/供电，"
                          "或点「连接」手动重连" % self._wd.max_retry, "fault")
        if ev["recovered_s"] is not None:
            self._link_exhaust_logged = False

    def _auto_reconnect(self, port):
        """B6：静默太久的自动重连。拔插后 COM 号会变，所以先刷新端口再挑一个。"""
        if self.worker is not None:
            self.disconnect_port()
        self.refresh_ports()
        found = []
        try:
            found = pm.list_serial_ports()
        except Exception:                        # 枚举失败就当没有
            found = []
        # 原端口没了（重插后换了号）：优先挑"看起来像板子"的那个
        cand = lc.pick_reconnect_port(port, found, pm.looks_like_board)
        if not cand:
            self.log_line("自动重连失败：系统里没有可用串口（USB 线被拔了？）", "fault")
            return
        self.connect_to(cand)

    def _update_speed(self):
        c = self._counters or {}
        now = time.monotonic()
        if self._stat_t is None:
            self._stat_t = now
            self._stat_frames = 0
            self._stat_bytes = c.get("rx_bytes", 0)
            return
        dt = now - self._stat_t
        if dt < 0.5:                                # 半秒内不刷新速率，避免抖动
            return
        frames = self._stat_frames
        db = c.get("rx_bytes", 0) - self._stat_bytes
        self._fps = frames / dt
        self._bps = db / dt
        self._stat_t = now
        self._stat_frames = 0
        self._stat_bytes = c.get("rx_bytes", 0)

        # R20：帧率/数据率/校验错比例走稳定显示（悬停看原始值）；计数类（丢批/丢帧）直接显示
        uk.show(self.v_fps, self.st_fps, self._fps, extra="半秒统计窗")
        uk.show(self.v_bps, self.st_bps, self._bps / 1000.0, extra="2 Mbaud 链路的 ~90%")
        total = c.get("frames", 0) + c.get("crc_err", 0)
        err = c.get("crc_err", 0)
        pct = 100.0 * err / total if total else 0.0
        self.st_crcp.update(pct)
        self.v_crc.setText("%d（%s）" % (err, self.st_crcp.text()))
        self.v_crc.setToolTip(self.st_crcp.tip("链路逐帧 XOR 校验；与 BiSS 帧 CRC 无关"))
        self.v_lost.setText("%d / %d" % (c.get("dropped_batches", 0),
                                         c.get("dropped_frames", 0)))
        # 链路健康趋势：每 2 s 一个点，只在诊断页可见时喂（看不见就不画）
        if self.health.isVisible():
            self.health.push(now, self._fps, pct, c.get("lost_frames", 0))
        # 记录卡片的时长/帧数/体积也按半秒刷新（别每帧刷，写 CSV 时刷界面会拖慢）
        # 校验错帧数取链路计数器（卡片自己减开始记录时的基线，显示“本次”的）
        self.record.set_crc(err)
        self.record.tick(now)
        # 底部状态条：帧率来自本地上位机统计，丢帧/校验错/运行时长为链路计数
        # ★ 丢批（batches）与丢帧（frames）单位不同，不能相加成一个"丢帧"数字
        # 帧率/丢帧/校验错在「通信统计」卡里已经有了，底栏只留运行时长（审计：别重复）
        self._sb_lab.setText("已运行 %s" % _hms(c.get("uptime")))
        self._refresh_overview()

    def _refresh_overview(self):
        """概览页的结论行——数据全从既有控件里取，不额外读板子、不加负载。"""
        ovp = getattr(self, "overview", None)
        if ovp is None:
            return
        # 设备与链路
        dev = self.v_device.text()
        if dev in ("—", "", None):
            ovp.set_row("device", "未自检", "点顶栏「设备自检」读一次", "idle")
        else:
            good = dev_id_ok(dev)
            ovp.set_row("device", "%s · %s" % (dev, self.v_build.text()),
                        "%s｜%s｜校验错 %s"
                        % ("已识别" if good else "型号未知",
                           self.v_fps.text(), self.v_crc.text()),
                        "ok" if good else "warn")
        # 输入频率 / 机械转速（取卡片上看得见的那个数，保证概览与实时页一致）
        f_txt = self.speed.v_f.text()
        r_txt = self.speed.v_rpm.text()
        ovp.set_row("freq", f_txt, "1 s 平滑窗，分辨力 ≈ ±1 Hz",
                    "idle" if f_txt in ("—", "") else "ok")
        ovp.set_row("rpm", r_txt,
                    "每转 %d 周期" % int(getattr(self.speed.est, "pairs", 0) or 0),
                    "idle" if r_txt in ("—", "") else "ok")
        # 信号幅值（⑧/④ 卡上的 r 与 ⑦ 卡的门限判定）
        amp_lv = self.alarm.level("amp")
        ovp.set_row("amp", self.v_r.text(),
                    self.alarm.chips["amp"].text(),
                    amp_lv if amp_lv != "idle" else "idle")
        # 前端质量（正交质量卡给的判定；没有数据就写"待数据"，不要编一个数）
        q = getattr(self, "quality", None)
        lvq = q.verdict() if q is not None else -1
        if q is None or lvq < 0:
            ovp.set_row("front", "待数据", "到「实时」页看，或等满 24 ms 数据", "idle")
        else:
            ovp.set_row("front", q.v_err.text(), q.lab_verdict.text().strip(),
                        {0: "ok", 1: "warn", 2: "fault"}.get(int(lvq), "idle"))
        # 告警（挑最严重的一项）
        lv, txt = self.alarm.summary()
        ovp.set_row("alarm", "正常" if lv == "ok" else "—", txt, lv)
        # 记录
        rec = self.record.lab_state.text()
        ovp.set_row("record", self.record.v_rows.text(),
                    "正在记录" if "记录中" in rec else rec,
                    "ok" if "记录中" in rec else "idle")

    def _update_live(self, f):
        # ★ 一律 .get(...) 取值（自查发现）：坏帧/缺键的帧以前会在这里抛 KeyError，
        #   而它由 100 ms 的 _tick 调用 ⇒ 变成"每 100 ms 一个模态错误框"。
        #   与项目别处（recorder.py:870 `f.get("angle_deg") or 0.0`）同一口径。
        b = f.get("io_bits") or {}
        self.v_angle.setText("%.3f °" % (f.get("angle_deg") or 0.0))
        self.v_pos.setText(format(f.get("pos_full") or 0, ","))
        self.v_sc.setText("%d / %d" % (f.get("s") or 0, f.get("c") or 0))
        # R20：幅值 r 稳定显示（悬停看原始值）；电角度/位置/s,c 本身就在变，直接显示
        uk.show(self.v_r, self.st_r, int(float(f.get("amp_sq") or 0.0) ** 0.5),
                extra="r=√(s²+c²)，Q1.15")
        for key, lab in self.chips.items():
            val = b.get(key)
            lab.setText("%s %s" % (key.upper(), "–" if val is None else val))
            uk.paint_chip(lab, val)
        d = b.get("dir")
        lim = b.get("limiter")
        self.v_dir.setText("%s / %s" % ("—" if d is None else ("正转" if d else "反转"),
                                        "—" if lim is None else ("限幅中" if lim else "正常")))
        flags = f.get("flags") or []
        # 只显示前 3 个告警名：位多时文字太长会把整张卡片撑宽（整行卡片跟着挪）
        if flags:
            self.v_flags.setText("● %s%s" % ("、".join(flags[:3]),
                                             "…" if len(flags) > 3 else ""))
            self.v_flags.setToolTip("、".join(flags))
        else:
            self.v_flags.setText("全 0（无告警）")
            self.v_flags.setToolTip("")

    # ---------------------------------------------------------------- 收尾
