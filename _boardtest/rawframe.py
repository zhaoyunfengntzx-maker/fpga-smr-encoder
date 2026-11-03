import serial, time, struct
s = serial.Serial("COM4", 2000000, timeout=0.5)
buf = bytearray()
t0 = time.time()
frames = []
while time.time() - t0 < 1.0:
    buf += s.read(4096)
s.close()
i = 0
while i + 18 <= len(buf) and len(frames) < 12:
    if buf[i] == 0xAA and buf[i+1] == 0x55:
        chk = 0
        for b in buf[i:i+18]: chk ^= b
        if chk == 0:
            f = buf[i:i+18]
            ang = struct.unpack(">H", f[2:4])[0]
            s16 = struct.unpack(">h", f[4:6])[0]
            c16 = struct.unpack(">h", f[6:8])[0]
            pos = struct.unpack(">I", f[12:16])[0]
            frames.append((ang, s16, c16, pos, f[8], f[10]))
            i += 18
            continue
    i += 1
for ang, s16, c16, pos, io, fl in frames:
    print("angle=%5d s=%6d c=%6d pos=0x%08X hi=%5d lo=%5d io=0x%02X fl=0x%02X"
          % (ang, s16, c16, pos, pos >> 16, pos & 0xFFFF, io, fl))
