# Veil

Native iOS photo and video processing, SwiftUI, iOS 17+, Liquid Glass on iOS 26, Russian interface. Version 0.7 adds file-backed video processing to the bounded non-generative phase filter, detail protection, optional subtle clarity and 4K interpolation. No model downloads, network processing, or generative dependencies are included in the app.

**SynthID removal is experimental and unverified.** Filtering a synthetic signal is not evidence of defeating the official detector. Protected image regions may retain the watermark. The app always displays “SynthID не проверен”.

## Processing

Choose a photo → Паттерн → strength → optional clarity/4K → Обработать → compare → export. Original dimensions and integer pixel coordinates are retained by default, including images larger than 1536 px. No diffusion or generative replacement of content. Output scaling is optional and explicit.

The independent filter uses overlapping 256×256 FFT tiles, hop 128, reflected padding, Hann analysis/synthesis windows and normalized overlap-add. Version 0.5's amplitude attenuation was reported to soften photographs. Version 0.6 rotates conjugate frequency pairs instead, preserving each analysis tile's spectral magnitudes before overlap, masking and clipping. Phase limits are 0.18 / 0.38 / 0.65 radians. A smooth angular phase field is shared across tiles: independent random bin phases were rejected because overlap cancellation softened the test signal. The band covers spatial periods 8–32 pixels, tapering to 6–48 pixels. Luminance changes are capped at 3 / 6 / 10 RGB levels. A common integer RGB offset is further limited to avoid channel clipping. This heuristic is not a recovered SynthID key or a proven universal watermark inverse.

A local detail check compares gradient energy in 64×64 cells. When the candidate loses more than 3% in a cell with source gradient energy above 0.05 per sample, its modifications and nearby cells are rolled back, with a smooth transition. This metric reduces visible softening; it is not a proof of semantic fidelity or watermark removal. Phase changes can still alter weak textures within the limits.

Vision recognizes text before filtering. Its bounding boxes, padded by four pixels, retain the decoded source pixels exactly. Contrast boundaries are detected by a 3×3 local luminance-range gate at 18+ levels. The experimental adaptive branch separates text margins (8 px freeze, feather to 32 px) from contrast-edge margins (2 px freeze, feather to 12 px). A local-contrast budget prevents flat backgrounds from acquiring ringing. A local contrast gate also tapers processing at 5–18 levels. Translucent pixels and alpha are unchanged. SHA-256 digests verify that every padded recognized text region retains its exact decoded source pixels before optional scaling. OCR transcription after scaling is diagnostic rather than a rejection oracle: it can change even when the source lettering is preserved. OCR can miss text, so this does not guarantee protection of all lettering. Weak-contrast textures may change. Protecting original pixels necessarily limits watermark attenuation.

PNG is the default and stores the filtered raster without lossy compression. JPEG is optional and adds compression, so exact pixel bounds and text guarantees apply **before JPEG encoding**. All processing uses decoded SDR sRGB; HDR/wide gamut and original compressed bytes are not retained. Input JPEG/PNG/HEIC/WebP up to 50 MiB and 20 MP, subject to system decoding. EXIF orientation is applied; animation is rejected. JPEG composites transparency on white.

**Мягкая чёткость**, off by default, adds a noise-cored 3×3 micro-contrast adjustment capped at one additional RGB level. Recognized text, alpha, local extrema and high-contrast edges are protected. There is no denoising or strong unsharp mask. The pattern-stage bounds apply before this optional extra adjustment.

**4K** sets the long side to 3840 px while retaining aspect ratio (portrait is supported). Enlargement uses monotone cubic interpolation with harmonic-mean tangents and local range clamping. Reduction uses pixel-area averages. Scaling works on premultiplied colors to avoid transparent-color fringes, with row caching for bounded intermediate memory. No ringing overshoot or new learned details are introduced. Upscaling cannot recover missing information. Exact source-pixel guarantees apply before resizing. The benchmark separately records OCR on the final resized image; interpolation does not establish semantic fidelity or missing-detail recovery.

The separate Метаданные mode performs no frequency filtering. Both modes create a fresh image container without copying source EXIF/GPS/XMP/IPTC/C2PA. Metadata removal alone does not remove a pixel watermark.

