import sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

path = sys.argv[1]
d = pd.read_csv(path)
s = d.s.values.astype(float)
c = d.c.values.astype(float)
fig, ax = plt.subplots(2, 1, figsize=(12, 7), sharex=True)
ax[0].plot(s[:1500], lw=0.8)
ax[0].set_ylabel("s")
ax[1].plot(c[:1500], lw=0.8)
ax[1].set_ylabel("c")
ax[1].set_xlabel("sample")
fig.tight_layout()
out = path.replace(".csv", "_wave.png")
fig.savefig(out, dpi=110)
print(out)
