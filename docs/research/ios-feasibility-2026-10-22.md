# Нативная обработка изображений на iPhone: техническая осуществимость

Дата проверки: 22 октября 2026 года. Это статическое исследование официального кода и документации. Модели не запускались, пользовательские изображения никуда не отправлялись, эффективность удаления SynthID этим исследованием не измерена.

## Главный вывод

Локальная нейросетевая регенерация изображения на iPhone технически возможна. Официальный Apple `ml-stable-diffusion` уже предоставляет Swift/Core ML pipeline для image-to-image. Однако возможность выполнить регенерацию не доказывает удаления SynthID. Нужен отдельный эксперимент на исходных файлах с известным происхождением и корректная оценка качества. Результаты на Google-моделях нельзя автоматически переносить на вариант OpenAI.

Текущий `PhotoProcessor` Veil 0.2.0 выполняет Core Image noise reduction и двухуровневое Haar-преобразование с подавлением небольших коэффициентов. Он не использует нейросеть, SynthID-декодер или проверяющий детектор. Сохранение в новый контейнер устраняет копирование исходных метаданных, но само по себе ничего не доказывает о водяном знаке в пикселях. Это видно непосредственно в `Sources/Processing/PhotoProcessor.swift` и описано в README приложения.

## 1. Apple Core ML: что действительно готово

В официальном Swift-коде обычного SD pipeline исходное изображение проходит через VAE encoder, в latent representation добавляется шум согласно `strength`, затем выполняется диффузия и VAE decoder. Callback позволяет остановить вычисление между шагами. Код SDXL также содержит `startingImage`, `imageToImage` и encoder. Это готовые механизмы регенерации, а не готовый алгоритм SynthID removal.

