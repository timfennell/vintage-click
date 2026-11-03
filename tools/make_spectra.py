"""Spectra for the lens flare and the diffraction gratings: what each light sends at each
wavelength, so a grating spreads the light's own spectrum (not an even rainbow) and the
flare's ghosts and ring fringe by the glass's dispersion, wavelength by wavelength.

    python3 tools/make_spectra.py

Writes Sources/SplatCamera/SpectraData.swift (tables for the shaders, in Metal source) and
tools/spectra.json (the same tables, for the Blender engine's optics importer).

- 36 bins, 380-730 nm every 10 nm; CIE 1931 2-degree colour matching, to linear Rec.709,
  white-balanced so D65 daylight is (1, 1, 1) (the game's convention: daylight = 1, 1, 1).
- The kit's lamps: 3200 K tungsten (Planck).
- Each gel's transmission curve: a shape for what the gel is (colour-temperature gels from the
  ratio of black bodies; a magenta's notch in the green; deep blues' leak into the far red),
  fitted so the gel's colour under tungsten is the game's own (Filters.swift).
- A grating's orders: order m puts wavelength lambda at U1 m lambda / 730 nm of the spike's
  length, with efficiency ETA[m]; scene highlights (only an RGB colour) are given a smooth
  spectrum from three basis curves.
- Bands for the ghosts and the ring: each band its own colour share and dispersion.
"""

import json
import math
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.dirname(HERE)

WL = np.arange(380, 731, 10, dtype=np.float64)
N = len(WL)

# CIE 1931 2-degree observer, 10 nm
CMF = np.array([
    [0.001368, 0.000039, 0.006450], [0.004243, 0.000120, 0.020050], [0.014310, 0.000396, 0.067850],
    [0.043510, 0.001210, 0.207400], [0.134380, 0.004000, 0.645600], [0.283900, 0.011600, 1.385600],
    [0.348280, 0.023000, 1.747060], [0.336200, 0.038000, 1.772110], [0.290800, 0.060000, 1.669200],
    [0.195360, 0.090980, 1.287640], [0.095640, 0.139020, 0.812950], [0.032010, 0.208020, 0.465180],
    [0.004900, 0.323000, 0.272000], [0.009300, 0.503000, 0.158200], [0.063270, 0.710000, 0.078250],
    [0.165500, 0.862000, 0.042160], [0.290400, 0.954000, 0.020300], [0.433450, 0.994950, 0.008750],
    [0.594500, 0.995000, 0.003900], [0.762100, 0.952000, 0.002100], [0.916300, 0.870000, 0.001650],
    [1.026300, 0.757000, 0.001100], [1.062200, 0.631000, 0.000800], [1.002600, 0.503000, 0.000340],
    [0.854450, 0.381000, 0.000190], [0.642400, 0.265000, 0.000050], [0.447900, 0.175000, 0.000020],
    [0.283500, 0.107000, 0.000000], [0.164900, 0.061000, 0.000000], [0.087400, 0.032000, 0.000000],
    [0.046770, 0.017000, 0.000000], [0.022700, 0.008210, 0.000000], [0.011359, 0.004102, 0.000000],
    [0.005790, 0.002091, 0.000000], [0.002899, 0.001047, 0.000000], [0.001440, 0.000520, 0.000000]])
D65 = np.array([49.9755, 54.6482, 82.7549, 91.486, 93.4318, 86.6823, 104.865, 117.008, 117.812,
                114.861, 115.923, 108.811, 109.354, 107.802, 104.790, 107.689, 104.405, 104.046,
                100.000, 96.3342, 95.788, 88.6856, 90.0062, 89.5991, 87.6987, 83.2886, 83.6992,
                80.0268, 80.2146, 82.2778, 78.2842, 69.7213, 71.6091, 74.349, 61.604, 69.8856])
XYZ_TO_709 = np.array([[3.2406, -1.5372, -0.4986], [-0.9689, 1.8758, 0.0415], [0.0557, -0.2040, 1.0570]])

# Each bin's contribution to linear Rec.709 per unit of power there, white-balanced to D65.
_raw = CMF @ XYZ_TO_709.T                          # (N, 3)
WHITE = (D65[:, None] * _raw).sum(0)
DENS = _raw / WHITE                                # rgb = sum_i S_i DENS_i, D65 -> (1, 1, 1)
LUMA = np.array([0.2126, 0.7152, 0.0722])


def rgb(S):
    return (np.asarray(S)[:, None] * DENS).sum(0)


