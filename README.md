# Veil

Native iOS photo processing, SwiftUI, iOS 17+, Liquid Glass on iOS 26, Russian interface. Version 0.6 uses bounded non-generative phase processing, detail protection, optional subtle clarity and 4K interpolation. No model downloads, network processing, or generative dependencies are included in the app.

**SynthID removal is experimental and unverified.** Filtering a synthetic signal is not evidence of defeating the official detector. Protected image regions may retain the watermark. The app always displays “SynthID не проверен”.

## Processing

Choose a photo → Паттерн → strength → optional clarity/4K → Обработать → compare → export. Original dimensions and integer pixel coordinates are retained by default, including images larger than 1536 px. No diffusion or generative replacement of content. Output scaling is optional and explicit.

The independent filter uses overlapping 256×256 FFT tiles, hop 128, reflected padding, Hann analysis/synthesis windows and normalized overlap-add. Version 0.5's amplitude attenuation was reported to soften photographs. Version 0.6 rotates conjugate frequency pairs instead, preserving each analysis tile's spectral magnitudes before overlap, masking and clipping. Phase limits are 0.18 / 0.38 / 0.65 radians. A smooth angular phase field is shared across tiles: independent random bin phases were rejected because overlap cancellation softened the test signal. The band covers spatial periods 8–32 pixels, tapering to 6–48 pixels. Luminance changes are capped at 3 / 6 / 10 RGB levels. A common integer RGB offset is further limited to avoid channel clipping. This heuristic is not a recovered SynthID key or a proven universal watermark inverse.

A local detail check compares gradient energy in 64×64 cells. When the candidate loses more than 3% in a cell with source gradient energy above 0.05 per sample, its modifications and nearby cells are rolled back, with a smooth transition. This metric reduces visible softening; it is not a proof of semantic fidelity or watermark removal. Phase changes can still alter weak textures within the limits.

Vision recognizes text before filtering. Its bounding boxes, padded by four pixels, retain the decoded source pixels exactly. Contrast boundaries are detected by a 3×3 local luminance-range gate at 18+ levels. A distance mask freezes 32 pixels around protected content, then smoothly fades filtering in over the next 64 pixels to avoid halos. A local contrast gate also tapers processing at 5–18 levels. Translucent pixels and alpha are unchanged. A second OCR pass must find every original recognized string in an overlapping box; otherwise the app rejects the result. OCR can miss text, so this does not guarantee protection of all lettering. Weak-contrast textures may change. Protecting original pixels necessarily limits watermark attenuation.

PNG is the default and stores the filtered raster without lossy compression. JPEG is optional and adds compression, so exact pixel bounds and text guarantees apply **before JPEG encoding**. All processing uses decoded SDR sRGB; HDR/wide gamut and original compressed bytes are not retained. Input JPEG/PNG/HEIC/WebP up to 50 MiB and 20 MP, subject to system decoding. EXIF orientation is applied; animation is rejected. JPEG composites transparency on white.

**Мягкая чёткость**, off by default, adds a noise-cored 3×3 micro-contrast adjustment capped at one additional RGB level. Recognized text, alpha, local extrema and high-contrast edges are protected. There is no denoising or strong unsharp mask. The pattern-stage bounds apply before this optional extra adjustment.

**4K** sets the long side to 3840 px while retaining aspect ratio (portrait is supported). Enlargement uses monotone cubic interpolation with harmonic-mean tangents and local range clamping. Reduction uses pixel-area averages. Scaling works on premultiplied colors to avoid transparent-color fringes, with row caching for bounded intermediate memory. No ringing overshoot or new learned details are introduced. Upscaling cannot recover missing information. Exact source-pixel guarantees apply before resizing; OCR is repeated on the final resized image.

The separate Метаданные mode performs no frequency filtering. Both modes create a fresh image container without copying source EXIF/GPS/XMP/IPTC/C2PA. Metadata removal alone does not remove a pixel watermark.

## Build and checks

On a Mac with Xcode 26.2 and XcodeGen:

```sh
xcodegen generate
xcodebuild build -project Veil.xcodeproj -scheme Veil -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

GitHub Actions independently builds the arm64 device app, runs unit/UI tests, and compiles a macOS diagnostic using the same processor. The diagnostic draws synthetic English/Russian text, runs real OCR before/after native and 4K processing, checks RGB limits, exact protected regions, the raster bridge and PNG round trips, and saves input/output/metrics. Unit tests check pattern changes without texture-energy loss, tile boundaries, edge preservation, tiny/odd dimensions, monotone scaling without overshoot, area reduction, alpha, clarity limits, metadata, orientation and cancellation. UI tests exercise clarity and actual 4K export. These checks do not measure SynthID removal or performance on a physical iPhone.

The release workflow publishes an unsigned IPA only after all three jobs pass. Packaging validates arm64, the application bundle, absence of model payloads and ZIP integrity, and supplies SHA-256. External signing or a compatible container is required; no Apple signing keys are stored here.

## Research and history

[Non-generative baseline](docs/research/non-generative-0.5.md) describes scope and evidence. [Detail-preservation audit](docs/research/detail-preservation-2026-10-23.md) explains why SD 2.1 was unsuitable for lettering. [Earlier research](docs/research/README.md) distinguishes metadata, visible logos and invisible watermarks. Historical neural sources, tools and license notices remain for research, excluded from the app and release workflow. They are not evidence of current algorithm efficacy.

No user photographs are uploaded or bundled. CI uses synthetic fixtures. No accounts, analytics or subscriptions. Saving/sharing requires user action; temporary sharing files are removed after dismissal. Independent project, unaffiliated with Google, Apple, OpenAI or removesynthid.io.
