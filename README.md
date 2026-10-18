# Vintage Click

(Formerly Splat Camera: rolls and sounds already kept under that name are still found.)

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

## Play

`./build.sh`, then copy `build/Vintage Click.app` to /Applications. Open it from Finder and it asks for
a scan (a 3DGS `.ply`) and two things about it: whether it's an object (scanned on a rig, lit from
the camera) or a place to stand in, and how bright its light was. The answers are remembered per
file. You can also drop a `.ply` on the app or use **Open With**. **File > Open Scene…** switches
scans, **File > Choose Where Rolls Are Kept…** picks the folder for developed rolls (default
`~/Pictures/Vintage Click`), and **Help > Controls** lists the keys and pad buttons.

**Speed (M2 Pro, 3M-splat bee, nothing else on the GPU):** about 6 finder frames a second, ~150 ms
each, nearly the same at 810x540 as at 1620x1080 and with shadows or the lens off. The cost is per
splat (projecting, sorting, relighting 3M of them), not per pixel: level of detail and a faster
renderer path are next.

## Build

Needs the Command Line Tools (no Xcode) and a build of `libspirula_render.dylib`
from the `blender-render` branch of the spirula-studio fork:

```bash
SPIRULA_BUILD=~/Documents/spirula-studio-capture/build ./build.sh
```

## Run

```bash
open "build/Vintage Click.app" --args ~/Desktop/bee/bee-final.ply
```

Options: `--res 1620x1080` (3:2, like 35 mm), `--fps 24`, `--scale`, `--demo-lights`,
`--lighting-mode`,
`--ev`, `--cells`, `--lens I`, `--aperture F`, `--film I`, `--bench FRAMES`
(scripted orbit, uncapped, prints render timings and quits; `--pinhole` for
no lens), `--shoot out.png` (take one frame and quit).

## The camera

Depth of field is made by the render, not painted on: Spirula's projection
gives every splat the blur and shift its depth and the lens pupil imply
(`sr_set_lens`), so occlusion and edges stay correct. The finder shows that
render at the lens's widest aperture (hold DOF preview to stop down) on a
focusing screen with a split-prism and microprism collar. Firing the
shutter swings the mirror up (the finder goes black for the mirror travel
plus the shutter time) and advances the film; the frame is then exposed and
developed in the background at photo resolution (`--photo-res`, default
twice the finder), so you keep shooting: one render thread alternates live
finder frames with the next sub-pupil of the oldest frame in the darkroom.
The finder is always the ground glass: the lens's image with its light
fall-off and lateral colour fringes, fine matte tooth and fresnel rings.
Exposures add axial colour too: sub-pupils carry one colour each, focused
where that colour focuses, so bokeh edges fringe magenta and green. An exposure adds up renders
from sub-pupils of the taking aperture (`--cells`, default 32), each
sheared so the focus plane stays put. Each
lens's pupil sets the bokeh: blade count, cat's-eye clipping by the barrel
(strong on the swirly Volna), and rim-bright soap bubbles. Then the stock
develops it: exposure from aperture, shutter and ISO against the scene's EV
(`--ev`, default 12), a characteristic curve, colour crosstalk, halation and
grain. Frames are filed by day, sitting and roll in the rolls folder
(`~/Pictures/Vintage Click` unless chosen in the menu or File menu):
`2026-10-17/09.14 Skate park/Roll 01 - Portrait 400/frame-01.png`, each with
a JSON of how it was taken and, with Digital negative on, a
high-dynamic-range DNG (linear light before the film, 16-bit float).

Scans carry no scale. When choosing a scan the app guesses from its shape
(an object on the rig, about 60 cm, or a place to stand in, about 30 m), and
the menu can switch it. To set it exactly: menu > Set the scale (measure):
aim the crosshair at one end of something you know the size of and press A /
click, then at the other end, then type its real length (2.5 m, 30 cm, 6 ft)
or dial it on the pad. The scale is remembered with the file; `--scale`
(metres per unit) sets it from the command line.

## Lighting

Lights relight the scan on the GPU (gs_render's model, made for scans lit
from the camera): each light reads the scan's broad colour in its own
direction for the diffuse and its higher SH bands at the half vector for the
shine; the house lights give back a share of the scan as captured. The kit is
1970s tungsten at 3200 K: Fresnel 650, 1K and 2K (flood to spot) and a 2K
quartz softlight, photometrically sized, so the meter and the film react to
them as they would (daylight stocks go warm; Tungsten 800T is balanced for
them). Heads show as wireframes in the finder only. Each light casts shadows.

## Seeing the pictures

