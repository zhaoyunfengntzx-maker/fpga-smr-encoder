# -*- coding: utf-8 -*-
"""v78 P4 scope 两处修正：
   ① e_wrap 极性反了（正向过零是 a_q=00 / a_qq=11，不是反过来）—— 于是电周期永远
      量不到（ecnt 一直涨、eclk 恒 0），下区窗口长度被当成 0，整段退化成"每 clk 一点"。
   ② 触发门控差一拍：第 2 个 A 沿时 aclk 里装的还是"复位到第 1 个 A 沿"的数（不是周期），
      要用第 3 个 A 沿（此时 aclk 才是第 1→2 沿的真实周期）。电角度同理。
"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

old1 = """    // 电角度正向过零（跨 0/65536）。只比最高两位：一次真过零必然 11 -> 00，
    // 而 ANG_GLITCH_MAX(1024 LSB) 量级的小毛刺动不了 [15:14]，误触发的可能性
    // 比"整条 16 位比较 + 16 位延迟寄存器"省下来的 LUT 更划算。
    wire e_wrap = (a_q[15:14] == 2'b11) && (a_qq[15:14] == 2'b00);"""
new1 = """    // 电角度正向过零（跨 0/65536）。只比最高两位：一次真过零必然 11 -> 00，
    // 而 ANG_GLITCH_MAX(1024 LSB) 量级的小毛刺动不了 [15:14]，误触发的可能性
    // 比"整条 16 位比较 + 16 位延迟寄存器"省下来的 LUT 更划算。
    // ★ 极性：a_q 是**新**样本、a_qq 是旧样本，所以正向过零后看到的是
    //   a_q = 00 / a_qq = 11（写反了会一次也测不到电周期，下区窗口变 0）。
    wire e_wrap = (a_q[15:14] == 2'b00) && (a_qq[15:14] == 2'b11);"""
assert s.count(old1) == 1
s = s.replace(old1, new1)

old2 = """    //     ⇒ 要量到**一个完整周期**之后才允许触发（aclk/eclk 那时才是真周期）。
    //     代价 4 个触发器：第二个 A 沿起就可触发，延迟仅 1~2 个 A 周期（µs 级）。
    reg [1:0] an_ok, en_ok;"""
new2 = """    //     ⇒ 要量到**一个完整周期**之后才允许触发（aclk/eclk 那时才是真周期）。
    //     数沿的时候还有一拍坑：第 2 个 A 沿这一拍，aclk 里装的还是"复位到第 1 个
    //     A 沿"的数，要到第 3 个 A 沿 aclk 才是第 1→2 沿的真实周期 ⇒ 用 an_ok[1]
    //     （数满 2 个沿）而不是 !=0。代价 4 个触发器，延迟 2 个 A 周期（µs 级）。
    reg [1:0] an_ok, en_ok;"""
assert s.count(old2) == 1
s = s.replace(old2, new2)

old3 = """    wire ap_ok = (an_ok != 2'd0);
    wire ep_ok = (en_ok != 2'd0);"""
new3 = """    wire ap_ok = an_ok[1];                        // 已量到 2 个 A 沿 ⇒ aclk 可信
    wire ep_ok = en_ok[1];                        // 已量到 2 个过零 ⇒ eclk 可信"""
assert s.count(old3) == 1
s = s.replace(old3, new3)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("fixed e_wrap polarity + trigger gate, %d chars" % len(s))
