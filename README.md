# Veil

Native iOS photo processing, SwiftUI, iOS 17+, Liquid Glass on iOS 26, Russian interface. Version 0.5 replaces diffusion regeneration with a bounded, non-generative pixel filter. No model downloads, network processing, or generative dependencies are included in the app.

**SynthID removal is experimental and unverified.** Filtering a synthetic signal is not evidence of defeating the official detector. Protected image regions may retain the watermark. The app always displays “SynthID не проверен”.

## Processing

Choose a photo → Паттерн → strength → Обработать → compare → export. Original dimensions and integer pixel coordinates are retained, including images larger than 1536 px. There is no resizing, warping, diffusion, or replacement of image content.

The independent filter uses overlapping 256×256 FFT tiles, hop 128, reflected padding, a Hann analysis/synthesis window, and normalized overlap-add. A soft radial attenuation band covers spatial periods 16–32 pixels, tapering to 12–40 pixels. It modifies luminance with one common integer RGB offset, capped at 3 / 6 / 10 levels out of 255 by strength. Clipping at channel endpoints can affect chroma. This heuristic band is not a recovered SynthID embedding key or a universal watermark inverse.

Vision recognizes text before filtering. Its bounding boxes, padded by four pixels, retain the decoded source pixels exactly. Contrast boundaries are detected by a 3×3 local luminance-range gate at 18+ levels. A distance mask freezes 32 pixels around protected content, then smoothly fades filtering in over the next 64 pixels to avoid halos. A local contrast gate also tapers processing at 5–18 levels. Translucent pixels and alpha are unchanged. A second OCR pass must find every original recognized string in an overlapping box; otherwise the app rejects the result. OCR can miss text, so this does not guarantee protection of all lettering. Weak-contrast textures may change. Protecting original pixels necessarily limits watermark attenuation.

PNG is the default and stores the filtered raster without lossy compression. JPEG is optional and adds compression, so exact pixel bounds and text guarantees apply **before JPEG encoding**. All processing uses decoded SDR sRGB; HDR/wide gamut and original compressed bytes are not retained. Input JPEG/PNG/HEIC/WebP up to 50 MiB and 20 MP, subject to system decoding. EXIF orientation is applied; animation is rejected. JPEG composites transparency on white.

The separate Метаданные mode performs no frequency filtering. Both modes create a fresh image container without copying source EXIF/GPS/XMP/IPTC/C2PA. Metadata removal alone does not remove a pixel watermark.

## Build and checks

On a Mac with Xcode 26.2 and XcodeGen:

```sh
xcodegen generate
xcodebuild build -project Veil.xcodeproj -scheme Veil -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

GitHub Actions independently builds the arm64 device app, runs unit/UI tests, and compiles a macOS diagnostic using the same processor. The diagnostic draws synthetic English/Russian text, runs real Vision OCR before/after processing, checks full resolution, RGB limits, exact protected regions, the raster bridge and PNG round trips, and saves input/output/metrics. Unit tests check synthetic frequency attenuation, tile-boundary continuity, edge preservation, tiny/odd dimensions, alpha, deterministic output, metadata, orientation, export and cancellation. UI tests exercise the actual default pixel-processing path. These checks do not measure SynthID removal or performance on a physical iPhone.

The release workflow publishes an unsigned IPA only after all three jobs pass. Packaging validates arm64, the application bundle, absence of model payloads and ZIP integrity, and supplies SHA-256. External signing or a compatible container is required; no Apple signing keys are stored here.

## Research and history

[Non-generative baseline](docs/research/non-generative-0.5.md) describes scope and evidence. [Detail-preservation audit](docs/research/detail-preservation-2026-10-23.md) explains why SD 2.1 was unsuitable for lettering. [Earlier research](docs/research/README.md) distinguishes metadata, visible logos and invisible watermarks. Historical neural sources, tools and license notices remain for research, excluded from the app and release workflow. They are not evidence of current algorithm efficacy.

No user photographs are uploaded or bundled. CI uses synthetic fixtures. No accounts, analytics or subscriptions. Saving/sharing requires user action; temporary sharing files are removed after dismissal. Independent project, unaffiliated with Google, Apple, OpenAI or removesynthid.io.
