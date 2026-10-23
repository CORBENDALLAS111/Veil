# Version 0.6: response to visible softening

The user observed that version 0.5's spectral attenuation made photos look soft. Its amplitude notch has been replaced with bounded phase rotations. This preserves analysis-bin magnitudes, although overlap, masks and hard pixel limits can still change final image energy. A local gradient-energy check therefore rolls back softened areas. Strong edges and recognized text keep their source pixels before optional scaling. This improves the quality objective; it does not establish improved SynthID removal.

The broader band is a hypothesis, not an identified watermark channel. No official detector was queried and no removal percentage is claimed. Protected regions can retain SynthID. The revised phase parameters require detector-based evaluation before any efficacy comparison with 0.5 is possible.

Optional clarity is limited to one RGB level with a small-radius noise-cored detail adjustment and no smoothing. Optional 4K uses monotone interpolation and area reduction. [Apple documents Lanczos ringing near high-frequency edges and an interpolation-based alternative](https://developer.apple.com/documentation/accelerate/reducing-artifacts-with-custom-resampling-filters); the implementation here uses an independent shape-preserving cubic method with explicit local bounds. Enlargement is interpolation, not detail recovery.

[MarkSweep](https://arxiv.org/abs/2602.15364) is a learned denoising method evaluated on HiDDeN and Stable Signature; those results are not evidence that this app removes SynthID. It was not substituted for this pipeline. The app stays model-free and does not redraw content.

Evidence is limited to known synthetic signals, bounded changes, local energy retention, real English/Russian OCR before/after 4K processing, monotonicity/alpha tests and native UI checks. Quality should still be checked on each output; a perceptual metric cannot guarantee intact fine textures.
