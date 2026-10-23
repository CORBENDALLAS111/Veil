"""Include every pinned model file in the IPA; no runtime download is required."""
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request

root = Path(__file__).resolve().parent.parent
manifest_path = root / 'Sources/Neural/NeuralManifest.json'
manifest = json.loads(manifest_path.read_text())
bundle = root / 'Sources/Neural/BundledVAE'
cached = root / 'build/neural-model' / manifest['id']

def valid(path, entry):
    if not path.is_file() or path.stat().st_size != entry['bytes']:
        return False
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() == entry['sha256']

for entry in manifest['files']:
    destination = bundle / entry['path']
    assert destination.resolve().is_relative_to(bundle.resolve())
    if entry.get('url'):
        destination.parent.mkdir(parents=True, exist_ok=True)
        source = cached / entry['path']
        if valid(source, entry):
            shutil.copyfile(source, destination)
        elif not valid(destination, entry):
            request = urllib.request.Request(entry['url'] + '?download=true', headers={'User-Agent': 'Veil-model-bundle'})
            with urllib.request.urlopen(request, timeout=120) as response, destination.open('wb') as output:
                shutil.copyfileobj(response, output)
    assert valid(destination, entry), 'Bundled model hash mismatch: ' + entry['path']
    entry.pop('url', None)
    entry['bundledPath'] = 'BundledVAE/' + entry['path']
manifest['totalBytes'] = 0
manifest['delivery'] = 'fully-bundled-offline'
manifest['id'] = 'apple-sd21-offline-' + hashlib.sha256(json.dumps(manifest['files'], sort_keys=True).encode()).hexdigest()[:12]
text = json.dumps(manifest, indent=2) + '\n'
manifest_path.write_text(text)
(root / 'build/NeuralManifest.json').write_text(text)
print('All models bundled:', sum(e['bytes'] for e in manifest['files']), 'bytes; runtime download: 0 bytes', flush=True)
