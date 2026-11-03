import serial, time, statistics, collections, struct, sys
PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
s=serial.Serial(PORT,2000000,timeout=0.1)
buf=bytearray(); t0=time.time()
while time.time()-t0<DUR: buf+=s.read(8192)
s.close()
frames=[]; i=0
while i+18<=len(buf):
    if buf[i]==0xAA and buf[i+1]==0x55:
        chk=0
        for b in buf[i:i+18]: chk^=b
        if chk==0:
            f=buf[i:i+18]
            frames.append((struct.unpack(">H",f[2:4])[0], struct.unpack(">I",f[12:16])[0], f[8], f[10]))
            i+=18; continue
    i+=1
dt=DUR; fps=len(frames)/dt
w=[]
for k in range(1,len(frames)):
    d=frames[k][1]-frames[k-1][1]
    w.append(((d+(1<<26))%(1<<27))-(1<<26))
small=[x for x in w if abs(x)<(1<<20)]
med=statistics.median(small); mean=statistics.mean(small)
print("frames=%d fps=%.0f" % (len(frames), fps))
print("step median=%.1f mean=%.1f n_small=%d/%d" % (med, mean, len(small), len(w)))
print("rate(mean)=%.0f cycles/s   rpm(2048)=%.1f" % (mean*fps/65536.0, mean*fps/65536.0/2048*60))
hi=[(f[1]>>16) for f in frames]
sc=[(h-65536 if h>32767 else h) for h in hi]
print("cnt signed min=%d max=%d distinct=%d" % (min(sc), max(sc), len(set(sc))))
zc=sum(1 for k in range(1,len(sc)) if (sc[k-1]>=-2 and sc[k]<-2) or (sc[k-1]<=2 and sc[k]>2))
print("rev(Z) events in %.1fs = %.2f Hz" % (dt, zc/dt))
st=collections.Counter((f[2]>>3)&7 for f in frames)
print("UVW states", dict(sorted(st.items())))
tr=sum(1 for k in range(1,len(frames)) if ((frames[k][2]>>3)&7)!=((frames[k-1][2]>>3)&7))
print("UVW transitions/s %.0f" % (tr/dt))
fl=collections.Counter(f[3] for f in frames)
print("flags", dict(fl))