def planck(T):
    lam = WL * 1e-9
    b = 1 / (lam ** 5 * (np.exp(1.438777e-2 / (lam * T)) - 1))
    return b / b[WL == 560][0]


TUNGSTEN = planck(3200.0)
GAME_TUNGSTEN = np.array([1.0, 0.80, 0.56]) / 0.80     # Lights.swift


def gauss(c, s):
    return np.exp(-0.5 * ((WL - c) / s) ** 2)


def longpass(c, w):
    return 1 / (1 + np.exp(-(WL - c) / w))


def shortpass(c, w):
    return 1 / (1 + np.exp((WL - c) / w))


# The game's gels (Filters.swift): name -> (target colour, curve shape).
def filter_colour(shape, t):
    shape = np.asarray(shape, np.float64)
    c = shape * (t / max(shape @ LUMA, 1e-4))
    m = c.max()
    return c / m if m > 1 else c


DAYLIGHT = np.ones(3)
TO_DAY = DAYLIGHT / GAME_TUNGSTEN
TO_TUNG = GAME_TUNGSTEN / DAYLIGHT
ct_blue = planck(5500.0) / TUNGSTEN
ct_orange = TUNGSTEN / planck(5500.0)
GELS = [
    ("No gel", np.ones(3), np.ones(N)),
    ("Leeward 201 Full CT Blue", filter_colour(TO_DAY, 0.36), ct_blue),
    ("Leeward 202 Half CT Blue", filter_colour(TO_DAY ** 0.5, 0.52), ct_blue ** 0.5),
    ("Leeward 203 Quarter CT Blue", filter_colour(TO_DAY ** 0.25, 0.69), ct_blue ** 0.25),
    ("Leeward 204 Full CT Orange", filter_colour(TO_TUNG, 0.55), ct_orange),
    ("Leeward 205 Half CT Orange", filter_colour(TO_TUNG ** 0.5, 0.70), ct_orange ** 0.5),
    ("Leeward 206 Quarter CT Orange", filter_colour(TO_TUNG ** 0.25, 0.81), ct_orange ** 0.25),
    ("Rosmont 07 Pale Straw", filter_colour([1, 0.9, 0.55], 0.80), 1 - 0.55 * shortpass(465, 14)),
    ("Rosmont 02 Bastard Amber", filter_colour([1, 0.75, 0.55], 0.68),
     0.25 + 0.75 * longpass(500, 18) - 0.12 * gauss(520, 25)),
    ("Rosmont 20 Medium Amber", filter_colour([1, 0.62, 0.22], 0.50), 0.03 + longpass(530, 16)),
    ("Rosmont 26 Primary Red", filter_colour([1, 0.03, 0.03], 0.12), 0.004 + longpass(605, 9)),
    ("Rosmont 46 Magenta", filter_colour([1, 0.12, 0.85], 0.22),
     0.85 * gauss(430, 35) + longpass(605, 12) + 0.01),
    ("Rosmont 54 Special Lavender", filter_colour([0.75, 0.55, 1], 0.45),
     0.35 + 0.65 * (shortpass(480, 20) + longpass(610, 18)).clip(0, 1)),
    ("Rosmont 89 Moss Green", filter_colour([0.12, 1, 0.18], 0.22), gauss(527, 30) + 0.02 + 0.3 * longpass(700, 8)),
    ("Rosmont 70 Peacock Blue", filter_colour([0.05, 0.75, 0.85], 0.30),
     gauss(495, 42) + 0.25 * longpass(705, 8)),
    ("Rosmont 66 Steel Blue", filter_colour([0.55, 0.75, 1], 0.48), 0.45 + 0.55 * shortpass(560, 35)),
    ("Rosmont 85 Deep Night Blue", filter_colour([0.08, 0.2, 1], 0.06),
     gauss(452, 22) + 0.35 * longpass(705, 7)),
]


def fit_gel(target, shape):
    """The shape, bent smoothly (exp(a + b x + c x^2)) so its colour under tungsten matches."""
    x = (WL - 555) / 100
    base = rgb(TUNGSTEN)
    shape = np.maximum(np.asarray(shape, np.float64), 1e-6)

    def curve(p):
        return np.clip(shape * np.exp(p[0] + p[1] * x + p[2] * x * x), 0, 1)

    def err(p):
        return np.log(np.maximum(rgb(TUNGSTEN * curve(p)) / base, 1e-6)) - np.log(np.maximum(target, 1e-6))

    p = np.zeros(3)
    for _ in range(200):
        e = err(p)
        J = np.empty((3, 3))
        for k in range(3):
            dp = np.zeros(3)
            dp[k] = 1e-5
            J[:, k] = (err(p + dp) - e) / 1e-5
        step = np.linalg.lstsq(J, -e, rcond=None)[0]
        p = p + np.clip(step, -0.5, 0.5)
        if np.abs(e).max() < 1e-5:
            break
    c = curve(p)
    return c, rgb(TUNGSTEN * c) / base


