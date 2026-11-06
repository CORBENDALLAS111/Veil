import PhotosUI
import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct StudioView: View {
    @State private var model = StudioModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsFiles = false
    @State private var showsInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if let preview = model.originalPreview {
                            editor(preview, photoHeight: max(200, min(580, geometry.size.height - (model.hasResult ? 290 : 495))))
                        } else {
                            emptyState.frame(minHeight: max(240, geometry.size.height - 130))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 650)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("studioScroll")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actions
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 10)
                        .frame(maxWidth: 650)
                        .frame(maxWidth: .infinity)
                }
            }
            .background { StudioBackground(animate: !model.hasSource && !model.isWorking) }
            .navigationTitle("Veil")
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) { LucideIcon(name: "aperture", size: 17); Text("VEIL").font(.system(size: 13, weight: .semibold)).tracking(3) }
                        .accessibilityElement(children: .combine).accessibilityLabel("Veil")
                }
                ToolbarItem(placement: .topBarLeading) {
                    if model.hasSource {
                        Button {
                            model.reset()
                            selectedPhoto = nil
                        } label: { LucideIcon(name: "plus") }
                            .accessibilityLabel("Другое фото или видео")
                            .accessibilityIdentifier("resetButton")
                            .disabled(model.isSaving)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsInfo = true } label: { LucideIcon(name: "info") }
                        .accessibilityLabel("О приложении")
                        .accessibilityIdentifier("infoButton")
                }
            }
        }
        .tint(VeilStyle.accent)
        .preferredColorScheme(previewScheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.hasResult)
        .onChange(of: model.isWorking) { _, working in UIApplication.shared.isIdleTimerDisabled = working }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: selectedPhoto) { _, item in
            if let item { model.select(item) }
        }
        .onChange(of: model.strength) { _, _ in model.clearResult() }
        .onChange(of: model.mode) { _, _ in model.clearResult() }
        .onChange(of: model.videoMode) { _, mode in
            model.clearResult()
            if mode == .upscale && model.videoResolution == .original { model.videoResolution = .fullHD }
        }
        .onChange(of: model.videoResolution) { _, _ in model.clearResult() }
        .onChange(of: model.smoothVideoBlocks) { _, _ in model.clearResult() }
        .onChange(of: model.format) { _, _ in model.clearResult() }
        .onChange(of: model.reduceRipple) { _, _ in model.clearResult() }
        .onChange(of: model.clarity) { _, _ in model.clearResult() }
        .onChange(of: model.resolution) { _, _ in model.clearResult() }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image, .movie]) { result in
            switch result {
            case .success(let url): model.selectFile(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsInfo) { AboutView() }
        .sheet(isPresented: Binding(get: { model.shareURL != nil }, set: { if !$0 { model.shareURL = nil } }),
               onDismiss: { model.cleanupExports() }) {
            if let url = model.shareURL { ShareSheet(url: url) }
        }
        .alert("Не получилось", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Понятно", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            model.configure()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-fixture") { model.loadFixture() }
            if ProcessInfo.processInfo.arguments.contains("-ui-video") { model.loadVideoFixture() }
            #endif
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)
            HomeSculpture()
            VStack(spacing: 13) {
                Text("Кадр. Чище.")
                    .font(.largeTitle.weight(.semibold)).fontDesign(.rounded).tracking(-1.3)
                    .minimumScaleFactor(0.7).lineLimit(1)
                Text("Фото и видео. Мягкая обработка до 4K.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 20) {
                LucideLabel(title: "На устройстве", icon: "shield-check")
                LucideLabel(title: "Без перерисовки", icon: "scan-line")
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 20)
        }.frame(maxWidth: .infinity)
    }

    private func editor(_ preview: UIImage, photoHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            HStack {
                if let source = model.source {
                    Text(verbatim: model.result.map { "\($0.width) × \($0.height)" } ?? "\(source.width) × \(source.height)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("photoDimensions")
                } else if let video = model.video {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "\(model.videoResult?.width ?? video.width) × \(model.videoResult?.height ?? video.height)")
                            .accessibilityIdentifier("videoDimensions")
                        Text("\(Int(video.duration) / 60):\(String(format: "%02d", Int(video.duration) % 60)) · \(Int(video.framesPerSecond.rounded())) fps")
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if let result = model.result {
                    Text("\(Int64(result.data.count).formatted(.byteCount(style: .file))) · \(result.format.title)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if model.videoResult != nil {
                    Text("MOV").font(.caption).foregroundStyle(.secondary)
                } else {
                    if model.video != nil && !model.copiesMetadataOnly {
                        Menu {
                            Picker("Апскейл", selection: $model.videoResolution) {
                                ForEach(VideoResolution.allCases.filter { model.videoMode != .upscale || $0 != .original }) { size in Text(size.title).tag(size) }
                            }
                        } label: {
                            HStack(spacing: 4) { Text(model.videoResolution.title); LucideIcon(name: "chevron-down") }
                                .font(.caption.weight(.medium)).frame(minHeight: 44)
                        }
                        .disabled(model.isWorking)
                        .accessibilityLabel("Апскейл: \(model.videoResolution.title)")
                        .accessibilityIdentifier("videoResolutionMenu")
                    } else if model.video == nil && model.mode == .pattern {
                        Menu {
                            Picker("Размер", selection: $model.resolution) {
                                ForEach(OutputResolution.allCases) { size in Text(size.title).tag(size) }
                            }
                        } label: {
                            HStack(spacing: 4) { Text(model.resolution.title); LucideIcon(name: "chevron-down") }
                                .font(.caption.weight(.medium)).frame(minHeight: 44)
                        }
                        .disabled(model.isWorking)
                        .accessibilityLabel("Размер: \(model.resolution.title)")
                        .accessibilityIdentifier("resolutionMenu")
                    }
                    if model.video != nil {
                        Text(model.copiesMetadataOnly ? "MOV" : "MOV · H.264").font(.caption).foregroundStyle(.secondary)
                    } else { Menu {
                        Picker("Формат", selection: $model.format) {
                            ForEach(ExportFormat.allCases) { format in Text(format.title).tag(format) }
                        }
                    } label: {
                        HStack(spacing: 5) { Text(model.format.title); LucideIcon(name: "chevron-down") }
                            .font(.caption.weight(.medium)).frame(minWidth: 52, minHeight: 44)
                    }
                    .disabled(model.isWorking)
                    .accessibilityLabel("Формат экспорта: \(model.format.title)")
                    }
                }
            }

            if let video = model.video {
                MovieComparisonView(original: video.url, processed: model.videoResult?.url,
                                    aspectRatio: CGFloat(video.width) / CGFloat(video.height), maximumHeight: photoHeight)
            } else {
                ComparisonView(original: preview, processed: model.resultPreview,
                               maximumHeight: photoHeight, position: $model.comparison)
            }

            if model.hasResult {
                HStack(spacing: 12) {
                    LucideLabel(title: "SynthID не проверен", icon: "info")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("verificationStatus")
                    Spacer(minLength: 0)
                    Link(destination: URL(string: "https://synthid.com/")!) {
                        LucideIcon(name: "arrow-up-right").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Открыть SynthID Detector")
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                if model.video != nil {
                    Picker("Обработка видео", selection: $model.videoMode) {
                        ForEach(VideoOperation.allCases) { mode in
                            Text(mode.title).tag(mode).disabled(mode != .metadata && model.video?.patternSupported == false)
                        }
                    }
                    .pickerStyle(.segmented).disabled(model.isWorking)
                    .accessibilityIdentifier("videoMode")
                } else {
                    Picker("Обработка", selection: $model.mode) {
                        ForEach(ProcessingMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented).disabled(model.isWorking)
                    .accessibilityIdentifier("processingMode")
                }
                if model.runsPattern {
                    Picker("Сила обработки", selection: $model.strength) {
                        ForEach(ProcessingStrength.allCases) { strength in Text(strength.title).tag(strength) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isWorking)
                    .accessibilityHint(model.strength.detail)
                    Toggle(isOn: $model.reduceRipple) { LucideLabel(title: "Убрать рябь", icon: "scan-line") }
                        .font(.subheadline).disabled(model.isWorking)
                        .accessibilityHint("Мягкое подавление периодической текстуры. Слабые узоры тоже могут измениться.")
                        .accessibilityIdentifier("rippleToggle")
                    Toggle(isOn: $model.clarity) { LucideLabel(title: "Мягкая чёткость", icon: "sparkles") }
                        .font(.subheadline)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("clarityToggle")
                    Text(model.video != nil ? "Без перерисовки · защита текста" : (model.resolution == .original ? "Без перерисовки · исходный размер" : "Без перерисовки · 4K по длинной стороне"))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if model.copiesMetadataOnly {
                    Text(model.video != nil ? "Перезапись контейнера без изменения кадров и звука. SynthID может сохраниться." : "Удаляет метаданные. SynthID в пикселях может сохраниться.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Увеличение без дорисовки букв и деталей")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if model.video != nil && !model.copiesMetadataOnly && model.videoResolution != .original {
                    Toggle("Мягкое сглаживание блоков", isOn: $model.smoothVideoBlocks)
                        .font(.subheadline).disabled(model.isWorking)
                        .accessibilityIdentifier("smoothVideoBlocks")
                }
                if model.video != nil {
                    Text(model.video?.patternSupported == false ? "HDR: доступна очистка метаданных. Паттерн работает с SDR." : "Звук сохраняется · держите приложение открытым")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if model.source?.hasAlpha == true && model.format == .jpeg {
                    Text("Прозрачность заменится белым фоном").font(.caption).foregroundStyle(.secondary)
                }
                }.padding(16).modifier(VeilGlassSurface())
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            VeilGlassGroup {
                HStack(spacing: 12) {
                    if model.isWorking {
                        HStack(spacing: 10) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.isImporting ? "Открываем…" : model.workLabel).font(.caption)
                                if !model.isImporting { ProgressView(value: model.progress).frame(maxWidth: 220) }
                            }
                            Spacer()
                            Button(action: model.cancel) { LucideIcon(name: "x").frame(width: 28, height: 28) }
                                .modifier(VeilActionStyle())
                                .accessibilityLabel("Отменить")
                                .accessibilityIdentifier("cancelButton")
                        }
                        .frame(minHeight: 54)
                    } else if model.hasResult {
                        Button { Task { await model.prepareShare() } } label: {
                            LucideIcon(name: "share-2").frame(width: 28, height: 28)
                        }
                        .modifier(VeilActionStyle())
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Поделиться файлом")
                        .accessibilityIdentifier("shareButton")
                        .disabled(model.isSaving)

                        Button { Task { await model.save() } } label: {
                            HStack(spacing: 8) {
                                if model.isSaving { ProgressView().tint(VeilStyle.onAccent) }
                                else { LucideIcon(name: "download") }
                                Text(model.isSaving ? "Подготовка…" : "Сохранить")
                            }
                            .font(.headline).foregroundStyle(VeilStyle.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .modifier(VeilActionStyle(prominent: true))
                        .accessibilityIdentifier("saveButton")
                        .disabled(model.isSaving)

                        Button(action: model.clearResult) {
                            LucideIcon(name: "sliders-horizontal").frame(width: 28, height: 28)
                        }
                        .modifier(VeilActionStyle())
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Изменить обработку")
                        .accessibilityIdentifier("editAgainButton")
                        .disabled(model.isSaving)
                    } else if model.hasSource {
                        Button(action: model.process) {
                            LucideLabel(title: "Обработать", icon: model.copiesMetadataOnly ? "scan-line" : "sliders-horizontal")
                                .font(.headline).foregroundStyle(VeilStyle.onAccent)
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .modifier(VeilActionStyle(prominent: true))
                        .accessibilityIdentifier("processButton")
                    } else {
                        PhotosPicker(selection: $selectedPhoto, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                            LucideLabel(title: "Выбрать фото или видео", icon: "plus")
                                .font(.headline).foregroundStyle(VeilStyle.onAccent)
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .modifier(VeilActionStyle(prominent: true))
                        .accessibilityIdentifier("photoPickerButton")
                        Button { showsFiles = true } label: {
                            LucideIcon(name: "folder-open").frame(width: 28, height: 28)
                        }
                        .modifier(VeilActionStyle())
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Открыть из Файлов")
                        .accessibilityIdentifier("filePickerButton")
                    }
                }
            }
            if let message = model.saveMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("saveConfirmation")
            } else if !model.hasResult && !model.isWorking {
                Text(model.hasSource ? "Оригинал останется у вас" : "JPEG · PNG · HEIC · WebP · MOV · MP4").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var previewScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-dark") { return .dark }
        if ProcessInfo.processInfo.arguments.contains("-ui-light") { return .light }
        #endif
        return nil
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "systemExportSheet"
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section("SynthID") {
                    Text("Обработка скрытого паттерна без генеративной перерисовки, с защитой от потери деталей. Эффективность против SynthID не подтверждена. В защищённых областях скрытый паттерн может сохраниться.")
                        .accessibilityIdentifier("synthidExplanation")
                    Link("Открыть детектор", destination: URL(string: "https://synthid.com/")!)
                }
                Section("Фото") {
                    Text("Работает на устройстве без интернета и загрузок. Исходный размер и геометрия сохраняются. Оригинал остаётся в медиатеке.")
                    Text("Распознанный текст и контрастные границы защищены от фильтра. Изменения ограничены по силе, однако слабоконтрастные текстуры могут измениться. Метаданные очищаются в обоих режимах.")
                    Text("Мягкая чёткость даёт едва заметное усиление деталей. Размер 4K — 3840 пикселей по длинной стороне с сохранением пропорций; это аккуратная интерполяция, она не восстанавливает утраченную информацию. При исходном размере масштабирования нет.")
                }
                Section("Экспорт") {
                    Text("В LiveContainer сохранение открывает системное меню: выберите «Сохранить изображение», «Сохранить видео» или «Сохранить в Файлы». Прямой запрос разрешения из гостевого приложения не используется.")
                    Text("PNG сохраняет обработанные пиксели без потерь. JPEG добавляет сжатие и заменяет прозрачность белым фоном. Без исходных метаданных. SDR sRGB.")
                }
                Section("Видео") {
                    Text("Апскейл: 1080p или 4K по длинной стороне, с сохранением пропорций. Работает отдельно или вместе с паттерном. GPU используется при доступности; нейросеть не перерисовывает текст и лица. Утраченные детали не восстанавливаются.")
                    Text("Мягкое сглаживание блоков ограничено одним уровнем RGB и защищает контрастные границы. Апскейл не уменьшает исходный размер и не меняет частоту кадров.")
                    Text("MOV и MP4: покадровая обработка SDR до 4K без генеративной перерисовки. Небольшие изменения стабилизируются между соседними кадрами; отсутствие мерцания на любом видео не гарантируется. Звук и тайминги сохраняются.")
                    Text("Экспорт паттерна — MOV H.264 со сжатием; точные пиксели после кодирования не сохраняются. Метаданные — перезапись исходных видео- и аудиодорожек без перекодирования. HDR доступен только в этом режиме. Эффективность против SynthID в видео не подтверждена.")
                }
                Section("Рябь") {
                    Text("Выключаемый фильтр ослабляет узкие спектральные пики в малоконтрастных областях. Распознанный текст и контрастные границы защищены. Слабые узоры могут измениться; исчезновение ряби не доказывает удаление SynthID.")
                }
                Section("Код") {
                    Text("Иконки Lucide · ISC / Feather MIT").font(.caption).foregroundStyle(.secondary)
                    Link("GitHub", destination: URL(string: "https://github.com/CORBENDALLAS111/Veil")!)
                }
                Section { Text("Veil \(version)").foregroundStyle(.secondary) }
            }
            .navigationTitle("О приложении")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
