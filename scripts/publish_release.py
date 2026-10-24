"""Publish only after the workflow's pixel preservation, OCR and iOS checks pass."""
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.request

root = Path(__file__).resolve().parent.parent
repo = os.environ['GITHUB_REPOSITORY']
sha = os.environ['GITHUB_SHA']
run_id = os.environ['GITHUB_RUN_ID']
version = re.search(r"MARKETING_VERSION: '([^']+)'", (root / 'project.yml').read_text()).group(1)
tag = 'v' + version

def api(path, data=None, method=None):
    raw = data if isinstance(data, bytes) else (json.dumps(data).encode() if data is not None else None)
    request = urllib.request.Request(path if path.startswith('https://') else 'https://api.github.com' + path,
        data=raw, method=method, headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
            'User-Agent': 'Veil-release', 'Accept': 'application/vnd.github+json',
            'Content-Type': 'application/octet-stream' if isinstance(data, bytes) else 'application/json'})
    with urllib.request.urlopen(request, timeout=300) as response:
        content = response.read()
        return json.loads(content) if content else {}

ipa = root / 'build/artifacts/Veil-unsigned.ipa'
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
assert (root / 'build/artifacts/SHA256SUMS.txt').read_text().split()[0] == digest
assert not any(r['tag_name'] == tag for r in api(f'/repos/{repo}/releases')), 'A release with this version already exists; bump the version rather than replacing it'
notes = root / 'docs/releases' / (version + '.md')
assert notes.is_file(), 'Write version-specific release notes before publishing'
body = notes.read_text(encoding='utf-8') + f'''

[Сборка и все проверки GitHub Actions](https://github.com/{repo}/actions/runs/{run_id}).
Исходники сборки: `{sha}`.
SHA-256 IPA: `{digest}`
'''

release = api(f'/repos/{repo}/releases', {'tag_name': tag, 'target_commitish': sha,
    'name': 'Veil ' + version + ' — апскейл видео', 'prerelease': True, 'draft': True, 'body': body})
for path in [ipa, root / 'build/artifacts/SHA256SUMS.txt']:
    data = path.read_bytes()
    asset = api(release['upload_url'].split('{', 1)[0] + '?name=' + path.name, data)
    assert asset['state'] == 'uploaded' and asset['size'] == len(data)
    if asset.get('digest'):
        assert asset['digest'] == 'sha256:' + hashlib.sha256(data).hexdigest()
release = api(f'/repos/{repo}/releases/{release["id"]}', {'draft': False}, method='PATCH')
print(release['html_url'])