# ---- gratings
U1 = 0.32                         # order 1's red end (730 nm), as a share of the spike's length
ETA = [1.0, 0.6, 0.35, 0.2]       # efficiency of orders 1-4
UBINS = 64


def grating_colour(dens, u):
    """Colour at u (0..1 of the spike) from a spectrum's per-bin colour `dens` (N, 3):
    each order's wavelengths spread along it (power per unit length: S d lambda / du)."""
    out = np.zeros(3)
    for m, eta in enumerate(ETA, 1):
        lam = u * 730.0 / (m * U1)
        if lam < 380 or lam > 730:
            continue
        f = (lam - 380) / 10
        i = min(int(f), N - 2)
        t = f - i
        d = dens[i] * (1 - t) + dens[i + 1] * t
        out += eta * d * (730.0 / (m * U1)) / 10.0    # per nm -> per unit u
    return out


# basis spectra for an RGB colour (scene highlights)
BASIS = np.stack([longpass(585, 18), gauss(535, 38), shortpass(485, 18)], 0)       # r, g, b
B_RGB = np.stack([rgb(b) for b in BASIS], 1)                                         # columns
B_INV = np.linalg.inv(B_RGB)
# the colour at u for a source of colour v is M(u) v, M(u) = G(u) B_INV with G's columns the
# bases' grating colours
G = np.stack([np.stack([grating_colour(BASIS[k][:, None] * DENS, u) for k in range(3)], 1)
              for u in (np.arange(UBINS) + 0.5) / UBINS], 0)                         # (U, 3, 3)
M = G @ B_INV


# normalise to the old even rainbow's brightness (1.3 x spectrum(), a luminance-weighted mean)
def old_spectrum(h):
    def ss(a, b, x):
        t = min(max((x - a) / (b - a), 0.0), 1.0)
        return t * t * (3 - 2 * t)
    c = np.array([ss(0.40, 0.85, h) + 0.4 * (1 - ss(0.0, 0.12, h)),
                  1 - min(max(abs(h - 0.52) * 2.4, 0), 1), 1 - ss(0.08, 0.50, h)])
    return np.clip(c, 0, 1) * 1.4


us = (np.arange(UBINS) + 0.5) / UBINS
old = np.mean([1.3 * old_spectrum((math.sqrt(u) * 3.2 + 0.15) % 1.0) @ LUMA for u in us])
new = np.mean([np.maximum(M[i] @ np.ones(3), 0) @ LUMA for i in range(UBINS)])
K = old / new
M *= K

# ---- ghost and ring bands: bins grouped by what the eye sees
BANDS = [(380, 410), (420, 440), (450, 470), (480, 500), (510, 530), (540, 560), (570, 590), (600, 630),
         (640, 730)]


def band_shares(S):
    """Each band's share of a spectrum's colour, per channel (they sum to 1 per channel).
    Pure spectral colours lie outside Rec.709 (a band can give a channel a little negative),
    so negative parts are dropped before sharing out."""
    out = []
    for lo, hi in BANDS:
        sel = (WL >= lo) & (WL <= hi)
        out.append(np.maximum(rgb(np.where(sel, S, 0.0)), 0.0))
    out = np.array(out)
    total = out.sum(0)
    flat = np.full_like(out, 1.0 / len(BANDS))
    return np.where(total > 1e-9, out / np.maximum(total, 1e-12), flat)


def band_centre(lo, hi, S):
    sel = (WL >= lo) & (WL <= hi)
    w = (S * (DENS @ LUMA).clip(1e-6))[sel]
    return float((WL[sel] * w).sum() / w.sum())


