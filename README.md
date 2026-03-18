# jellyfin-emms-mpv.el

<p align="center">
  <img src="logo.png" alt="jellyfin-emms-mpv.el" width="256">
</p>

Jellyfin API client for Emacs EMMS with mpv.

Browse and play music/video from a Jellyfin server via EMMS + mpv. Tracks playback state via mpv IPC and reports to Jellyfin's session API so "Continue Watching" stays up to date.

## Requirements

- A Jellyfin server
- EMMS (for Music/Audio, it will play through whatever you have configured)
- mpv (for Movies and Shows, mpv is required)

Media is discovered by type (Movie, Shows, Music, etc.) across all libraries on the server - library names and folder structure don't matter.

## Usage

| Command                                  | Description                                          |
|------------------------------------------|------------------------------------------------------|
| `M-x jellyfin-browse-movies`            | Pick a movie, open mpv. Minibuffer completion; with `jellyfin-preview` shows poster previews that narrow as you type |
| `M-x jellyfin-browse-movies-gallery`   | Poster grid of all movies (GUI only). No minibuffer; navigate and search like a normal text buffer. Click or RET to play. Images are cached to disk |
| `M-x jellyfin-browse-shows`             | Series -> season -> pick episode, mpv plays through to end of season. Minibuffer completion; with `jellyfin-preview` shows poster previews that narrow as you type |
| `M-x jellyfin-browse-shows-gallery`    | Poster grid of all shows (GUI only). Drill down through series -> season -> episode without the minibuffer, dired-inspired. Click or RET to play; mpv plays through to end of season. Images are cached to disk |
| `M-x jellyfin-browse-continue-watching` | Resume a movie or show where you left off. For shows, mpv plays through to end of season. Minibuffer completion; with `jellyfin-preview` shows poster previews that narrow as you type |
| `M-x jellyfin-browse-albums`            | Artist -> album -> queue tracks in EMMS              |
| `M-x jellyfin-browse-playlists`         | Pick playlist -> queue tracks in EMMS                |
| `M-x jellyfin-browse-songs`            | Dired-like song picker, mark with m, unmark with u, queue tracks in EMMS with RET |
| `M-x jellyfin-browse-songs-refetch-metadata` | Bust the local song cache and re-fetch from the server. The cache powers the `jellyfin-browse-songs` picker |
| `M-x jellyfin-browse-movies-gallery-refetch-metadata` | Bust the local movie/poster cache. Run `jellyfin-browse-movies-gallery` after to re-fetch |
| `M-x jellyfin-browse-shows-gallery-refetch-metadata` | Bust the local show/poster cache. Run `jellyfin-browse-shows-gallery` after to re-fetch |

### Metadata and image caching

`jellyfin-browse-songs`, `jellyfin-browse-movies-gallery`, and `jellyfin-browse-shows-gallery` are the slowest operations (fetching every item and its images from the server), so they cache their metadata to disk (in `user-emacs-directory`). Only the first invocation hits the server; after that they open instantly.

| Cache file                            | Command                              |
|---------------------------------------|--------------------------------------|
| `jellyfin-songs-cache.el`             | `jellyfin-browse-songs`              |
| `jellyfin-movies-gallery-cache.el`    | `jellyfin-browse-movies-gallery`     |
| `jellyfin-shows-gallery-cache.el`     | `jellyfin-browse-shows-gallery`      |

Poster images are cached separately in `jellyfin-image-cache/` (inside `user-emacs-directory`) and shared across all commands — a poster fetched during `jellyfin-browse-movies` will be reused by `jellyfin-browse-movies-gallery` and vice versa.

Run the corresponding refetch command when you've added, removed, or renamed media on your Jellyfin server. Each one deletes the old metadata cache and its associated poster images, then re-fetches everything fresh:

- `M-x jellyfin-browse-songs-refetch-metadata`
- `M-x jellyfin-browse-movies-gallery-refetch-metadata`
- `M-x jellyfin-browse-shows-gallery-refetch-metadata`

`jellyfin-browse-continue-watching` always fetches fresh from the server (no cache) since the list changes every time you watch something.

## Installation

Add your Jellyfin credentials to `~/.authinfo`:

```
machine your-server.example.com login USERNAME password PASSWORD
```

If your server uses a custom port (e.g. `http://your-server.example.com:8096`), use the hostname only in the `machine` field:

```
machine your-server.example.com port 8096 login USERNAME password PASSWORD
```

Note: custom port auth-source matching is untested. Please report any issues.

### With Elpaca

```elisp
(use-package jellyfin-emms-mpv
  :defer t
  :ensure (:host github :repo "emacs-os/jellyfin-emms-mpv.el")
  :config
  (setq jellyfin-server-url "https://your-server.example.com"
        jellyfin-preview t
        jellyfin-preferred-language "eng"
        jellyfin-subtitles t))
```

### With straight.el

```elisp
(use-package jellyfin-emms-mpv
  :defer t
  :straight (:host github :repo "emacs-os/jellyfin-emms-mpv.el")
  :config
  (setq jellyfin-server-url "https://your-server.example.com"
        jellyfin-preview t
        jellyfin-preferred-language "eng"
        jellyfin-subtitles t))
```

### mpv (required for movies/shows)

mpv handles virtually every codec and container format out of the box, so all streams are direct play (no server-side transcoding needed).

```bash
# Arch
sudo pacman -S mpv

# Debian / Ubuntu
sudo apt-get install mpv

# Fedora
sudo dnf install mpv

# macOS
brew install mpv
```

### EMMS configuration (required for music)

