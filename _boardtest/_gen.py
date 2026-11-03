import re, io
def gen(src, dst, subs, keep_def=None):
    t = open(src, encoding="utf-8-sig").read()
    for a, b in subs:
        assert a in t, (src, a)
        t = t.replace(a, b)
    open(dst, "w", encoding="utf-8", newline="\n").write(t)
    print("wrote", dst, len(t))
gen("tools/impl_check_v69.tcl", "tools/impl_check_v70.tcl",
    [("_impl_v69", "_impl_v70"), ("enc_top_v69", "enc_top_v70"), ("rtl_v69", "rtl_v70"), ("v69", "v70")])
gen("tools/impl_check_disp_v69.tcl", "tools/impl_check_disp_v70.tcl",
    [("_impl_disp_v69", "_impl_disp_v70"), ("enc_top_disp_v69", "enc_top_disp_v70"),
     ("rtl_v69", "rtl_v70"), ("v69", "v70")])
