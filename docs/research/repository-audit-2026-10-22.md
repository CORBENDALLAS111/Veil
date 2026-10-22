# Статический аудит открытых проектов удаления SynthID

Дата проверки: 22 октября 2026 года. Цель — выбрать техническую основу для Veil, отдельно оценив настоящий SynthID, вариант OpenAI и перенос на iPhone.

Это чтение исходников и опубликованных результатов. Чужие скрипты и модели не запускались; собственных обращений к детекторам и загрузок пользовательских фотографий не было. «Проверено кодом» ниже означает наличие конкретной реализации. «Автор сообщает» означает внешний результат, который здесь не воспроизводился.

## Вывод

Лучше всего документирован `wiltodelta/remove-ai-watermarks`: в нём есть реальные диффузионные конвейеры, отдельные положительные и отрицательные результаты официальных проверок, история исправлений и честные ограничения. Его нынешний движок требует CUDA. Это хороший серверный исследовательский ориентир, но не готовая библиотека для iOS.

Самая интересная нативная зацепка — `froggeric/gemini-watermark-and-synthid-remover`: там уже написан Core ML конвейер SDXL на Objective-C++. Он работает на Mac, требует около 4,7 ГБ весов, а опубликованная проверка относится к девяти изображениям Google. Работоспособность на iPhone и удаление OpenAI SynthID этим не установлены.

Ни в одном из проверенных проектов не найден убедительно подтверждённый универсальный способ убрать production SynthID лёгким фильтром без заметного изменения изображения. Практически реализованные кандидаты перерисовывают изображение нейросетью. Результат зависит от содержимого, модели, случайного зерна и версии водяного знака.

## Зафиксированные версии

