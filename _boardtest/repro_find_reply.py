import sys
sys.path.insert(0, 'tools')
import uart_spi as sp

pre = b"\x00" * 10 + b"\xAA\x55"
rep = sp.build_reply(0x00, 0x11, 0x22, 0x33)
buf = pre + rep + b"\xAA\x55" + b"\x00" * 15
print("len", len(buf), "reply at", len(pre))
print("found:", sp.find_reply(buf, 0))
