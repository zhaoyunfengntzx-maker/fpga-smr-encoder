import serial, time, statistics, collections
PORT="COM4"
FRAME=18
s=serial.Serial(PORT,2000000,timeout=0.1)
buf=bytearray(); frames=[]
t0=time.time()
while time.time()-t0 < 2.5:
    d=s.read(4096)
    if not d: continue
    buf+=d
    while len(buf)>=FRAME:
        if buf[0]==0xAA and buf[1]==0x55:
            fr=buf[:FRAME]
            x=0
            for b in fr[:17]: x^=b
            if x==fr[17]:
                pos=fr[12]|fr[13]<<8|fr[14]<<16|fr[15]<<24
                ang=fr[2]|fr[3]<<8
                io=fr[8]; fl=fr[9]
                sgn=(fr[6]|fr[7]<<8); cgn=(fr[10]|fr[11]<<8)
                frames.append((t0+len(frames)*0, pos, ang, io, fl, sgn, cgn))
                buf=buf[FRAME:]; continue
        buf=buf[1:]
s.close()
print("frames", len(frames))
if len(frames)>10:
    deltas=[(frames[i][1]-frames[i-1][1]) for i in range(1,len(frames))]
    w=[((d+ (1<<26)) % (1<<27)) - (1<<26) for d in deltas]
    steps=[x for x in w if abs(x)< (1<<20)]
    print("median step LSB = %.1f  (=> %.1f cycles/s if ~10600fps)" % (statistics.median(steps), statistics.median(steps)*10600/65536.0))
    print("small-step share %.3f" % (len(steps)/len(w)))
    # Z edges (io_flags bit2) and UVW states
    zc=sum(1 for i in range(1,len(frames)) if (frames[i][4]&4) and not (frames[i-1][4]&4))
    print("Z rising edges in %.2fs = %.2f Hz" % (2.5, zc/2.5))
    st=collections.Counter((f[3]>>3)&7 for f in frames)
    print("UVW states", dict(st))
    tr=sum(1 for i in range(1,len(frames)) if ((frames[i][3]>>3)&7)!=((frames[i-1][3]>>3)&7))
    print("UVW transitions %.0f/s" % (tr/2.5))
    cnt=collections.Counter((f[1]>>16) for f in frames)
    print("cnt range", min(cnt), max(cnt), "distinct", len(cnt))
