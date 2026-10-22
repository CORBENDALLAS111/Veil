# Veil

A small native iOS photo studio for experimental processing of invisible noise and frequency patterns. SwiftUI, Core Image and ImageIO. iOS 17+. Russian interface. No accounts, subscriptions, analytics, network processing or third-party dependencies.

**This version does not provide verified SynthID removal.** It has no SynthID encoder, decoder or detector. Generic denoising may leave the watermark intact. A completed processing operation is never presented as a negative SynthID detection. Verify exported files independently at [Google's detector](https://synthid.com/). No success rate has been measured.

## Use

Choose a photo from Photos or Files → choose Gentle, Balanced or Strong → Process → compare with the divider → save a new photo or share the file. Export PNG or JPEG. The original is never overwritten.

JPEG, PNG, HEIC and WebP are accepted, subject to system decoder availability. Maximum 50 MiB / 20 megapixels. Animated images are rejected. EXIF orientation is baked in; output dimensions are preserved. PNG retains alpha; JPEG composites on white. Output is SDR sRGB, not HDR or original wide gamut.

## Processing, precisely

1. Validate the encoded container's size, dimensions, format and frame count before decoding.
2. Decode and apply orientation with Core Image, rendering in sRGB.
3. Apply edge-preserving `CINoiseReduction`.
4. Render straight color, apply a two-level separable orthonormal Haar transform to each RGB channel and firm-shrink small detail coefficients. Invert the transform, preserving alpha. This is a **generic frequency/noise filter**, not an implementation of Google's watermark mechanism.
5. Build a fresh PNG or 97%-quality JPEG container without copying source EXIF/GPS/XMP/IPTC/C2PA data. This metadata cleanup is separate from the pixel processing.

Work runs in a dedicated actor with cooperative cancellation. Preview images are limited to 1400 pixels; exports use the full accepted resolution. No real or simulated detection scores are displayed. Strong processing can alter textures; changing settings invalidates the previous result.

## Relation to removesynthid.io

The requested reference is [removesynthid.io](https://removesynthid.io/). Its publicly served client, inspected on 2026-10-22, routes SynthID processing through server operations/upload/premium endpoints. Its separate browser C2PA path reconstructs the file and strips metadata. The server algorithm is not disclosed by those scripts; this project does not copy it, call private endpoints, bypass its authentication, or claim equivalent efficacy. Its FAQ describes removal as best effort. Veil is an independent implementation of generic local pixel processing, with explicit limitations.

Google describes SynthID as robust to ordinary edits: [official overview](https://deepmind.google/models/synthid/). Research on neural regeneration and latent-space attacks should not be confused with this lightweight filter: [MarkNull](https://arxiv.org/abs/2608.10166). That model is not included in Veil.

## Build

On a Mac with Xcode 26.2+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open Veil.xcodeproj
```

Select your signing team in Xcode for installation on a normal device. CI builds without Apple signing credentials and packages an **unsigned arm64 IPA**. It requires a compatible container such as LiveContainer or external signing; it cannot be installed directly through Files. No signing keys are stored in this repository.

Every push to `main` runs unit tests, a native UI flow in an iPhone simulator, screenshot export, and a Release device build. Download `Veil-unsigned-IPA` from the Actions run; the ZIP contains the IPA and a SHA-256 checksum. Tests cover transform reconstruction, signal suppression, edge/alpha preservation, corrupt inputs, EXIF orientation, metadata exclusion, JPEG output, cancellation, and the native process/compare/reset flow. **These tests do not measure SynthID removal.**

## Privacy

User photos are not bundled. CI uses synthetic generated artwork. Sharing and Photos export happen only after a user action. The detector link opens a browser without automatically sending a photo. Temporary share files are deleted after dismissal; originals and working images live in memory. No browser wrapper or remote processing service is embedded.

Independent project; not affiliated with Google or removesynthid.io.
