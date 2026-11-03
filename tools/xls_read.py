#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
xls_read.py —— 纯 Python 的 OLE2(CFB) + BIFF8 读取器
=====================================================
为什么自己写：本机沙箱禁止 pip 写入（site-packages 与 %TEMP% 都拒绝），
而 xlrd / olefile / pandas 的 xls 引擎都不可用。`.xls` 是 OLE2 复合文档
（CFB）+ 一系列 BIFF 记录，格式是公开且稳定的，直接解析即可。

支持：BIFF8（Excel 97-2003）与 WPS 表格导出的 .xls。
需要的记录：
  - SST(0x00FC) + CONTINUE(0x003C)  —— 共享字符串表
  - LABELSST(0x00FD)                —— 指向 SST 的字符串单元格
  - LABEL(0x0204)                   —— 内联字符串单元格
  - NUMBER(0x0203) / RK(0x027E) / MULRK(0x00BD)   —— 数值
  - BOF(0x0809) / EOF(0x000A)       —— 工作表边界
  - BOUNDSHEET(0x0085)              —— 工作表名 + 起始偏移
  - FORMAT(0x041E) / XF(0x00E0)     —— 仅用于判断是否为日期

用法：
  python tools/xls_read.py <file.xls> [sheet_index] [output.tsv]
  不带 sheet_index 时列出所有工作表并打印全部内容。
