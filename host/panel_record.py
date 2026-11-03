r"""⑩ 记录与导出卡片（需求 M6）：开始/停止记录、一键导出波形 PNG。

分工：
* 落盘与统计在 host/recorder.py（纯逻辑、可离线自检）；
* 出图在 host/export_png.py（纯逻辑、可离线自检）；
* 本文件只做界面与"把数据交给上面两个模块"，不自己写文件、不自己画图。

导出用的数据由主窗口收集（它才知道波形卡片/等效采样卡片现在存了什么），
本卡片通过 export_requested 信号请求，再用 finish_export() 收结果并提示。
"""

import os

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import (QCheckBox, QDialog, QFileDialog, QFrame, QGridLayout,
                               QHBoxLayout, QLabel, QPlainTextEdit, QPushButton,
                               QVBoxLayout)

import recorder as rc
import record_bin as rb
import export_png as ep
import theme as th
import ui_kit as uk

C = th.C


def _short_path(path, keep=2):
    """路径太长会把卡片撑宽 ⇒ 只显示最后 keep 段，前面用 …\\ 代替（完整路径进 tooltip）。"""
    if not path:
        return "—"
    parts = os.path.normpath(path).split(os.sep)
    if len(parts) <= keep:
        return path
    return "…" + os.sep + os.sep.join(parts[-keep:])


