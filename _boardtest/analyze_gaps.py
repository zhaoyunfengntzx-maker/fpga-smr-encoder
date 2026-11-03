import sys
import numpy as np
import pandas as pd

path = sys.argv[1] if len(sys.argv) > 1 else r"_boardtest/cor_v68.csv"
d = pd.read_csv(path)
s = d.s.values.astype(float)
c = d.c.values.astype(float)
r = np.hypot(s, c)
print("n", len(s), "both zero", np.sum((s == 0) & (c == 0)), "r<1000", np.sum(r < 1000), "r<5000", np.sum(r < 5000))
idx = np.where(r < 1000)[0]
print("first low-r indices", idx[:20].tolist())
print("around first low:", [(i, int(s[i]), int(c[i])) for i in idx[:10]])
# print a contiguous chunk of 60 samples at start
print("s chunk", s[:60].astype(int).tolist())
print("c chunk", c[:60].astype(int).tolist())
