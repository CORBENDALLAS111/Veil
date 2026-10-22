import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct StudioView: View {
    @State private var model = StudioModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsFiles = false
    @State private var showsInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let preview = model.originalPreview {
                    editor(preview)
                } else {
                    introduction
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 650)
            .frame(maxWidth: .infinity)
        }
        .background(VeilStyle.paper.ignoresSafeArea())
        .foregroundStyle(VeilStyle.ink)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
                .padding(.horizontal, 26)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: 650)
                .frame(maxWidth: .infinity)
                .background(VeilStyle.paper.opacity(0.97))
        }
        .preferredColorScheme(.light)
        .tint(VeilStyle.ink)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.result != nil)
        .onChange(of: selectedPhoto) { _, item in
            if let item { model.select(item) }
        }
        .onChange(of: model.strength) { _, _ in model.clearResult() }
        .onChange(of: model.format) { _, _ in model.clearResult() }
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-fixture") { model.loadFixture() }
            #endif
        }
    }

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("veil.").font(.system(size: 38, weight: .medium, design: .serif)).tracking(-2)
                Circle().fill(VeilStyle.accent).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            .accessibilityLabel("Veil")
            Spacer()
            if model.source != nil {
                Button {
                    model.reset()
                    selectedPhoto = nil
                } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium)).frame(width: 46, height: 46)
                }
                .accessibilityLabel("Другое фото")
                .accessibilityIdentifier("resetButton")
                .disabled(model.isSaving)
            }
            Button { showsInfo = true } label: {
                Image(systemName: "info").font(.system(size: 17, weight: .medium))
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(VeilStyle.line, lineWidth: 1))
            }
            .accessibilityLabel("Как работает Veil")
            .accessibilityIdentifier("infoButton")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path")
                Text("SYNTHID / PHOTO STUDIO").tracking(2)
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(VeilStyle.muted)
            .padding(.top, 20)

            Text("Меньше шума.\nБольше фото.")
                .font(.system(.largeTitle, design: .serif, weight: .medium))
                .tracking(-1.1)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("homeTitle")
            Text("Обработка невидимых паттернов.\nСпокойно, просто, на вашем iPhone.")
                .font(.body)
                .foregroundStyle(VeilStyle.muted)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            NoiseEmblem().frame(maxWidth: .infinity).padding(.vertical, 5)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "iphone").font(.system(size: 21, weight: .light))
                    .frame(width: 24).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ваше фото остаётся вашим").font(.subheadline.weight(.medium))
                    Text("Без загрузки на сервер, аккаунта и подписки.")
                        .font(.footnote).foregroundStyle(VeilStyle.muted)
                }
            }
        }
    }

    private func editor(_ preview: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.result == nil ? "Тихая работа\nс пикселями." : "Разница\nв деталях.")
                    .font(.system(.largeTitle, design: .serif, weight: .medium))
                    .tracking(-1)
                if let source = model.source {
                    Text("\(source.width) × \(source.height)  ·  \(Int64(source.data.count).formatted(.byteCount(style: .file)))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(VeilStyle.muted)
                        .accessibilityIdentifier("photoDimensions")
                }
            }

            ComparisonView(original: preview, processed: model.resultPreview, position: $model.comparison)

            if let output = model.result {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Обработка завершена", systemImage: "circle.lefthalf.filled")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(output.format.title).font(.system(.caption, design: .monospaced))
                    }
                    HStack {
                        Text("\(Int64(output.data.count).formatted(.byteCount(style: .file))) · \(output.elapsed.formatted(.number.precision(.fractionLength(1)))) с")
                        Spacer()
                        Text(output.strength.title)
                    }
                    .font(.footnote).foregroundStyle(VeilStyle.muted)
                    Rectangle().fill(VeilStyle.line).frame(height: 1)
                    Label("Статус SynthID: не проверен", systemImage: "info.circle")
                        .font(.footnote.weight(.medium))
                        .accessibilityIdentifier("verificationStatus")
                    Text("Проверьте результат в детекторе. Изменение пикселей само по себе не подтверждает удаление метки.")
                        .font(.footnote).foregroundStyle(VeilStyle.muted).lineSpacing(3)
                    Link(destination: URL(string: "https://synthid.com/")!) {
                        Label("Открыть SynthID Detector", systemImage: "arrow.up.right")
                            .font(.footnote.weight(.semibold)).frame(minHeight: 44)
                    }
                    Button("Изменить обработку") { model.clearResult() }
                        .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                        .accessibilityIdentifier("editAgainButton")
                }
            } else {
                controls
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Сила обработки").font(.subheadline.weight(.medium))
                Spacer()
                Menu {
                    Picker("Формат экспорта", selection: $model.format) {
                        ForEach(ExportFormat.allCases) { format in Text(format.title).tag(format) }
                    }
                } label: {
                    HStack(spacing: 4) { Text(model.format.title); Image(systemName: "chevron.down") }
                        .font(.system(.caption, design: .monospaced)).frame(minWidth: 60, minHeight: 44)
                }
                .accessibilityLabel("Формат экспорта: \(model.format.title)")
            }
            Picker("Сила обработки", selection: $model.strength) {
                ForEach(ProcessingStrength.allCases) { strength in Text(strength.title).tag(strength) }
            }
            .pickerStyle(.segmented)
            Text(model.strength.detail).font(.footnote).foregroundStyle(VeilStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.source?.hasAlpha == true && model.format == .jpeg {
                Text("Прозрачность будет заменена белым фоном.")
                    .font(.footnote).foregroundStyle(VeilStyle.muted)
            }
        }
        .disabled(model.isWorking)
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 12) {
            if model.isWorking {
                HStack(spacing: 10) {
                    ProgressView().tint(VeilStyle.ink)
                    Text(model.isImporting ? "Открываем фото…" : "Обрабатываем пиксели…")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Отменить") { model.cancel() }.font(.subheadline)
                        .frame(minHeight: 44).accessibilityIdentifier("cancelButton")
                }
                .frame(minHeight: 58)
            } else if model.result != nil {
                HStack(spacing: 12) {
                    Button { Task { await model.prepareShare() } } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 20)).frame(width: 58, height: 58)
                            .overlay(Circle().stroke(VeilStyle.line, lineWidth: 1))
                    }
                    .accessibilityLabel("Поделиться файлом")
                    .accessibilityIdentifier("shareButton")
                    Button { Task { await model.save() } } label: {
                        HStack(spacing: 10) {
                            if model.isSaving { ProgressView().tint(VeilStyle.paper) }
                            else { Image(systemName: "arrow.down") }
                            Text(model.isSaving ? "Сохраняем…" : "Сохранить фото")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("saveButton")
                    .disabled(model.isSaving)
                }
                if let message = model.saveMessage {
                    Text(message).font(.footnote).foregroundStyle(VeilStyle.muted)
                        .accessibilityIdentifier("saveConfirmation")
                }
            } else if model.source != nil {
                Button(action: model.process) {
                    HStack(spacing: 10) { Image(systemName: "waveform.path"); Text("Обработать фото"); Image(systemName: "arrow.right") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("processButton")
                Text("Экспериментально · удаление SynthID не гарантируется")
                    .font(.caption2).foregroundStyle(VeilStyle.muted).multilineTextAlignment(.center)
            } else {
                PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current) {
                    HStack(spacing: 10) { Image(systemName: "plus"); Text("Выбрать фото"); Spacer(); Image(systemName: "arrow.right") }
                        .padding(.horizontal, 24)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("photoPickerButton")
                Button { showsFiles = true } label: {
                    Label("Открыть из Файлов", systemImage: "folder").font(.footnote.weight(.medium))
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("filePickerButton")
                Text("Экспериментальная обработка · SynthID может сохраниться")
                    .font(.caption2).foregroundStyle(VeilStyle.muted).multilineTextAlignment(.center)
            }
        }
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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Немного\nпрозрачности.")
                        .font(.system(.largeTitle, design: .serif, weight: .medium)).tracking(-1)
                    section("Что делает Veil", "Локальное шумоподавление Core Image и двухуровневое вейвлет-преобразование Хаара ослабляют мелкие шумовые и частотные компоненты изображения. Чем сильнее обработка, тем больше могут измениться текстуры.")
                    section("Что с SynthID", "Это экспериментальный способ обработки, а не подтверждённый алгоритм удаления SynthID. У приложения нет декодера SynthID и встроенного детектора. Метка может остаться даже после сильной обработки. Проценты «очистки» не вычисляются.")
                    section("Что с метаданными", "Экспорт создаёт новый PNG или JPEG без копирования исходных EXIF, GPS, XMP, IPTC и Content Credentials. Цветовое пространство результата — sRGB. Отсутствие метаданных не означает отсутствие SynthID.")
                    section("Ваши файлы", "Фото обрабатываются на устройстве. Здесь нет аналитики, аккаунтов, рекламы и сетевой обработки. Оригинал не перезаписывается. Поддерживаются JPEG, PNG, HEIC и WebP до 50 МБ и 20 мегапикселей; анимации не поддерживаются. HDR преобразуется в SDR sRGB.")
                    section("Проверка результата", "Кнопка детектора открывает сайт Google в браузере. Приложение не отправляет ему фото автоматически. Если решите проверить файл, его загрузку вы выполняете самостоятельно.")
                    Link("О технологии SynthID ↗", destination: URL(string: "https://deepmind.google/models/synthid/")!)
                    Text("Veil 0.1 · Независимый проект. Не связан с Google или removesynthid.io.")
                        .font(.caption).foregroundStyle(VeilStyle.muted)
                }
                .padding(26).frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
            .background(VeilStyle.paper)
            .foregroundStyle(VeilStyle.ink)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(VeilStyle.muted).lineSpacing(4)
        }
    }
}
