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
body = f'''Обработка без генеративной перерисовки. Модель и загрузка больше не нужны: всё работает офлайн.

- Исходное разрешение и геометрия; без уменьшения до 1536 px.
- Мягкий частотный фильтр с ограничением изменения RGB: 3 / 6 / 10 из 255.
- Распознанный текст сохраняется пиксель в пиксель перед экспортом, контрастные границы защищены. Повторная OCR-проверка отклоняет результат, если распознанный текст изменился.
- PNG без потерь, JPEG со сжатием, очистка исходных метаданных, сравнение, Liquid Glass на iOS 26.

Экспериментальный алгоритм. Удаление SynthID официальным детектором не подтверждено; защищённые области могут сохранить скрытый паттерн. Слабоконтрастные текстуры могут измениться. Обработка SDR sRGB, до 20 Мп. Нужна iOS 17+. Проверено на синтетических изображениях и симуляторе; физический iPhone ещё не измерен.

**IPA без подписи: нужна внешняя подпись или совместимый контейнер.**

Проверки: ограничение изменений, неизменность текстовых областей, реальные OCR-проверки, частотный тест, PNG, прозрачность, ориентация, отмена, модульные и UI-тесты. [GitHub Actions](https://github.com/{repo}/actions/runs/{run_id}).

SHA-256 IPA: `{digest}`
'''

release = api(f'/repos/{repo}/releases', {'tag_name': tag, 'target_commitish': sha,
    'name': 'Veil ' + version + ' — без перерисовки', 'prerelease': True, 'draft': True, 'body': body})
for path in [ipa, root / 'build/artifacts/SHA256SUMS.txt']:
    data = path.read_bytes()
    asset = api(release['upload_url'].split('{', 1)[0] + '?name=' + path.name, data)
    assert asset['state'] == 'uploaded' and asset['size'] == len(data)
    if asset.get('digest'):
        assert asset['digest'] == 'sha256:' + hashlib.sha256(data).hexdigest()
release = api(f'/repos/{repo}/releases/{release["id"]}', {'draft': False}, method='PATCH')
print(release['html_url'])