The following is the Elpaca EMMS configuration used personally during development and testing. It is not required to be this way, but is here for informational purposes:

```elisp
(use-package emms
  :ensure t
  :defer t
  :config
  (require 'emms-setup)
  (emms-all)
  (setq emms-player-list '(emms-player-mpv))
  (setq emms-player-mpv-parameters '("--no-video")))
```

Or with straight.el:

```elisp
(use-package emms
  :straight t
  :defer t
  :config
  (require 'emms-setup)
  (emms-all)
  (setq emms-player-list '(emms-player-mpv))
  (setq emms-player-mpv-parameters '("--no-video")))
```

## Configuration

| Variable                       | Default | Description                                                      |
|--------------------------------|---------|------------------------------------------------------------------|
| `jellyfin-server-url`          | `nil`   | Base URL of your Jellyfin server                                 |
| `jellyfin-preview`             | `nil`   | Show a preview buffer with posters and descriptions when browsing, requires graphical Emacs, fancier, but slower |
| `jellyfin-preferred-language`  | `nil`   | Preferred audio language for video playback (ISO 639-2, e.g. `"eng"`, `"jpn"`). See below. |
| `jellyfin-subtitles` | `nil`   | When non-nil, enable subtitles matching `jellyfin-preferred-language`. See below. |

Most media files have a single audio track so language selection never comes up. For files with multiple audio tracks (e.g. foreign films with both original and dubbed audio, or anime with Japanese and English tracks), the player uses the container's default track which may not be the language you want. Setting `jellyfin-preferred-language` to a three-letter ISO 639-2 code (e.g. `"eng"`, `"jpn"`, `"fre"`) passes `--alang` to mpv, which selects the matching audio track without breaking direct play. Falls back to the container default if no match is found.

When `jellyfin-subtitles` is also enabled, mpv will show subtitles matching the preferred language if the file contains them (via `--slang`). Requires `jellyfin-preferred-language` to be set.

When `jellyfin-preview` is enabled:

- **Movies**: a side buffer with poster images, titles, and descriptions updates as you type to narrow results. Clicking a title or poster selects that movie.
- **Shows**: series selection works the same way; after picking a series the buffer becomes a clickable drill-down through seasons and episodes with images and descriptions at each level.
- **Albums/Playlists**: album cover art is displayed at the top of the EMMS playlist buffer and updates dynamically as the current track changes. Falls back to artist image, then the Jellyfin server splash screen if no cover is found.

---

## How it Works

### Video (movies, shows, continue-watching)

Spawns mpv directly via `start-process`, completely bypassing EMMS. Movies are a single `completing-read` pick; shows add two more steps (series -> season -> episode), then generate an m3u playlist from the chosen episode through the end of the selected season so mpv plays them in sequence. Playback position is tracked via mpv's IPC socket and reported to Jellyfin's session API for "Continue Watching" progress.

Resuming a movie seeks to the saved position. Resuming an episode fetches the remaining episodes in that season and builds a playlist from the resumed episode through the end of the season, seeking to the saved position in the first entry.

The mpv requirement is only for video. Audio works with whatever EMMS player the user already has configured.

### Audio (albums, playlists, song picker)

Audio integrates with EMMS using its native extension points rather than ad-hoc track decoration:

**Info method** (`emms-info-jellyfin`): Registered in `emms-info-functions` via `with-eval-after-load`. When EMMS creates a track, this function checks if the URL points at the configured Jellyfin server. If so, it looks up the item metadata and sets standard EMMS keys:

| Key                | Source                        |
|--------------------|-------------------------------|
| `info-title`       | Song name                     |
| `info-artist`      | Album artist name             |
| `info-album`       | Album name                    |
| `info-tracknumber` | Track number within album     |

It also sets `jellyfin-cover-id` and `jellyfin-artist-id` for cover art display.

Because metadata flows through EMMS's own info pipeline, track information is available everywhere EMMS expects it (playlist display, modeline, etc.) without any manual post-insertion fixup.

**Item cache**: Metadata lookups are backed by an in-memory hash table (`jellyfin--item-cache`) keyed by Jellyfin item ID. The song picker's disk cache and each browse command pre-populate this table before adding tracks, so the info method resolves instantly with no extra API calls. On a cache miss (e.g. a track added by something else), it falls back to a single API request and caches the result.

**Playback**: Uses EMMS's normal player system (`emms-player-list`), so it respects whatever player the user has configured (mpv, VLC, etc.). No Jellyfin progress reporting is done for audio.

## Why video bypasses EMMS

Movies and shows spawn mpv directly instead of going through EMMS. This is deliberate -EMMS's player model doesn't support what video playback needs:

- **Progress reporting**: An IPC connection over a Unix socket tracks playback position in real time and reports it to Jellyfin's session API every 30 seconds, keeping "Continue Watching" accurate. EMMS has no equivalent -it hands a URL to a player and forgets about it.
- **Resume**: When you resume a movie or episode, mpv seeks to the saved position on launch. EMMS doesn't track or restore playback position.
- **Seamless episode transitions**: Shows generate an m3u playlist so mpv plays episodes in sequence with its own native playlist handling. If EMMS managed the playlist instead, every episode transition would kill one mpv instance and spawn another, losing seamless playback.
- **Pause/state tracking**: mpv's pause state is observed over IPC so the correct status is reported to Jellyfin. EMMS doesn't expose player state this way.

Audio has none of these requirements (no progress reporting, no resume, no multi-episode playlists), so it uses EMMS normally and benefits from EMMS's playlist management, metadata display, and player abstraction.

## License

MIT
