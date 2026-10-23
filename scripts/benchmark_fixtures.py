"""Download pinned public fixtures only; never upload or copy user photographs."""
import hashlib
import json
from pathlib import Path
import urllib.request

output = Path('build/watermark-benchmark/inputs')
output.mkdir(parents=True, exist_ok=True)
bypass = 'https://raw.githubusercontent.com/cebeuq/Synthid-Bypass/c45d3bddc33d71ef925521f65e8ca9439c8a7efa/V1/comparison/before/'
fixtures = [
    ('ai-tomb.png', bypass + '01.png', 'fbcde051b9f73c294dbcea5f3447cc80ab679d9635ae390771c88ba5381034e1', 'upstream_claimed_positive'),
    ('ai-market.png', bypass + '06.png', '704eb16022069918880948014648566e137caac27c37b0ab2559967b31489215', 'upstream_claimed_positive'),
    ('ai-city.png', bypass + '14.png', 'e488ac9fbddc9765a8c3b23c370d3a887f9ce6dc6eb48fe347a28be0289eaff5', 'upstream_claimed_positive'),
    ('camera-fruits.jpg', 'https://raw.githubusercontent.com/opencv/opencv/4ffd42f66ae8e554819d86647753f2cec6380748/samples/data/fruits.jpg',
     '9c031d80a1c52da5eca790db896baffec6a7e52bf786cdb7bbfca5c7f880e6a1', 'historical_camera_control'),
]
manifest = []
for name, url, digest, claim in fixtures:
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(50 * 1024 * 1024 + 1)
    assert len(data) <= 50 * 1024 * 1024
    assert hashlib.sha256(data).hexdigest() == digest, 'Fixture changed: ' + name
    (output / name).write_bytes(data)
    manifest.append(dict(file=name, url=url, sha256=digest, source_claim=claim, official_verdict=None))
    print(name, len(data), digest)
(output / 'sources.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
