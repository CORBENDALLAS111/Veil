# Veil

Native iOS photo processing with SwiftUI and local Core ML image regeneration. Russian interface, iOS 17+, Liquid Glass on iOS 26+, light/dark appearance.

Version 0.3 adds a real neural engine: Apple SD 2.1 palettized denoiser and a matching FP32 VAE, VAE encode в†’ latent noise в†’ diffusion denoising в†’ VAE decode. It uses Apple's pinned Swift pipeline with reduced-memory loading. It does not upload photographs or run a web wrapper.

**SynthID removal is experimental and has not been independently measured.** Neural regeneration may weaken an embedded watermark but can change faces, lettering and textures. The app never presents completion as a negative SynthID detection. No generic AI-classifier score is used as proof.

## Offline delivery (0.4)

All model components ship inside the IPA: matching FP32 VAE, palettized Text Encoder and UNet, merges and vocabulary. Runtime download size is zero. The store verifies bundled bytes and SHA-256 once per process and returns the read-only model directory inside the application bundle. It does not duplicate 1.3 GB of models into Application Support or create a download session. No network connection is required after IPA installation. The first processing button says Process, not Download. The legacy native background downloader remains available in source for non-bundled manifests.

`prepare_vae.py` prepares the pinned FP32 codec; `bundle_models.py` verifies and embeds the remaining pinned files, reusing validated CI model files where available. Packaging rejects manifests with any remote model file. CI runs the actual engine against the bundled model directory, checks that the offline store creates no download storage/session, and tests the native interface.

## Use

Choose a photo в†’ Neural в†’ download the model once в†’ Process в†’ compare в†’ save or share a new file. The original is not overwritten.

The app includes the full model (about 1.3 GB uncompressed), including a matching full-precision VAE. All files use pinned revisions, expected byte lengths and SHA-256. A device with at least 8 GB RAM is required for neural processing; actual app memory limits vary.

Three neural strengths: 0.12, 0.20 and 0.30 on a 50-step DPM schedule. An empty prompt and guidance 1 reduce prompt-driven changes. Processing uses overlapping 512Г—512 tiles, with weighted blending. All RGB pixels come from regenerated tiles; original detail is not pasted back. Alpha is retained. The working image is reduced proportionally to a maximum long side of **1536 pixels** and exported at that size; it is not upscaled to pretend to retain the original resolution. Cancel is checked between steps/tiles.

The separate **Metadata** mode requires no model and applies no noise filter. Both modes reconstruct the PNG/JPEG container without copying source EXIF/GPS/XMP/IPTC/C2PA. This cleanup does not by itself remove a watermark in pixels.

JPEG, PNG, HEIC and WebP accepted, subject to system decoding; input up to 50 MiB and 20 MP. Animated images rejected. EXIF orientation is applied. PNG retains transparency; JPEG composites on white. Output is SDR sRGB, not original HDR/wide gamut.

## Build and verification

GitHub Actions prepares the codec, verifies it, and then builds the app. For a local Mac build, install Xcode 26.2+, XcodeGen and the pinned Python dependencies from the workflow, then:

```sh
python3 scripts/prepare_vae.py
xcodegen generate
open Veil.xcodeproj
```

The app pins `apple-aiml-research/ml-stable-diffusion` at `ea2805dc1945be20561c77e5f6d1d9a5a637cda2`. Remote models are pinned at `dca5f2fda9c5143c71aded72bbb4ce39f3c2cc9c`. The matching VAE source is the safetensors-only `sd2-community/stable-diffusion-2-1-base` revision `4e63672c03103b6c636b8fb4119ba982469b2955`. `scripts/prepare_vae.py` converts encoder and decoder in FP32 with Core ML Tools 9.0, verifies the source reconstruction in PyTorch, and generates the final file manifest. Each bundled and remote file is verified by SHA-256 before use. Large model files are build artifacts rather than Git files.

CI builds the arm64 device IPA, runs unit and native UI tests, and runs the actual downloaded Core ML model on an asymmetric synthetic image through the same neural engine. The smoke check verifies VAE reconstruction and real gentle/balanced diffusion, exports input/output PNGs and MAE/PSNR/runtime metrics, and rejects missing, unchanged or grossly distorted outputs. The app also rejects results that lose source structure or undergo excessive color changes. This is **not a SynthID efficacy test** and runs on a Mac, not a physical iPhone. UI flow tests check the neural preparation screen and select metadata mode for export to avoid downloading gigabytes into each simulator. Tiling tests verify full coverage, no seams in identity reconstruction, alpha preservation and no accidental original-RGB restoration.

The unsigned IPA requires external signing or a compatible container such as LiveContainer. The FP32 VAE is bundled in the IPA; remaining model files download separately. No Apple signing keys are stored here.

## Evidence and limitations

[Research review, 2026-10-22](docs/research/README.md) audits papers, repository implementations, limited OpenAI/Google results and native feasibility. The current engine is an independent SD 2.1 regeneration baseline. It is not MarkNull, the website's private engine, or a copied Qwen/CUDA workflow. Published results from those methods do not establish a removal rate for this implementation.

The old Core Image/Haar filter remains as a legacy test reference; the version 0.3 UI uses neural regeneration or metadata cleanup. Unit tests of that filter are not evidence of watermark removal.

[Google SynthID Detector](https://synthid.com/) can be opened from the app without sending a file automatically. A negative result is limited to that check and does not prove that an image is human-created or free of other provenance signals. Errors and timeouts are not negative detections.

## Licenses and privacy

Apple Swift pipeline: MIT; the license text is bundled. Swift Transformers: Apache 2.0; the license text is bundled. Model weights: the CreativeML Open RAIL++-M text is bundled; see [Apple model card and OpenRAIL++ terms](https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized). Library and weight licenses are separate.

No accounts, subscriptions, analytics or server photo processing. Networking downloads model files only. User photos are not bundled or uploaded by CI; tests use synthetic artwork. Photos export and sharing require a user action. Temporary share files are removed after dismissal.

Independent project; not affiliated with Google, Apple, OpenAI or removesynthid.io.

The original precompiled FP16 codec did not pass reconstruction on the CI machine. It is not used in the released neural mode. The VAE now runs with CPU/GPU compute and full precision; the iPhone denoiser uses the Neural Engine with reduced-memory loading. No physical iPhone performance or SynthID success rate has been measured by CI.