def main():
    gels = []
    print(f"tungsten 3200 K from Planck: {rgb(TUNGSTEN) / rgb(TUNGSTEN)[1]}, the game's {GAME_TUNGSTEN}")
    for name, target, shape in GELS:
        c, got = fit_gel(target, shape)
        gels.append((name, c))
        print(f"{name:32s} target {np.round(target, 3)} fitted {np.round(got, 3)}")
    centres = [band_centre(lo, hi, TUNGSTEN) for lo, hi in BANDS]

    def f3(v):
        return "float3(%.6g, %.6g, %.6g)" % tuple(v)

    msl = []
    msl.append("// ---- spectra (generated by tools/make_spectra.py) --------------------------")
    msl.append(f"constant int SPEC_N = {N};          // bins, 380-730 nm every 10 nm")
    msl.append(f"constant float GRATING_U1 = {U1};   // order 1's 730 nm end, share of the spike")
    msl.append(f"constant int SPEC_GELS = {len(gels)};")
    msl.append(f"constant float GRATING_K = {K:.6g};")
    msl.append("constant float GRATING_ETA[4] = {" + ", ".join("%g" % e for e in ETA) + "};")
    msl.append("// each bin's colour per unit power (D65 = 1, 1, 1), times 3200 K tungsten")
    msl.append("constant float3 SPEC_TUNGSTEN[%d] = {%s};" % (N, ", ".join(f3(TUNGSTEN[i] * DENS[i]) for i in range(N))))
    msl.append("// the gels' transmission per bin (index as in gels)")
    msl.append("constant float SPEC_GEL[%d][%d] = {%s};" % (len(gels), N, ", ".join(
        "{" + ", ".join("%.5g" % v for v in c) + "}" for _, c in gels)))
    msl.append("// each gel's colour under tungsten from its curve (for a grating's share along a spike)")
    msl.append("constant float3 SPEC_GEL_RGB[%d] = {%s};" % (len(gels), ", ".join(
        f3(np.maximum(rgb(TUNGSTEN * c), 1e-3 * max(rgb(TUNGSTEN * c).max(), 1e-6))) for _, c in gels)))
    msl.append("// the bands the ghosts and ring split the light into: centre wavelength, and each")
    msl.append("// gel's colour share per band under tungsten (sums to 1 per channel)")
    msl.append("constant int SPEC_BANDS = %d;" % len(BANDS))
    msl.append("constant float SPEC_BAND_NM[%d] = {%s};" % (len(BANDS), ", ".join("%.1f" % c for c in centres)))
    msl.append("constant float SPEC_BAND_WIDTH[%d] = {%s};   // each band's span, in dispersion units (90 nm)" % (
        len(BANDS), ", ".join("%.3f" % ((hi - lo + 10) / 90.0) for lo, hi in BANDS)))
    msl.append("constant float3 SPEC_BAND_SHARE[%d][%d] = {%s};" % (len(gels), len(BANDS), ", ".join(
        "{" + ", ".join(f3(v) for v in band_shares(TUNGSTEN * c)) + "}" for _, c in gels)))
    msl.append("// a grating's colour along the spike for a scene highlight of colour v: M(u) v,")
    msl.append("// u = distance / spike length in %d steps; rows of M as three float3" % UBINS)
    msl.append("constant float3 GRATING_M[%d][3] = {%s};" % (UBINS, ", ".join(
        "{" + ", ".join(f3(M[i][r]) for r in range(3)) + "}" for i in range(UBINS))))
    body = "\n".join(msl)
    swift = ('// Generated by tools/make_spectra.py: do not edit (run it again instead).\n'
             '// The lamps\' and gels\' spectra, for the lens flare and the diffraction gratings.\n\n'
             'let spectraShaderSource = """\n' + body + '\n"""\n')
    open(os.path.join(GAME, "Sources/SplatCamera/SpectraData.swift"), "w").write(swift)
    data = dict(
        about="Vintage Click spectra (tools/make_spectra.py): bins 380-730 nm every 10 nm",
        wavelengths=WL.tolist(), dens=DENS.tolist(), d65=D65.tolist(), tungsten=TUNGSTEN.tolist(),
        gels=[dict(name=n, transmission=c.tolist()) for n, c in gels],
        lamps=dict(tungsten=TUNGSTEN.tolist(), daylight=(D65 / 100).tolist()),
        grating=dict(u1=U1, eta=ETA, k=K, ubins=UBINS, basis=BASIS.tolist(), basis_inv=B_INV.tolist(),
                     m=M.tolist()),
        bands=[list(b) for b in BANDS], band_nm=centres,
        band_width=[(hi - lo + 10) / 90.0 for lo, hi in BANDS])
    json.dump(data, open(os.path.join(HERE, "spectra.json"), "w"), indent=0)
    print("wrote SpectraData.swift and tools/spectra.json")


if __name__ == "__main__":
    main()
