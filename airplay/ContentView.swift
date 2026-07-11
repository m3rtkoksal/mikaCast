import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @AppStorage("appLanguage") private var languageCode = AppLanguage.turkish.rawValue
    @State private var model = PlaybackModel()

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .turkish
    }

    var body: some View {
        VStack(spacing: 20) {
            statusCard

            PlayerView(player: model.player)
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            controls
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 480)
        .environment(\.locale, language.locale)
        .onChange(of: languageCode) { _, _ in
            model.refreshLanguage()
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
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = SupportedVideo.contentTypes

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await model.play(file: url)
            }
        }
    }
}

private enum SupportedVideo {
    static var contentTypes: [UTType] {
        [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            .video,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "avi") ?? .movie,
            UTType(filenameExtension: "webm") ?? .movie
        ]
    }
}

#Preview {
    ContentView()
}
