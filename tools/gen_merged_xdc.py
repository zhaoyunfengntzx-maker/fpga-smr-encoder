# -*- coding: utf-8 -*-
"""合并约束生成器：constr/enc_top_disp.xdc

为什么用脚本生成而不是手写：
  · 合并工程有 90+ 个 PACKAGE_PIN，手抄一遍必然出错，而且将来改一处就要改两处；
  · 三个来源文件（constr/enc_top.xdc、constr/enc_top_eth.xdc 与
    lcd_test2/constr/lcd_test2.xdc）都是 **已签核**的约束，本脚本只做"并集 + 去重"，
    不改任何一个数值 —— 合并实验不该顺带改别人的约束。
  · 输出一律 ASCII（见 docs/DEV_STATUS.md §1.7：Tcl/Vivado 按系统代码页读，
    中文注释会在非 UTF-8 代码页下被吃坏）。

产出：constr/enc_top_disp.xdc（覆盖写入）

===============================================================================
 修订记录（本脚本第 2 版；第 1 版的三个真缺陷，全部由自检抓出）
===============================================================================
 [D1] **属性被拆成单个字母**：第 1 版里 `list(extra)` 把字符串
      `"SLEW SLOW DRIVE 8"` 变成了 13 个**字符**的列表，再 `" ".join(...)`
      输出成 `S L E W   S L O W   D R I V E   8`。Vivado 会把它当成
      三个非法属性名，轻则报错、重则**静默丢掉 slew/drive 约束**。
      第 1 版的产物里 30 行都带这个毛病。
      修法：属性按 **token 列表**处理，绝不把字符串交给 `list()`。
      自检：任何 `-dict {…}` 里出现"单字母词"即报错。
 [D2] **全局语句重复**：`create_clock` / `CFGBVS` / `CONFIG_VOLTAGE` /
      `BITSTREAM.GENERAL.COMPRESS` 在两个源文件里各有一份，第 1 版原样拼在一起
      ⇒ 同一个端口上定义了两次 sys_clk，Vivado 直接报错。
      修法：非引脚语句按"归一化文本"去重，且全局语句只从 enc 侧取。
 [D3] **引用了合并顶层不存在的端口**：第 1 版把 lcd_test2.xdc 里的
      `touch_scl/sda/rst_n/int` 四条引脚约束与八条时序约束都抄了进来，
      而 `disp/enc_top_disp.v` **没有** touch 端口 ⇒
      `set_property PACKAGE_PIN … [get_ports touch_scl]` 匹配不到任何对象，
      Vivado 报 "no objects matched"。
      修法：合法端口集合**从 RTL 解析**，不在集合里的端口其语句一律丢弃并记录。
      为什么本阶段不做 touch：见本文件下方 TOUCH POLICY。

  [D5] **层次敏感约束被原样抄入，指向了不存在的对象**（2026-10-15 由合并综合日志抓出）
===============================================================================
  症状（真日志，_disp_work/synth_disp.log）：
      WARNING:  [Vivado 12-508]  No pins matched 'u_ad_clk_oddr/C'.
      CRITICAL: [Vivado 12-4739] create_generated_clock: No valid object(s) found
                for '-source [get_pins u_ad_clk_oddr/C]'. [constr/enc_top_disp.xdc:145]
      WARNING:  [Vivado 12-646]  clock 'adc_clk' not found.
      CRITICAL: [Vivado 12-4739] set_output_delay: No valid object(s) found for
                '-clock adc_clk'. [constr/enc_top_disp.xdc:149]

  根因：`constr/enc_top.xdc` 是给**单层**顶层 enc_top 写的，
      `create_generated_clock -source [get_pins u_ad_clk_oddr/C]` 里的
      `u_ad_clk_oddr` 是 enc_top 里的一级子模块实例名。合并顶层之后 enc_top
      被例化成 `u_enc`，真实路径变成 `u_enc/u_ad_clk_oddr/C` ⇒ 这条约束
      匹配不到任何对象。
  危害（为什么这是真缺陷而不是噪声）：`adc_clk` / `adc_clk2` 两个生成时钟
      **根本没有被创建**，于是 4 条 `set_output_delay -clock adc_clk{,2}` 也一并失效
      ⇒ ADC 采样时钟输出路径变成**无约束**。无约束不等于安全，只等于"不被报告"，
      量出来的 WNS 因此失去可比性（这正是本次 −0.120 ns 必须在修好之后重测的原因）。

  修法：把**层次敏感**的对象查询（`get_pins` / `get_cells` / `get_nets`）的每个
      路径 token 加上 `u_enc/` 前缀。三条纪律：
        ① **只对 enc 侧源文件做前缀**：lcd_test2.xdc 里一条层次查询都没有
           （已逐行核对），而它的引脚本来就在合并顶层，不许碰。
        ② **`get_ports` 一律不加前缀**：合并顶层逐个复刻了 enc_top 的全部端口，
           端口名在顶层依然有效，加前缀反而会让它匹配不到。
        ③ 前缀不是"尽力而为"：加完之后仍有**未加前缀**的层次查询就直接报错
           （自检 D5），绝不留下"某条约束悄悄失效"的可能。
      改写逐条打印在生成日志里（HIERARCHY REWRITES 段），可人工复核。

===============================================================================
 TOUCH POLICY（触摸自 2026-10-15 起**已并入**合并实验）
===============================================================================
  历史：本实验第一版主动排除了 touch —— 当时合并顶层没有 touch 端口，
  `[get_ports touch_scl]` 匹配不到对象会直接报错，而触摸状态机对像素路径
  没有贡献，接进来只会让"测 WNS"这件事多背一份无关的复杂度。

  现在已并入，理由变了：**P6 设置页的编辑交互要用触摸**（用户 2026-10-15 选定
  "先做触摸"这条路）。触摸栈（disp/touch_ctrl.v + disp/i2c_master_seq.v +
  disp/i2c_io_wrap.v）自 lcd_test2 原样搬入，仿真里已经读回 5 个触点
  （disp/logs/tb_touch_ctrl.log：type=GT911 num=5 (600,256) (900,400)
   reads=11 nack=0 timeout=0 prod_id=0x39 0x814E=0x05 XMAX/YMAX=1024/600）。

  ⇒ 约束头部不再声明"TOUCH IS EXCLUDED"。`touch_int` 的 `PULLTYPE PULLUP`
    必须保留：GT911 的 INT 是开漏，没有上拉它就永远回不到高电平，
    表现为"能识别芯片、读得到产品 ID，但 0x814E 恒为 0"——正是本板上
    历史遗留的那个现象。lcd_test2.xdc 里那条约束是踩过坑写下的，不能丢。

  仍未并入：屏 ID 三态读取（lcd_rgb[7]/[15]/[23] 在 lcd_rst 低时当输入）。
  那需要 24 根数据线整体换成 IOBUF，属于"正式并入 enc_top"（S2 收口）的工作。
===============================================================================
"""
import io
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_ENC = os.path.join(ROOT, "constr", "enc_top.xdc")
SRC_LCD = os.path.join(ROOT, "lcd_test2", "constr", "lcd_test2.xdc")
# ★ v60：以太网约束整份并入。下面那段"只复制两条 CDC"的历史补丁随之删除。
SRC_ETH = os.path.join(ROOT, "constr", "enc_top_eth.xdc")
SRC_TOP = os.path.join(ROOT, "disp", "enc_top_disp.v")
OUT = os.path.join(ROOT, "constr", "enc_top_disp.xdc")

