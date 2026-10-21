# GlassPlayer roadmap

What a full-featured iOS player has that GlassPlayer doesn't yet, grouped by
how much they change day-to-day use. Items are ordered within each group by
value ÷ effort. Nothing here is committed to a version until it moves into a
release note.

## Done (1.0 → 1.7)
mpv/libmpv engine (Metal · libplacebo · Dolby Vision · HDR · TrueHD/DTS/Atmos passthrough-free decode) · Liquid Glass chrome · active PiP in background · WebDAV library (Real-Debrid, NAS) with logos and search · local library with IMDb metadata · Discover (IMDb charts/genres/search, optional TMDB, streaming-service rows) · Stremio stream addons · skip intro/outro (AniSkip/OAT) · Anime4K and Enhanced Quality · GLSL shaders and Lua scripts · chapters, markers, hold-to-speed · diagnostics with redaction.

## Tier 1 — things people notice every session
1. **Seek-bar thumbnails** — frame strip generated in the background (mpv `screenshot-raw` at keyframes, cached per file) shown in the scrub bubble. Needed for long films; the live-seek added in 1.6 covers most of it.
2. **Up next / autoplay for series** — when an episode ends: countdown card, next episode from the library (same show, next S/E by filename), from a WebDAV folder, or from the addon episode list.
3. **Subtitle search** — OpenSubtitles (hash + name search) straight from the Tracks panel; download and attach. Currently only addon subtitles.
4. **Audio passthrough & output picker** — route to AirPlay/HomePod/HDMI adapters with multichannel; show current route in the Tracks panel.
5. **Background audio for music** — library audio files (FLAC, OPUS…) with lock-screen art and Now Playing controls (MPNowPlayingInfoCenter already partly wired for video).
6. **Gesture customisation** — map left/right swipe, double-tap zones and pinch in Settings; option to disable brightness/volume swipes.

## Tier 2 — library and metadata
7. **Match fixing** — long-press a tile → "Fix match": pick the right IMDb title/episode when the filename parser guesses wrong.
8. **Collections and folders** — show the Media folder's sub-folders as groups; series grouped into seasons with episode art.
9. **Watched state and sync** — mark watched/unwatched, per-episode progress badges; optional **Trakt** scrobbling (OAuth, scrobble start/pause/stop, pull watched history).
10. **Wi-Fi transfer** — in-app HTTP server (GCDWebServer-style) so files can be dropped from a computer without the Files app; also plain URL download with progress.
11. **More sources** — SMB (via libsmb2), FTP/SFTP, Jellyfin/Plex/Emby (official APIs expose direct-play streams), Google Drive/OneDrive (OAuth, range requests).
12. **Smart playlists** — recently added, unwatched, by genre; continue-watching across local and WebDAV.

## Tier 3 — player depth
13. **Audio EQ and normalisation** — mpv `af=lavfi` equaliser presets, `dynaudnorm` night mode, per-file audio delay memory.
14. **Subtitle styling** — font, size, colour, outline, background, vertical offset (sub-ass-override) with live preview; secondary subtitle track.
15. **Frame-by-frame, A-B loop, bookmarks with notes** — markers already exist; add A-B loop controls and export.
16. **Playback speed presets & pitch correction toggle** (`audio-pitch-correction`).
17. **Video filters** — brightness/contrast/saturation/gamma sliders, deinterlace toggle, rotation.
18. **External display** — true second-screen playback (UIScreen/UIWindowScene for the external display with controls staying on the phone).
19. **Shader management UI** — enable/disable/reorder chains per file type (anime vs live-action auto-switch by IMDb genre).
20. **Keyboard & game-controller** — full key map (mpv input.conf), controller seek/pause.

## Tier 4 — polish and platform
21. **iPad layout** — sidebar navigation, multi-column library, keyboard shortcuts, Stage Manager window sizes.
22. **Home Screen widgets / Shortcuts** — "Continue watching" widget, App Intents for "Play latest episode of…".
23. **Localisation** — strings catalog; IMDb language already selectable.
24. **Accessibility** — VoiceOver labels on every glass control, Dynamic Type in panels, reduce-motion variants of the spring transitions.
25. **Siri Remote / tvOS** — the engine and UI split are already there; tvOS target would reuse PlayerModel.

## Known gaps to close before any public release
- IMDb page access depends on the WAF challenge staying solvable in WebKit; keep the TMDB path as fallback and consider an own metadata proxy.
- Streaming-service rows come from a community addon host; cache aggressively, fail quietly.
- Sideloading: no App Store entitlements (no background downloads beyond ~30 s, no CarPlay); document it.

## What could be paid (one-time "Pro" unlock)

Keep everything a player *needs* free — playback of every format, Liquid Glass UI, PiP, one WebDAV server, local library with IMDb metadata, Discover, subtitles, chapters, skip intro. Charge once for the things that are conveniences, integrations or power-user depth:

| Pro feature | Why people pay for it |
|---|---|
| Unlimited WebDAV / cloud sources (SMB, FTP, Google Drive, OneDrive, Jellyfin/Plex/Emby) | Infuse's model; sources are the sticky part |
| Trakt sync + watched-state across devices | Ongoing value, hard to replicate |
| Seek-bar thumbnails & live scrub strip | Visible polish, costs CPU work to build |
| Anime4K / shader presets per genre, Enhanced Quality profiles | Enthusiast feature |
| Subtitle styling (fonts, colours, outline, position) and OpenSubtitles search | Daily-use convenience |
| Audio EQ, night-mode normalisation, audio route picker | Power-user audio |
| Wi-Fi transfer server & URL downloads with queue | Replaces a separate app |
| Up-next autoplay with countdown, smart playlists, collections | Binge features |
| App icons, accent colours, custom glass tint, iPad layout extras | Cosmetic, cheap to build |
| Priority metadata (TMDB key bundled through a proxy), "Fix match" | Saves the user from getting their own key |

Pricing shape that works for this category: free tier with no time limit, Pro unlock as a single purchase (A$14–20), optional "supporter" tier later. 

Caveat for a sideloaded build: StoreKit in-app purchase only works through the App Store (TestFlight included). For a sideloaded/KSign distribution the only honest options are a licence key checked against your own server, or making the sideloaded build fully unlocked and charging only on the App Store.
