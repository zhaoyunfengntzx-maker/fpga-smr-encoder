# -*- coding: utf-8 -*-
"""v78 P4 scope：触发源改成"电角度过零"，并给 A 相缺席时一个短的兜底窗口。
   理由（这是 TB 抓出来的第二个真问题）：A 的上升沿每个电周期有 inter(=32) 个，
   而帧间隔 500 ms 不是电周期的整数倍 ⇒ "抓下一个 A 沿"每次落在 32 个不同电角度之一，
   下区 U/V/W 的相位会逐帧左右乱跳（z_pos 在 TB 里 59 / 171 两帧就不一样）。
   电角度过零是**唯一**对上下两区都锁相的触发点：下区从 0° 开始，上区也从同一个
   A 相位开始（A 是电角度的函数，0° 处的 A 值恒定）⇒ 画面稳定。
   任务要求里本来就写了"A 相上升沿（或电角度过零）为触发"。"""
import io

P = r"C:\Users\zhaoy\Desktop\FPGA\disp\p4_scope.v"
s = io.open(P, encoding="utf-8", newline="\n").read()

old = """    // =========================================================================
    // 3. 触发与 500 ms 冷却
    //    主触发 = A 相上升沿；AB 关掉（a_out 恒 0，acnt 饱和）时退化到
    //    电角度过零 —— 否则这一页会永远停在"上电全 0"的画面上，连 U/V/W 都不动。
    //    两种触发在信号上是**固定相位差**（A 的上升沿相对电角度零点的相位是
    //    常量），所以不会出现"这一帧左移、下一帧右移"的跳动。
    // =========================================================================
    wire a_absent = &acnt;                        // 1.3 ms 内没有 A 上升沿
    wire trig_a   = a_rise & ~a_absent;
    wire trig_x   = e_wrap &  a_absent;

    //   ★ 上电第一帧不能用：复位后第一个 A 上升沿的 acnt 是"复位到该沿的 clk 数"，
    //     不是 A 周期（可能只有几个 clk），拿它定窗口会让第一帧的时基完全错。
    //     ⇒ 要量到**一个完整周期**之后才允许触发（aclk/eclk 那时才是真周期）。
    //     数沿的时候还有一拍坑：第 2 个 A 沿这一拍，aclk 里装的还是"复位到第 1 个
    //     A 沿"的数，要到第 3 个 A 沿 aclk 才是第 1→2 沿的真实周期 ⇒ 用 an_ok[1]
    //     （数满 2 个沿）而不是 !=0。代价 4 个触发器，延迟 2 个 A 周期（µs 级）。
    reg [1:0] an_ok, en_ok;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin an_ok <= 2'd0; en_ok <= 2'd0; end
        else begin
            if (a_rise && !(&an_ok)) an_ok <= an_ok + 2'd1;
            if (e_wrap && !(&en_ok)) en_ok <= en_ok + 2'd1;
        end
    end
    wire ap_ok = an_ok[1];                        // 已量到 2 个 A 沿 ⇒ aclk 可信
    wire ep_ok = en_ok[1];                        // 已量到 2 个过零 ⇒ eclk 可信

    reg [24:0] cd;
    reg        cd_done;                           // 0 = 冷却中，1 = 可以开始下一次采集
    //   下区窗口长度用 eclk ⇒ 任何触发都必须等 ep_ok；上区用 aclk ⇒ A 触发还要 ap_ok。
    wire trig = ((trig_a & ap_ok) | trig_x) & ep_ok & cd_done;
"""

new = """    // =========================================================================
    // 3. 触发与 500 ms 冷却
    //    触发 = **电角度过零**（angle 从 0xFFFF 附近跨到 0）。
    //    ★ 为什么不用 A 相上升沿：A 每个电周期有 inter（标称 32）个上升沿，而两次
    //      采集之间隔着 500 ms（不是电周期的整数倍）⇒ "抓下一个 A 沿"在 32 个不同
    //      电角度上随机落点，下区 U/V/W 的相位会逐帧左右乱跳（TB 里两帧 z_pos 一个
    //      59、一个 171 就是这个症状），上区虽然自锁 A 相位、下区却稳不住。
    //      电角度过零是唯一对**上下两区都锁相**的触发点：下区从 0° 开始，上区也从
    //      同一个 A 相位开始（A 是电角度的固定函数）⇒ 每帧画面完全一样。
    //      任务要求里写的就是"A 相上升沿（**或电角度过零**）为触发"。
    //    好处之三：不需要 a_absent 判断 —— AB 全关掉时角度照样在转，U/V/W/Z 照样
    //    有波形，页面不会停在"上电全 0"的画面上。
    // =========================================================================
    wire a_absent = &acnt;                        // 1.3 ms 内没有 A 上升沿（A 相缺席）

    //   ★ 上电第一帧不能用：复位后第一个过零的 ecnt 是"复位到该过零的 clk 数"，
    //     不是电周期。⇒ 数满 2 个过零（en_ok[1]）才允许触发，那时 eclk 已是真周期。
    //     代价 2 个触发器，延迟 2 个电周期（<80 µs，用户感觉不到）。
    reg [1:0] en_ok;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) en_ok <= 2'd0;
        else if (e_wrap && !(&en_ok)) en_ok <= en_ok + 2'd1;
    end
    wire ep_ok = en_ok[1];                        // 已量到 2 个过零 ⇒ eclk 可信

    reg [24:0] cd;
    reg        cd_done;                           // 0 = 冷却中，1 = 可以开始下一次采集
    wire trig = e_wrap & ep_ok & cd_done;
"""
assert s.count(old) == 1
s = s.replace(old, new)

# A 相缺席时 win_u 不能是 4×65535（5.24 ms，帧会拖得很长），给个 20 µs 的兜底窗口
old = """                win_u  <= {aclk, 2'b00};           // 4 × A 周期，冻结"""
new = """                //   4 × A 周期；A 缺席（aclk 已饱和到 0xFFFF）时兜底 1024 clk
                //   = 20 µs，否则这一帧要拖 5.24 ms 才结束
                win_u  <= a_absent ? 18'd1024 : {aclk, 2'b00};"""
assert s.count(old) == 1
s = s.replace(old, new)

io.open(P, "w", encoding="utf-8", newline="\n").write(s)
print("trig -> e_wrap, %d chars" % len(s))