"""

import struct
import sys
import io


# ---------------------------------------------------------------- OLE2 / CFB

class Ole2:
    """最小的 OLE2 复合文档读取器（只实现读流）。"""

    def __init__(self, path):
        self.data = open(path, "rb").read()
        d = self.data
        if d[:8] != b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
            raise ValueError("不是 OLE2 复合文档（缺 CFB 签名）")
        if d[28:30] != b"\xfe\xff":
            raise ValueError("字节序不是 little-endian（%r）" % d[28:30])

        self.sector_shift = struct.unpack_from("<H", d, 30)[0]
        self.sector_size = 1 << self.sector_shift            # 通常 512 或 4096
        self.mini_shift = struct.unpack_from("<H", d, 32)[0]
        self.mini_size = 1 << self.mini_shift                # 通常 64
        self.num_fat = struct.unpack_from("<I", d, 44)[0]
        self.dir_start = struct.unpack_from("<I", d, 48)[0]
        self.mini_cutoff = struct.unpack_from("<I", d, 56)[0]
        self.mini_fat_start = struct.unpack_from("<I", d, 60)[0]
        self.num_mini_fat = struct.unpack_from("<I", d, 64)[0]
        self.difat_start = struct.unpack_from("<I", d, 68)[0]
        self.num_difat = struct.unpack_from("<I", d, 72)[0]

        self.fat = self._load_fat()
        self.dir_entries = self._load_dir()
        self.mini_fat = self._load_mini_fat()
        self.mini_stream = None

    # -- 扇区寻址 ---------------------------------------------------------
    def _sector_off(self, sid):
        return (sid + 1) * self.sector_size

    def _read_sector(self, sid):
        off = self._sector_off(sid)
        return self.data[off:off + self.sector_size]

    def _load_fat(self):
        # DIFAT：先取头部的 109 项，再沿 DIFAT 链继续
        difat = list(struct.unpack_from("<109I", self.data, 76))
        sid = self.difat_start
        per = self.sector_size // 4
        guard = 0
        while sid not in (0xFFFFFFFE, 0xFFFFFFFF) and guard < 100000:
            blk = self._read_sector(sid)
            vals = list(struct.unpack_from("<%dI" % per, blk, 0))
            difat.extend(vals[:-1])
            sid = vals[-1]
            guard += 1
        fat = []
        for fs in difat[:self.num_fat]:
            if fs in (0xFFFFFFFE, 0xFFFFFFFF):
                continue
            blk = self._read_sector(fs)
            fat.extend(struct.unpack_from("<%dI" % per, blk, 0))
        return fat

    def _chain(self, start, fat):
        """沿 FAT 链收集扇区号。"""
        out = []
        sid = start
        guard = 0
        while sid not in (0xFFFFFFFE, 0xFFFFFFFF) and guard < 1000000:
            out.append(sid)
            if sid >= len(fat):
                break
            sid = fat[sid]
            guard += 1
        return out

    def _read_chain(self, start, fat, size=None):
        parts = [self._read_sector(s) for s in self._chain(start, fat)]
        buf = b"".join(parts)
        return buf[:size] if size is not None else buf

    def _load_dir(self):
        raw = self._read_chain(self.dir_start, self.fat)
        ent_size = 128
        entries = []
        for i in range(0, len(raw) - ent_size + 1, ent_size):
            e = raw[i:i + ent_size]
            nlen = struct.unpack_from("<H", e, 64)[0]
            if nlen == 0:
                continue
            name = e[:max(0, nlen - 2)].decode("utf-16le", "replace")
            etype = e[66]
            start = struct.unpack_from("<I", e, 116)[0]
            size = struct.unpack_from("<Q", e, 120)[0]
            entries.append({"name": name, "type": etype,
                            "start": start, "size": size})
        return entries

    def _load_mini_fat(self):
        if self.mini_fat_start in (0xFFFFFFFE, 0xFFFFFFFF):
            return []
        raw = self._read_chain(self.mini_fat_start, self.fat)
        n = len(raw) // 4
        return list(struct.unpack_from("<%dI" % n, raw, 0))

    def _root_entry(self):
        for e in self.dir_entries:
            if e["type"] == 5:
                return e
        return None

    def _mini_stream_data(self):
        if self.mini_stream is None:
            root = self._root_entry()
            self.mini_stream = self._read_chain(root["start"], self.fat,
                                                root["size"])
        return self.mini_stream

    def stream(self, name):
        """按名字取流（大小写不敏感）。"""
        for e in self.dir_entries:
            if e["type"] == 2 and e["name"].lower() == name.lower():
                if e["size"] < self.mini_cutoff:
                    ms = self._mini_stream_data()
                    parts = []
                    sid = e["start"]
                    guard = 0
                    while sid not in (0xFFFFFFFE, 0xFFFFFFFF) and guard < 1000000:
                        off = sid * self.mini_size
                        parts.append(ms[off:off + self.mini_size])
                        if sid >= len(self.mini_fat):
                            break
                        sid = self.mini_fat[sid]
                        guard += 1
                    return b"".join(parts)[:e["size"]]
                return self._read_chain(e["start"], self.fat, e["size"])
        raise KeyError("找不到流 %r，可用：%s" % (name,
                       [e["name"] for e in self.dir_entries if e["type"] == 2]))

    def names(self):
        return [(e["name"], e["size"]) for e in self.dir_entries if e["type"] == 2]


# ------------------------------------------------------------------- BIFF8

def _biff_records(buf):
    """顺序产出 (record_type, payload)。"""
    pos = 0
    n = len(buf)
    while pos + 4 <= n:
        rt, ln = struct.unpack_from("<HH", buf, pos)
        pos += 4
        if pos + ln > n:
            break
        yield rt, buf[pos:pos + ln]
        pos += ln


def _decode_short_str(buf, off):
    """ShortXLUnicodeString：1 字节长度 + 标志 + 字符。返回 (s, 新偏移)"""
    cch = buf[off]
    flags = buf[off + 1]
    off += 2
    if flags & 0x01:            # 16 位字符
        s = buf[off:off + cch * 2].decode("utf-16le", "replace")
        return s, off + cch * 2
    s = buf[off:off + cch].decode("latin-1", "replace")
    return s, off + cch


def parse_sst(payload, nstrings):
    """
    解析 SST。返回字符串列表。
    处理 record 内部的 rich-text / far-east 扩展，以及跨 CONTINUE 的续接
    （CONTINUE 续接时若字符串被截断，下一个 CONTINUE 开头有一个 grbit 字节
     说明后续字符是 8 位还是 16 位——这是 BIFF8 里最容易被忽略的细节）。
    """
    strings = []
    off = 8          # 跳过 cstTotal(4) + cstUnique(4)
    buf = payload
    total = len(buf)

    def get_byte():
        return buf[off]

    while len(strings) < nstrings:
        if off + 3 > total:
            break
        cch = struct.unpack_from("<H", buf, off)[0]
        flags = buf[off + 2]
        off += 3
        rich = flags & 0x08
        far = flags & 0x04
        nrich = 0
        if rich:
            nrich = struct.unpack_from("<H", buf, off)[0]
            off += 2
        cchfar = 0
        if far:
            cchfar = struct.unpack_from("<I", buf, off)[0]
            off += 4

        # 读字符——可能要跨 CONTINUE，这里 buf 已由调用者拼好，
        # 但拼接处存在 grbit 字节，需要按“期望宽度”判断。
        chars = []
        left = cch
        wide = bool(flags & 0x01)
        while left > 0:
            if off >= total:
                break
            # 若从这里开始能读满 left 个字符，且宽度匹配，则直接读
            if wide:
                avail = (total - off) // 2
                if avail >= left:
                    chars.append(buf[off:off + left * 2]
                                 .decode("utf-16le", "replace"))
                    off += left * 2
                    left = 0
                else:
                    chars.append(buf[off:off + avail * 2]
                                 .decode("utf-16le", "replace"))
                    off += avail * 2
                    left -= avail
            else:
                avail = total - off
                if avail >= left:
                    chars.append(buf[off:off + left]
                                 .decode("latin-1", "replace"))
                    off += left
                    left = 0
                else:
                    chars.append(buf[off:off + avail]
                                 .decode("latin-1", "replace"))
                    off += avail
                    left -= avail
            if left > 0:
                # 这里本该跳 CONTINUE 边界；调用者已把 payload 连起来，
                # 边界处多了一个 grbit 字节，跳过它并更新宽度
                if off < total:
                    g = buf[off]
                    if g in (0, 1):
                        wide = bool(g & 0x01)
                        off += 1
                        continue
                break
        strings.append("".join(chars))
        if rich:
            off += 4 * nrich
        if far:
            off += cchfar
    return strings


def _rk_to_number(rk):
    """BIFF 的 RK 编码 -> float。"""
    if rk & 0x02:
        val = float(rk >> 2)
    else:
        val = struct.unpack("<d", struct.pack("<Q", (rk & 0xFFFFFFFC) << 32))[0]
    if rk & 0x01:
        val /= 100.0
    return val


def _col_letters(c):
    s = ""
    c += 1
    while c:
        c, r = divmod(c - 1, 26)
        s = chr(65 + r) + s
    return s


def read_xls(path, want_sheet=None):
    ole = Ole2(path)
    wb = ole.stream("Workbook") if any(
        n.lower() == "workbook" for n, _ in ole.names()) else ole.stream("Book")

    # 第一遍：收集全局项（SST、BOUNDSHEET）并切出各 sheet 的字节区间
    sheets = []          # (name, offset)
    sst = []
    bofs = []
    pos = 0
    n = len(wb)
    while pos + 4 <= n:
        rt, ln = struct.unpack_from("<HH", wb, pos)
        pos += 4
        if pos + ln > n:
            break
        payload = wb[pos:pos + ln]
        pos += ln
        if rt == 0x0809:                       # BOF
            bofs.append((pos - ln - 4, struct.unpack_from("<H", payload, 2)[0]))
        elif rt == 0x0085:                     # BOUNDSHEET
            off = struct.unpack_from("<I", payload, 0)[0]
            cch = payload[6]
            flags = payload[7]
            if flags & 0x01:
                nm = payload[8:8 + cch * 2].decode("utf-16le", "replace")
            else:
                nm = payload[8:8 + cch].decode("latin-1", "replace")
            sheets.append((nm, off))
        elif rt == 0x00FC:                     # SST
            cnt = struct.unpack_from("<I", payload, 4)[0]
            # 把后续所有 CONTINUE 拼起来
            combined = bytearray(payload)
            save = pos
            while pos + 4 <= n:
                rt2, ln2 = struct.unpack_from("<HH", wb, pos)
                if rt2 != 0x003C:
                    break
                combined += wb[pos + 4:pos + 4 + ln2]
                pos += 4 + ln2
            try:
                sst = parse_sst(bytes(combined), cnt)
            except Exception:
                sst = []
            pos = save

    if want_sheet is None:
        return sheets, sst, wb, ole

    # 第二个 pass：解析指定 sheet
    target_off = sheets[want_sheet][1]
    cells = {}
    pos = target_off
    depth = 0
    while pos + 4 <= n:
        rt, ln = struct.unpack_from("<HH", wb, pos)
        pos += 4
        if pos + ln > n:
            break
        payload = wb[pos:pos + ln]
        pos += ln
        if rt == 0x0809:
            depth += 1
            if depth > 1:
                break
        elif rt == 0x000A:                     # EOF
            break
        elif rt == 0x00FD:                     # LABELSST
            r, c, _xf, idx = struct.unpack_from("<HHHI", payload, 0)
            cells[(r, c)] = sst[idx] if idx < len(sst) else ""
        elif rt == 0x0204:                     # LABEL
            r, c = struct.unpack_from("<HH", payload, 0)
            s, _ = _decode_short_str(payload, 6)
            cells[(r, c)] = s
        elif rt == 0x0203:                     # NUMBER
            r, c = struct.unpack_from("<HH", payload, 0)
            cells[(r, c)] = struct.unpack_from("<d", payload, 6)[0]
        elif rt == 0x027E:                     # RK
            r, c = struct.unpack_from("<HH", payload, 0)
            cells[(r, c)] = _rk_to_number(struct.unpack_from("<I", payload, 6)[0])
        elif rt == 0x00BD:                     # MULRK
            r, c1 = struct.unpack_from("<HH", payload, 0)
            cnt = (len(payload) - 6) // 6
            for i in range(cnt):
                rk = struct.unpack_from("<I", payload, 4 + i * 6 + 2)[0]
                cells[(r, c1 + i)] = _rk_to_number(rk)
        elif rt == 0x0006:                     # FORMULA（只取缓存值）
            r, c = struct.unpack_from("<HH", payload, 0)
            raw = payload[6:14]
            fv = struct.unpack("<d", raw)[0]
            if raw[6:8] == b"\xff\xff":
                if raw[0] == 0:
                    cells[(r, c)] = "<str>"
                elif raw[0] == 1:
                    cells[(r, c)] = bool(raw[2])
                elif raw[0] == 2:
                    cells[(r, c)] = "#ERR"
                else:
                    cells[(r, c)] = ""
            else:
                cells[(r, c)] = fv
    return sheets, sst, cells, ole


def dump(path, sheet_index=None):
    sheets, sst, cells, ole = read_xls(path, sheet_index)
    out = []
    out.append("流：%s" % ", ".join("%s(%d B)" % (n, s) for n, s in ole.names()))
    out.append("工作表：%s" % ", ".join(
        "%d=%s@%d" % (i, nm, off) for i, (nm, off) in enumerate(sheets)))
    if sheet_index is None:
        return "\n".join(out)
    name = sheets[sheet_index][0]
    out.append("=" * 70)
    out.append("SHEET %d: %s   非空单元格 %d 个" % (sheet_index, name, len(cells)))
    if not cells:
        return "\n".join(out)
    rmax = max(r for r, _ in cells)
    cmax = max(c for _, c in cells)
    out.append("范围：%s1 .. %s%d" % (_col_letters(0), _col_letters(cmax), rmax + 1))
    for r in range(rmax + 1):
        row = []
        for c in range(cmax + 1):
            v = cells.get((r, c), "")
            if isinstance(v, float):
                v = ("%g" % v)
            row.append(str(v))
        if any(x.strip() for x in row):
            out.append("%3d | %s" % (r + 1, " | ".join(row).rstrip(" |")))
    return "\n".join(out)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    p = sys.argv[1]
    if len(sys.argv) < 3:
        text = dump(p, None)
        # 列出每个 sheet 的规模
        lines = [text]
        sheets, sst, _cells, _ole = read_xls(p, None)
        for i, (nm, _off) in enumerate(sheets):
            _s, _ss, cc, _o = read_xls(p, i)
            lines.append("  [%d] %-40s %d 个非空单元格" % (i, nm, len(cc)))
        text = "\n".join(lines)
    else:
        idx = sys.argv[2]
        idx = None if idx.lower() in ("all", "*") else int(idx)
        if idx is None:
            sheets, _sst, _c, _o = read_xls(p, None)
            text = "\n\n".join(dump(p, i) for i in range(len(sheets)))
        else:
            text = dump(p, idx)
    if len(sys.argv) >= 4:
        open(sys.argv[3], "w", encoding="utf-8").write(text)
        print("written %s (%d chars)" % (sys.argv[3], len(text)))
    else:
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8",
                                      errors="replace")
        print(text)