Only on the light table (View / K): each roll laid out in strips of six,
edge print and sprocket holes, unexposed frames black, frames still in the
darkroom blank. Slide the loupe over it with either stick (L2/R2 for its
power, 2-10x); it magnifies from the full-size frames. The d-pad chooses a
frame (the loupe glides to it) and A marks it as a keeper in red grease
pencil (kept in the roll's marks.json). Nothing pops up when the shutter fires.

## Film

Load film from the menu (or the pad's top button / R): choose a stock and
rate the roll at box speed, pulled one stop or pushed up to three. The meter
and the ISO readout follow the rating, and the whole roll is developed for
it: pushing raises contrast and grain, deepens shadows and adds a little fog;
pulling softens contrast and fines the grain. The rating is in the roll's
folder name and each frame's .json.

## Sounds

The camera sounds are a real Nikon, recorded for the game (Resources/Sounds):
the shutter at every speed from 1/2000 to 1 s (the recording nearest the
speed set plays), thirteen takes of the film advance lever, the aperture
ring, the shutter-speed dial, lens changes and loading film. Each event
plays a random take, never the same twice running, slightly varied in
speed and level. Menu > Camera sounds turns them on or off.

## The menu

Esc (keyboard) or + / Menu (pad) opens the game menu: switch between the
camera, lighting and the light table, reset the view, open another scene,
choose where rolls are kept, quit, and see every control (Controls, also
Help > Controls) for pad and keyboard side by side.

## Controls

Keyboard and mouse, laid out like a first-person game (click in the window to
take the mouse, Esc to let it go):

| | Camera | Lighting (L) | Light table (Tab) |
|---|---|---|---|
| Mouse | look | look | the loupe |
| WASD / Shift | walk / run | walk / run | |
| Space, Ctrl (or E, Q) | rise, sink | rise, sink | |
| Left click | shutter | take / place the light | mark a keeper |
| Right button (hold) | depth-of-field preview | | |
| Wheel | focus ring | flood / spot | loupe power |
| [ ] | aperture | choose a light | |
| - = | shutter speed | dimmer | |
| 1-8 | lens from the bag | | |
| R | new roll (reload) | | |
| F / T / Backspace | | add / change head / remove | |
| G | | house lights (day ... night) | |
| arrows / Q E / Esc | look | look | choose frame / roll / back |
| M + arrows | tilt or shift the lens (tilt and shift lenses only) | | |
| N | lens back square and centred | | |
| H, U | reset view, up axis | | |

Lens movements: the bendy lens tilts its plane of focus up to 15 degrees
(hold M and use the arrows, or on a pad hold Y and use the right stick:
left / right swings the sharp band across the frame, up / down along it);
the PC lenses shift up to 11 mm (up raises the lens to keep a
building's verticals straight while showing its top, left / right slides
sideways). The finder shows the result as you move, and the amount flashes
on the screen. N (or Y + a click of the right stick) squares the lens up;
changing lens does too. A quick tap of Y still loads film.

Pad (Xbox / PlayStation / Switch Pro), camera mode:

| Pad | |
|---|---|
| Left stick | walk / strafe |
| Right stick | look |
| L1 / R1 | sink / rise |
| L2 / R2 | focus ring near / far |
| D-pad left / right | aperture open / close |
| D-pad up / down | shutter faster / slower |
| A / cross | shutter release |
| B / circle (hold) | depth-of-field preview |
| X / square | next lens from the bag |
| Y / triangle | tap: load a new roll; hold + right stick: tilt / shift the lens; hold + R3: square it |
| R3 | lighting mode |
| View / Share | light table |
| Menu | reset the view |
| L3 | walk faster / slower |

Pad, lighting mode (walking and looking as above): X adds a light (in hand, held
out in front and aimed where you focus), A takes / places the chosen light,
B removes it, Y changes its head, d-pad left/right chooses, up/down dims in
half stops, L2/R2 flood / spot, L3 house lights, R3 back to the camera.

Pad, light table: sticks slide the loupe, L2/R2 its power, d-pad chooses a frame,
A marks it, L1/R1 change session (all its rolls are on the table, each cut into its own strips), B back to the camera.

## Where it is going

A manual-focus 35 mm SLR in your hands: viewfinder with a meter needle and a
split-prism, aperture / shutter / ISO; a bag of classic lenses and film stocks
(each "inspired by", no trademarks) with lens character from thin-lens
sampling and film looks as a post pass; lights you place with the pad; a
limited roll you develop. Next stages: GPU relighting and soft fur shadows,
then a many-sample photo mode, then the game.
