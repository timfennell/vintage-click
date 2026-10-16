# Splat Camera

A vintage 35 mm film-camera photography game set inside 3D Gaussian splat
scenes, for macOS. Free and open source (GPL-3.0).

**Stage 1 (this spike):** a native Mac window that loads a 3DGS PLY and flies
a camera through it with a game controller, rendered in real time by
[Spirula Studio](https://github.com/harry7557558/spirula-studio)'s Vulkan
rasterizer (via MoltenVK). Frames never leave the GPU: Spirula renders into
buffers it shares with Metal (`sr_shared_frames` / `sr_render_to_frame`), and
a Metal pass composites them on screen.

Play runs at a film cadence — 24 fps by default (`--fps 18` .. `--fps 24`),
each frame held evenly for 1/fps.

## Build

Needs the Command Line Tools (no Xcode) and a build of `libspirula_render.dylib`
from the `blender-render` branch of the spirula-studio fork:

```bash
SPIRULA_BUILD=~/Documents/spirula-studio-capture/build ./build.sh
```

## Run

```bash
open "build/Splat Camera.app" --args ~/Desktop/bee/bee-final.ply
```

Options: `--res 1620x1080` (3:2, like 35 mm), `--fps 24`, `--sh 0..3`, `--scale`,
`--ev`, `--cells`, `--lens I`, `--aperture F`, `--film I`, `--bench FRAMES`
(scripted orbit, uncapped, prints render timings and quits; `--pinhole` for
no lens), `--shoot out.png` (take one frame and quit).

## The camera

Depth of field is made by the render, not painted on: Spirula's projection
gives every splat the blur and shift its depth and the lens pupil imply
(`sr_set_lens`), so occlusion and edges stay correct. The finder shows that
render at the lens's widest aperture (hold DOF preview to stop down) on a
focusing screen with a split-prism and microprism collar. The shutter
exposes the film by adding up renders from sub-pupils of the taking aperture
(`--cells`, default 32), each sheared so the focus plane stays put. Each
lens's pupil sets the bokeh: blade count, cat's-eye clipping by the barrel
(strong on the swirly Volna), and rim-bright soap bubbles. Then the stock
develops it: exposure from aperture, shutter and ISO against the scene's EV
(`--ev`, default 12), a characteristic curve, colour crosstalk, halation and
grain. Frames land in `~/Pictures/Splat Camera/Roll NN - <stock>/` with a
JSON of how each was taken.

Scans carry no scale: `--scale` sets metres per scene unit (by default the
subject is treated as a 60 cm still life).

## Controls

| Pad (Xbox / PlayStation) | Keyboard | |
|---|---|---|
| Left stick | WASD | walk / strafe |
| Right stick | arrows | look |
| L1 / R1 | Q / E | sink / rise |
| L2 / R2 | Z / C | focus ring near / far |
| D-pad left / right | 1 / 2 | aperture open / close |
| D-pad up / down | 4 / 3 | shutter faster / slower |
| A / cross | Space | shutter release |
| B / circle (hold) | Tab (hold) | depth-of-field preview |
| X / square | L | next lens from the bag |
| Y / triangle | R | load a new roll (next stock) |
| Menu | 0 | reset the view |
| View / Share | P | film-look preview in the finder |
| Left stick click | G | walk faster / slower |
| | U | cycle the up axis |

## Where it is going

A manual-focus 35 mm SLR in your hands: viewfinder with a meter needle and a
split-prism, aperture / shutter / ISO; a bag of classic lenses and film stocks
(each "inspired by", no trademarks) with lens character from thin-lens
sampling and film looks as a post pass; lights you place with the pad; a
limited roll you develop. Next stages: GPU relighting and soft fur shadows,
then a many-sample photo mode, then the game.
