"""Create a local review page and an explicitly unverified detector ledger."""
import csv
import html
import json
from pathlib import Path

root = Path('build/watermark-benchmark/outputs')
rows = json.loads((root / 'results.json').read_text())
esc = lambda value: html.escape(str(value), quote=True)
with (root / 'detector-results.csv').open('w', newline='', encoding='utf-8') as stream:
    writer = csv.writer(stream)
    writer.writerow(['source', 'variant', 'original_file', 'output_file', 'input_sha256', 'output_sha256',
                     'official_original_verdict', 'official_output_verdict', 'detector', 'evidence'])
    for row in rows:
        writer.writerow([row['source'], row['variant'], row['original'], row['output'] if row['status'] == 'produced' else '',
                         row['inputSHA256'], row.get('outputSHA256', ''), 'NOT_TESTED', 'NOT_TESTED', '', ''])

parts = ['''<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Veil — проверка до / после</title><style>
body{font:16px system-ui;max-width:1200px;margin:32px auto;padding:0 20px;background:#101312;color:#edf3ef}
h1,h2{font-weight:550}p{line-height:1.6}small{color:#b5c0b9}article{margin:24px 0;padding:20px;background:#1b211e;border-radius:20px}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}img{width:100%;max-height:650px;object-fit:contain;background:#080b09;border-radius:8px}
table{border-collapse:collapse;font-size:14px}td,th{text-align:left;padding:8px;border-bottom:1px solid #424a45}
summary{cursor:pointer;padding:12px 0}a{color:#acd6ba}.notice{padding:16px;border:1px solid #d3a656;border-radius:12px}
@media(max-width:650px){.pair{grid-template-columns:1fr}}
</style><h1>Veil: до и после</h1>
<p class="notice">SynthID пока НЕ ПРОВЕРЕН. Это проверка качества и подготовка файлов для официального детектора.
PSNR, сохранность текста и естественный вид не доказывают удаление метки.</p>
<p>Исходник и каждый результат нужно проверить одним детектором. Исходник должен определяться как положительный.
Тайм-аут, ошибка, отсутствие метаданных и сомнительный ответ не считаются успешным удалением.</p>''']
for source in sorted({row['source'] for row in rows}):
    parts.append('<h2>' + esc(source) + '</h2>')
    for row in [r for r in rows if r['source'] == source]:
        parts.append('<article><h3>' + esc(row['variant']) + '</h3>')
        if row['status'] != 'produced':
            parts.append('<p>Обработка отклонена: ' + esc(row.get('error', '')) + '</p></article>')
            continue
        parts.append('<div class="pair"><div><p>Исходник</p><a href="' + esc(row['original']) + '"><img src="' + esc(row['original']) + '"></a></div>'
                     '<div><p>Результат</p><a href="' + esc(row['output']) + '"><img src="' + esc(row['output']) + '"></a></div></div>')
        parts.append('<p>' + esc(row['width']) + ' × ' + esc(row['height']) + ' · ' + esc(round(row.get('seconds', 0), 2)) + ' с</p>')
        parts.append('<details><summary>Измерения качества</summary><table>')
        for key, value in row.get('quality', {}).items():
            if isinstance(value, float): value = round(value, 6)
            parts.append('<tr><th>' + esc(key) + '</th><td>' + esc(value) + '</td></tr>')
        parts.append('</table><p>OCR исходника: ' + esc(' | '.join(row.get('sourceText', []))) + '</p><p>OCR результата: ' + esc(' | '.join(row.get('outputText', []))) + '</p></details></article>')
parts.append('<p><a href="detector-results.csv">Таблица для фиксации результатов детектора</a> · <a href="results.json">Все измерения</a></p></html>')
(root / 'index.html').write_text('\n'.join(parts), encoding='utf-8')
for row in rows:
    quality = row.get('quality', {})
    print(row['source'], row['variant'], row['status'], 'changed %:', quality.get('changedPixelPercent', 'resized'),
          'PSNR:', quality.get('PSNR_dB', 'n/a'), 'text changed:', quality.get('protectedTextChangedPixels', 'n/a'))