class RecordPanel(QFrame):
    """记录与导出卡片。"""

    export_requested = Signal(str)          # "wave" / "abz"，由主窗口收集数据后回调
    notice = Signal(str, str)               # (文本, 级别 ok/warn/fault/info) → 写进日志卡片
    replay_requested = Signal(str)          # .bin 路径 → 主窗口开回放

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Card")
        self.rec = None
        self.bin = None               # 二进制副本（原始 18 B/帧）
        # ★ 阶段 5 补丁（用户 m16915）：默认目录先探一次能不能写，不能就换一个能写的
        #   —— 省得"点了开始记录才发现被系统挡住、悄悄改存到别处"。
        self.dir, self.dir_note = rc.pick_dir()
        # ★ 若本进程被降权/带受限令牌（沙箱），"换目录"也救不了 —— 直接在卡片上说清楚，
        #   否则用户只会看到一连串"拒绝访问"，误以为软件坏了（用户 m16915 的现场就是这么来的）。
        _env = rc.env_warning()
        if _env:
            self.dir_note = (_env + "  " + self.dir_note).strip() if self.dir_note else _env
        self._last_info = None
        self._conn = False
        self._crc = 0                # 本机累计校验错帧数（链路计数器给，见 set_crc）
        self._crc_base = 0           # 开始记录那一刻的基线：卡片显示"本次"的校验错
        # ★ R4：停止记录那一刻把六项读数定格（None = 没有定格，按实时值刷新）。
        #   不定格的话，"校验错帧数"取的是实时链路计数器，停止后还会一直涨（用户实测投诉）。
        self._frozen = None

        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(8)

        head = QHBoxLayout()
        title = QLabel("记录与导出")
        title.setObjectName("CardTitle")
        head.addWidget(title)
        head.addStretch(1)
        self.lab_state = QLabel("未记录")
        self.lab_state.setObjectName("BigValueSmall")
        self.lab_state.setProperty("mono", "false")
        head.addWidget(self.lab_state)
        lay.addLayout(head)

        lay.addWidget(uk.hint_label(
            "记录 = 一帧一行：原始 18 字节帧 + 解析列 + 上位机时间戳，用 Excel 直接能开。"
            "10 kHz 下一分钟约 40 MB、六分钟约 100 万行，写满一卷会自动换下一个文件"
            "（…_part002.csv），不会给你一个打不开的巨文件。", lines=3))

        grid = QGridLayout()
        grid.setHorizontalSpacing(10)
        grid.setVerticalSpacing(2)
        self.v_secs = uk.field(grid, "本次时长", "—", width=76, row=0, col=0)
        self.v_rows = uk.field(grid, "本次帧数", "—", width=76, row=0, col=1)
        self.v_size = uk.field(grid, "文件大小", "—", width=76, row=1, col=0)
        self.v_lost = uk.field(grid, "丢帧估计", "—", width=76, row=1, col=1)
        self.v_crc = uk.field(grid, "校验错帧数", "—", width=76, row=2, col=0)
        self.v_rate = uk.field(grid, "写入速率", "—", width=76, row=2, col=1)
        self.v_crc.setToolTip("本次记录期间，板上发出的帧里 XOR 校验失败被丢掉的帧数"
                              "（不含重同步吞掉的字节，那一部分计在“丢帧估计”里）")
        self.v_lost.setToolTip("丢帧估计 = 校验错 + 重同步吞掉的帧，占应到帧数的百分比")
        lay.addLayout(grid)
        # R20（批次 5）：丢帧估计与写入速率随噪声跳 ⇒ 显示层稳定化；
        #   时长/帧数/字节/校验错帧数是累计量（本来就该在涨），不套
        self.st_lost = uk.Stable("rec_lost")
        self.st_rate = uk.Stable("rec_rate")

        # 保存位置：只显示末尾两段，完整路径放 tooltip（长路径会把卡片撑宽）
        row_dir = QHBoxLayout()
        row_dir.setSpacing(6)
        row_dir.addWidget(uk.small_label("保存到", 76))
        self.lab_dir = QLabel(_short_path(self.dir))
        self.lab_dir.setProperty("mono", "true")
        self.lab_dir.setToolTip(self.dir)
        row_dir.addWidget(self.lab_dir, 1)
        self.btn_dir = QPushButton("选择文件夹…")
        self.btn_dir.setToolTip("换个地方存（默认存到“我的文档\\host_app记录”）")
        self.btn_dir.clicked.connect(self._choose_dir)
        row_dir.addWidget(self.btn_dir)
        self.btn_open = QPushButton("打开文件夹")
        self.btn_open.setToolTip("用资源管理器打开记录所在文件夹（有文件时会直接选中它）")
        self.btn_open.clicked.connect(self._open_dir)
        row_dir.addWidget(self.btn_open)
        self.btn_diag = QPushButton("写入诊断")
        self.btn_diag.setToolTip("写不进去时点这里：会逐个目录真的写一次，"
                                 "把错误码和「受控文件夹访问」状态摊开给你看")
        self.btn_diag.clicked.connect(self._show_diag)
        row_dir.addWidget(self.btn_diag)
        lay.addLayout(row_dir)

        row_btn = QHBoxLayout()
        row_btn.setSpacing(6)
        self.btn_rec = QPushButton("● 开始记录")
        self.btn_rec.setToolTip("把收到的每一帧写进 CSV（可随时停止）")
        self.btn_rec.clicked.connect(self.toggle_record)
        row_btn.addWidget(self.btn_rec)
        self.btn_wave = QPushButton("导出波形全貌 PNG")
        self.btn_wave.setToolTip("把当前输入波形（时域 + 李萨如）存成一张大图，"
                                 "图上自带读数，可以直接发给人")
        self.btn_wave.clicked.connect(lambda: self.export_requested.emit("wave"))
        row_btn.addWidget(self.btn_wave)
        self.btn_abz = QPushButton("导出 ABZ 全貌 PNG")
        self.btn_abz.setToolTip("把当前 ABZ/UVW 等效采样图与六状态数据表存成一张大图")
        self.btn_abz.clicked.connect(lambda: self.export_requested.emit("abz"))
        row_btn.addWidget(self.btn_abz)
        self.chk_bin = QCheckBox("同时存二进制")
        self.chk_bin.setProperty("switch", "true")
        self.chk_bin.setChecked(True)
        self.chk_bin.setToolTip(
            "另存一份 .bin：每帧只写原始 18 字节（10.8 MB/分钟，CSV 的 1/4），\n"
            "回放时能还原出与现场逐字节一致的帧流，CSV/频谱都可以由它再生成。\n"
            "带 CRC 与结束标记，断电截断会被明确报出来。")
        row_btn.addWidget(self.chk_bin)
        self.chk_auto = QCheckBox("连上就自动开始记录")
        self.chk_auto.setProperty("switch", "true")      # 阶段 3：状态开关用滑块外观
        self.chk_auto.setToolTip("适合长时间拷机：插上就记录，不用点按钮")
        row_btn.addWidget(self.chk_auto)
        # 回放：.bin 只有能重演才有价值。这里只管"选文件 + 发信号"，
        # 真正的喂帧在 main_window（它才知道波形/质量/告警该喂给谁）。
        self.btn_replay = QPushButton("回放记录…")
        self.btn_replay.setToolTip(
            "选一个 .bin 回放：按 10 kHz 的节奏把当时的帧重新喂给界面，\n"
            "波形、正交质量、告警状态机全部照跑——现场问题可以带回办公室重演。")
        self.btn_replay.clicked.connect(self._choose_replay)
        row_btn.addWidget(self.btn_replay)
        row_btn.addStretch(1)
        lay.addLayout(row_btn)

        self.lab_note = uk.hint_label("还没开始记录。点「开始记录」会把收到的帧写进 CSV；"
                                      "导出 PNG 不用先记录，随时可以按。", lines=2)
        lay.addWidget(self.lab_note)
        # ★ 阶段 5 补丁：默认目录被系统挡住时，一进来就说明白（不能等自检/用户去发现）
        if self.dir_note:
            self.lab_note.setText("%s。点「写入诊断」看细节。" % self.dir_note)
            self.lab_note.setStyleSheet("color:%s;" % C["warn"])
        lay.addStretch(1)
        self._refresh_buttons(conn=False, enabled=False)

    # ------------------------------------------------------------- 外部接口
    def set_connected(self, conn, enabled=None):
        """conn = 串口是否连着；enabled = 现在能不能点（连上且不忙）。"""
        self._conn = bool(conn)
        self._refresh_buttons(conn, enabled)
        if not conn and self.rec is not None and self.rec.active:
            self.stop_record("串口断开，已自动停止记录")

    def auto_record(self):
        return bool(self.chk_auto.isChecked())

    def _show_dir(self):
        """把当前保存目录写进标签（只显示末尾几段，完整路径进 tooltip）。

        ★ 正在记录时显示的是**当前这个文件**的真实路径：换目录只影响下一段记录，
        若这时显示新目录，卡片就在"撒谎"（数据其实还在旧文件里）。
        """
        if self.rec is not None and self.rec.active:
            self.lab_dir.setText(_short_path(self.rec.path))
            self.lab_dir.setToolTip("%s\n（正在写的文件；换目录从下一段记录开始）"
                                    % self.rec.path)
            return
        self.lab_dir.setText(_short_path(self.dir))
        self.lab_dir.setToolTip(self.dir)

    def set_dir(self, path):
        """换保存目录（命令行参数/程序化设置用；不存在就建出来）。

        ★ 阶段 5（D 批）：建出来之后还要**真写一次探针文件**才知道能不能写 ——
        Windows「受控文件夹访问」会在运行时拦下写桌面/文档的陌生程序，`os.access()`
        照样报可写，只有真写才会暴露。不可写时不静默接受，而是当场把原因和下一步
        写在卡片上（开始记录时还会自动换一个能写的位置，见 `rc.Recorder.start()`）。
        """
        if not path:
            return False
        try:
            path = os.path.abspath(path)
            os.makedirs(path, exist_ok=True)
        except (OSError, ValueError) as exc:                  # 含 NUL 的路径抛 ValueError
            self.lab_note.setText("这个目录建不出来：%s" % exc)
            self.lab_note.setStyleSheet("color:%s;" % th.C["warn"])
            return False
        self.dir = path
        self._show_dir()
        ok, why = rc.probe_writable(path)
        if not ok:
            self.lab_note.setText("这个目录现在写不进去（%s）%s；开始记录时会自动改存到"
                                  "一个能写的位置" % (why, rc.dir_hint(why)))
            self.lab_note.setStyleSheet("color:%s;" % C["warn"])
            self.notice.emit("保存目录 %s 不可写：%s" % (path, why), "warn")
        else:
            self.lab_note.setStyleSheet("color:%s;" % th.C["muted"])
        if self.rec is not None and self.rec.active:
            self.notice.emit("保存目录已改成 %s（当前这段记录仍在 %s）"
                             % (path, self.rec.path), "warn")
        return True

    def reset(self):
        if self.bin is not None:
            self.bin.close()
            self.bin = None
        """断开/重连时收尾（把正在写的文件关掉，统计留着给人看）。"""
        if self.rec is not None and self.rec.active:
            self.stop_record("连接复位，已自动停止记录")
        self._last_info = None
        self.st_lost.reset()
        self.st_rate.reset()

    def feed(self, frames, n_bad=0, n_drop=0, t_mono=None):
        """把这一批帧喂给记录器（没在记录就什么也不做）。

        ★ 注意：`frames` 为空但 n_bad/n_drop 不为 0 时**也要转发** —— 主窗口在"这一 tick
        一帧都没到（整批被链路丢了）"时正是这样调的，为的是把丢帧数记进 CSV 的丢帧估计；
        老实现一句 `not frames` 直接 return，那种情况下的丢帧就被静默吃掉了。
        """
        if self.rec is None or not self.rec.active:
            return 0
        if not frames and not n_bad and not n_drop:
            return 0
        if self.bin is not None and frames:
            self.bin.write_frames(frames)     # 只搬 raw 字节，解析仍是 CSV 那份
        return self.rec.feed(frames, n_bad=n_bad, n_drop=n_drop, t_mono=t_mono)

    def start_record(self):
        """开始记录。自动起一个带时间戳的文件名。"""
        if self.rec is not None and self.rec.active:
            return True
        name = rc.default_name()
        path = os.path.join(self.dir, name)
        self.rec = rc.Recorder(path, notice=lambda t, lv: self.notice.emit(t, lv))
        if not self.rec.start():
            self.lab_note.setText(self.rec.error or "开始记录失败")
            self.lab_note.setStyleSheet("color:%s;" % C["fault"])
            return False
        # 二进制副本：与 CSV 同名同目录，只换扩展名（回放时两者可交叉核对）
        if getattr(self, "chk_bin", None) is not None and self.chk_bin.isChecked():
            try:
                self.bin = rb.BinRecorder(
                    os.path.splitext(self.rec.path)[0] + ".bin", fs_hz=10000,
                    meta={"csv": os.path.basename(self.rec.path),
                          "port": getattr(self.rec, "port", "") or "",
                          "app": "host_app"})
            except Exception as exc:                     # noqa: BLE001
                self.bin = None
                self.notice.emit("二进制副本开不了（%s），CSV 照常记" % exc, "warn")
        self._crc_base = self._crc        # “本次”校验错从这一刻算起
        self._frozen = None               # ★ R4：重新开表 ⇒ 六项读数从 0 重新算
        self.st_lost.reset()              # R20：稳定器也重新起算（新一次记录）
        self.st_rate.reset()
        self.lab_dir.setText(_short_path(self.rec.path))
        self.lab_dir.setToolTip(self.rec.path)
        # ★ 阶段 5：目录不可写时记录器会自动改存（did_fallback）—— 卡片必须显示
        #   **真正在写的那个文件**，并把"为什么换了位置"摆在人们看得见的地方。
        if getattr(self.rec, "did_fallback", False):
            self.lab_note.setText("原目录写不进去 ⇒ 本次已自动改存到 %s" % self.rec.path)
            self.lab_note.setStyleSheet("color:%s;" % C["warn"])
        else:
            self.lab_note.setText("正在记录到 %s" % self.rec.path)
            self.lab_note.setStyleSheet("")
        # 不再自己发一条"开始记录"：Recorder.start() 已经通过 notice 回调报过了，
        # 自己再发一条日志里会出现两遍一模一样的行（预览截图里真出现过）
        self._refresh_buttons(self._conn)
        self.tick()
        return True

    def stop_record(self, why=None):
        """停止记录并显示本次统计。"""
        if self.rec is None:
            return None
        bin_note = ""
        if self.bin is not None:
            st_bin = self.bin.stats()
            self.bin.close()
            self.bin = None
            if st_bin.get("error"):
                bin_note = "（二进制副本有错：%s）" % st_bin["error"]
            else:
                bin_note = "、二进制 %d 帧/%.0f MB" % (
                    st_bin["n"], st_bin["bytes"] / 1e6)
        st = self.rec.stop()
        self._freeze(st)                     # ★ R4：先定格，再显示（tick 只读定格值）
        if st and st.get("rows"):
            self.lab_note.setText("记录完成：%s%s（存到 %s）"
                                  % (rc.stats_text(st), bin_note,
                                     _short_path(st["files"][-1] if st["files"]
                                                 else st["path"])))
            self.lab_note.setStyleSheet("color:%s;" % C["ok"])
            # 完成提示也走记录器自己的 notice（"已停止记录：共 … 帧 / N 个文件 / 体积"），
            # 这里不再重复发一遍统计，只在日志里补上文件位置这一条有用信息
            last = st["files"][-1] if st["files"] else st["path"]
            self.notice.emit("记录文件：%s" % last, "ok")
        elif why:
            self.lab_note.setText(why)
            self.lab_note.setStyleSheet("color:%s;" % C["warn"])
            self.notice.emit(why, "warn")
        self.tick()
        self._refresh_buttons(self._conn)
        return st

    def toggle_record(self):
        if self.rec is not None and self.rec.active:
            self.stop_record()
        else:
            self.start_record()

    def stats(self):
        """本次记录的统计；从没开过表就返回空 dict（调用方直接 .get 也不会炸）。"""
        return self.rec.stats() if self.rec is not None else {}

    def set_crc(self, n):
        """本机累计校验错帧数（link.counters()['crc_err']），主窗口每 0.5 s 给一次。"""
        n = int(n or 0)
        if n < self._crc:
            # 计数器变小说明换了 worker（重连后从 0 起）：把基线也归零，
            # 否则新会话的校验错会被上一条连接的基线全吃掉（显示成 0）
            self._crc_base = 0
        self._crc = n

    def _freeze(self, st):
        """把本次统计定格成一份快照（需求 R4：停止记录后读数不再变动）。

        为什么要单独存一份：卡片上的"校验错帧数"来自链路计数器（主窗口每 0.5 s 还会
        调 set_crc()），"时长/帧数/体积/速率"来自 recorder.stats()。停止后这些来源都还在
        变（链路照旧收帧、计数器照旧涨），所以必须把停止那一刻的六个数抄下来，
        之后一律显示这份快照，做到"随动随止"。
        """
        if not st or not st.get("rows"):
            self._frozen = None              # 没有数据（空记录）不值得定格
            return
        self._frozen = {
            "seconds": float(st.get("seconds") or 0.0),
            "rows": int(st.get("rows") or 0),
            "bytes": float(st.get("bytes") or 0.0),
            "lost_pct": float(st.get("lost_pct") or 0.0),
            "fps": float(st.get("fps") or 0.0),
            "crc": max(0, self._crc - self._crc_base),
        }

    def _show_frozen(self):
        f = self._frozen
        # 定格值就是最终值，直接写原始数（不套稳定器）
        self.v_secs.setText("%.1f s" % f["seconds"])
        self.v_rows.setText(format(f["rows"], ","))
        self.v_size.setText(rc.size_text(f["bytes"]))
        self.v_lost.setText("%.2f %%" % f["lost_pct"])
        self.v_lost.setToolTip("定格：本次记录结束时的丢帧估计\n" + self.st_lost.tip())
        self.v_crc.setText(format(f["crc"], ","))
        self.v_rate.setText("%s" % format(int(round(f["fps"])), ",") + " 帧/秒")
        self.v_rate.setToolTip("定格：本次记录结束时的平均写入速率\n" + self.st_rate.tip())
        for st in (self.st_lost, self.st_rate):
            st.reset()

    def refresh_readouts(self):
        """R20：按当前显示口径重画读数（切「原始值」时由主窗口调）。"""
        self.tick()

    def tick(self, t_mono=None):
        """定期刷新读数（主窗口每 0.5 s 叫一次）。"""
        if self._frozen is not None:            # ★ R4：停止后只显示定格值
            self._show_frozen()
            self.lab_state.setText("已停止")
            self.lab_state.setStyleSheet("color:%s;" % C["muted"])
            self._refresh_buttons(self._conn)
            return
        st = self.rec.stats(t_mono) if self.rec is not None else None
        if not st or not st["rows"]:
            self.v_secs.setText("—")
            self.v_rows.setText("—")
            self.v_size.setText("—")
            self.v_lost.setText("—")
            self.v_lost.setToolTip("丢帧估计 = 校验错 + 重同步吞掉的帧，占应到帧数的百分比")
            self.v_crc.setText("—")
            self.v_rate.setText("—")
            self.v_rate.setToolTip("写盘速度（本机磁盘性能）")
            self.st_lost.reset()
            self.st_rate.reset()
        else:
            self.v_secs.setText("%.1f s" % st["seconds"])
            self.v_rows.setText(format(st["rows"], ","))
            self.v_size.setText(rc.size_text(st["bytes"]))
            # R20：丢帧估计与写入速率稳定显示（悬停看原始值）
            uk.show(self.v_lost, self.st_lost, st["lost_pct"],
                    extra="校验错帧 + 重同步吞帧占应到帧数")
            uk.show(self.v_rate, self.st_rate, st["fps"], extra="写盘速度（本机磁盘性能）")
            self.v_crc.setText(format(max(0, self._crc - self._crc_base), ","))
        active = bool(st and st["active"])
        if active:
            self.lab_state.setText("● 记录中")
            self.lab_state.setStyleSheet("color:%s; font-weight:bold;" % C["fault"])
        else:
            self.lab_state.setText("未记录")
            self.lab_state.setStyleSheet("color:%s;" % C["muted"])
        # ★ 这里不能写死 True：断开后按钮会立刻回弹，能在没有串口时开表（生成空 CSV，
        #   叠加"同一秒重名"还会覆盖上一段记录）。连通性以主窗口最后一次给的为准。
        self._refresh_buttons(self._conn)

    # --------------------------------------------------------- 导出结果回执
    def finish_export(self, kind, info, data_note=""):
        """主窗口导出完把结果给回来，这里提示"存哪儿了"。"""
        self._last_info = info
        if not info or not info.get("ok"):
            msg = (info or {}).get("error") or "导出失败"
            self.lab_note.setText(msg)
            self.lab_note.setStyleSheet("color:%s;" % C["fault"])
            self.notice.emit("导出 PNG 失败：%s" % msg, "fault")
            return
        # 用 .get 兜底：槽有可能收到缺键的 dict（比如别处造的失败 info），
        # 直接 info["bytes"] 会抛 KeyError 打进 Qt 槽
        nbytes = info.get("bytes") or 0
        px = info.get("px") or (0, 0)
        what = "ABZ/UVW 图" if str(kind).startswith("abz") else "波形图"
        if str(kind).endswith("_view"):
            what += "（当前视图）"
        path = info.get("path") or ""
        self.lab_note.setText("已导出%s：%s（%.0f kB，%d×%d 像素）%s"
                              % (what, _short_path(path),
                                 nbytes / 1024.0, px[0], px[1],
                                 ("　" + data_note) if data_note else ""))
        self.lab_note.setStyleSheet("color:%s;" % C["ok"])
        self.notice.emit("已导出 PNG：%s（%.0f kB）" % (path, nbytes / 1024.0), "ok")

    # ---------------------------------------------------------------- 内部
    def _refresh_buttons(self, conn, enabled=None):
        live = bool(conn if enabled is None else enabled)
        active = bool(self.rec is not None and self.rec.active)
        self.btn_rec.setEnabled(live or active)
        self.btn_rec.setText("■ 停止记录" if active else "● 开始记录")
        self.btn_rec.setStyleSheet(
            "QPushButton{background:%s;color:#FFFFFF;font-weight:bold;}"
            % (C["fault"] if active else C["primary"]))
        # 导出不需要串口：断开后也能把最后一批波形存下来
        self.btn_wave.setEnabled(True)
        self.btn_abz.setEnabled(True)
        self.btn_dir.setEnabled(not active)
        self.chk_auto.setEnabled(live and not active)

    def _choose_dir(self):
        d = QFileDialog.getExistingDirectory(self, "选择记录保存文件夹", self.dir)
        if d:
            # ★ 阶段 5 补丁：必须走 set_dir() —— 老代码直接赋值，**跳过了写探测**，
            #   于是用户选了一个写不进去的目录后，界面不吭声、直到记录/导出才报错。
            if self.set_dir(d):
                self.notice.emit("记录保存位置改为：%s" % d, "info")
            else:
                self.notice.emit("记录保存位置改成 %s，但这里现在写不进去" % d, "warn")

    def _choose_replay(self):
        """选一个 .bin，交给主窗口回放（本面板不认识别的面板）。"""
        p, _f = QFileDialog.getOpenFileName(
            self, "选择要回放的二进制记录", self.dir,
            "二进制记录 (*.bin);;所有文件 (*.*)")
        if not p:
            return
        if not os.path.isfile(p):
            self.notice.emit("回放文件不存在：%s" % p, "warn")
            return
        self.replay_requested.emit(p)

    def _open_dir(self):
        """用系统文件管理器打开保存位置（有记录文件时直接选中那个文件）。

        ★ 阶段 5 补丁（用户 m16915「打不开文件夹」）：老实现只调 `os.startfile(dir)`，
        在这台机器上抛 `[WinError 5] 拒绝访问`，用户看到的就是"打不开"。改成三级兜底：
        ① `explorer /select,<文件>`（能选中，最直观）；② `os.startfile`；
        ③ `explorer <目录>`；全失败就把路径复制到剪贴板并明确告诉用户。
        """
        target = self.dir
        if self.rec is not None and self.rec.files:
            target = os.path.dirname(self.rec.files[-1])
        if not target or not os.path.isdir(target):
            self.notice.emit("要打开的文件夹还不存在：%s" % target, "warn")
            return
        sel = self.rec.files[-1] if (self.rec is not None and self.rec.files) else None
        errors = []
        if os.name == "nt":
            import subprocess                                       # noqa: PLC0415
            if sel and os.path.exists(sel):
                try:
                    subprocess.Popen(["explorer", "/select,%s" % os.path.normpath(sel)],
                                     close_fds=True)
                    return
                except Exception as exc:                            # noqa: BLE001
                    errors.append("explorer /select：%s" % exc)
            try:
                os.startfile(target)                                # noqa: S606
                return
            except Exception as exc:                                # noqa: BLE001
                errors.append("startfile：%s" % exc)
            try:
                subprocess.Popen(["explorer", os.path.normpath(target)], close_fds=True)
                return
            except Exception as exc:                                # noqa: BLE001
                errors.append("explorer：%s" % exc)
        else:                                                       # pragma: no cover
            import subprocess                                       # noqa: PLC0415
            try:
                subprocess.Popen(["xdg-open", target])
                return
            except Exception as exc:                                # noqa: BLE001
                errors.append("xdg-open：%s" % exc)
        # 三条路都不通：把路径交到用户手上，别再只说一句"打不开"
        try:
            QGuiApplication.clipboard().setText(target)
            self.notice.emit("自动打开失败（%s）；路径已复制到剪贴板：%s"
                             % ("；".join(errors), target), "warn")
        except Exception:                                           # noqa: BLE001
            self.notice.emit("自动打开失败（%s）；路径：%s"
                             % ("；".join(errors), target), "warn")

    def _show_diag(self):
        """把"为什么写不进去"摊开：逐目录真写一次，给出错误码与受控文件夹访问状态。"""
        target = self.dir
        if self.rec is not None and self.rec.files:
            target = os.path.dirname(self.rec.files[-1])
        try:
            txt = rc.write_diagnosis(target)
        except Exception as exc:                                    # noqa: BLE001
            txt = "诊断本身出错了：%s" % exc
        # ★ 连点不能越点越多（自查发现）：以前每点一次新建一个 QDialog，旧的留在
        #   parent=self 上不关 ⇒ 点 N 次 N 个常驻窗口。这里优先复用已经开着的那个。
        old_box = getattr(self, "_diag_box", None)
        if old_box is not None:
            try:
                old_box.setWindowTitle("写入诊断 — %s" % target)
                inner = old_box.findChild(QPlainTextEdit, "Log")
                if inner is not None:
                    inner.setPlainText(txt)
                old_box.show()
                old_box.raise_()
                old_box.activateWindow()
                return
            except RuntimeError:                    # 底层 C++ 对象已销毁
                self._diag_box = None
        box = QDialog(self)
        box.setWindowTitle("写入诊断 — %s" % target)
        box.resize(760, 460)
        v = QVBoxLayout(box)
        head = QLabel("下面每个目录都真的写了一次探针文件（写完即删）。"
                      "把这段发给开发者即可定位；文本可以直接选中复制。")
        head.setObjectName("Hint")
        head.setWordWrap(True)
        v.addWidget(head)
        edit = QPlainTextEdit(txt)
        edit.setReadOnly(True)
        edit.setObjectName("Log")
        v.addWidget(edit, 1)
        row = QHBoxLayout()
        btn_copy = QPushButton("复制全部")
        btn_copy.clicked.connect(lambda: QGuiApplication.clipboard().setText(txt))
        row.addWidget(btn_copy)
        row.addStretch(1)
        btn_close = QPushButton("关闭")
        btn_close.clicked.connect(box.accept)
        row.addWidget(btn_close)
        v.addLayout(row)
        # ★ 非模态：用户要能一边看报告一边继续用界面（也让自检点它不会卡住）
        self._diag_box = box
        box.show()
        box.raise_()
