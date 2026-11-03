# -*- coding: utf-8 -*-
"""v78 P4 scope: 触发前先要求"已量到一个完整周期"，否则上电第一帧会用
   '复位到第一个 A 沿之间的 clk 数' 当周期，窗口长度是错的。"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

old = """    wire a_absent = &acnt;                        // 1.3 ms 内没有 A 上升沿
    wire trig_a   = a_rise & ~a_absent;
    wire trig_x   = e_wrap &  a_absent;

    reg [24:0] cd;
    reg        cd_done;                           // 0 = 冷却中，1 = 可以开始下一次采集
    wire trig = (trig_a | trig_x) & cd_done;
"""

new = """    wire a_absent = &acnt;                        // 1.3 ms 内没有 A 上升沿
    wire trig_a   = a_rise & ~a_absent;
    wire trig_x   = e_wrap &  a_absent;

    //   ★ 上电第一帧不能用：复位后第一个 A 上升沿的 acnt 是"复位到该沿的 clk 数"，
    //     不是 A 周期（可能只有几个 clk），拿它定窗口会让第一帧的时基完全错。
    //     ⇒ 要量到**一个完整周期**之后才允许触发（aclk/eclk 那时才是真周期）。
    //     代价 4 个触发器：第二个 A 沿起就可触发，延迟仅 1~2 个 A 周期（µs 级）。
    reg [1:0] an_ok, en_ok;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin an_ok <= 2'd0; en_ok <= 2'd0; end
        else begin
            if (a_rise && !(&an_ok)) an_ok <= an_ok + 2'd1;
            if (e_wrap && !(&en_ok)) en_ok <= en_ok + 2'd1;
        end
    end
    wire ap_ok = (an_ok != 2'd0);
    wire ep_ok = (en_ok != 2'd0);

    reg [24:0] cd;
    reg        cd_done;                           // 0 = 冷却中，1 = 可以开始下一次采集
    wire trig = ((trig_a & ap_ok) | (trig_x & ep_ok)) & cd_done;
"""

assert s.count(old) == 1
s = s.replace(old, new)
io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("trigger gate added, %d chars" % len(s))
