# Veil

Native iOS photo processing with SwiftUI and local Core ML image regeneration. Russian interface, iOS 17+, Liquid Glass on iOS 26+, light/dark appearance.

Version 0.3 adds a real neural engine: Apple SD 2.1 palettized, VAE encode → latent noise → diffusion denoising → VAE decode. It uses Apple's pinned Swift pipeline with reduced-memory loading. It does not upload photographs or run a web wrapper.

**SynthID removal is experimental and has not been independently measured.** Neural regeneration may weaken an embedded watermark but can change faces, lettering and textures. The app never presents completion as a negative SynthID detection. No generic AI-classifier score is used as proof.

## Use

Choose a photo → Neural → download the model once → Process → compare → save or share a new file. The original is not overwritten.

The first download is **1,141,368,596 bytes (1.14 GB)** from Apple's Hugging Face repository. Every file uses a pinned revision, expected byte length and SHA-256. Completed files survive a cancelled download; incomplete installations are never loaded. Models stay in Application Support and are excluded from iCloud backup. After installation, photo processing works offline. A device with at least 6 GB RAM is required for neural download; actual app memory limits vary.

Three neural strengths: 0.12, 0.20 and 0.30 on a 50-step DPM schedule. An empty prompt and guidance 1 reduce prompt-driven changes. Processing uses overlapping 512×512 tiles, with weighted blending. All RGB pixels come from regenerated tiles; original detail is not pasted back. Alpha is retained. The working image is reduced proportionally to a maximum long side of **1536 pixels** and exported at that size; it is not upscaled to pretend to retain the original resolution. Cancel is checked between steps/tiles.

The separate **Metadata** mode requires no model and applies no noise filter. Both modes reconstruct the PNG/JPEG container without copying source EXIF/GPS/XMP/IPTC/C2PA. This cleanup does not by itself remove a watermark in pixels.

JPEG, PNG, HEIC and WebP accepted, subject to system decoding; input up to 50 MiB and 20 MP. Animated images rejected. EXIF orientation is applied. PNG retains transparency; JPEG composites on white. Output is SDR sRGB, not original HDR/wide gamut.

## Build and verification

On a Mac with Xcode 26.2+ and XcodeGen:

```sh
xcodegen generate
open Veil.xcodeproj
```

The app pins `apple-aiml-research/ml-stable-diffusion` at `ea2805dc1945be20561c77e5f6d1d9a5a637cda2`. Models are pinned at `dca5f2fda9c5143c71aded72bbb4ce39f3c2cc9c` in `Sources/Neural/NeuralManifest.json`.

CI builds the arm64 device IPA, runs unit and native UI tests, and runs the actual downloaded Core ML model on an asymmetric synthetic image through the same neural engine. The smoke check exports input/output PNGs and MAE/PSNR/runtime metrics; it rejects missing, unchanged or grossly distorted outputs. This is **not a SynthID efficacy test** and runs on a Mac, not a physical iPhone. UI flow tests explicitly select metadata mode to avoid downloading gigabytes into each simulator. Tiling tests verify full coverage, no seams in identity reconstruction, alpha preservation and no accidental original-RGB restoration.

The unsigned IPA requires external signing or a compatible container such as LiveContainer. Model weights are not bundled in the IPA. No Apple signing keys are stored here.

## Evidence and limitations

[Research review, 2026-10-22](docs/research/README.md) audits papers, repository implementations, limited OpenAI/Google results and native feasibility. The current engine is an independent SD 2.1 regeneration baseline. It is not MarkNull, the website's private engine, or a copied Qwen/CUDA workflow. Published results from those methods do not establish a removal rate for this implementation.

The old Core Image/Haar filter remains as a legacy test reference; the version 0.3 UI uses neural regeneration or metadata cleanup. Unit tests of that filter are not evidence of watermark removal.

[Google SynthID Detector](https://synthid.com/) can be opened from the app without sending a file automatically. A negative result is limited to that check and does not prove that an image is human-created or free of other provenance signals. Errors and timeouts are not negative detections.

## Licenses and privacy

Apple Swift pipeline: MIT; the license text is bundled. Swift Transformers: Apache 2.0; the license text is bundled. Model weights: see [Apple model card and OpenRAIL++ terms](https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized). Library and weight licenses are separate.

No accounts, subscriptions, analytics or server photo processing. Networking downloads model files only. User photos are not bundled or uploaded by CI; tests use synthetic artwork. Photos export and sharing require a user action. Temporary share files are removed after dismissal.

Independent project; not affiliated with Google, Apple, OpenAI or removesynthid.io.
