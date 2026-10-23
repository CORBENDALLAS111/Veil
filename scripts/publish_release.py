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
body = f'''Обновление для сохранения деталей: без генеративной перерисовки, скачивания моделей и отправки фото на сервер.

- Вместо приглушения частот — ограниченное изменение фазы с сохранением спектральных амплитуд каждого блока. Экспериментальное ослабление скрытого паттерна; эффективность против SynthID не подтверждена.
- Проверка детализации по участкам: изменения ослабляются там, где падает энергия градиентов. Распознанный текст и резкие границы защищены; повторная проверка текста до экспорта.
- Отдельная мягкая чёткость: изменение не более одного уровня RGB, без сильного шарпинга и шумоподавления.
- Выбор исходного размера или 4K: 3840 px по длинной стороне, пропорции сохраняются. Монотонная интерполяция при увеличении; усреднение площади при уменьшении. Масштабирование не восстанавливает утраченные детали.
- PNG без потерь, JPEG со сжатием, очистка исходных метаданных, сравнение и Liquid Glass.

Нужна iOS 17+, входные фото до 20 Мп, обработка SDR sRGB. **IPA без подписи: нужна внешняя подпись или совместимый контейнер.** SynthID может сохраниться, особенно в защищённых областях. Эффективность против официального детектора и производительность на физическом iPhone не измерены.

Проверки: модульные и UI-тесты, реальный OCR английского и русского текста в исходном и 4K-размере, отсутствие выбросов при масштабировании, прозрачность и ограничение изменений. [GitHub Actions](https://github.com/{repo}/actions/runs/{run_id}).

SHA-256 IPA: `{digest}`
'''

release = api(f'/repos/{repo}/releases', {'tag_name': tag, 'target_commitish': sha,
    'name': 'Veil ' + version + ' — детали и 4K', 'prerelease': True, 'draft': True, 'body': body})
for path in [ipa, root / 'build/artifacts/SHA256SUMS.txt']:
    data = path.read_bytes()
    asset = api(release['upload_url'].split('{', 1)[0] + '?name=' + path.name, data)
    assert asset['state'] == 'uploaded' and asset['size'] == len(data)
    if asset.get('digest'):
        assert asset['digest'] == 'sha256:' + hashlib.sha256(data).hexdigest()
release = api(f'/repos/{repo}/releases/{release["id"]}', {'draft': False}, method='PATCH')
print(release['html_url'])
