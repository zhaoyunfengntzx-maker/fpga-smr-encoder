import re, io
p = "_synth_work_v70/rtl_v70/pole_counter.v"
t = open(p, encoding="utf-8").read()
assert "wire wrap_p_raw = acc_pos;" in t
t = t.replace("wire wrap_p_raw = acc_pos;", "wire wrap_p_raw = pair_valid;   // DEBUG bisect: every valid sample counts")
t = t.replace("wire wrap_n_raw = acc_neg;", "wire wrap_n_raw = 1'b0;         // DEBUG")
open(p, "w", encoding="utf-8", newline="\n").write(t)

p2 = "_synth_work_v70/rtl_v70/enc_top.v"
t2 = open(p2, encoding="utf-8").read()
assert "16'h0012" in t2
t2 = t2.replace("16'h0012", "16'h0013")
open(p2, "w", encoding="utf-8", newline="\n").write(t2)
print("patched debug variant -> BUILD 0x0013")
