"""Publish only after the workflow's native download, neural and iOS checks pass."""
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
body = f'''Вся нейросеть встроена в IPA. После установки приложение работает без интернета и без отдельной загрузки модели.

- Все компоненты SD 2.1, включая FP32 VAE, Text Encoder, UNet и токенизатор, включены в приложение.
- Модели читаются прямо из приложения: дополнительная копия на 1,3 ГБ не создаётся.
- Нейрообработка Core ML, очистка метаданных, сравнение и экспорт PNG/JPEG. Liquid Glass на iOS 26.

Нужны iOS 17+ и 8 ГБ RAM для нейрорежима. Фото остаются на устройстве. Нейрообработка может менять мелкие детали и ограничена длинной стороной 1536 px.

**IPA без подписи: нужна внешняя подпись или совместимый контейнер. Удаление SynthID официальным детектором не подтверждено.**

Проверки: наличие и SHA-256 всех моделей внутри IPA, ноль внешних файлов в итоговом манифесте, реальная обработка Core ML из встроенных ресурсов, модульные и UI-тесты. [GitHub Actions](https://github.com/{repo}/actions/runs/{run_id}). Производительность на физическом iPhone пока не измерена.

SHA-256 IPA: `{digest}`
'''

release = api(f'/repos/{repo}/releases', {'tag_name': tag, 'target_commitish': sha,
    'name': 'Veil ' + version + ' — вся модель внутри', 'prerelease': True, 'draft': True, 'body': body})
for path in [ipa, root / 'build/artifacts/SHA256SUMS.txt', root / 'Sources/Licenses/SD2.1-OpenRAIL.txt']:
    data = path.read_bytes()
    asset = api(release['upload_url'].split('{', 1)[0] + '?name=' + path.name, data)
    assert asset['state'] == 'uploaded' and asset['size'] == len(data)
    if asset.get('digest'):
        assert asset['digest'] == 'sha256:' + hashlib.sha256(data).hexdigest()
release = api(f'/repos/{repo}/releases/{release["id"]}', {'draft': False}, method='PATCH')
print(release['html_url'])
