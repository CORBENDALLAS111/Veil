import PhotosUI
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
                            editor(preview, photoHeight: max(200, min(580, geometry.size.height - (model.result == nil ? 415 : 270))))
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
            .background { StudioBackground() }
            .navigationTitle("Veil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.source != nil {
                        Button {
                            model.reset()
                            selectedPhoto = nil
                        } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Другое фото")
                            .accessibilityIdentifier("resetButton")
                            .disabled(model.isSaving)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsInfo = true } label: { Image(systemName: "info") }
                        .accessibilityLabel("О приложении")
                        .accessibilityIdentifier("infoButton")
                }
            }
        }
        .tint(VeilStyle.accent)
        .preferredColorScheme(previewScheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.result != nil)
        .onChange(of: selectedPhoto) { _, item in
            if let item { model.select(item) }
        }
        .onChange(of: model.strength) { _, _ in model.clearResult() }
        .onChange(of: model.mode) { _, _ in model.clearResult() }
        .onChange(of: model.format) { _, _ in model.clearResult() }
        .onChange(of: model.clarity) { _, _ in model.clearResult() }
        .onChange(of: model.resolution) { _, _ in model.clearResult() }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image]) { result in
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
            #endif
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(VeilStyle.accent)
                .frame(width: 128, height: 128)
                .background(VeilStyle.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 36))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Добавьте фото").font(.title3.weight(.semibold))
                Text("JPEG · PNG · HEIC · WebP").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func editor(_ preview: UIImage, photoHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            HStack {
                if let source = model.source {
                    Text(verbatim: model.result.map { "\($0.width) × \($0.height)" } ?? "\(source.width) × \(source.height)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("photoDimensions")
                }
                Spacer()
                if let result = model.result {
                    Text("\(Int64(result.data.count).formatted(.byteCount(style: .file))) · \(result.format.title)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    if model.mode == .pattern {
                        Menu {
                            Picker("Размер", selection: $model.resolution) {
                                ForEach(OutputResolution.allCases) { size in Text(size.title).tag(size) }
                            }
                        } label: {
                            HStack(spacing: 4) { Text(model.resolution.title); Image(systemName: "chevron.down") }
                                .font(.caption.weight(.medium)).frame(minHeight: 44)
                        }
                        .disabled(model.isWorking)
                        .accessibilityLabel("Размер: \(model.resolution.title)")
                        .accessibilityIdentifier("resolutionMenu")
                    }
                    Menu {
                        Picker("Формат", selection: $model.format) {
                            ForEach(ExportFormat.allCases) { format in Text(format.title).tag(format) }
                        }
                    } label: {
                        HStack(spacing: 5) { Text(model.format.title); Image(systemName: "chevron.down") }
                            .font(.caption.weight(.medium)).frame(minWidth: 52, minHeight: 44)
                    }
                    .disabled(model.isWorking)
                    .accessibilityLabel("Формат экспорта: \(model.format.title)")
                }
            }

            ComparisonView(original: preview, processed: model.resultPreview,
                           maximumHeight: photoHeight, position: $model.comparison)

            if model.result != nil {
                HStack(spacing: 12) {
                    Label("SynthID не проверен", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("verificationStatus")
                    Spacer(minLength: 0)
                    Link(destination: URL(string: "https://synthid.com/")!) {
                        Image(systemName: "arrow.up.right").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Открыть SynthID Detector")
                }
            } else {
                Picker("Обработка", selection: $model.mode) {
                    ForEach(ProcessingMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .disabled(model.isWorking)
                .accessibilityIdentifier("processingMode")
                if model.mode == .pattern {
                    Picker("Сила обработки", selection: $model.strength) {
                        ForEach(ProcessingStrength.allCases) { strength in Text(strength.title).tag(strength) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isWorking)
                    .accessibilityHint(model.strength.detail)
                    Toggle("Мягкая чёткость", isOn: $model.clarity)
                        .font(.subheadline)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("clarityToggle")
                    Text(model.resolution == .original ? "Без перерисовки · исходный размер" : "Без перерисовки · 4K по длинной стороне")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Удаляет метаданные. SynthID в пикселях может сохраниться.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if model.source?.hasAlpha == true && model.format == .jpeg {
                    Text("Прозрачность заменится белым фоном").font(.caption).foregroundStyle(.secondary)
                }
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
                            Button(action: model.cancel) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                                .modifier(VeilActionStyle())
                                .accessibilityLabel("Отменить")
                                .accessibilityIdentifier("cancelButton")
                        }
                        .frame(minHeight: 54)
                    } else if model.result != nil {
                        Button { Task { await model.prepareShare() } } label: {
                            Image(systemName: "square.and.arrow.up").frame(width: 28, height: 28)
                        }
                        .modifier(VeilActionStyle())
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Поделиться файлом")
                        .accessibilityIdentifier("shareButton")

                        Button { Task { await model.save() } } label: {
                            HStack(spacing: 8) {
                                if model.isSaving { ProgressView().tint(VeilStyle.onAccent) }
                                else { Image(systemName: "arrow.down") }
                                Text(model.isSaving ? "Сохраняем…" : "Сохранить")
                            }
                            .font(.headline).foregroundStyle(VeilStyle.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .modifier(VeilActionStyle(prominent: true))
                        .accessibilityIdentifier("saveButton")
                        .disabled(model.isSaving)

                        Button(action: model.clearResult) {
                            Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
                        }
                        .modifier(VeilActionStyle())
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Изменить обработку")
                        .accessibilityIdentifier("editAgainButton")
                        .disabled(model.isSaving)
                    } else if model.source != nil {
                        Button(action: model.process) {
                            Label("Обработать", systemImage: model.mode == .pattern ? "slider.horizontal.3" : "document.badge.minus")
                                .font(.headline).foregroundStyle(VeilStyle.onAccent)
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .modifier(VeilActionStyle(prominent: true))
                        .accessibilityIdentifier("processButton")
                    } else {
                        PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current) {
                            Label("Выбрать фото", systemImage: "plus")
                                .font(.headline).foregroundStyle(VeilStyle.onAccent)
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .modifier(VeilActionStyle(prominent: true))
                        .accessibilityIdentifier("photoPickerButton")
                        Button { showsFiles = true } label: {
                            Image(systemName: "folder").frame(width: 28, height: 28)
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
            } else if model.result == nil && !model.isWorking {
                Text("Экспериментальная обработка").font(.caption2).foregroundStyle(.secondary)
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
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
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
                    Text("PNG сохраняет обработанные пиксели без потерь. JPEG добавляет сжатие и заменяет прозрачность белым фоном. Без исходных метаданных. SDR sRGB.")
                }
                Section("Код") {
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
