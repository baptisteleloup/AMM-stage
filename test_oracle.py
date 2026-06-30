import numpy as np

def price_curves(s, d, lam_u, lam_o):
    lam_m = 0.5 * (lam_u + lam_o)
    ratio_sd = np.divide(s, d, out=np.zeros_like(s), where=d > 1e-12)
    ratio_ds = np.divide(d, s, out=np.zeros_like(d), where=s > 1e-12)
    c = lam_m + (lam_o - lam_m) * np.maximum(1 - ratio_sd, 0.0)
    r = lam_m - (lam_m - lam_u) * np.maximum(1 - ratio_ds, 0.0)
    return r, c

lam_u, lam_o = 8.86, 21.46
for name, (s, d) in {"I s=d": (100., 100.), "II s>d": (150., 100.), "III d>s": (100., 150.)}.items():
    r, c = price_curves(np.array([s]), np.array([d]), lam_u, lam_o)
    print(f"{name}: s={s} d={d} -> r={r[0]:.5f} c={c[0]:.5f}")