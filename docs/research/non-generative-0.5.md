# Non-generative release 0.5

The user rejected diffusion because it corrupted fine details and text, and requested a solution without redrawing. Version 0.5 removes SD 2.1 and every model download from the shipped application.

The selected baseline is independent bounded spectral attenuation, not an assertion of proven SynthID removal. The reviewed satiricalguru and wiltodelta projects motivated investigation of a 16–32 px frequency band. No project code was copied. Resizing, geometric distortions, lossy intermediate encoding, diffusion and restoration-by-redrawing are absent.

Apple system APIs: [complex two-dimensional FFT](https://developer.apple.com/documentation/accelerate/vdsp_fft2d_zip) and [Vision text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest). The filter operates on original-resolution decoded luminance; overlapping windows and a streaming row buffer limit extra memory. It protects OCR rectangles, strong local edges and translucent pixels. Full parameters and limitations are in the root README.

Quality checks use synthetic known signals and drawn lettering. A signal-energy check verifies attenuation of the selected band. This is an implementation check, not a watermark-removal benchmark: real SynthID may occupy different bands, contain redundancy, survive bounded filtering, or remain intact in protected areas. No detector result, removal percentage or success guarantee is inferred from these tests. Physical iPhone performance and detector efficacy require separate observation.

The source raster is decoded SDR sRGB, so exact preservation means equality to that raster, not to source JPEG bytes, HDR, or a wide-gamut original. PNG preserves the output raster; JPEG can introduce further changes after protection/OCR checks.
