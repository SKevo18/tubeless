import SwiftUI

@main
struct TubelessApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var nav = AppNavigation()
    @StateObject private var player = AudioPlayer()
    @StateObject private var downloads = DownloadManager.shared

    var body: some Scene {
        WindowGroup("Tubeless") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(nav)
                .environmentObject(player)
                .environmentObject(downloads)
                .frame(minWidth: 560, minHeight: 420)
                .tint(settings.accentColor)
                .preferredColorScheme(settings.preferDarkMode ? .dark : .light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings { SettingsView().environmentObject(settings) }
    }
}
