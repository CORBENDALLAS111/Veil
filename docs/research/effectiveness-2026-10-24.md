# Native benchmark: coverage, preservation, and unverified SynthID efficacy

## Finding

The 0.6.0 protection mask could prevent almost all processing on detailed images. The adaptive candidate fixes that failure and false 4K rejections. **Neither build has an independently verified SynthID removal result.** A small pixel difference, unchanged text, a quality metric, and successful export are not evidence of watermark removal or human origin.

The candidate keeps the non-generative pipeline. It cannot repair existing invented lettering, anatomy, or other source artifacts without replacing content. Optional 4K interpolation increases dimensions; it does not recover missing detail. Clarity remains optional and off by default.

## Reproducible experiment

The benchmark compiles the app's actual Swift processor on macOS with Swift 6/Xcode 26.2. Four pinned public images are processed in seven variants: metadata-only, gentle, balanced, strong, strong plus clarity, strong plus 4K, and strong JPEG. No personal photographs are uploaded or bundled.

Three sources are Gemini/SynthID examples claimed by the upstream repository, not detector-confirmed positives in this experiment. The fourth is a historical OpenCV photograph used as a quality control, not a detector-confirmed negative. Sources, pinned revisions and SHA-256 checks are in `scripts/benchmark_fixtures.py`. The artifact retains original bytes, output hashes, final OCR, quality metrics, and an empty official-detector ledger.

- [Baseline run](https://github.com/CORBENDALLAS111/Veil/actions/runs/40042295840), processor at `c403ff296ed6dfa0f7d78eaf7a324c6ac543270a` (same processing as 0.6.0).
- [Candidate run](https://github.com/CORBENDALLAS111/Veil/actions/runs/40042912384), `4e9eacce12d0c627433870123ef8612de2fab835`.
- [Native device build, pixel smoke and simulator tests](https://github.com/CORBENDALLAS111/Veil/actions/runs/40042915664), same candidate revision.

## Strong PNG at original dimensions

Changed pixels are percentages of the decoded raster. PSNR compares decoded source/output RGB. Gradient ratio is output/source gradient energy. These measure change and preservation, **not SynthID attenuation**.

| Public source | Baseline changed pixels | Candidate changed pixels | Candidate PSNR | Maximum RGB change | Gradient ratio | Changed pixels in recognized text boxes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| AI tomb | 0% | 6.3285% | 56.67 dB | 5 | 1.000094 | 0 |
| AI market | 3.0091% | 16.2497% | 50.85 dB | 5 | 1.000233 | 0 |
| AI city | 0.0083% | 9.7192% | 54.17 dB | 5 | 1.000054 | 0 |
| Camera fruits | 0.0053% | 23.8517% | 49.66 dB | 5 | 1.001348 | 0 |

The baseline tomb result retained identical decoded source pixels. Pixel-watermark weakening cannot be attributed to that unchanged raster. Metadata-only PNG also retained identical decoded RGB on all three AI examples, independently checked with Pillow.

The candidate produced all 28 outputs. The baseline rejected all three AI 4K variants and the tomb clarity variant because a second OCR transcription changed. The candidate hashes protected source regions before optional interpolation instead. Final OCR is still recorded separately: recognition changes are not interpreted as either proof of glyph damage or proof of semantic fidelity.

## Safeguards and limitations

The candidate separates OCR text margins from contrast-edge margins, retains hard RGB bounds and local gradient rollback, and limits adjustment in low-contrast neighborhoods to avoid halos. Text regions retain exact decoded pixels before resizing and JPEG encoding. OCR can miss lettering; these guarantees do not cover undetected text. JPEG is lossy and changes protected regions during encoding, so PNG is used for exact-pixel comparisons.

The four-image sample is small. Gradient energy does not rule out all local artifacts, and PSNR does not assess natural appearance or provenance. Original image color conversion is SDR sRGB; wide-gamut/HDR retention is outside this experiment. Physical iPhone memory, thermal behavior and runtime are not measured by macOS or simulator runs.

## Official detector protocol still outstanding

1. Check each original in the official SynthID Detector. Only a positive original is an eligible removal test.
2. Check the metadata-only PNG control, then the candidate strong PNG, recording the exact input/output SHA-256 and detector result.
3. Repeat across independent images and relevant providers. A Gemini example does not establish effectiveness on OpenAI watermarks.
4. Report positive-to-negative counts and quality costs separately. An absent watermark does not establish that an image was made by a camera.

Official detection has **not been run**: the browser backend was unavailable and no authenticated official API was available. Every `officialOriginalVerdict` and `officialOutputVerdict` remains null; every `synthIDRemovalVerified` remains false. The public examples' upstream labels are not substituted for detector results.
