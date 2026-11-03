t = open("tools/impl_check_v70.tcl", encoding="utf-8").read()
t = t.replace("_impl_v70", "_impl_v70b").replace("enc_top_v70", "enc_top_v70b")
open("tools/impl_check_v70b.tcl", "w", encoding="utf-8", newline="\n").write(t)
print("wrote tools/impl_check_v70b.tcl")