## Video

Import MOV/MP4 from Photos or Files, preview before/after, save a new video to Photos or share its file. Imports use a copied file URL rather than loading the movie into a Data object (up to 2 GB). The app processes one decoded frame at a time and interleaves video/audio writes under encoder backpressure. Keep the app open; it prevents auto-lock while working. This is foreground processing, not an iOS background-export service.

Pattern mode accepts a single SDR video track up to 3840 px on the long side and 8,294,400 pixels. It applies the same text-protected phase filter to each upright frame, with optional clarity and 4K interpolation. A fixed phase field avoids random per-frame seeds. A temporal stabilizer averages only the small correction, never source frames: it resets at motion over three luma levels, keeps newly protected pixels unchanged and never exceeds the current correction's sign/magnitude. It reduces correction flicker, but is not an optical-flow model or a guarantee of temporal quality on arbitrary motion. OCR runs on every frame; this can be slow on long or high-resolution clips.

Pattern export is high-bitrate H.264 in MOV, SDR Rec.709, with source presentation timestamps and rotation baked into the pixels. H.264 is lossy, including chroma subsampling: exact protected-pixel guarantees apply **before video encoding**. Odd output dimensions get at most one padded edge pixel, without stretching. No frame-rate conversion or frame interpolation is applied. Optional 4K changes spatial dimensions only.

Metadata mode remuxes original compressed video/audio samples into a new MOV without filtering or re-encoding, including HDR. It clears container/track metadata rather than copying source tags. Codec payloads are passed through, so metadata or watermarks embedded inside those payloads may remain. This is not a complete provenance eraser. Original compressed audio packets are passed through in both modes; unsupported tracks fail instead of silently muting. Captions, multiple video tracks and unreadable assets are rejected. Necessary codec/color/timing data remains. Partial output files are deleted on cancellation/failure; owned imports and results are removed on reset/replacement.

**SynthID removal on video is unverified.** Image watermark heuristics are not evidence against a video detector, which can use temporal information. No visible-logo detector/remover or diffusion regeneration is included. The source review in [video research](docs/research/video-2026-10-24.md) explains the distinction.

## Build and checks

On a Mac with Xcode 26.2 and XcodeGen:

```sh
xcodegen generate
xcodebuild build -project Veil.xcodeproj -scheme Veil -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

GitHub Actions independently builds the arm64 device app, runs unit/UI tests, and compiles a macOS diagnostic using the same processor. The diagnostic draws synthetic English/Russian text, runs real OCR before/after native and 4K processing, checks RGB limits, exact protected regions, the raster bridge and PNG round trips, and saves input/output/metrics. Unit tests check pattern changes without texture-energy loss, tile boundaries, edge preservation, tiny/odd dimensions, monotone scaling without overshoot, area reduction, alpha, clarity limits, metadata, orientation and cancellation. UI tests exercise clarity and actual 4K export. These checks do not measure SynthID removal or performance on a physical iPhone.

The release workflow publishes an unsigned IPA only after the build, pixel, video and simulator jobs pass. Packaging validates arm64, the application bundle, absence of model payloads and ZIP integrity, and supplies SHA-256. External signing or a compatible container is required; no Apple signing keys are stored here.

## Research and history

[Non-generative baseline](docs/research/non-generative-0.5.md) describes scope and evidence. [Detail-preservation audit](docs/research/detail-preservation-2026-10-23.md) explains why SD 2.1 was unsuitable for lettering. [Earlier research](docs/research/README.md) distinguishes metadata, visible logos and invisible watermarks. Historical neural sources, tools and license notices remain for research, excluded from the app and release workflow. They are not evidence of current algorithm efficacy.

No user photographs or videos are uploaded or bundled. Native CI checks use synthetic fixtures; the separately dispatched watermark benchmark uses pinned public images. No accounts, analytics or subscriptions. Saving/sharing requires user action; photo sharing copies are removed after dismissal, and video files remain available until reset/replacement. Independent project, unaffiliated with Google, Apple, OpenAI or removesynthid.io.
