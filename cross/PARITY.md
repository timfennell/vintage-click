# Windows ↔ Mac feature parity

The goal: the Windows build (`cross/`) does everything the Mac app (`Sources/SplatCamera`) does, and looks the same.
This list tracks it. ✅ done · 🟡 partly · ❌ not yet. Priority order: **lens design, lens flare, render engine** first.

## 1. Render engine (Shaders.swift + RenderLoop.swift → GPU compute on Windows)

The Mac post-processes on the GPU (Metal compute). Windows ports the Metal kernels line for line to GLSL compute
(`cross/shaders`, compiled to SPIR-V by glslc and run through SDL_GPU on Vulkan: the renderer already needs Vulkan 1.3).
`VC_CPU=1` uses the old CPU path instead, for comparison. Like the Mac, a photo of a place shows the background through
the scan's leaks (the old CPU path rescaled them, as the finder does).

| Mac kernel / stage | What it does | Windows |
|---|---|---|
| `accumulate` | sum the sub-pupil renders into the exposure (pupil weight, lamp faces) | ✅ GPU |
| `develop` | lateral colour, vignette, streaks, filter fx, flare, halation, fisheye rim, film look | ✅ GPU |
| `develop16` | the same for movie frames, half floats | ✅ GPU (floats into a 10-bit HEVC final, P010; H.264 and previews stay 8-bit) |
| `streak` | anamorphic wire streaks (lenses with `streak` > 0) | ✅ GPU |
| `lens_fx` | effect filters (star, soft, mist, grating) | ✅ GPU |
| `negative` | DNG digital negative | ✅ GPU (floats down, halved on the CPU) |
| `viewfinder` (fragment) | the focusing screen, split prism, microprism, fresnel, eyepiece pincushion, surround glow, meter light and needle | ✅ GPU (refine fade with the shells) |
| `dof_pack` / `dof_tiles` / `dof_blur` | "smooth" finder blur (rendered sharp, blurred like a print) | ✅ GPU |
| `meter` | the meter (48 × 32, centre-weighted) | ✅ GPU |
| `probe` | what is under the crosshair (for measuring) | ✅ (read from the finder frame's centre depth) |
| finder size and layout | 1620 × 1080 drawable, image at 82 % in the surround, letterboxed window | ✅ |
| `background_fill` | the sky, the distant shells, fog in front, the lamps' beams and shafts in the fog | ✅ GPU, whole kernel with `fog_lamps` (shells feed it when they land; the shafts take their shadows from the finder's 512² maps, the Mac from each pass's own) |
| `shell_store` | the distant shells' bake | ✅ GPU (baked once the view holds still: ~190 ms on the church) |
| `relight` / `shadow_vis` | studio lights and their shadows | ✅ GPU (higher SH bands kept as half floats to spare video memory; relit colours reach the renderer through `sr_set_colors`). Test with `--demo-lights`, `--house`, `--gel`, `--head`, `--modifier`, `--no-shadows`. Lighting mode ✅ (below). |
| `flare_probe` | which lamps the lens sees, for the flare | ✅ GPU |
| shared GPU frames (`sr_add_shared_frames`, `sr_render_to_frame`) | zero-copy renderer → post | ❌ (copies through the CPU) |
| `sr_set_region` | render a region of the scan | ✅ (near splats live, far ones from the shells) |
| render degree control (`sr_set_render_degree`) | relit colours drawn at degree 0 | ✅ (as the Mac: the relight sets it) |

## 2. Lens design (Lens.swift)

| Feature | Windows |
|---|---|
| ~40 lenses, same data (generated from the Swift by `tools/gen_data.py`) | ✅ |
| blades, rotation, cat's eye, soap bubble, obstruction (mirror lenses) | ✅ |
| spherical aberration, axial and lateral colour, field curvature, breathing, close-focus magnification | ✅ |
| fisheye and circular fisheye projections | ✅ |
| anamorphic squeeze | ✅ |
| anamorphic streak | ✅ |
| tilt / shift movements (M + arrows, Y + right stick; N squares; `--tilt` / `--shift`) | ✅ |
| rangefinder vs reflex lenses (which body takes which); the nine Rangefinder lenses | ✅ |
| rear-filter lenses (colour and ND only) | ✅ |

## 3. Lens flare (Flare.swift, `lens_flare` in Shaders.swift)

| Feature | Windows |
|---|---|
| ghosts, glare, starburst, ring from lights shining into the lens (finder and photos) | ✅ |
| coatings (single-coated old optics: brighter, more colourful ghosts), dust, cleaning marks, scratches, seed bubbles, fungus, spectral fringes (the Mac's spectra tables, converted by `cross/tools/spectra_glsl.py`) | ✅ |
| filter glass ghost, star / grating on the filter | ✅ |
| lamp faces and bloom, hidden behind nearer scan; visibility probe | ✅ |
| fog dimming the flare | ✅ |
| flare per light on/off, "on new lights" default (`--flare-light`, `--flare` for tests) | ✅ |

## 4. Everything else

| Area | Mac | Windows |
|---|---|---|
| Menu | pages: main, camera bag, motion, lights, scene, photos, settings, viewfinder graphics | ✅ (every item the Mac has; the mouse points and clicks as on the Mac) |
| Place / object reading, remembered per scan | ✅ | ✅ |
| Scene light, remembered per scan | ✅ | ✅ |
| Set the scale (measure two points; Menu › Scene; type the real length or dial it) | ✅ | ✅ |
| Sky (equirectangular .hdr), turn and brightness, remembered per scan (`--sky`) | ✅ | ✅ (.hdr; the Mac also reads .exr) |
| Fog, lit by the lamps, with shafts (Fog.swift): haze with height fall-off, up to 8 patches (box, sphere, cylinder) | ✅ | ✅ |
| Camera bodies (Ohi Kor S2, Kwanon EF, Lahntal R5), shutter-priority auto, the rangefinder's window, patch, bright frames and shoe finder (`--body`) | ✅ | ✅ |
| HUD per body (LEDs in the Mac's orange-red, the meter card's M, the R5's fine bright frame): LEDs, the Kwanon's lit window and aperture scale, the Lahntal's readout line and top needle; lighting plot and beam marks while placing lights | ✅ | ✅ |
| Gaits: rail to run (, slower, . faster), picked for the scene's size | ✅ | ✅ |
| Motion camera (the hidden Wilmont W11: W on the bag's body row): frame rate, shutter angle, keyed takes (K, I / O, Z / X, P, G / Shift-G; Y, A and B + d-pad on a pad), rolling with focus pulls, motion blur through the shutter, the timeline and 1.85 marks, darkroom monitor, Motion page, takes on the light table (A / Enter plays, R develops the final). Test: `--take-demo S --develop preview\|final`, `--motion-menu` | ✅ | ✅ (a movie frame's flare doesn't yet check whether the scan hides a lamp; a final developed later from the light table uses the lights as they are then) |
| Lighting mode: place and fly lights, house lights (L / R3; F add, 1-9 fly, T head, G house lights...) | ✅ | ✅ |
| Lights: gels, modifiers (barn doors, flags, cookies, gobos, ellipsoidal), dimmer, spot / flood | ✅ | ✅ |
| Light wireframes in the finder (and the camera seen from a light) | ✅ | ✅ (drawn on the CPU) |
| Lights menu page, gel book and modifier pages | ✅ | ✅ |
| Lens filters: ND, colour, star, soft, mist (bag's last shelf, V, menu, `--filter`) | ✅ | ✅ |
| Film: 17 stocks, push / pull | ✅ | ✅ |
| Proofs at the shutter + enlarger at the light table (Menu › Photos; Y / P enlarges the marked frames, or all; frame-NN.shot.json records each shot) | ✅ | ✅ (the shot records are Windows' own JSON: the Mac's and Windows' enlargers each read their own) |
| Photo size, exposure quality | ✅ | ✅ |
| Digital negative (DNG 1.4 linear raw, half floats; Menu › Photos, `--dng`) | ✅ | ✅ (GPU path; the VC_CPU path keeps none) |
| EXIF in the photos (body, serial, lens, exposure, the roll as rated; film and filter in the comment) | ✅ | ✅ (eXIf chunk in the PNG) |
| Where rolls are kept: choose the folder (Menu › Photos) | ✅ | ✅ |
| Light table: strips laid by hand, edge printing and bar codes, dust and hairs, keepers in red china marker (A, marks.json), the loupe with its power scale, brass lip, knurled barrel and knob | ✅ | ✅ (the loupe's barrel is drawn, not rendered as the Mac's LoupeArt is) |
| Print wall: the session's prints in bevelled mats with L-pins under track lights; walk, step closer, look closely (X / G at the light table) | ✅ | ✅ (enlarged prints only, as on the Mac) |
| Camera sounds | ✅ | ✅ |
| Scene sound (.vcscene soundscape): placed loops and beds, Menu › Settings › Scene sound | ✅ | ✅ (sounds pan between the ears; the Mac places them around the head with HRTF. WAV, MP3, M4A, FLAC through Media Foundation) |
| Scene bundles (.vcscene): unpacked once into the caches; scale, kind, up, start view and lens, house lights, lights, sky, bounds, fog, sounds | ✅ | ✅ (open, drop or pass on the command line; unpacked with Windows' own tar) |
| Haptics (controller rumble; Menu › Settings) | ✅ | ✅ (a rumble per camera sound; the Mac plays hits taken from the recordings, and the trackpad too) |
| Viewfinder graphics: smooth / classic blur, fast focus | ✅ | ✅ |
| Viewfinder graphics: distant shells (Menu › Settings; VC_SHELLS, VC_SHELL_M) | ✅ | ✅ (used while you turn and focus; held still the finder draws everything, as the Mac's refine does. ~23% faster renders on the church) |
| Keyboard layout (arrows look, F / C focus, number keys pick a lens of the collection, H menu, U up axis, V filters, L lighting, , . gait, the movie camera's K I O Z X P G) | ✅ | ✅ |
| Controls guide | ✅ | ✅ |
| App icon | ✅ | ✅ |
| Movie developing (Mac: preview HEVC, final ProRes 422 HQ or HEVC 10-bit, up to 4096 × 2730) | ✅ | ✅ Media Foundation: preview H.264, final H.264 or HEVC Main 10 (falls back to 8-bit HEVC, then H.264), 3072 × 2048 or 1920 × 1280, .mp4 |
