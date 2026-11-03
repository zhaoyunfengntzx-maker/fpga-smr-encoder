import serial, time, struct
def read_reg(s, addr):
    pass
s = serial.Serial("COM4", 2000000, timeout=0.3)
# 读 build id (0x05F2) / 采样 pos_full 高 16 位
import re
def frames_for(sec):
    buf = bytearray(); t0 = time.time(); out=[]
    while time.time() - t0 < sec:
        buf += s.read(8192)
    i=0
    while i + 18 <= len(buf):
        if buf[i]==0xAA and buf[i+1]==0x55:
            chk=0
            for b in buf[i:i+18]: chk^=b
            if chk==0:
                f=buf[i:i+18]
                out.append((f, struct.unpack(">I", f[12:16])[0]))
                i+=18; continue
        i+=1
    return out
fr = frames_for(1.0)
his = [p>>16 for _,p in fr]
print("frames=%d  hi distinct=%d  hi min=%d max=%d" % (len(fr), len(set(his)), min(his), max(his)))
print("first his:", his[:12])
print("last his:", his[-6:])
s.close()
