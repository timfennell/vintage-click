"""A small synthetic splat scan for the CI smoke test: a chequered floor and a
few coloured spheres, written as a trained 3DGS PLY (degree-0 SH).

    python make_test_ply.py out.ply
"""
import sys
import numpy as np

rng = np.random.default_rng(1)
pts, cols = [], []
# The floor, 30 x 30 units at y = 0 (y is down in the scan, so the floor is below).
g = np.stack(np.meshgrid(np.linspace(-15, 15, 300), np.linspace(-15, 15, 300)), -1).reshape(-1, 2)
pts.append(np.c_[g[:, 0], np.zeros(len(g)), g[:, 1]])
check = ((np.floor(g[:, 0]) + np.floor(g[:, 1])) % 2)[:, None]
cols.append(0.35 + 0.3 * check * np.ones((1, 3)))
# Spheres.
for c, colour in [((0, -1, 4), (0.8, 0.2, 0.15)), ((-3, -1, 7), (0.2, 0.6, 0.3)), ((3, -1.5, 10), (0.2, 0.3, 0.8))]:
    d = rng.normal(size=(20000, 3))
    d /= np.linalg.norm(d, axis=1, keepdims=True)
    pts.append(np.array(c) + d)
    cols.append(np.array(colour) * (0.7 + 0.3 * np.clip(-d[:, 1:2], 0, 1)))
p = np.concatenate(pts).astype(np.float32)
rgb = np.concatenate(cols).astype(np.float32)
n = len(p)
dc = (rgb - 0.5) / 0.28209479
data = np.zeros((n, 14), np.float32)
data[:, 0:3] = p
data[:, 3:6] = dc
data[:, 6] = 4.0                      # opacity logit
data[:, 7:10] = np.log(0.06)          # scale
data[:, 10] = 1.0                     # rot w
names = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity", "scale_0", "scale_1", "scale_2",
         "rot_0", "rot_1", "rot_2", "rot_3"]
with open(sys.argv[1], "wb") as f:
    f.write(("ply\nformat binary_little_endian 1.0\nelement vertex %d\n" % n).encode())
    for k in names:
        f.write(("property float %s\n" % k).encode())
    f.write(b"end_header\n")
    f.write(data.tobytes())
print("wrote", n, "splats to", sys.argv[1])
