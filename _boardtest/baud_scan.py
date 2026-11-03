import serial, time
for baud in (2000000, 115200, 921600, 1000000, 3000000):
    try:
        s = serial.Serial("COM4", baud, timeout=0.05)
        s.reset_input_buffer()
        t0=time.time(); n=0; b=b""
        while time.time()-t0 < 0.8:
            d=s.read(2048)
            if d: n+=len(d); b+=d
        s.close()
        print(f"baud={baud:>8} bytes={n:>6} head={b[:24].hex()}")
    except Exception as e:
        print("baud", baud, "ERR", e)