# 合并顶层 rtl/enc_top_disp.v 里**新增**的探针端口（不在任何既有 xdc 中）
# ★ 不能选 J21/K21 —— 那两根在 enc_top.xdc 里已经给了 led[2]/led[3]（J5-18/19）。
#   本实验要"观测不扰动被测对象"，所以探针**另起 8 根**空闲针，
#   宁可让 led[2]/led[3] 照旧受约束（它们在本设计里本来就没被用到）。
# 全部选 J5 中段的空闲引脚（Bank 15，已被 J9 拨到 3.3V；`_synth_work/j5.py` 已核对）。
# 中段还有个附带好处：Artix-7 的时钟能力引脚（MRCC/SRCC）都在 bank 的两端，
# 中段引脚天然不会和"未来可能想要的时钟输入"抢位置。
PROBE_PINS = [
    ("disp_test[0]", "M15"),   # J5-21
    ("disp_test[1]", "M16"),   # J5-22
    ("disp_test[2]", "L13"),   # J5-23
    ("disp_test[3]", "M13"),   # J5-24
    ("disp_test[4]", "K13"),   # J5-25
    ("disp_test[5]", "K14"),   # J5-26
    ("disp_test[6]", "J19"),   # J5-27
    ("disp_test[7]", "H19"),   # J5-28
]

# 屏侧人机输入：页切换按键（低有效）。
#   ★ 2026-10-15 上板教训：第一版只留了 J5-29 一颗**外接**针，板上并没有按钮，
#     用户自然会去按板载 KEY0(W9) —— 而那根在本设计里是全局异步复位，按了"没反应"。
#     现在补上板载 USER KEY1(Y9)：enc_top.xdc:64 已注明它空闲，可直接拿来当按钮。
#   key1_n 是板上按钮，ui_btn(J5-29) 保留给飞线/外部信号，两者在 RTL 里相与。
UI_PINS = [
    ("key1_n", "Y9"),          # 板载 USER KEY1，按下接地
    ("ui_btn", "H14"),         # J5-29，需外接跳线才有效
]

# 在 enc_top.xdc 与 lcd_test2.xdc 里都被约束的端口：只保留 enc 侧那一份
DUP_PORTS = {"sys_clk", "key_n", "uart_tx"}

