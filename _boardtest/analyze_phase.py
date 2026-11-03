import sys
import numpy as np
import pandas as pd

path = sys.argv[1] if len(sys.argv) > 1 else r"_boardtest/cor_v68.csv"
d = pd.read_csv(path)
s = d.s.values.astype(float)
c = d.c.values.astype(float)
s -= s.mean()
c -= c.mean()
vs = np.mean(s * s)
vc = np.mean(c * c)
cov = np.mean(s * c)
print("std_s %.0f std_c %.0f cov %.0f corr %.4f" % (np.sqrt(vs), np.sqrt(vc), cov, cov / np.sqrt(vs * vc)))
print("cos(phi)=cov/sqrt(vs*vc)=%.4f -> phi=%.2f deg" % (cov / np.sqrt(vs * vc), np.degrees(np.arccos(np.clip(cov / np.sqrt(vs * vc), -1, 1)))))
r = np.hypot(d.s.values, d.c.values)
print("r pct 1/5/50/95/99:", np.percentile(r, [1, 5, 50, 95, 99]).round(0))
print("r std %.0f mean %.0f" % (r.std(), r.mean()))
# zero-crossing rate of s
z = np.sum(np.diff(np.signbit(s)) != 0)
print("s zero crossings", z, "in", len(s), "samples")
