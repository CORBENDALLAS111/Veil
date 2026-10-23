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
body = f'''Фоновая загрузка модели и исправленная индикация прогресса.

- Системная фоновая сессия iOS: все файлы ставятся в очередь заранее; разрешены Wi‑Fi и мобильная сеть.
- Вместо неподвижного «0%» — состояние соединения и точное количество загруженных мегабайт.
- При возвращении в приложение восстанавливается прогресс. Готовые файлы сохраняются и проверяются по SHA‑256.
- Нативная нейрообработка Core ML, очистка метаданных и Liquid Glass.

Можно свернуть приложение или заблокировать экран. Принудительное закрытие смахиванием останавливает фоновые передачи iOS. LiveContainer и другие контейнеры могут ограничивать фоновую работу.

Нужны iOS 17+ и 8 ГБ RAM для нейрорежима; разовая загрузка оставшейся модели около 0,97 ГБ. Фото остаются на устройстве. Нейрообработка может менять мелкие детали и ограничена длинной стороной 1536 px.

**IPA без подписи: нужна внешняя подпись или совместимый контейнер. Удаление SynthID официальным детектором не подтверждено.**

Проверки: сборка arm64, модульные и UI-тесты, реальная обработка Core ML, нативная загрузка с промежуточным прогрессом, отменой/повторным запуском, сохранением готовых файлов и отклонением HTTP/хеш-ошибок; загрузка настоящего закреплённого файла Hugging Face. [GitHub Actions](https://github.com/{repo}/actions/runs/{run_id}). Фоновое поведение на физическом iPhone требует проверки на устройстве.

SHA‑256 IPA: `{digest}`
'''
release = api(f'/repos/{repo}/releases', {'tag_name': tag, 'target_commitish': sha,
    'name': 'Veil ' + version + ' — фоновая загрузка', 'prerelease': True, 'draft': True, 'body': body})
for path in [ipa, root / 'build/artifacts/SHA256SUMS.txt', root / 'Sources/Licenses/SD2.1-OpenRAIL.txt']:
    data = path.read_bytes()
    asset = api(release['upload_url'].split('{', 1)[0] + '?name=' + path.name, data)
    assert asset['state'] == 'uploaded' and asset['size'] == len(data)
    if asset.get('digest'):
        assert asset['digest'] == 'sha256:' + hashlib.sha256(data).hexdigest()
release = api(f'/repos/{repo}/releases/{release["id"]}', {'draft': False}, method='PATCH')
print(release['html_url'])