# 主动排除的端口（合并顶层不存在）。丢弃时打印，绝不静默吞掉。
#   ★ 2026-10-15：touch_* 四根从本集合里**移除**了 —— 合并顶层现在已经真的
#     例化了触摸控制器（disp/enc_top_disp.v 的 4.5 节），所以 lcd_test2.xdc 里
#     那四条 PACKAGE_PIN 与七条时序语句应当**照原样保留**（其中
#     `PULLTYPE PULLUP` 是 GT911 中断能拉高的前提，删了触摸就永远读不到点）。
#     反过来，只要本文件里再次出现 touch_*，就说明有人把触摸从合并顶层删了，
#     那时这里的端口覆盖自检会立刻报出来（见 D3b）。
EXCLUDED_PORTS = set()

# 全局属性语句：只从 enc 侧取一份，且**必须**恰好出现一次。
#   ★ v60 起 create_clock 不再是"全局唯一"：三个来源各带自己的时钟
#     （sys_clk / eth_rxc_clk），合并后应恰好 2 条，改由 D2b 按数量自检。
GLOBAL_MUST_ONCE = ("CFGBVS", "CONFIG_VOLTAGE", "BITSTREAM.GENERAL.COMPRESS")

# ★ D5：合并顶层里 enc_top 的实例名。源文件的层次查询要统一挂到这个前缀下。
MERGED_PREFIX = "u_enc"

# 层次敏感的对象查询：get_pins / get_cells / get_nets（**不含** get_ports ——
# 合并顶层复刻了 enc_top 的全部端口，端口名在顶层依然有效）。
HIER_RE = re.compile(r"\[get_(?P<kind>pins|cells|nets)\s+(?P<inner>\{[^}]*\}|[^\]]+?)\s*\]")

PIN_RE = re.compile(
    r"^set_property\s+-dict\s+\{(?P<dict>.*?)\}\s*\[get_ports\s+(?P<port>.+?)\]\s*(?:;?#.*)?$")

# 端口引用出现在这些形态里：`[get_ports foo]`、`[get_ports {a b c[*]}]`
# ★ 必须允许 `{…}` 内部出现 `[`（`lcd_rgb[*]`）：第 2 版第一稿写成 `[^\}\]\[]+?`
#   就匹配不到 `{lcd_rgb[*]}`，会让 `rewrite_ports` 静默漏掉这类语句。
GET_PORTS_RE = re.compile(r"\[get_ports\s+(?P<inner>\{[^}]*\}|[^\]]+?)\s*\]")

# 单个端口 token：name 或 name[i] 或 name[*]
PORT_TOK_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[(\d+|\*)\])?$")

# 端口声明里的关键字，不能当端口名
DECL_KEYWORDS = {"input", "output", "inout", "wire", "reg", "signed", "unsigned"}


def read_text(path):
    with io.open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# 1. 从 RTL 解析合并顶层的合法端口集合