| Проект | Проверенный commit | Статус |
|---|---|---|
| [wiltodelta/remove-ai-watermarks](https://github.com/wiltodelta/remove-ai-watermarks/tree/b5021b0f6872b533f009a2cc50af9726f33e2177) | `b5021b0f6872b533f009a2cc50af9726f33e2177` | Основной проект, Apache-2.0 |
| [hpdkhoa/rw](https://github.com/hpdkhoa/rw/tree/4855586834fe78499f06295ab24d2b3f3a2bf4b9) | `4855586834fe78499f06295ab24d2b3f3a2bf4b9` | Fork предыдущего, Apache-2.0 |
| [mertizci/noai-watermark](https://github.com/mertizci/noai-watermark/tree/9b84a551b70637825e7c39722f5a4c8d95c99af0) | `9b84a551b70637825e7c39722f5a4c8d95c99af0` | Python, MIT |
| [cebeuq/Synthid-Bypass](https://github.com/cebeuq/Synthid-Bypass/tree/c45d3bddc33d71ef925521f65e8ca9439c8a7efa) | `c45d3bddc33d71ef925521f65e8ca9439c8a7efa` | Прежний адрес `00quebec` перенаправляется сюда; LICENSE не найден |
| [froggeric/gemini-watermark-and-synthid-remover](https://github.com/froggeric/gemini-watermark-and-synthid-remover/tree/37f338847c7fcdbaa1ab3f883c6a742173dd9595) | `37f338847c7fcdbaa1ab3f883c6a742173dd9595` | C++/Objective-C++, корневой LICENSE — MIT |

## 1. wiltodelta/remove-ai-watermarks

### Что действительно реализовано

Текущие профили — `qwen-zimage`, `sdxl-zimage`, `chroma-zimage` и маршрутизатор `auto`. Старые `sdxl`, `controlnet`, `qwen`, `default` удалены. Требование CUDA есть в коде, это не просто рекомендация README. Профили используют глобальную регенерацию и общую стадию обработки лиц через Z-Image, YuNet и SAM. [Конфигурация профилей](https://github.com/wiltodelta/remove-ai-watermarks/blob/b5021b0f6872b533f009a2cc50af9726f33e2177/src/remove_ai_watermarks/_internal/watermark_profiles.py), [проверки устройства и лицевая стадия](https://github.com/wiltodelta/remove-ai-watermarks/blob/b5021b0f6872b533f009a2cc50af9726f33e2177/src/remove_ai_watermarks/_internal/two_stage_pipeline.py).

Глобальная Qwen-стадия загружает `Qwen/Qwen-Image-2512`, `DiffSynth-Studio/Qwen-Image-Blockwise-ControlNet-Canny` и Lightning LoRA. SDXL использует `stabilityai/stable-diffusion-xl-base-1.0` и Canny ControlNet; Chroma — `lodestones/Chroma1-HD`. Это набор больших моделей, а не небольшой специализированный фильтр. Порог 64 GiB в Qwen-коде определяет постоянное размещение глобальной модели; его нельзя выдавать за минимально необходимый объём VRAM, поскольку предусмотрена выгрузка компонентов. [Qwen-конвейер](https://github.com/wiltodelta/remove-ai-watermarks/blob/b5021b0f6872b533f009a2cc50af9726f33e2177/src/remove_ai_watermarks/_internal/qwen_zimage_pipeline.py), [Chroma-конвейер](https://github.com/wiltodelta/remove-ai-watermarks/blob/b5021b0f6872b533f009a2cc50af9726f33e2177/src/remove_ai_watermarks/_internal/chroma_zimage_pipeline.py).

### Что известно именно об OpenAI

В техническом журнале есть проверка одного свежего исходника от каждой из двух GPT Image 2.5 моделей: после удаления метаданных официальная API всё ещё обнаруживала SynthID в источниках, а в обработанных выходах не обнаруживала. Авторы прямо ограничивают вывод двумя источниками. Там же описано последующее расширение на шесть `gpt-image-2` исходников. Это заметно сильнее рекламного before/after, но не массовая оценка надёжности. [Технический журнал, раздел 4.2](https://github.com/wiltodelta/remove-ai-watermarks/blob/b5021b0f6872b533f009a2cc50af9726f33e2177/docs/synthid.md#42-openai).

Текущий код фиксирует зерно `0`, OpenAI-порог Qwen `0.15625`, полученный по восьми источникам, а не по большой независимой выборке. Нельзя переносить этот порог на другие модели или объявлять гарантией. [Текущая политика](https://github.com/wiltodelta/remove-ai-watermarks/blob/b5021b0f6872b533f009a2cc50af9726f33e2177/src/remove_ai_watermarks/_internal/watermark_profiles.py).

Проверяющий helper отделяет `type == synthid` от C2PA. Перед запросом он удаляет AI-метаданные и проверяет сохранение декодированных пикселей. Это важная часть эксперимента: исчезновение C2PA не считается исчезновением водяного знака. Однако helper не включён в пользовательскую автоматическую проверку. [Реализация](https://github.com/wiltodelta/remove-ai-watermarks/blob/b5021b0f6872b533f009a2cc50af9726f33e2177/src/remove_ai_watermarks/openai_provenance.py).

### Отрицательные результаты важнее красивых примеров

В архиве автор сообщает, что лёгкие спектральные, геометрические и surrogate-атаки часто убирали локальную оценку, но официальный OpenAI SynthID продолжал обнаруживаться. Зафиксированы отрицательные проверки фиксированных шаблонов Rinne414, градиентов `newideas99`, а также определённого commit DeSynth. Это результаты автора на его контрольных файлах, не наши воспроизведения и не вердикт обо всех будущих версиях этих проектов. [Журнал отрицательных проверок](https://github.com/wiltodelta/remove-ai-watermarks/blob/b5021b0f6872b533f009a2cc50af9726f33e2177/docs/synthid-removal-research.md#closed-quiet-removers).

Имеются противоречащие ранним обобщениям результаты: одни и те же слабые настройки могли пройти на одном содержимом и провалиться на другом; изменение случайного зерна меняло исход. Поэтому современные ограничения и код важнее исторического заголовка «0.05 удаляет OpenAI». [Ограничения](https://github.com/wiltodelta/remove-ai-watermarks/blob/b5021b0f6872b533f009a2cc50af9726f33e2177/docs/known-limitations.md#strength-is-content-and-seed-dependent).

**Оценка для Veil:** основной ориентир для сравнительных серверных экспериментов; прямой перенос нынешнего CUDA/Python/DiffSynth стека в iPhone не подготовлен. Его API не даёт локального универсального подтверждения удаления SynthID.

## 2. hpdkhoa/rw

GitHub API указывает `fork: true`, родитель — `wiltodelta/remove-ai-watermarks`. Проверенный snapshot содержит те же Qwen/Z-Image и SDXL/Z-Image направления и CUDA-ограничение. Дата последнего push snapshot — 13 августа 2026 года, позже основной проект существенно менялся. [Профили fork](https://github.com/hpdkhoa/rw/blob/4855586834fe78499f06295ab24d2b3f3a2bf4b9/src/remove_ai_watermarks/_internal/watermark_profiles.py), [репозиторий и происхождение](https://github.com/hpdkhoa/rw).

**Оценка для Veil:** не отдельное независимое подтверждение работоспособности. Два похожих README нельзя считать двумя исследованиями. При выборе основы предпочтительнее основной проект с более свежими исправлениями и результатами.

## 3. mertizci/noai-watermark

### Реализация

Основной путь — стандартный `StableDiffusionImg2ImgPipeline`; базовая модель `Lykon/dreamshaper-8`, пустой prompt, шум и диффузионное восстановление. Есть CPU, MPS и CUDA, а при ошибке MPS предусмотрен повтор на CPU. Это настоящий нейросетевой конвейер, но обычная desktop Python-реализация. [Загрузка модели](https://github.com/mertizci/noai-watermark/blob/9b84a551b70637825e7c39722f5a4c8d95c99af0/src/watermark_remover.py), [запуск img2img](https://github.com/mertizci/noai-watermark/blob/9b84a551b70637825e7c39722f5a4c8d95c99af0/src/img2img_runner.py).

Альтернативный CtrlRegen использует SD 1.5 Realistic Vision, Canny ControlNet и DINOv2 IP-Adapter, веса `yepengliu/ctrlregen`, отдельный VAE и перекрывающиеся плитки 512 пикселей. Само наличие tiling сохраняет размер выходного изображения, но не доказывает сохранение мельчайших деталей. [CtrlRegen engine](https://github.com/mertizci/noai-watermark/blob/9b84a551b70637825e7c39722f5a4c8d95c99af0/src/ctrlregen/engine.py).

### Доказательства

README предлагает вручную сравнить исходник и результат в Google AI Studio/Gemini и содержит пример. Полной независимой матрицы OpenAI SynthID в просмотренных материалах нет. Более того, собственный `verify_image` явно **не запускает пиксельный детектор**: поля `pixel_watermark_detector` и `pixel_watermark_present` остаются `None`. «Verification passed» для контейнера не означает «SynthID удалён». [Проверяющий код](https://github.com/mertizci/noai-watermark/blob/9b84a551b70637825e7c39722f5a4c8d95c99af0/src/verification.py), [README](https://github.com/mertizci/noai-watermark/blob/9b84a551b70637825e7c39722f5a4c8d95c99af0/README.md).

**Оценка для Veil:** более простой baseline семейства SD 1.5 для будущей Core ML реализации. Наличие MPS не означает готовность к iOS: это backend desktop PyTorch. Утверждение комментария, что фиксированный уровень подходит SynthID в целом, недостаточно обосновано без своей выборки.

## 4. cebeuq/Synthid-Bypass, прежний 00quebec

V2 — ComfyUI workflow: глобальный Qwen Image 2512 GGUF с Lightning LoRA и DiffSynth Canny ControlNet, затем сегментация лиц и отдельная Z-Image Turbo стадия. В набор входят дополнительные text encoder, VAE, YOLO, SAM и несколько внешних node-пакетов. Собственная Python-нода изменяет силу регенерации по площади лица и вызывает ComfyUI/Impact Pack. [Граф](https://github.com/cebeuq/Synthid-Bypass/blob/c45d3bddc33d71ef925521f65e8ca9439c8a7efa/Synthid-Bypass-v2.0.json), [код лицевой стадии](https://github.com/cebeuq/Synthid-Bypass/blob/c45d3bddc33d71ef925521f65e8ca9439c8a7efa/custom_nodes/Comfyui-SynthidBypass/segs_detailer_modelswap.py).

README позиционирует проект как proof of concept для Google Nano Banana Pro и публикует пары сравнения. В просмотренных материалах нет воспроизводимой независимой матрицы официальных verdict для OpenAI. Видимый улучшенный портрет не подтверждает удаление невидимого маркера. Объяснение «визуализированный шум и есть весь SynthID» остаётся гипотезой автора. [README и модели](https://github.com/cebeuq/Synthid-Bypass/blob/c45d3bddc33d71ef925521f65e8ca9439c8a7efa/README.md).

**Оценка для Veil:** полезный источник идей по восстановлению лиц при полной регенерации. Готового мобильного runtime нет. Корневой LICENSE не найден, поэтому публичность кода нельзя считать разрешением включить его в распространяемое приложение. Права на модели и внешние узлы тоже проверяются отдельно.

## 5. froggeric/gemini-watermark-and-synthid-remover

### Почему этот проект особенно важен для нативного приложения

В `coreml_sd_pipeline.mm` есть реальная реализация: Core ML VAE encoder, добавление шума, UNet с Euler scheduler на Accelerate, VAE decoder. Размер плитки 1024×1024, латента 128×128. Используются заранее сохранённые embeddings пустого prompt, поэтому text encoder не поставляется. Это полноценная регенерация, а не один проход VAE. [Objective-C++ pipeline](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/src/core/coreml_sd_pipeline.mm), [scheduler](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/src/core/coreml_sd_scheduler.cpp).

Модели скачиваются из `huggingface.co/froggeric/wmr`; код содержит SHA256-пины encoder, decoder, UNet и embeddings. README сообщает около 4,7 ГБ Core ML файлов и приблизительное время на Mac. Более поздний фактический benchmark Phase 4 фиксирует 183 секунды на 2816×1536, примерно шесть плиток, на M4. Раннюю гипотезу 1–3 секунды на плитку в том же документе нельзя выдавать за измерение. Ни одна из этих цифр не является прогнозом для iPhone. [Загрузка и пины](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/src/core/coreml_sd_model_fetch.cpp), [поздний фактический benchmark, Phase 4](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/docs/research/coreml-sd-placement.md).

### Насколько сильны результаты

Журнал автора сообщает 9/9 отрицательных результатов ручной проверки Google на SDXL регенерации и повторную проверку после перехода на Core ML GPU, включая изображение с двойным watermark. Он также различает время исполнения, спектральную метрику и официальный verdict. Однако опубликованная таблица не является полным набором per-image исходных verdict-артефактов. Совпадение архитектуры CPU и Core ML само по себе не доказывает совпадение удаления на всех файлах. [Журнал валидации](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/docs/research/synthid-regen-validation.md).

Отдельный detail-restoration возвращает часть высокочастотной информации из оригинала. Автор отмечает, что на тёмных изображениях это может вернуть детектируемый watermark, и применяет ограничение по яркости. Такая эвристика выведена на малой выборке и не переносится автоматически на OpenAI. [Восстановление деталей](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/src/core/regen_restore.cpp), [обоснование автора](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/README.md#synthid-reality).

### Что потребуется для iOS

Нельзя просто добавить desktop executable в IPA. Загрузчик использует системный `tar`, код работает с путями исполняемого файла и desktop cache; для iOS нужны управляемая приложением загрузка/распаковка моделей, storage lifecycle и подходящий Swift/Objective-C мост. Надо измерить пиковую память, первый compile, время и нагрев на настоящем iPhone. Рассматривать 4,7 ГБ на диске как оценку RAM нельзя. [Desktop-загрузчик](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/src/core/coreml_sd_model_fetch.cpp).

Корневой LICENSE — MIT, хотя комментарий в начале `.mm` всё ещё говорит Apache-2.0. Эту несогласованность следует прояснить перед прямым заимствованием. Это отдельный вопрос от лицензии SDXL и сторонних зависимостей. [LICENSE](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/LICENSE), [сторонние компоненты](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/LICENSE-THIRD-PARTY.md).

**Оценка для Veil:** первый кандидат для нативного исследовательского прототипа; пока не основание обещать пользователю удаление OpenAI SynthID на телефоне.

## Лицензии весов отличаются от лицензий программ

Проверены metadata карточек Hugging Face на дату аудита. Это названия лицензий из карточек; перед поставкой весов нужно читать их полный текст и фиксировать конкретные версии.

| Модель | Лицензия карточки | Первичный источник |
|---|---|---|
| Qwen-Image-2512 | Apache-2.0 | [Qwen](https://huggingface.co/Qwen/Qwen-Image-2512) |
| Z-Image-Turbo | Apache-2.0 | [Tongyi-MAI](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo) |
| SDXL base 1.0 | OpenRAIL++ | [Stability AI](https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0) |
| DreamShaper 8 | CreativeML OpenRAIL-M | [Lykon](https://huggingface.co/Lykon/dreamshaper-8) |
| CtrlRegen | Apache-2.0 | [yepengliu](https://huggingface.co/yepengliu/ctrlregen) |
| DINOv2 giant | Apache-2.0 | [Meta](https://huggingface.co/facebook/dinov2-giant) |
| SDXL Canny ControlNet | Apache-2.0 | [xinsir](https://huggingface.co/xinsir/controlnet-canny-sdxl-1.0) |
| Qwen-Image-2512-Lightning | Apache-2.0 | [lightx2v](https://huggingface.co/lightx2v/Qwen-Image-2512-Lightning) |

Это не полный аудит прав всего стека. Внешние ComfyUI nodes, сегментаторы, квантизированные перераспределения и конкретные checkpoints имеют собственные условия. Корневая MIT/Apache лицензия проекта не заменяет их.

## Следующий этап для Veil

1. Сохранить текущую обработку как экспериментальный локальный фильтр с честным статусом. Она не содержит ни одного из исследованных генеративных движков.
2. Сделать отдельный прототип Core ML по мотивам SDXL pipeline, не встраивая неподтверждённые «быстрые» спектральные обходы. Измерить реальные затраты iPhone до решения о поставке моделей.
3. Сравнивать выходы на независимых фиксированных наборах Google и OpenAI. Источник должен сначала быть подтверждён пиксельным детектором после удаления C2PA без изменения растра. Ошибку/таймаут/лимит детектора нельзя записывать в отрицательные verdict.
4. Фиксировать commit кода, SHA весов, зерно, настройки, hashes входа и выхода и официальный verdict. При сравнении качества отдельно проверять текст, лица, мелкие логотипы и текстуры; PSNR сам по себе не гарантирует сохранение значимых деталей.
5. Отдельно измерять долю не обнаруженных watermark и качество. Универсальный AI-классификатор не заменяет SynthID detector, а `not detected` не доказывает отсутствие следов генерации.

Нынешний аудит выбирает направление для эксперимента. Он не устанавливает победителя по качеству и надёжности без запуска моделей и внешней проверки.
