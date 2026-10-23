"""Build matching FP32 SD2.1 VAE models; never execute remote model code or pickle."""
import hashlib
import json
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUNDLE = ROOT / 'Sources/Neural/BundledVAE'
VERSION = 'sd21-4e63672-fp32-coreml9-v1'
REPO = 'sd2-community/stable-diffusion-2-1-base'
REVISION = '4e63672c03103b6c636b8fb4119ba982469b2955'


def convert():
    import numpy as np
    import torch
    import coremltools as ct
    from diffusers import AutoencoderKL
    from diffusers.models.attention_processor import AttnProcessor

    torch.set_num_threads(3)
    vae = AutoencoderKL.from_pretrained(REPO, subfolder='vae', revision=REVISION,
                                      use_safetensors=True, torch_dtype=torch.float32).eval()
    vae.requires_grad_(False)
    vae.set_attn_processor(AttnProcessor())

    class Encoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = vae.encoder
            self.quant = vae.quant_conv

        def forward(self, image):
            return self.quant(self.encoder(image))

    class Decoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.post = vae.post_quant_conv
            self.decoder = vae.decoder

        def forward(self, latent):
            return self.decoder(self.post(latent))

    # Establish the PyTorch reference before conversion.
    from PIL import Image
    y, x = np.mgrid[:512, :512]
    rgb = np.stack([40 + x // 4, 40 + y // 4, 80 + 2 * ((x + y) % 2 == 0)], axis=-1).astype(np.uint8)
    sample = torch.from_numpy(rgb.transpose(2, 0, 1).copy()).unsqueeze(0).float() / 127.5 - 1
    with torch.no_grad():
        moments = Encoder()(sample)
        decoded = Decoder()(moments[:, :4])
    restored = ((decoded[0].permute(1, 2, 0).numpy() + 1) * 127.5).clip(0, 255).round().astype(np.uint8)
    error = np.abs(restored.astype(float) - rgb.astype(float)).mean()
    print('PyTorch VAE reconstruction MAE', error, flush=True)
    if not np.isfinite(error) or error >= 12:
        raise RuntimeError('Source VAE failed reconstruction quality')
    (ROOT / 'build').mkdir(exist_ok=True)
    Image.fromarray(restored).save(ROOT / 'build/vae-pytorch-reference.png')

    for name, model, shape, output in [('VAEEncoder', Encoder(), (1, 3, 512, 512), 'latent'),
                                        ('VAEDecoder', Decoder(), (1, 4, 64, 64), 'image')]:
        print('Converting', name, 'FP32', flush=True)
        with torch.no_grad():
            traced = torch.jit.trace(model.eval(), torch.zeros(shape), check_trace=False)
        converted = ct.convert(traced, convert_to='mlprogram',
                               inputs=[ct.TensorType(name='z', shape=shape, dtype=np.float32)],
                               outputs=[ct.TensorType(name=output, dtype=np.float32)],
                               compute_precision=ct.precision.FLOAT32,
                               minimum_deployment_target=ct.target.iOS17)
        converted.author = 'Veil conversion; Stability AI SD2.1 VAE'
        converted.license = 'CreativeML Open RAIL++-M'
        converted.short_description = 'SD2.1 VAE, FP32 inference, pinned safetensors source ' + REVISION
        package = ROOT / ('build/' + name + '.mlpackage')
        converted.save(str(package))
        compiled = pathlib.Path(ct.models.utils.compile_model(str(package)))
        target = BUNDLE / (name + '.mlmodelc')
        if target.exists():
            assert target.resolve().is_relative_to(BUNDLE.resolve())
            shutil.rmtree(target)
        shutil.copytree(compiled, target)
    (BUNDLE / 'version.txt').write_text(VERSION)


if __name__ == '__main__':
    BUNDLE.mkdir(parents=True, exist_ok=True)
    if not (BUNDLE / 'version.txt').exists() or (BUNDLE / 'version.txt').read_text() != VERSION:
        convert()
    manifest_path = ROOT / 'Sources/Neural/NeuralManifest.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['files'] = [x for x in manifest['files'] if x.get('url') and not x['path'].startswith(('VAEEncoder.', 'VAEDecoder.'))]
    for file in sorted(BUNDLE.rglob('*')):
        if not file.is_file() or file.name in ('version.txt', '.gitkeep'):
            continue
        relative = file.relative_to(BUNDLE).as_posix()
        manifest['files'] = [x for x in manifest['files'] if x['path'] != relative]
        manifest['files'].append({'path': relative, 'bundledPath': 'BundledVAE/' + relative,
                                  'bytes': file.stat().st_size,
                                  'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
    signature = hashlib.sha256(json.dumps(manifest['files'], sort_keys=True).encode()).hexdigest()[:12]
    manifest['id'] = 'apple-sd21-fp32-vae-' + signature
    manifest['totalBytes'] = sum(x['bytes'] for x in manifest['files'] if x.get('url'))
    manifest['vaeSource'] = REPO + '@' + REVISION
    manifest['vaeConversion'] = VERSION
    text = json.dumps(manifest, indent=2) + '\n'
    manifest_path.write_text(text)
    (ROOT / 'build/NeuralManifest.json').write_text(text)
    print('Prepared', manifest['id'], 'remote bytes', manifest['totalBytes'], flush=True)
