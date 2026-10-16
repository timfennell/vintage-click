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

Options: `--res 1920x1080`, `--fps 24`, `--sh 0..3` (SH bands),
`--bench FRAMES` (scripted orbit, uncapped, prints render timings and quits),
`--still out.png`.

## Controls

| Pad (Xbox / PlayStation) | Keyboard | |
|---|---|---|
| Left stick | WASD | walk / strafe |
| Right stick | arrows | look |
| R2 / L2 | E / Q | rise / sink |
| D-pad up / down | = / - | zoom (focal length) |
| R1 / L1 | ] / [ | walk faster / slower |
| A / cross | R | reset view |
| Y / triangle | U | cycle the up axis |
| B / circle | H | SH bands: full / base colour |
| X / square | Space | save a still to ~/Pictures/Splat Camera |

## Where it is going

A manual-focus 35 mm SLR in your hands: viewfinder with a meter needle and a
split-prism, aperture / shutter / ISO; a bag of classic lenses and film stocks
(each "inspired by", no trademarks) with lens character from thin-lens
sampling and film looks as a post pass; lights you place with the pad; a
limited roll you develop. Next stages: GPU relighting and soft fur shadows,
then a many-sample photo mode, then the game.
