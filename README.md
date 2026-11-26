# Compositor

## About this fork

This is a fork of [robbietilton/Compositor](https://github.com/robbietilton/Compositor), kept on top of its 1.7.2; the work is done on the `macos15` branch. It runs on macOS 15, speaks Simplified Chinese, and gives Camera Raw the RAW file to work from. It isn't the official app: there is no download and no automatic update, and its problems aren't upstream's to answer for. Below this section the README is upstream's, unchanged. Where the two disagree, on the macOS version and on translations, this section is what holds for the fork.

To build it, run `scripts/build-macos15.sh` and open `build/macos15/release/Compositor.app`. The Command Line Tools are enough; Xcode isn't needed. The app is signed ad hoc, for the Mac that built it.

### Features added
- **Runs on macOS 15.4 and later**, where upstream needs macOS 26. Controls that only macOS 26 draws, Liquid Glass among them, take macOS 15's own look. RAW Highlight Recovery is the one feature left out: the system's decoder has it from macOS 26.
- **Simplified Chinese interface**, following the language macOS is set to for the app, with Adobe's own Chinese terms for what Photoshop, Camera Raw and Lightroom have too. It starts from the translation in [emptykid/Compositor](https://github.com/emptykid/Compositor); [docs/localization.md](docs/localization.md) says how to add to it.
- **A RAW section in Camera Raw.** On a layer that is still what its RAW file developed to, Exposure, Temperature, Tint, Boost, Noise Reduction and Lens Correction develop the file again, so a blown highlight comes back from the sensor's data rather than from pixels already clipped.
- **RAW layers stay recipes.** OK keeps the file and the settings with the layer: open Camera Raw on it again and every slider is where it was left, to carry on from. A saved project keeps the recipe too, with a read-only reference to the RAW file rather than a copy of it: the file is never written, and with it moved away the project still opens, with the layer's pixels.
- **Lightroom's keys.** ← and → move the slider under the pointer, by a larger step with Shift and the smallest with Option. `\` switches between before and after while a filter's panel is previewing.

### Fixes
- Tonal Contrast layers were drawn out of place on the canvas on macOS 15, by as far as their blur reaches, so the canvas and the export disagreed.
- Motion Blur left a solid picture 1 to 3% see-through on macOS 15.
- Camera Raw opened with a number field focused, which took the arrow keys from its sliders.

### Design
- **Camera Raw previews in two passes** on a layer of 8 megapixels or more: a draft from a copy 2560 pixels long while a slider moves, then the whole frame 160 ms after it rests. On a 42-megapixel layer a Light slider's frame went from 73 ms to 17, and one with Shadows and Clarity on from 1.1 s to about 0.1 s.
- **One RAW decoder is kept for the panel**: a draft develops in about 10 ms and the whole 42-megapixel frame in about 0.2 s.
- **Undo is sized to the Mac**: an eighth of its memory, where it was a fixed 256 MB that one 42-megapixel 16-bit layer overflowed, leaving nothing to undo. Over that, a RAW layer's older steps are kept as small stand-ins and developed again when returned to, the farthest first, so the nearest steps come back at once.
- **Before and after are both kept**, so `\` switches between them without rendering again.

Checked on macOS 15.6 with a Sony A7R III's 42-megapixel RAW files: all the unit tests pass.

---

Adobe Photoshop costs too much and tools like GIMP don’t feel familiar enough for me to stay in flow. That’s why I built Compositor.

The goal was to create a full-featured image editor that is completely free and open source. I used to use Photoshop for compositing and post-processing, so Compositor is built around that workflow - with the tools needed to create a pixel-perfect final image.

Because it’s open source, you can download the Xcode project and add, remove, or modify any feature to fit your workflow.

## Installation

### Download
Get Compositor from [robbietilton.com/compositor](https://robbietilton.com/compositor), or download the latest release directly from [GitHub Releases](https://github.com/robbietilton/Compositor/releases/latest).

### Homebrew

```sh
brew install --cask robbietilton-compositor
```

## Features

### Layers
- Layers and folders, with opacity and Photoshop's full set of blend modes in its order — a folder's opacity dims everything inside it
- Layer masks: paint, fill, invert, blur and feather them anywhere on the canvas, past the layer's own pixels; link or unlink them to transform a mask on its own
- Clipping masks and folder masks
- Adjustment layers: Hue/Saturation, Levels, Curves, Exposure, Gradient Map, Grain, Black & White, Color Balance, Invert, and filter layers: Gaussian Blur, Motion Blur, Progressive Blur, Sharpen, Reduce Noise, Noise, Vignette, Bloom / Glow, RGB Split, Lens Effects and Tonal Contrast
- Layer effects: Stroke, Drop Shadow, Color Overlay, Inner Shadow, Outer Glow and Inner Glow, rendered on the GPU and editable at any time
- Merge Down, Merge Layers and Merge Group (⌘E)
- Duplicate, rename inline, reorder and nest by drag and drop; Option-drag to duplicate; a right-click menu in the Layers panel
- Copy and paste whole layers and folders (⌘C/⌘V with no selection), within a project or between projects, or drag them between projects

### Transform
- Non-destructive move, scale, rotate and flip — images keep their full resolution however small you make them
- Free distort (⌘-drag a handle), with Shift to lock to an axis
- Transform several layers, or a whole folder, together
- Snapping to canvas and layer edges and centers, with guides
- Distances (View › Show › Distances): pixel gaps to the canvas edges and nearby layers while moving a layer, and to the layer under the pointer with ⌘ held
- Exact values for position, size, scale and angle, stepped with the arrow keys
- Flip Layer and Flip Canvas, horizontal and vertical
- Align and Distribute layers to each other, the selection or the canvas, from the Move tool's bar or the Layer menu

### Selections
- Rectangle and Ellipse Marquee, Freehand and Polygonal Lasso, and the Magic tool — Wand selects by color, Object traces whatever you click (Tab switches)
- Select Subject, and Expand, Contract and Feather on any selection
- Add to and subtract from selections, move the outline, or move and duplicate the pixels inside
- Load a layer's pixels or a mask as a selection
- Content-Aware Fill, which can also extend an image past its edges

### Painting and retouching
- Brush with size, hardness, opacity and smoothing, in Paint or Erase mode (B and E), and Shift for straight lines
- Pen pressure for the Brush's size and opacity, on a graphics tablet
- Spot Healing Brush (content-aware)
- Clone Stamp, aligned or not, sampling one layer or all of them
- Blur tool, on pixels or masks
- Gradient tool and Shape tool (rectangles, rounded rectangles, ellipses and lines), which stay editable rather than being rasterized
- Type tool (T): inline multiline editing in draggable, resizable paragraph boxes; font, size, color, alignment and spacing in the tool header; transform text and use it as a clipping mask
- Eyedropper and a full color picker

### Adjustments and filters
- Camera Raw filter: light, color, curves, color mixer, color grading, detail, optics and geometry, in a panel beside the canvas; each section resets to its defaults from its header
- Levels (with Auto), Curves, Hue/Saturation, Exposure, Gradient Map, Grain, Black & White, Color Balance and Invert
- Gaussian Blur and Motion Blur that spread past a layer's edges
- Sharpen, Reduce Noise, Add Noise, Vignette, Bloom / Glow, Dither, Scanlines, RGB Split, Lens Effects (anamorphic flare, starburst, mist, prism and bokeh in round, hexagon, oval or cat's-eye shapes), Tonal Contrast, Volumetric Light (fog that thickens with distance around the subject, lit by a light you place, with the photo's own lights glowing into it and optional beams), Rim Light (up to three colored lights behind the subject, with glow that wraps it into the light), Lens Correction and Remove Background
- Live previews, limited to the selection when there is one
- Last Filter (⌃⌘F) runs the last filter again with the same settings

### Canvas and files
- Multiple projects in tabs
- Search Commands (⌘F): find every menu command and tool by name, as in Raycast or Obsidian, and run it with Return
- Toggle Fullscreen (F): the canvas alone on black over the whole screen, with every panel put away; F or Esc brings them back
- Rulers (⌘R), guides dragged from them, a layout grid with adjustable spacing and subdivisions, and Snap To for guides, grid, layers and document bounds
- Crop with snapping, ratios including 3:4 and 9:16, and Option for symmetric cropping; with a selection, the crop starts at it
- Canvas Size, Image Size and Trim
- The tool bar moves into two columns when the window is too short for one
- A Navigator minimap in the canvas's corner from 300% zoom: the whole document in small with a box around the view; click or drag to move there (View › Navigator)
- Sharp high-quality downsampling when zoomed out, and a pixel grid when zoomed in
- Import JPEG, PNG, HEIC, TIFF, WebP, SVG, PDF (every page its own layer, at 300 DPI or fitted to the canvas), animated GIF (one layer whose frames show in a strip under the canvas, to play, paint on, duplicate, delete and retime), camera RAW (with a develop step first) and Photoshop PSD and PSB (8-bit RGB; not CMYK). Each Photoshop artboard opens in a tab of its own; folders, masks, blend modes, fill rectangles/ellipses, and simple horizontal text stay editable; other vectors and vertical text become pixels. A conversion report is shown before anything is applied.
- Large documents: the memory budget scales with your Mac, and a Photoshop file too big to open has its layers cropped to the canvas instead
- Export PNG (⇧⌘E) and Export As (⇧⌥⌘S, or ⇧⌥⌘W) for PNG, JPEG, a one-page PDF at the print size or, with a GIF layer, an animated GIF, scaled if you like, with a live preview, JPEG quality and file size; Channel Pack in Export As packs layers into a PNG's red, green, blue and alpha for game textures, and RGB Split's Split to Layers turns a layer back into those four; right-click layers in the Layers panel to export each as its own PNG, trimmed to its pixels; Copy Merged
- Keep working while a project saves
- Photoshop-style keyboard shortcuts throughout, remappable in Edit > Keyboard Shortcuts
- Drag a number's label to scrub its value, as in Photoshop
- Automatic updates, signed and notarized

### Works with AI agents
- AI agents and scripts can build and edit projects directly: a `.comp` is a folder of PNG layers and a manifest, and an open project updates live as it's written. See [Writing Compositor projects](docs/writing-comp-files.md)

## Requirements

- macOS 26.0 or later on a Mac with Apple silicon
- Xcode 26 or later (to build from source)

## Translations

Compositor is English only for now, and translation pull requests aren't being accepted. It's maintained by one person, every new string would need translating from then on, and translations in languages I don't read can't be reviewed. I'll revisit this once the app settles; until then, please don't open localization PRs.

## Other platforms

Compositor is macOS only. These unofficial ports are made by others, not reviewed or supported by me, so please report issues to them:

- [CompositorWindows](https://github.com/Cengokill/CompositorWindows) by [@Cengokill](https://github.com/Cengokill): Windows
- [Composa](https://github.com/dvdstelt/Composa) by [@dvdstelt](https://github.com/dvdstelt): Windows and Linux
- [CompositorLX](https://github.com/ClaudiuJitea/compositorLX) by [@ClaudiuJitea](https://github.com/ClaudiuJitea): Linux

More are listed in [#23 (Windows)](https://github.com/robbietilton/Compositor/issues/23) and [#19 (Linux)](https://github.com/robbietilton/Compositor/issues/19).

## Building

Open `Compositor.xcodeproj` and run the **Compositor** scheme.

## Releasing

`scripts/release.sh` builds a Release version, signs it with Developer ID, notarizes and staples it, and packages it into `dist/Compositor-<version>.dmg`.

It needs, all kept outside this repository:

- a **Developer ID Application** certificate in the login keychain
- notarization credentials saved with `xcrun notarytool store-credentials "compositor-notary" …`
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`)

## License

MIT — see [LICENSE](LICENSE).

Volumetric Light's depth model, DepthMini, is distilled from [Depth Anything V2 Small](https://github.com/DepthAnything/Depth-Anything-V2)
(Apache-2.0) and starts from torchvision's ImageNet-trained MobileNetV3 weights (BSD-3-Clause). It isn't in the app:
it's downloaded the first time Volumetric Light opens.