# ---------------------------------------------------------------------------
def parse_top_ports(path):
    """返回 {base_name: width}。width 来自 `[n:0]` 声明。

    ★ 必须先按逗号切分再逐段解析：合并顶层的端口表里存在
      `output wire a_out, b_out, z_out,` 这种**一条声明多个端口**的写法，
      用"匹配 input|output 开头的整行"的朴素正则只会抓到 a_out，
      剩下两个会让后面的"端口覆盖自检"和"未知端口自检"同时误报。
    """
    text = read_text(path)
    m = re.search(r"module\s+enc_top_disp\s*\((.*?)\)\s*;", text, re.S)
    if not m:
        raise SystemExit("cannot find port list of module enc_top_disp in " + path)
    # 先把行注释整段删掉：注释里可能带逗号，先删再按逗号切才安全
    body = re.sub(r"//[^\n]*", "", m.group(1))

    ports = {}
    last_width = 1
    for frag in body.split(","):
        if not frag.strip():
            continue
        dm = re.match(r"\s*(?:input|output|inout)\b", frag)
        rest = frag
        if dm:
            rest = frag[dm.end():]
        wm = re.search(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", rest)
        if wm:
            last_width = int(wm.group(1)) + 1
        # 名字 = 去掉位宽方括号后剩下的最后一个标识符
        names = [n for n in re.findall(r"[A-Za-z_][A-Za-z0-9_]*",
                                      re.sub(r"\[[^\]]*\]", " ", rest))
                 if n not in DECL_KEYWORDS]
        if not names:
            continue
        ports[names[-1]] = last_width
    if not ports:
        raise SystemExit("no ports parsed from " + path)
    return ports


# ---------------------------------------------------------------------------
# 2. 源文件解析
# ---------------------------------------------------------------------------
def strip_inline_comment(line):
    """去掉 `;# …` 之后的 Tcl 行内注释（本工程一律用 `;#` 起头）。"""
    idx = line.find(";#")
    return line[:idx].rstrip() if idx >= 0 else line.rstrip()


def norm_key(line):
    """归一化：去注释、去花括号、压空白。用于语义去重。

    ★ 花括号要替换成**空串**再压空白，不能替换成空格：
      `[get_ports {key_n}]` → `[get_ports key_n ]`（多一个空格）与
      `[get_ports key_n]` 就不相等了，于是 `set_false_path -from … key_n`
      在两个源文件里各留一份 —— 这正是第 2 版第一稿漏掉的那条重复。
      所以这里还要额外把 `[`/`]` 两侧的空白压掉。
    """
    s = strip_inline_comment(line)
    s = s.replace("{", "").replace("}", "")
    s = re.sub(r"\s*\[\s*", " [", s)
    s = re.sub(r"\s*\]", "]", s)
    s = re.sub(r"\s*,\s*", ",", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def ports_in_stmt(line):
    """语句里引用到的全部端口 token（去掉 [i] / [*] 后返回基础名集合）。"""
    out = set()
    for gm in GET_PORTS_RE.finditer(line):
        for tok in gm.group("inner").strip("{}").split():
            tok = tok.strip()
            if not PORT_TOK_RE.match(tok):
                continue
            out.add(tok.split("[")[0])
    return out


def rewrite_ports(line, drop):
    """把语句里被排除的端口 token 删掉。

    返回值为 \x00EMPTY\x00 占位表示"这条语句引用的端口全被排除，整条丢弃"。
    """
    def fix(gm):
        inner = gm.group("inner")
        braced = inner.startswith("{")
        toks = [t for t in inner.strip("{}").split() if t.split("[")[0] not in drop]
        if not toks:
            return "\x00EMPTY\x00"
        joined = " ".join(toks)
        return "[get_ports {%s}]" % joined if braced else "[get_ports %s]" % joined

    return GET_PORTS_RE.sub(fix, line)


def prefix_hier(line, prefix):
    """[D5] 把 get_pins / get_cells / get_nets 的路径 token 挂到 `prefix/` 下。

    返回 (新行, [(kind, 原文, 新文), …])。已经带前缀的 token 原样保留（幂等），
    这样重复运行生成器不会写出 `u_enc/u_enc/…`。

    ★ 为什么不能只做字符串 replace("u_ad_clk_oddr", "u_enc/u_ad_clk_oddr")：
      那样只会修好"刚好想到的那两个名字"。这里改成按**语法形态**改写，将来
      enc_top.xdc 里再加任何 `get_pins ` 都会被自动带上，且自检 D5 会把
      "漏网的"直接判死。
    """
    changes = []

    def fix(gm):
        kind = gm.group("kind")
        inner = gm.group("inner")
        braced = inner.startswith("{")
        new_toks = []
        for tok in inner.strip("{}").split():
            if tok.startswith(prefix + "/"):
                new_toks.append(tok)
                continue
            path = "%s/%s" % (prefix, tok)
            changes.append((kind, tok, path))
            new_toks.append(path)
        joined = " ".join(new_toks)
        return "[get_%s {%s}]" % (kind, joined) if braced else "[get_%s %s]" % (kind, joined)

    return HIER_RE.sub(fix, line), changes


def collect(path, top_ports, drop_ports):
    """返回 (pin_lines, other_lines, stats)。"""
    pin_lines, other_lines = [], []
    stat = {"pin": 0, "pin_dropped": 0, "other": 0, "other_dropped": 0,
            "dropped_ports": []}
    lines = read_text(path).splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        st = raw.strip()
        i += 1
        if not st or st.startswith("#"):
            continue

        # 多行语句（行尾反斜杠续行）：并成一条，保持原样输出
        buf = [raw]
        while buf[-1].rstrip().endswith("\\") and i < len(lines):
            buf.append(lines[i])
            i += 1
        stmt = "\n".join(buf)

        # --- 引脚约束 ---
        if st.startswith("set_property -dict") and "PACKAGE_PIN" in st:
            m = PIN_RE.match(st)
            if not m:
                raise SystemExit("PIN line format unrecognized, fix by hand: " + st)
            d = m.group("dict")
            toks = d.split()
            if toks[0] != "PACKAGE_PIN" or len(toks) < 4 or toks[2] != "IOSTANDARD":
                raise SystemExit("unexpected pin dict: " + d)
            ball, io, extra = toks[1], toks[3], toks[4:]
            prt = m.group("port").strip()
            base = prt.strip("{}").split("[")[0]
            if base in drop_ports:
                stat["pin_dropped"] += 1
                stat["dropped_ports"].append(prt.strip("{}"))
                continue
            if base not in top_ports:
                raise SystemExit(
                    "MERGED XDC WOULD REFERENCE A PORT THAT DOES NOT EXIST: %s" % prt)
            stat["pin"] += 1
            pin_lines.append((prt, ball, io, extra))
            continue

        # --- 其它语句 ---
        new = rewrite_ports(stmt, drop_ports)
        if "\x00EMPTY\x00" in new:
            stat["other_dropped"] += 1
            stat["dropped_ports"].append(norm_key(stmt))
            continue
        # 丢掉"引用到的端口全被排除"之外的另一种情况：语句含被排除端口与保留端口混用
        for base in ports_in_stmt(stmt) & drop_ports:
            stat["dropped_ports"].append("%s (from %s)" % (base, norm_key(stmt)))
        stat["other"] += 1
        other_lines.append(new)
    return pin_lines, other_lines, stat


# ---------------------------------------------------------------------------
# 3. 主流程
# ---------------------------------------------------------------------------
def main():
    top_ports = parse_top_ports(SRC_TOP)
    print("merged top ports: %d  %s" % (len(top_ports), " ".join(sorted(top_ports))))

    enc_pins, enc_other, enc_stat = collect(SRC_ENC, top_ports, EXCLUDED_PORTS)
    lcd_pins, lcd_other, lcd_stat = collect(SRC_LCD, top_ports, EXCLUDED_PORTS)
    eth_pins, eth_other, eth_stat = collect(SRC_ETH, top_ports, EXCLUDED_PORTS)

    # 0) ★ [D5] 给 enc 侧与 eth 侧的层次查询挂上前缀 u_enc/
    #    为什么只做这两份：lcd_test2.xdc 里没有任何 get_pins/get_cells/get_nets
    #    （已逐行核对），而它的引脚本来就在合并顶层，加前缀会让它匹配不到。
    #    eth 侧反过来：enc_top_eth.xdc 是给单层 enc_top 写的，里面的
    #    `get_pins u_eth/u_rgmii/u_oddr_clk/C` 在合并后必须变成
    #    `u_enc/u_eth/…`，否则生成时钟 eth_txc_out 建不起来、TX 输出延时失效。
    #    为什么必须在去重之前做：去重比的是归一化文本，先改写再比才能保证
    #    "改写后仍相同的两条"被正确合并。
    hier_changes = []
    enc_other_prefixed = []
    for ln in enc_other:
        new_ln, ch = prefix_hier(ln, MERGED_PREFIX)
        hier_changes.extend(ch)
        enc_other_prefixed.append(new_ln)
    eth_other_prefixed = []
    for ln in eth_other:
        new_ln, ch = prefix_hier(ln, MERGED_PREFIX)
        hier_changes.extend(ch)
        eth_other_prefixed.append(new_ln)

    # 1) sys_clk / key_n / uart_tx 在两边都有：lcd 那份丢掉
    keep_lcd, dropped_dup = [], []
    for p in lcd_pins:
        base = p[0].strip("{}").split("[")[0]
        if base in DUP_PORTS:
            dropped_dup.append(p[0].strip("{}"))
        else:
            keep_lcd.append(p)

    # 2) 非引脚语句语义去重（先 enc，再 eth，最后 lcd）+ 全局语句只留一份
    seen = set()
    merged_other = []
    for ln in enc_other_prefixed + eth_other_prefixed + lcd_other:
        k = norm_key(ln)
        if k in seen:
            continue
        seen.add(k)
        merged_other.append(ln)

    # 3) 去重自检：任何 FPGA 球号不得出现两次
    seen_ball = {}
    for prt, ball, _io, _ex in (enc_pins + eth_pins + keep_lcd
                                + [(p, b, "LVCMOS33", []) for p, b in PROBE_PINS]
                                + [(p, b, "LVCMOS33", []) for p, b in UI_PINS]):
        if ball in seen_ball:
            raise SystemExit("ball conflict on %s: %s vs %s" % (ball, seen_ball[ball], prt))
        seen_ball[ball] = prt

    # 4) 自检 D1：属性 token 里不得出现"单字母词"
    def check_dict_tokens(parts, where):
        for t in parts:
            if len(t) == 1 and t.isalpha():
                raise SystemExit(
                    "[D1] single-letter attribute token %r in %s -- "
                    "a string was passed to list() again" % (t, where))

    # 5) 自检 D2：全局语句恰好各一份
    glob_text = norm_key("\n".join(merged_other))
    for g in GLOBAL_MUST_ONCE:
        n = glob_text.count(g)
        if n != 1:
            raise SystemExit("[D2] %s appears %d times, expected exactly 1" % (g, n))

    # 5b) 自检 D2b：时钟恰好两条 —— sys_clk（enc 侧）与 eth_rxc_clk（eth 侧）。
    #     少一条 = 某个域变成无约束；多一条 = 两个来源重复定义同一个端口。
    n_clk = sum(1 for ln in merged_other if ln.strip().startswith("create_clock"))
    if n_clk != 2:
        raise SystemExit("[D2b] create_clock appears %d times, expected exactly 2 "
                         "(sys_clk + eth_rxc_clk)" % n_clk)

    # 6) 自检 D3b：端口覆盖 —— 顶层每个端口都必须有 PACKAGE_PIN
    covered = set()
    for prt, _b, _io, _ex in enc_pins + eth_pins + keep_lcd:
        covered.add(prt.strip("{}").split("[")[0])
    for prt, _b in PROBE_PINS:
        covered.add(prt.split("[")[0])
    for prt, _b in UI_PINS:
        covered.add(prt.split("[")[0])
    missing = sorted(set(top_ports) - covered)
    if missing:
        raise SystemExit("[D3b] no PACKAGE_PIN for top-level port(s): %s" % ", ".join(missing))

    # ---- 输出 ----
    out = []
    w = out.append
    w("# =============================================================================")
    w("#  enc_top_disp.xdc  --  MERGED EXPERIMENT (encoder + 7-inch LCD display engine)")
    w("#  Device: xc7a35tfgg484-2   (ALIENTEK DaVinci Lite)")
    w("#")
    w("#  AUTO-GENERATED by tools/gen_merged_xdc.py (v2) -- do not edit by hand.")
    w("#  Sources: constr/enc_top.xdc + constr/enc_top_eth.xdc +")
    w("#           lcd_test2/constr/lcd_test2.xdc")
    w("#  To change a constraint, edit the source and re-run:")
    w("#      python tools/gen_merged_xdc.py")
    w("#")
    w("#  ONE rule governs this merge: no numeric value from either source is altered.")
    w("#  The experiment measures timing after putting two signed-off designs into one")
    w("#  device; quietly re-budgeting anything would make the number incomparable.")
    w("#")
    w("#  SCOPE: the encoder side is complete. The LCD side carries the pixel")
    w("#  interface (lcd_rgb / pclk / hs / vs / de / bl / rst) AND the capacitive")
    w("#  touch pins (touch_scl T4 / touch_sda U5 / touch_rst_n W4 / touch_int T5).")
    w("#  touch_int keeps PULLTYPE PULLUP -- without it the GT911 interrupt can")
    w("#  never be released high and no touch point is ever reported.")
    w("#  Still OUT of scope: panel-ID tri-state readback (lcd_rgb[7]/[15]/[23] as")
    w("#  inputs while lcd_rst is low). Do not read a healthy WNS here as")
    w("#  'the whole display subsystem fits'.")
    w("#")
    w("#  Port collisions: sys_clk / key_n / uart_tx exist in both sources; only the")
    w("#  enc_top.xdc copy is kept. Dropped lcd_test2 duplicates: %s" % (", ".join(dropped_dup) if dropped_dup else "none"))
    w("#  Bank rails: J5/J6 VCCIO are selected by jumpers J9/J10 -- BOTH must be 3.3V.")
    w("# =============================================================================")
    w("")
    w("# -----------------------------------------------------------------------------")
    w("# A. Encoder-side pins (verbatim from constr/enc_top.xdc)")
    w("#    ad_clk / ad_clk2 are the two ADC sample clocks and MUST be kept separate:")
    w("#    on the module CH1_CLK and CH2_CLK are independent nets.")
    w("# -----------------------------------------------------------------------------")

    def emit_pin(prt, ball, io, extra):
        # ★ extra 必须是 token 列表。第 1 版在这里写成 list(extra)（extra 是字符串），
        #   结果把 "SLEW" 输出成 "S L E W"。见文件头 [D1]。
        check_dict_tokens(extra, "pin " + prt)
        parts = ["PACKAGE_PIN %-4s" % ball, "IOSTANDARD %s" % io] + extra
        w("set_property -dict {%s} [get_ports %s]" % (" ".join(parts), prt))

    for prt, ball, io, extra in enc_pins:
        emit_pin(prt, ball, io, extra)
    w("")
    w("# -----------------------------------------------------------------------------")
    w("# A2. Ethernet-side pins (verbatim from constr/enc_top_eth.xdc)")
    w("#     RGMII: 4-bit TX/RX DDR at 125 MHz. eth_rxc is the PHY-supplied RX clock")
    w("#     and the reference for the RX input-delay budget; eth_txc is forwarded")
    w("#     by an ODDR inside u_enc/u_eth/u_rgmii (see the timing section).")
    w("#     v59 built these pins nowhere (the merged top had no eth ports at all),")
    w("#     so a working link could not exist no matter how the PHY straps were set.")
    w("# -----------------------------------------------------------------------------")
    for prt, ball, io, extra in eth_pins:
        emit_pin(prt, ball, io, extra)
    w("")
    w("# -----------------------------------------------------------------------------")
    w("# B. LCD-side pins (from lcd_test2/constr/lcd_test2.xdc, minus %s)" % ", ".join(dropped_dup))
    w("#    The tri-state screen-ID read (lcd_rgb[7]/[15]/[23] driven as inputs while")
    w("#    lcd_rst is low) needs an IOBUF per data line and is NOT wired up in this")
    w("#    experiment: disp_engine drives all 24 lines as pure outputs. The pins and")
    w("#    the output-delay budget are still the signed-off ones, so the pixel-path")
    w("#    timing measured here is the right thing to compare against the encoder.")
    w("# -----------------------------------------------------------------------------")
    for prt, ball, io, extra in keep_lcd:
        emit_pin(prt, ball, io, extra)
    w("")
    w("# -----------------------------------------------------------------------------")
    w("# C. Experiment probe: 8 free J5 pins (bank 15, not used by any on-board device)")
    w("# -----------------------------------------------------------------------------")
    w("#    Acceptance: disp_test[7:0] must increment once per frame (58.6 times/s).")
    w("#    Frozen counter => the timing generator or the renderer has stalled.")
    for prt, ball in PROBE_PINS:
        w("set_property -dict {PACKAGE_PIN %-4s IOSTANDARD LVCMOS33} [get_ports {%s}]" % (ball, prt))
    w("")
    w("# -----------------------------------------------------------------------------")
    w("# D. Timing / configuration (union of all three sources, de-duplicated)")
    w("#    CFGBVS / CONFIG_VOLTAGE / COMPRESS appear in more than one source;")
    w("#    exactly one copy of each survives below. create_clock appears twice")
    w("#    by design: sys_clk (encoder) and eth_rxc_clk (PHY-supplied RX clock).")
    w("# -----------------------------------------------------------------------------")
    for ln in merged_other:
        w(ln)
    w("")
    w("# -----------------------------------------------------------------------------")
    w("# E. Probe output budget (indicator class: sampled by the far end, 17 ns is fine)")
    w("#    Same rationale as the LED/IRQ section of enc_top.xdc: the probe is a FRAME")
    w("#    COUNTER, not position information, so the exact edge instant carries no")
    w("#    meaning and a generous output delay is the honest constraint.")
    w("# -----------------------------------------------------------------------------")
    w("set_output_delay -clock sys_clk -max 3.000 [get_ports {disp_test[*]}]")
    w("set_output_delay -clock sys_clk -min 0.500 [get_ports {disp_test[*]}]")
    w("set_property SLEW SLOW [get_ports {disp_test[*]}]")
    w("set_property DRIVE 4   [get_ports {disp_test[*]}]")
    w("")
    w("# -----------------------------------------------------------------------------")
    w("# F. Page-switch button (input): on-board USER KEY1 + 1 free J5 pin, active low")
    w("# -----------------------------------------------------------------------------")
    w("#    Acceptance: pressing it flips the page (P1 <-> P6 <-> P8).")
    w("#    key1_n is the ON-BOARD USER KEY1 (Y9) -- the one the operator can press")
    w("#    without a jumper wire. ui_btn (J5-29) is kept in parallel for an external")
    w("#    signal; the RTL ANDs the two (both are 'press to GND', both pulled up).")
    w("#    NOTE: key_n (W9 = USER KEY0) is the global ASYNC RESET in this design,")
    w("#    NOT a page button -- pressing it just re-initialises the whole design.")
    w("#    Pull-up is mandatory: the button only shorts the pin to GND, so without it")
    w("#    the level floats and the debounce counter sees random edges.")
    w("#    No input delay: the edge instant carries no meaning after the 20 ms")
    w("#    debounce, exactly like key_n in enc_top.xdc.")
    for prt, ball in UI_PINS:
        w("set_property -dict {PACKAGE_PIN %-4s IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports {%s}]"
          % (ball, prt))
    w("set_false_path -from [get_ports {%s}]" % " ".join(p for p, _b in UI_PINS))
    w("")

    # 输出一律 ASCII + LF。
    # ★ 为什么必须 ASCII：docs/DEV_STATUS.md §1.7 记录过这个坑 —— Tcl/Vivado 按系统
    #   代码页读文件，本机是 GBK/cp936，UTF-8 中文注释会被吃成一个乱字节，
    #   极端情况下会把后面的引号也吞掉。既有 enc_top.xdc / lcd_test2.xdc 里
    #   的中文注释是"碰巧没踩到"，**新文件不再赌这个运气**。
    #   ★ 顺带把"只剩标点"的行内注释整段去掉：`;# 两级同步 + 去抖` 的中文被清成
    #   空格后只剩一个孤零零的 `+`，虽然无害但会让人以为约束被写坏了。
    def ascii_only(line):
        s = "".join(ch if ord(ch) < 128 else " " for ch in line)
        if ";" in s:
            head, sep, tail = s.partition(";#")
            if sep and not re.search(r"[A-Za-z0-9]", tail):
                s = head.rstrip()
        return s.rstrip()

    data = "\n".join(ascii_only(x) for x in out) + "\n"
    bad = [(i + 1, ch) for i, ch in enumerate(data) if ord(ch) >= 128]
    if bad:
        raise SystemExit("non-ASCII survived cleaning at %r" % (bad[:5],))

    # 7) 自检 D4：产出的**约束语句**里不得出现语义重复。
    #    这条检查是"事后兜底"：D2 只盯四个已知全局语句，而重复可能出现在
    #    任何一条（第 2 版就漏过 `set_false_path -from [get_ports key_n]`）。
    #    比对的是归一化后的语句，注释与花括号都不参与。
    dup_check = {}
    for ln in data.splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        k = norm_key(s)
        dup_check.setdefault(k, []).append(ln)
    dups = {k: v for k, v in dup_check.items() if len(v) > 1}
    if dups:
        msg = "; ".join("%r x%d" % (k, len(v)) for k, v in list(dups.items())[:5])
        raise SystemExit("[D4] duplicate constraint statement(s) in output: " + msg)

    # 8) ★ 自检 D5：产出里不允许存在**未挂前缀**的层次查询。
    #    这条是本次真正抓到缺陷的那一条：D1~D4 全都只看"语句有没有重复/属性有没有
    #    写坏"，没有一条会发现"语句语法完全合法、但对象在合并后的层次里根本不存在"。
    #    Vivado 对这种情况只给 WARNING + CRITICAL WARNING，synth 仍然"成功"，
    #    于是一个失效的时钟约束会静悄悄地把 WNS 变成一个不可比的数字。
    leftover = []
    for ln in data.splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        for gm in HIER_RE.finditer(s):
            for tok in gm.group("inner").strip("{}").split():
                if not tok.startswith(MERGED_PREFIX + "/"):
                    leftover.append((gm.group("kind"), tok, s[:70]))
    if leftover:
        msg = "; ".join("get_%s %s (%s)" % t for t in leftover[:5])
        raise SystemExit("[D5] hierarchy query without '%s/' prefix in output: %s"
                         % (MERGED_PREFIX, msg))

    # 9) ★ 自检 D6：LCD 数据线的**球序**必须与厂商 IO 分配表一致。
    #    这条抓的是"语法全对、编译通过、屏也亮，只是红蓝对调"的缺陷 ——
    #    D1~D5 没有一条能看见它：引脚不冲突、端口覆盖完整、语句不重复。
    #    2026-10-15 实地踩到：本生成器的上游 lcd_test2.xdc 早先按 J7 针号的
    #    自然顺序（R,G,B）把球依次写进 lcd_rgb[0..23]，于是 lcd_rgb[0]=V9
    #    （=LCD_R0）而 lcd_rgb[16]=V5（=LCD_B0），红蓝两个字节整体对调。
    #    上板症状是状态栏/导航高亮这类蓝、浅蓝元素变成橙、米色，而布局、文字、
    #    同步全部正常，极容易被当成"配色问题"而不是"接线问题"。
    #    真值来源：厂商《达芬奇Lite开发板IO引脚分配表》Sheet1，与
    #    docs/ATK_board_digest.md:438 是同一张球表（注明"蓝/绿/红 各 8 位"）。
    VENDOR_LCD_BALLS = (
        "V5 AB1 AA4 AA1 Y3 Y1 Y4 W1 "      # [7:0]   B0..B7  （蓝）
        "W7 Y7 V7 AB5 Y6 AB3 AA3 U6 "      # [15:8]  G0..G7  （绿）
        "V9 AB8 V8 AB7 AA8 AB6 Y8 AA6"     # [23:16] R0..R7  （红）
    ).split()
    got_rgb = {}
    for m in re.finditer(r"PACKAGE_PIN\s+(\S+)\s+IOSTANDARD\s+LVCMOS33[^\n]*"
                         r"\[get_ports\s+\{lcd_rgb\[(\d+)\]\}\]", data):
        got_rgb[int(m.group(2))] = m.group(1)
    if len(got_rgb) != 24:
        raise SystemExit("[D6] expected 24 constrained lcd_rgb pins, found %d"
                         % len(got_rgb))
    bad_rgb = [(i, got_rgb[i], VENDOR_LCD_BALLS[i]) for i in range(24)
               if got_rgb[i] != VENDOR_LCD_BALLS[i]]
    if bad_rgb:
        msg = "; ".join("lcd_rgb[%d]=%s (vendor %s)" % t for t in bad_rgb[:6])
        raise SystemExit("[D6] LCD data ball order does not match the vendor table "
                         "(R/B bytes swapped?): " + msg)

    # ---- (removed) 125M <-> sys_clk CDC hand-copy -------------------------
    # v59 之前合并顶层没有 eth 端口，constr/enc_top_eth.xdc 读不进来（引脚与
    # create_clock 在合并顶层找不到对象），只能把两条 set_max_delay 手抄在此。
    # v60 起该文件整份合并（见 A2 段与 D 段），手抄副本删除 —— 留着它就是
    # 第三份来源，数值迟早和源文件不一致，而且 D4 还会把它当重复语句报错。

    with open(OUT, "w", encoding="ascii", newline="\n") as fh:
        fh.write(data)

    print("wrote %s" % OUT)
    print("  enc pins  : %d" % len(enc_pins))
    print("  eth pins  : %d" % len(eth_pins))
    print("  lcd pins  : %d (dropped %d dup)" % (len(keep_lcd), len(dropped_dup)))
    print("  probe     : %d" % len(PROBE_PINS))
    print("  total     : %d balls, 0 conflicts" % len(seen_ball))
    print("  other stmt: %d (enc %d + eth %d + lcd %d, after de-dup)" % (
        len(merged_other), enc_stat["other"], eth_stat["other"], lcd_stat["other"]))
    all_dropped = sorted(set(enc_stat["dropped_ports"] + eth_stat["dropped_ports"]
                             + lcd_stat["dropped_ports"]))
    if all_dropped:
        print("  DROPPED for excluded ports (%d):" % len(all_dropped))
        for d in all_dropped:
            print("      - %s" % d)
    print("  HIERARCHY REWRITES (D5, prefix '%s/'): %d" % (MERGED_PREFIX, len(hier_changes)))
    for kind, old, new in hier_changes:
        print("      get_%-5s %-24s -> %s" % (kind, old, new))
    print("  self-checks: D1 token / D2 globals-once / D2b clock-count(2) / D3 ball-conflict / "
          "D3b port-coverage / D4 no-dup / D5 hier-prefix / D6 lcd-ball-order : all PASS")


if __name__ == "__main__":
    main()
