# Tubeless Audio

A lightweight, custom-UI macOS audio player for YouTube Music, minus the bullshit.
No browser, no embedded player, no Electron — native SwiftUI over `yt-dlp` + `AVPlayer`,
styled like YouTube Music.

## Features

### Playback & sources

- Audio-only streaming via [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) (direct `m4a`/AAC
  to `AVPlayer`; no transcoding, low memory).
- Prefers clean **song versions** (`"- Topic"` / official audio) over music videos.
- **Single click** plays a track and opens the expanded player.

### UI (YouTube-Music style)

- Left sidebar: Home · Search · Library · Liked Songs · your playlists.
- **Home**: "Listen again" (recently played) + "Discovery" (personalized) + playlists.
- **Expanded player**: large artwork with an **Up Next / Related** side panel ("radio").
- Clear highlight + animated speaker icon on the currently-playing row.

### Library & playlists (persistent)

- Liked songs, playlists, and recently-played history saved to
  `~/Library/Application Support/Tubeless/library.json`.
- Like from any row / the player; add to / remove from playlists; reorder the queue.

### SponsorBlock

- Auto-skips non-music sections, sponsors, intros/outros.
- **Segments are painted on the timeline** in per-category colors (configurable):
  non-music = red, sponsor = green, intro/outro = blue by default.

### Recommendations

- **Discovery** + **Related** powered by Last.fm `track.getSimilar` when an API key is
  set, otherwise YouTube's own radio mix (zero-config fallback).

### System integration

- **Media keys (fn+F8) & Control Center**: publishes to the system Now Playing center via
  `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`, so the play-pause key controls
  Tubeless instead of Apple Music while it's the active audio app. Artwork, scrubbing
  and next/prev work from Control Center too.
- **Discord Rich Presence** (optional): shows "Listening to …" with progress. Speaks the
  local Discord IPC protocol directly — no third-party library. Needs a Discord
  application client ID (off by default).

### Settings

- Accent color + dark mode, song-preference, per-category SponsorBlock toggles & colors,
  timeline-segment visibility, recommendation count, recently-played cap, Last.fm key,
  Discord toggle + client ID, and yt-dlp path with **auto-detect** + **Browse…**.

## Requirements

- macOS 13+ (Ventura or newer)
- Xcode Command Line Tools (`xcode-select --install`) — full Xcode not required
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp): `brew install yt-dlp` (auto-detected)
- `ffmpeg` optional (not used for plain streaming): `brew install ffmpeg`

## Run

```bash
./run.sh            # build (release), assemble Tubeless.app, launch
./run.sh --debug    # faster compile for iterating
./run.sh --clean    # wipe build artifacts and the .app first
```

## Optional setup

- **Last.fm recommendations**: get a free API key at
  <https://www.last.fm/api/account/create>, paste it into Settings → Recommendations.
- **Discord presence**: create an app at <https://discord.com/developers/applications>,
  copy its *Application ID* into Settings → Discord, and enable the toggle.

## Architecture

```text
Sources/Tubeless/
  App.swift                 @main app, scenes, theming, env objects
  Models/
    Track.swift             a YouTube item (+ title cleaning / artist split)
    Playlist.swift          a named list of tracks
    Settings.swift          UserDefaults-backed settings (singleton)
    Navigation.swift        page routing + search + single-click play
  Services/
    YTDLPService.swift      actor wrapping yt-dlp (search / stream / radio / firstResult)
    SponsorBlock.swift      skip-segment fetch
    LibraryStore.swift      persistent recents / likes / playlists
    LastFM.swift            track.getSimilar client
    Recommender.swift       Related + Discovery (Last.fm → YouTube fallback)
    NowPlayingCenter.swift  media keys + Control Center (MediaPlayer framework)
    DiscordRPC.swift        Rich Presence over local Discord IPC socket
    AudioPlayer.swift       AVPlayer wrapper: queue, transport, SB skipping, integrations
  Views/
    ContentView.swift       shell: sidebar + top bar + content + player bar
    SidebarView.swift       navigation + playlists
    HomeView.swift          Listen again / Discovery / playlists
    SearchView.swift        search results
    LibraryView.swift       Library, Liked, Playlist pages
    ExpandedPlayerView.swift big artwork + Up Next / Related
    NowPlayingBar.swift     bottom transport + SponsorBlock timeline
    SponsorTimeline.swift   interactive seek bar with colored segments
    Components.swift        Artwork, TrackRow, TrackCard, SectionHeader
    SettingsView.swift      settings sheet / preferences
  Util/Color+Hex.swift      Color <-> hex
```

## Known limitations (prototype)

- Stream URLs are time-limited; very long pauses may require re-resolving.
- AVPlayer plays `m4a`/AAC; opus-only videos may need `ffmpeg` remuxing (rare).
- No lyrics source wired up (the expanded panel shows Up Next / Related only).
- Not sandboxed / not notarized — local dev prototype.
- Discord presence cover-art uses the YouTube thumbnail URL; if Discord doesn't proxy it,
  text + progress still show.
