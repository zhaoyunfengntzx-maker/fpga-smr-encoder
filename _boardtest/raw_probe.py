import serial, time, sys
p = sys.argv[1] if len(sys.argv)>1 else "COM4"
s = serial.Serial(p, 2000000, timeout=0.2)
s.reset_input_buffer()
t0=time.time(); n=0; buf=b""
while time.time()-t0 < 2.0:
    d = s.read(4096)
    if d: n += len(d); buf += d
print("PORT", p, "READ_BYTES", n, "BPS", n/2.0)
print("HEAD", buf[:64].hex())
idx = buf.find(b"\xaa\x55")
print("AA55_AT", idx)
if idx>=0:
    print("FIRST_FRAME", buf[idx:idx+18].hex())
s.close()
