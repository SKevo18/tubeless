import SwiftUI

// observable, UserDefaults-backed app settings. shared singleton so background
// services can read paths/categories without threading the object everywhere.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var accentColorHex: String { didSet { d.set(accentColorHex, forKey: K.accent) } }
    @Published var preferDarkMode: Bool { didSet { d.set(preferDarkMode, forKey: K.dark) } }
    @Published var preferSongVersions: Bool { didSet { d.set(preferSongVersions, forKey: K.songs) } }

    @Published var sponsorBlockEnabled: Bool { didSet { d.set(sponsorBlockEnabled, forKey: K.sbOn) } }
    @Published var sbMusicOfftopic: Bool { didSet { d.set(sbMusicOfftopic, forKey: K.sbMusic) } }
    @Published var sbSponsor: Bool { didSet { d.set(sbSponsor, forKey: K.sbSponsor) } }
    @Published var sbIntroOutro: Bool { didSet { d.set(sbIntroOutro, forKey: K.sbIntro) } }
    @Published var showSegmentsOnTimeline: Bool { didSet { d.set(showSegmentsOnTimeline, forKey: K.sbShow) } }

    // per-category segment colors (also used to tint the timeline)
    @Published var colorMusicOfftopic: String { didSet { d.set(colorMusicOfftopic, forKey: K.colMusic) } }
    @Published var colorSponsor: String { didSet { d.set(colorSponsor, forKey: K.colSponsor) } }
    @Published var colorIntroOutro: String { didSet { d.set(colorIntroOutro, forKey: K.colIntro) } }

    @Published var autoSkipUnreachable: Bool { didSet { d.set(autoSkipUnreachable, forKey: K.autoSkip) } }
    @Published var autoRetry: Bool { didSet { d.set(autoRetry, forKey: K.autoRetry) } }

    @Published var fadeEnabled: Bool { didSet { d.set(fadeEnabled, forKey: K.fadeOn) } }
    @Published var fadeOutSeconds: Double { didSet { d.set(fadeOutSeconds, forKey: K.fadeOut) } }
    @Published var fadeInSeconds: Double { didSet { d.set(fadeInSeconds, forKey: K.fadeIn) } }
    @Published var prebufferCount: Int { didSet { d.set(prebufferCount, forKey: K.preCount) } }
    @Published var prebufferSeconds: Double { didSet { d.set(prebufferSeconds, forKey: K.preSecs) } }

    @Published var autoQueueRecommendations: Bool { didSet { d.set(autoQueueRecommendations, forKey: K.autoRec) } }
    @Published var recommendationRefreshCount: Int { didSet { d.set(recommendationRefreshCount, forKey: K.recCount) } }
    @Published var recentlyPlayedLimit: Int { didSet { d.set(recentlyPlayedLimit, forKey: K.recentLimit) } }
    @Published var lastfmApiKey: String { didSet { d.set(lastfmApiKey, forKey: K.lastfm) } }

    @Published var discordRPCEnabled: Bool { didSet { d.set(discordRPCEnabled, forKey: K.discordOn) } }
    @Published var discordClientID: String { didSet { d.set(discordClientID, forKey: K.discordID) } }

    @Published var playerExpanded: Bool { didSet { d.set(playerExpanded, forKey: K.expanded) } }
    @Published var volume: Double { didSet { d.set(volume, forKey: K.volume) } }
    @Published var downloadQuality: String { didSet { d.set(downloadQuality, forKey: K.dlQuality) } }

    @Published var ytdlpPath: String { didSet { d.set(ytdlpPath, forKey: K.ytdlp) } }

    var accentColor: Color { Color(hex: accentColorHex) ?? .pink }

    var sponsorBlockCategories: [String] {
        guard sponsorBlockEnabled else { return [] }
        var c: [String] = []
        if sbMusicOfftopic { c.append("music_offtopic") }
        if sbSponsor { c.append("sponsor") }
        if sbIntroOutro { c += ["intro", "outro"] }
        return c
    }

    // color used to render a segment category on the timeline
    func color(for category: String) -> Color {
        switch category {
        case "sponsor": return Color(hex: colorSponsor) ?? .green
        case "music_offtopic": return Color(hex: colorMusicOfftopic) ?? .red
        default: return Color(hex: colorIntroOutro) ?? .blue   // intro / outro / other
        }
    }

    private init() {
        accentColorHex = d.string(forKey: K.accent) ?? "#FF375F"
        preferDarkMode = d.object(forKey: K.dark) as? Bool ?? true
        preferSongVersions = d.object(forKey: K.songs) as? Bool ?? true
        sponsorBlockEnabled = d.object(forKey: K.sbOn) as? Bool ?? true
        sbMusicOfftopic = d.object(forKey: K.sbMusic) as? Bool ?? true
        sbSponsor = d.object(forKey: K.sbSponsor) as? Bool ?? true
        sbIntroOutro = d.object(forKey: K.sbIntro) as? Bool ?? true
        showSegmentsOnTimeline = d.object(forKey: K.sbShow) as? Bool ?? true
        colorMusicOfftopic = d.string(forKey: K.colMusic) ?? "#FF453A"
        colorSponsor = d.string(forKey: K.colSponsor) ?? "#30D158"
        colorIntroOutro = d.string(forKey: K.colIntro) ?? "#0A84FF"
        autoSkipUnreachable = d.object(forKey: K.autoSkip) as? Bool ?? true
        autoRetry = d.object(forKey: K.autoRetry) as? Bool ?? true
        fadeEnabled = d.object(forKey: K.fadeOn) as? Bool ?? true
        fadeOutSeconds = d.object(forKey: K.fadeOut) as? Double ?? 3.0
        fadeInSeconds = d.object(forKey: K.fadeIn) as? Double ?? 1.0
        prebufferCount = d.object(forKey: K.preCount) as? Int ?? 2
        prebufferSeconds = d.object(forKey: K.preSecs) as? Double ?? 10.0
        autoQueueRecommendations = d.object(forKey: K.autoRec) as? Bool ?? true
        recommendationRefreshCount = d.object(forKey: K.recCount) as? Int ?? 15
        recentlyPlayedLimit = d.object(forKey: K.recentLimit) as? Int ?? 50
        lastfmApiKey = d.string(forKey: K.lastfm) ?? ""
        discordRPCEnabled = d.object(forKey: K.discordOn) as? Bool ?? false
        discordClientID = d.string(forKey: K.discordID) ?? ""
        playerExpanded = d.object(forKey: K.expanded) as? Bool ?? false
        volume = d.object(forKey: K.volume) as? Double ?? 1.0
        downloadQuality = d.string(forKey: K.dlQuality) ?? "192"
        ytdlpPath = d.string(forKey: K.ytdlp) ?? Self.discoverYTDLP() ?? "/opt/homebrew/bin/yt-dlp"
    }

    // probe common install locations for yt-dlp
    static func discoverYTDLP() -> String? {
        let candidates = [
            "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp", "/opt/local/bin/yt-dlp",
            (FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/yt-dlp"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private enum K {
        static let accent = "accentColorHex"
        static let dark = "preferDarkMode"
        static let songs = "preferSongVersions"
        static let sbOn = "sponsorBlockEnabled"
        static let sbMusic = "sbMusicOfftopic"
        static let sbSponsor = "sbSponsor"
        static let sbIntro = "sbIntroOutro"
        static let sbShow = "showSegmentsOnTimeline"
        static let colMusic = "colorMusicOfftopic"
        static let colSponsor = "colorSponsor"
        static let colIntro = "colorIntroOutro"
        static let autoSkip = "autoSkipUnreachable"
        static let autoRetry = "autoRetry"
        static let fadeOn = "fadeEnabled"
        static let fadeOut = "fadeOutSeconds"
        static let fadeIn = "fadeInSeconds"
        static let preCount = "prebufferCount"
        static let preSecs = "prebufferSeconds"
        static let autoRec = "autoQueueRecommendations"
        static let recCount = "recommendationRefreshCount"
        static let recentLimit = "recentlyPlayedLimit"
        static let lastfm = "lastfmApiKey"
        static let discordOn = "discordRPCEnabled"
        static let discordID = "discordClientID"
        static let expanded = "playerExpanded"
        static let volume = "volume"
        static let dlQuality = "downloadQuality"
        static let ytdlp = "ytdlpPath"
    }
}
