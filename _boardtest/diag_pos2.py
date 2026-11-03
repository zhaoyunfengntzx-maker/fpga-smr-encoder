import serial, time, statistics, collections, struct
s=serial.Serial("COM4",2000000,timeout=0.1)
buf=bytearray(); t0=time.time()
while time.time()-t0<2.5: buf+=s.read(8192)
s.close()
frames=[]; i=0
while i+18<=len(buf):
    if buf[i]==0xAA and buf[i+1]==0x55:
        chk=0
        for b in buf[i:i+18]: chk^=b
        if chk==0:
            f=buf[i:i+18]
            ang=struct.unpack(">H",f[2:4])[0]
            pos=struct.unpack(">I",f[12:16])[0]
            frames.append((ang,pos,f[8],f[9],f[10],f[11],f[16]))
            i+=18; continue
    i+=1
print("frames",len(frames))
for f in frames[:3]: print("ang=%5d pos=0x%08X hi=%5d lo=%5d b8=%02X b9=%02X b10=%02X b11=%02X b16=%02X"%(f[0],f[1],f[1]>>16,f[1]&0xFFFF,f[2],f[3],f[4],f[5],f[6]))
w=[]
for k in range(1,len(frames)):
    d=frames[k][1]-frames[k-1][1]
    w.append(((d+(1<<26))%(1<<27))-(1<<26))
small=[x for x in w if abs(x)<(1<<20)]
print("median step=%%.1f  mean small=%%.1f  n_small=%d/%d" % (statistics.median(small), statistics.mean(small), len(small), len(w)))
fps=len(frames)/2.5
print("fps=%.0f  rate_est=%.0f cycles/s" % (fps, statistics.mean(small)*fps/65536.0))
# wait: mean small * fps/65536 -> cycles/s
hi=[f[1]>>16 for f in frames]
print("cnt min=%d max=%d distinct=%d"%(min(hi),max(hi),len(set(hi))))
st=collections.Counter((f[2]>>3)&7 for f in frames)
print("UVW states",dict(st))
tr=sum(1 for k in range(1,len(frames)) if ((frames[k][2]>>3)&7)!=((frames[k-1][2]>>3)&7))
print("UVW transitions/s %.0f"%(tr/2.5))