Источники: [StableDiffusionPipeline.swift](https://github.com/apple-aiml-research/ml-stable-diffusion/blob/main/swift/StableDiffusion/pipeline/StableDiffusionPipeline.swift), [StableDiffusionXLPipeline.swift](https://github.com/apple-aiml-research/ml-stable-diffusion/blob/main/swift/StableDiffusion/pipeline/StableDiffusionXLPipeline.swift).

Практическое ограничение обнаруживается в [Encoder.swift](https://github.com/apple-aiml-research/ml-stable-diffusion/blob/main/swift/StableDiffusion/pipeline/Encoder.swift): размер входного массива должен точно совпадать с shape модели, иначе выбрасывается `sampleInputShapeNotCorrect`. Автоматического resize/crop там нет. Поэтому произвольное фото 720×1280 нельзя без подготовки передать в модель 512×512. Конвертация в дополнительные размеры или аккуратная геометрическая подготовка — отдельная задача; она влияет и на качество, и на воспроизводимость эксперимента.

### Производительность и память

Официальный README публикует измерения Apple/Hugging Face 2023 года:

| Модель и условия | Устройство | Полное время |
| --- | --- | --- |
| SD 2.1-base, 512×512, 20 шагов, 6-bit weights | iPhone 14 Pro Max | 7,9 с |
| SDXL, 768×768, 20 шагов, mixed-bit UNet | iPhone 15 Pro Max | 31 с |
| SDXL, те же условия | iPhone 14 Pro Max | 77 с |

Это медианы нескольких генераций; **это не измерения удаления SynthID**, не обещание скорости на iPhone 2026 года и не тест Veil. Для iOS рекомендован `reduceMemory = true`, а UNet должен быть разбит на части. Описана возможность пикового потребления более 2 GB, зависящего от выбранных compute units. Источник: [официальный README, Performance Benchmarks / Swift / FAQ](https://github.com/apple-aiml-research/ml-stable-diffusion).

### Размеры скачивания и недостающие компоненты

| Публичный пакет | Что подтверждено файлами | Следствие |
| --- | --- | --- |
| Apple SD 2.1-base palettized | Готовый 6-bit compiled ZIP около 1,14 GB | Это уже заметная отдельная загрузка; размер репозитория целиком не равен требуемому download |
| Apple SDXL iOS | Compiled ZIP около 3,05 GB; 768×768 и mixed-bit 4,04 | Тяжелее для хранения и памяти; сам архив ориентирован на генерацию |
| Содержимое SDXL compiled directory | Два text encoder, два UNet chunk, VAE decoder, tokenizer; **VAE encoder отсутствует** | Для image-to-image потребуется подготовить совместимый encoder; просто подключить ZIP недостаточно |

Источники: [SD 2.1 palettized files](https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/tree/main), [SDXL model card](https://huggingface.co/apple/coreml-stable-diffusion-xl-base-ios), [SDXL files](https://huggingface.co/apple/coreml-stable-diffusion-xl-base-ios/tree/main), [SDXL compiled contents](https://huggingface.co/apple/coreml-stable-diffusion-xl-base-ios/tree/main/coreml-stable-diffusion-xl-base-ios_split_einsum_compiled).

Apple отдельно показывает сжатие SDXL UNet с 4,8 GB fp16 до приблизительно 1,2 GB при grouped-channel 4-bit palettization и около 1 GB при совместном pruning+palettization. Это размер **одного компонента**, а не всего приложения. Иллюстрации качества получены на macOS 15; они не подтверждают идентичность вывода PyTorch/Core ML или эффективность против watermark. Источник: [Core ML Tools: Optimizing StableDiffusion Model](https://github.com/apple/coremltools/blob/main/docs-guides/source/opt-stable-diffusion.md).

## 2. Современные альтернативы Swift/Core ML

### MLX Swift examples

Официальная библиотека MLX содержит `ImageToImageGenerator`, `createImageToImageGenerator` и последовательность генерации latent states. Пакет заявляет iOS 16+. Пример приложения использует SDXL Turbo; его README описывает режим экономии памяти при менее 4 GB доступной памяти, обычно на устройстве с 6 GB RAM или больше. В ограниченном режиме пример выполняет только один diffusion step и выгружает части модели. Это ограничение конкретного demo, а не универсальная оценка всех возможных MLX pipeline.

Источники: [StableDiffusion.swift](https://github.com/ml-explore/mlx-swift-examples/blob/main/Libraries/StableDiffusion/StableDiffusion.swift), [Package.swift](https://github.com/ml-explore/mlx-swift-examples/blob/main/Package.swift), [README приложения](https://github.com/ml-explore/mlx-swift-examples/blob/main/Applications/StableDiffusionExample/README.md).

**Оценка применимости:** MLX удобен для экспериментов с latent math в Swift. Скорость и память конкретного алгоритма всё равно нужно измерять. Наличие Turbo-модели само по себе не означает, что она повторит эффект стандартной многопроходной регенерации, MarkNull или другой опубликованной атаки.

### Draw Things MediaGenerationKit

Обнаружен отдельный Swift SDK [MediaGenerationKit](https://github.com/drawthingsai/media-generation-kit). Он поддерживает local/remote/cloud backend, `UIImage`/`CIImage` input и image-to-image; минимум iOS 16 указан в [Package.swift](https://github.com/drawthingsai/media-generation-kit/blob/main/Package.swift). Есть model-management и progress API.

Лицензию SDK нужно отличать от лицензии основного `draw-things-community`: сам community repo имеет GPLv3, а README **MediaGenerationKit** прямо описывает LGPLv3 и перелицензирование переносимых зависимостей для распространения через этот package. Это сведения авторов SDK, а не утверждение, что любые части community repo можно свободно копировать под другой лицензией. Источники: [SDK README, License](https://github.com/drawthingsai/media-generation-kit#license), [community README](https://github.com/drawthingsai/draw-things-community#license).

**Оценка применимости:** интересный готовый backend для локальной генерации и современных моделей; требует проверки сборки и памяти на целевых устройствах. В изученных SDK docs нет доказательства удаления SynthID. Произвольная модель FLUX/SDXL с малым количеством шагов не становится watermark remover только из-за подключения этого SDK.

### Дополнительный кандидат: wmr / froggeric

Проверен также [froggeric/gemini-watermark-and-synthid-remover](https://github.com/froggeric/gemini-watermark-and-synthid-remover), commit `37f338847c7fcdbaa1ab3f883c6a742173dd9595`. Это более близкий к предмету исследования reference: есть самостоятельный Objective-C++ SDXL pipeline, а не только общий image-generation SDK.

В [coreml_sd_pipeline.mm](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/src/core/coreml_sd_pipeline.mm) реально реализованы Core ML VAE encoder → latent sampling → Euler/UNet → decoder, готовые embeddings пустого prompt и tile 1024×1024. Однако init держит UNet и оба VAE одновременно; готового iOS-режима экономии памяти там не обнаружено. Код загружает монолитный UNet и использует batch 2. Комментарий об ANE в начале файла устарел относительно текущего выбора compute units; `.all` не доказывает выполнение на Neural Engine.

Блок Core ML в [CMakeLists.txt](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/CMakeLists.txt) описан как macOS-only. В [model fetcher](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/src/core/coreml_sd_model_fetch.cpp) есть SHA-256 pins, но распаковка вызывает внешний `tar` через `std::system`. Для iOS нужны собственный download/storage/extraction layer, app target и управление жизненным циклом моделей. Наличие macOS arm64 binary не является готовностью к iOS.

Особенно полезна честная история измерений в [coreml-sd-placement.md, Phase 4](https://github.com/froggeric/gemini-watermark-and-synthid-remover/blob/37f338847c7fcdbaa1ab3f883c6a742173dd9595/docs/research/coreml-sd-placement.md). В начале документа есть гипотеза 1–3 секунды на tile, но поздний фактический замер для 2816×1536, около шести tiles: **183 с** у ORIGINAL против **223 с** у SPLIT_EINSUM. Автор оценивает первый вариант примерно в 30 с/tile на M4; предполагаемое ускорение не достигнуто. Это desktop-результат автора, не независимое воспроизведение и не iPhone benchmark.

**Вывод:** wmr — ценный reference для портирования именно pipeline и изучения ограничений. Прямо переносить его desktop model package в Veil без работы с памятью и измерений на устройстве преждевременно. Его небольшие ручные Google-verifier проверки, разобранные в отдельном аудите репозиториев, не подтверждают эффективность на OpenAI SynthID.

## 3. Код, веса и лицензии — разные составляющие

| Компонент | Подтверждённая лицензия / источник |
| --- | --- |
| Apple `ml-stable-diffusion` | [MIT LICENSE.md](https://github.com/apple-aiml-research/ml-stable-diffusion/blob/main/LICENSE.md) |
| MLX Swift examples | [MIT LICENSE](https://github.com/ml-explore/mlx-swift-examples/blob/main/LICENSE) |
| Draw Things community | [GPLv3 по README](https://github.com/drawthingsai/draw-things-community#license) |
| MediaGenerationKit | [LGPLv3 и отдельное описание scope](https://github.com/drawthingsai/media-generation-kit#license) |
| Apple-конвертированные SD 2.1 / SDXL weights | Model cards указывают CreativeML Open RAIL++-M; [SD 2.1](https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized), [SDXL](https://huggingface.co/apple/coreml-stable-diffusion-xl-base-ios) |

Лицензия библиотеки не заменяет лицензию модели. Подготовка продукта должна фиксировать точные версии кода и весов, включать attribution и выполнять условия выбранных артефактов. В этом исследовании модель и SDK не добавлялись в Veil.

## 4. Что пока нельзя честно утверждать

1. Что generic noise reduction/Haar уже удаляет SynthID. Из кода следует только преобразование пикселей; замеров детектора нет.
2. Что VAE encode→decode достаточно. VAE — сжатие с потерями, но степень разрушения watermark зависит от конкретной схемы. Возможность быстро выполнить roundtrip не равна доказательству удаления.
3. Что результаты PyTorch сохранены после Core ML conversion, 4/6-bit quantization и изменения размера. Это отдельный transfer test.
4. Что Google Gemini/Nano Banana и OpenAI используют взаимозаменяемые настройки watermark. Публичный результат для одного происхождения не доказывает эффект на другом.
5. Что регенерация сохранит текст, лица и мелкие структуры исходного фото. Это нейросетевое восстановление с возможными изменениями, особенно при усилении обработки.
6. Что аппаратная поддержка image generation означает пригодность на каждом iPhone. RAM, температура, фоновая нагрузка, модель, геометрия и число шагов имеют значение.

Пункты 2–6 — инженерные ограничения и выводы, а не результаты запуска Veil с этими моделями.

## 5. Реалистичная архитектура для дальнейшей проверки

Ниже — предложение, не реализованная функция.

- Сохранить минимальный SwiftUI интерфейс, а обработчик сделать сменным: текущий лёгкий фильтр и отдельный neural engine. Технические параметры остаются внутри движка.
- Для первого native proof of concept разумно взять официальный Apple SD 2.1/Core ML path: он проще и легче SDXL. Цель первого этапа — подтвердить геометрию, воспроизводимость, реальную память, отмену и время. Это ещё не основание выпускать функцию как удаление SynthID.
- Готовить encoder и decoder одной модели с согласованными scaling factors; для SDXL не считать опубликованный text-to-image ZIP полным image-to-image комплектом.
- Веса хранить отдельно от лёгкого IPA, с явным размером перед первоначальной загрузкой, проверкой хеша и версией manifest. После загрузки локальная обработка не требует передачи фото на сервер.
- Выполнять одну задачу за раз в выделенном actor/очереди, выгружать неиспользуемые модели, проверять отмену между diffusion steps. Распознавать нехватку памяти и состояние thermal pressure; не выдавать пустой/старый preview за успешную обработку.
- Отдельно решить работу с прямоугольными и большими фото. Не обещать сохранение исходных пикселей после уменьшения до рабочего разрешения и обратного увеличения. Tiling требует проверки швов и соответствия экспериментальному алгоритму.
- Перенос более сильного исследовательского метода начинать с воспроизводимого desktop reference и набора тестовых файлов. После переноса сравнивать результат с reference, включая perceptual quality. Просто увеличить интенсивность текущего Haar-фильтра — недостаточное обоснование нового движка.

## 6. Проверка provenance и ограничение официального API

Официальная [документация OpenAI Content provenance](https://developers.openai.com/api/docs/guides/content-provenance) описывает отдельные результаты C2PA и SynthID. `not_detected` означает отсутствие обнаруженного поддерживаемого сигнала, а не доказательство человеческого происхождения. API поддерживает OpenAI signals; это не универсальный детектор всех генераторов.

В разделе Use verification results responsibly отдельно сказано: **“Don’t use repeated queries to reverse-engineer, remove, or evade a watermark.”** Поэтому найденный API нельзя включать в автоматический подбор параметров удаления или предлагать как unrestricted oracle для такой задачи. Исследование сейчас ограничено чтением опубликованных источников. Пользовательские фото и ключи не использовались, API-запросов на проверку изображений не выполнялось.

Для дальнейшего исследования нужен допустимый режим доступа к оценке watermark и соблюдение его условий. Ни пользовательский скриншот, ни успешная генерация изображения в симуляторе, ни unit tests denoiser не являются проверкой удаления SynthID.

## Рекомендация

Наиболее прямой путь к нативному offline-прототипу — официальный Core ML image-to-image с отдельно подготовленными весами. Более современный backend-кандидат — MediaGenerationKit; MLX полезен для исследовательской работы с latent representation. Выбор engine должен следовать результатам воспроизводимого эксперимента на нужном типе watermark. До этого в UI корректен статус «SynthID не проверен» и описание обработки без обещания гарантированного удаления.
