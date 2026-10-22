import SwiftUI
import PhotosUI

/// 背景图选择：相册（PHPicker，无需相册权限）或 URL 下载；已设置时可清除。
struct BackgroundImagePickerSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showPhotoPicker = false
    @State private var urlText = ""
    @State private var downloading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("从相册选择") {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("选择照片", systemImage: "photo.on.rectangle")
                    }
                }
                Section {
                    TextField("https://example.com/bg.jpg", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        download()
                    } label: {
                        HStack {
                            Label("下载", systemImage: "arrow.down.circle")
                            if downloading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(urlText.isEmpty || downloading)
                } header: {
                    Text("从 URL 下载")
                } footer: {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
                if app.backgroundImage != nil {
                    Section {
                        Button("清除背景图", role: .destructive) {
                            app.clearBackgroundImage()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("背景图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { data in
                    guard let data else { return }
                    do {
                        try app.applyBackgroundImage(data)
                        dismiss()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
        }
    }

    private func download() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            errorText = "URL 无效"
            return
        }
        downloading = true
        errorText = nil
        Task { @MainActor in
            defer { downloading = false }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !data.isEmpty else {
                    errorText = "下载失败：无内容"
                    return
                }
                try app.applyBackgroundImage(data)
                dismiss()
            } catch {
                errorText = "下载失败：\(error.localizedDescription)"
            }
        }
    }
}

/// PHPicker 封装：选中后回传原始图片数据（无需相册读取权限）。
struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: (Data?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (Data?) -> Void
        init(onPick: @escaping (Data?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let callback = onPick
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                Task { @MainActor in callback(nil) }
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                // 统一重编码为 JPEG，避免 HEIC 直存后解码失败。
                let data = image.flatMap {
                    $0.jpegData(compressionQuality: 0.9) ?? $0.pngData()
                }
                Task { @MainActor in callback(data) }
            }
        }
    }
}
