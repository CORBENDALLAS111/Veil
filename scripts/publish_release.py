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
body = f'''Фото и видео без генеративной перерисовки, загрузки моделей и отправки файлов на сервер.

- Импорт MOV/MP4 из Фото и Файлов. Покадровый фильтр с защитой распознанного текста; стабилизация небольших изменений между кадрами. Просмотр «до/после», сохранение и экспорт.
- Паттерн: SDR до 4K, экспорт MOV H.264 со сжатием. Исходные тайминги кадров и сжатые аудиопакеты сохраняются; вертикальные ролики поворачиваются в пикселях. Мягкая чёткость и пространственный размер 4K — по выбору.
- Метаданные: перезапись контейнера с исходными видео- и аудиодорожками без перекодирования, включая HDR. Встроенные в кодек метки могут остаться. Неподдерживаемые дорожки вызывают ошибку, а не тихую потерю звука.
- Исправлена избыточная блокировка фотофильтра на детализированных изображениях и ложные отказы экспорта 4K. Распознанный текст проверяется по исходным пикселям до масштабирования и сжатия.
- Фото: PNG/JPEG, исходный размер или аккуратная интерполяция до 4K, Liquid Glass.

**Эффективность против SynthID на фото и видео не подтверждена официальным детектором.** Это экспериментальная обработка, без обещания скрыть AI-происхождение. H.264 меняет пиксели при сжатии; отсутствие мерцания на любом ролике не гарантируется. Масштабирование не восстанавливает утраченные детали.

Нужна iOS 17+. Фото до 20 Мп; видео до 2 ГБ, одна видеодорожка, без субтитров. Для фильтра видео — SDR, не более 3840 px по длинной стороне и 8,294,400 пикселей. HDR поддерживается только в режиме метаданных. Обработку видео держите на экране; скорость, пиковая память и нагрев на физическом iPhone не измерены.

**IPA без подписи: нужна внешняя подпись или совместимый контейнер.**

Проверки: сборка arm64, модульные и UI-тесты, OCR фото и 4K; синтетическое вертикальное видео с переменными таймингами, точные хеши аудиопакетов, сохранение кадров/таймингов/звука, отмена, ориентация и сравнение декодированных кадров. Это проверки качества и целостности, не удаления SynthID. [GitHub Actions](https://github.com/{repo}/actions/runs/{run_id}).

SHA-256 IPA: `{digest}`
'''

release = api(f'/repos/{repo}/releases', {'tag_name': tag, 'target_commitish': sha,
    'name': 'Veil ' + version + ' — фото и видео', 'prerelease': True, 'draft': True, 'body': body})
for path in [ipa, root / 'build/artifacts/SHA256SUMS.txt']:
    data = path.read_bytes()
    asset = api(release['upload_url'].split('{', 1)[0] + '?name=' + path.name, data)
    assert asset['state'] == 'uploaded' and asset['size'] == len(data)
    if asset.get('digest'):
        assert asset['digest'] == 'sha256:' + hashlib.sha256(data).hexdigest()
release = api(f'/repos/{repo}/releases/{release["id"]}', {'draft': False}, method='PATCH')
print(release['html_url'])
