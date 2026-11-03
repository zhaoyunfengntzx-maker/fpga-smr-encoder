import sys
import numpy as np
import pandas as pd

path = sys.argv[1]
fs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.125e6
d = pd.read_csv(path)
s = d.s.values.astype(float)
c = d.c.values.astype(float)
# largest contiguous nonzero run
mask = ~((s == 0) & (c == 0))
runs = []
start = None
for i, m in enumerate(mask):
    if m and start is None:
        start = i
    elif not m and start is not None:
        runs.append((start, i))
        start = None
if start is not None:
    runs.append((start, len(mask)))
a, b = max(runs, key=lambda t: t[1] - t[0])
print("run", a, b, "n", b - a)
x = s[a:b] - s[a:b].mean()
w = np.hanning(len(x))
X = np.fft.rfft(x * w)
f = np.fft.rfftfreq(len(x), 1 / fs)
k = np.argmax(np.abs(X))
print("dominant %.1f Hz  bin %.1f Hz  n=%d" % (f[k], fs / len(x), len(x)))
print("top5", [(round(f[i], 1), round(abs(X[i]), 0)) for i in np.argsort(np.abs(X))[-5:][::-1]])
