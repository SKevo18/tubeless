import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                appearance
                playback
                sponsorBlock
                recommendations
                discord
                advanced
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 640)
    }

    private var appearance: some View {
        Section("Appearance") {
            ColorPicker("Accent color", selection: colorBinding(\.accentColorHex), supportsOpacity: false)
            Toggle("Dark mode", isOn: $settings.preferDarkMode)
            HStack {
                ForEach(["#FF375F", "#0A84FF", "#30D158", "#BF5AF2", "#FF9F0A", "#64D2FF"], id: \.self) { hex in
                    Circle().fill(Color(hex: hex) ?? .gray).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(.primary.opacity(settings.accentColorHex == hex ? 0.6 : 0), lineWidth: 2))
                        .onTapGesture { settings.accentColorHex = hex }
                }
            }
        }
    }

    private var playback: some View {
        Section("Playback") {
            Toggle("Prefer song versions over music videos", isOn: $settings.preferSongVersions)
                .help("Ranks '- Topic' / audio uploads above official videos in search results.")

            Toggle("Automatically skip unavailable songs", isOn: $settings.autoSkipUnreachable)
            Toggle("Auto-retry on network errors", isOn: $settings.autoRetry)

            Toggle("Crossfade between songs", isOn: $settings.fadeEnabled)
            Group {
                Stepper("Fade out: \(settings.fadeOutSeconds, specifier: "%.1f")s",
                        value: $settings.fadeOutSeconds, in: 0...10, step: 0.5)
                Stepper("Fade in: \(settings.fadeInSeconds, specifier: "%.1f")s",
                        value: $settings.fadeInSeconds, in: 0...10, step: 0.5)
            }
            .disabled(!settings.fadeEnabled)
            .padding(.leading, 8)

            Stepper("Preload next \(settings.prebufferCount) song(s)",
                    value: $settings.prebufferCount, in: 0...5)
            Stepper("Buffer \(Int(settings.prebufferSeconds))s ahead of each",
                    value: $settings.prebufferSeconds, in: 5...30, step: 5)
            Text("Preloading buffers nearby songs (previous + next) so they start instantly.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Prefetch songs on hover", isOn: $settings.prefetchOnHover)
            Text("Resolves a song's stream while you hover it, so clicking plays almost instantly.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Download quality", selection: $settings.downloadQuality) {
                Text("128 kbps").tag("128")
                Text("192 kbps").tag("192")
                Text("320 kbps").tag("320")
            }
            Text("MP3 downloads need ffmpeg (brew install ffmpeg). Saved to your Downloads folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sponsorBlock: some View {
        Section("SponsorBlock") {
            Toggle("Enable SponsorBlock", isOn: $settings.sponsorBlockEnabled)
            Group {
                colorRow("Non-music sections", isOn: $settings.sbMusicOfftopic, color: colorBinding(\.colorMusicOfftopic))
                colorRow("Sponsor segments", isOn: $settings.sbSponsor, color: colorBinding(\.colorSponsor))
                colorRow("Intros & outros", isOn: $settings.sbIntroOutro, color: colorBinding(\.colorIntroOutro))
                Toggle("Show segments on the timeline", isOn: $settings.showSegmentsOnTimeline)
            }
            .disabled(!settings.sponsorBlockEnabled)
            .padding(.leading, 8)
        }
    }

    private var recommendations: some View {
        Section("Recommendations") {
            Toggle("Auto-queue similar songs", isOn: $settings.autoQueueRecommendations)
            Stepper("Fetch \(settings.recommendationRefreshCount) per refill",
                    value: $settings.recommendationRefreshCount, in: 5...50, step: 5)
            Stepper("Keep \(settings.recentlyPlayedLimit) recently played",
                    value: $settings.recentlyPlayedLimit, in: 10...200, step: 10)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Last.fm API key (optional)", text: $settings.lastfmApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Adds collaborative-filtering recommendations. Without a key, YouTube's radio mix is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var discord: some View {
        Section("Discord Rich Presence") {
            Toggle("Show what I'm listening to on Discord", isOn: $settings.discordRPCEnabled)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Discord application client ID", text: $settings.discordClientID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.discordRPCEnabled)
                Text("Create an app at discord.com/developers and paste its Application ID.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var advanced: some View {
        Section("Advanced") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("yt-dlp path", text: $settings.ytdlpPath).textFieldStyle(.roundedBorder)
                    Image(systemName: ytdlpValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ytdlpValid ? .green : .red)
                    Button("Browse…") { browseForYTDLP() }
                }
                HStack {
                    Button("Auto-detect") {
                        if let p = AppSettings.discoverYTDLP() { settings.ytdlpPath = p }
                    }
                    .controlSize(.small)
                    Text(ytdlpValid ? "Found" : "Not found at this path")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ytdlpValid: Bool { FileManager.default.isExecutableFile(atPath: settings.ytdlpPath) }

    private func colorRow(_ label: String, isOn: Binding<Bool>, color: Binding<Color>) -> some View {
        HStack {
            Toggle(label, isOn: isOn)
            Spacer()
            ColorPicker("", selection: color, supportsOpacity: false).labelsHidden()
        }
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, String>) -> Binding<Color> {
        Binding(get: { Color(hex: settings[keyPath: keyPath]) ?? .gray },
                set: { settings[keyPath: keyPath] = $0.hexString })
    }

    private func browseForYTDLP() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        let current = (settings.ytdlpPath as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: current) {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        if panel.runModal() == .OK, let url = panel.url {
            settings.ytdlpPath = url.path
        }
    }
}
