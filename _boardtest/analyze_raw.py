import sys
import numpy as np
import pandas as pd

path = sys.argv[1] if len(sys.argv) > 1 else r"_boardtest/raw_v68.csv"
d = pd.read_csv(path)
s = d.s.values.astype(float)
c = d.c.values.astype(float)
r = np.hypot(s, c)
print("n", len(s))
print("s min/max/mean/std %.0f %.0f %.0f %.0f" % (s.min(), s.max(), s.mean(), s.std()))
print("c min/max/mean/std %.0f %.0f %.0f %.0f" % (c.min(), c.max(), c.mean(), c.std()))
print("r min/mean/max %.0f %.0f %.0f  (%.3f FS)" % (r.min(), r.mean(), r.max(), r.max() / 32768.0))
print("adjacent |ds| mean/max %.0f %.0f" % (np.abs(np.diff(s)).mean(), np.abs(np.diff(s)).max()))
print("adjacent |dc| mean/max %.0f %.0f" % (np.abs(np.diff(c)).mean(), np.abs(np.diff(c)).max()))
print("clipped |s|>=32700: %d  |c|>=32700: %d" % (np.sum(np.abs(s) >= 32700), np.sum(np.abs(c) >= 32700)))
print("s first", np.round(s[:8]).astype(int).tolist())
print("c first", np.round(c[:8]).astype(int).tolist())
print("r first", np.round(r[:8]).astype(int).tolist())
