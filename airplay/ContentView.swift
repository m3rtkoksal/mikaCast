import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @AppStorage("appLanguage") private var languageCode = AppLanguage.turkish.rawValue
    @State private var model = PlaybackModel()
    @State private var isDropTargeted = false

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .turkish
    }

    var body: some View {
        VStack(spacing: 20) {
            statusCard

            PlayerView(player: model.player)
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.tint, lineWidth: 2)
                    }
                }

            controls
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 480)
        .background(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
        .environment(\.locale, language.locale)
        .onChange(of: languageCode) { _, _ in
            model.refreshLanguage()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            if model.isPreparing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: model.isExternalPlaybackActive ? "airplayvideo" : "tv.and.mediabox")
                    .foregroundStyle(model.isExternalPlaybackActive ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let name = model.currentFileName {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Text(L10n.string("language"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .id(languageCode)

                Picker("", selection: $languageCode) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName)
                            .tag(lang.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        HStack {
            Button(L10n.string("select_file")) {
                openFilePicker()
            }
            .keyboardShortcut("o", modifiers: .command)
            .id(languageCode)

            Spacer()
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // Do NOT filter by UTI. Fresh / huge downloads often have no Spotlight
        // content type yet (null UTI) and macOS greys them out in the panel.
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true

        if panel.runModal() == .OK, let url = panel.url {
            playResolved(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                playResolved(url)
            }
        }
        return true
    }

    private func playResolved(_ url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else {
            model.reportUnsupportedFile()
            return
        }

        if isDir.boolValue {
            guard let video = SupportedVideo.firstVideo(in: url) else {
                model.reportUnsupportedFile()
                return
            }
            Task { await model.play(file: video, securityScopedRoot: url) }
            return
        }

        if SupportedVideo.isSupported(url) {
            Task { await model.play(file: url) }
        } else {
            model.reportUnsupportedFile()
        }
    }
}

private enum SupportedVideo {
    static let extensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "ts", "m2ts", "mpg", "mpeg"
    ]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func firstVideo(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files
            .filter { isSupported($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }
}

#Preview {
    ContentView()
}
