import io,sys
for f in ["tools/impl_check_v68.tcl","tools/impl_check_v69.tcl","tools/impl_check_v70.tcl","tools/impl_check_disp_v68.tcl","tools/impl_check_disp_v69.tcl","tools/impl_check_disp_v70.tcl"]:
    b=open(f,"rb").read()
    print(f, "bytes=%d"%len(b), "head=", b[:12])
