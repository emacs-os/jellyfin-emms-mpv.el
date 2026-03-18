# jellyfin-emms-mpv.el

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
| `M-x jellyfin-browse-movies`            | Pick a movie, open mpv                               |
| `M-x jellyfin-browse-shows`             | Series -> season -> pick episode, mpv plays through  |
| `M-x jellyfin-browse-continue-watching` | Resume a movie or show where you left off            |
| `M-x jellyfin-browse-albums`            | Artist -> album -> queue tracks in EMMS              |
| `M-x jellyfin-browse-playlists`         | Pick playlist -> queue tracks in EMMS                |

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
  (setq jellyfin-server-url "https://your-server.example.com"))
```

### With straight.el

```elisp
(use-package jellyfin-emms-mpv
  :defer t
  :straight (:host github :repo "emacs-os/jellyfin-emms-mpv.el")
  :config
  (setq jellyfin-server-url "https://your-server.example.com"))
```

---

## How it Works

**Video** (movies, shows, continue-watching): Spawns mpv directly via `start-process`, completely bypassing EMMS. Movies are a single `completing-read` pick; shows add two more steps (series -> season -> episode), then generate an m3u playlist from the chosen episode through the end of the selected season so mpv plays them in sequence. Playback position is tracked via mpv's IPC socket and reported to Jellyfin's session API for "Continue Watching" progress.

Resuming a movie seeks to the saved position. Resuming an episode fetches the remaining episodes in that season and builds a playlist from the resumed episode through the end of the season, seeking to the saved position in the first entry.

**Audio** (albums, playlists): Uses EMMS's normal player system (`emms-add-url`, `emms-playlist-mode-play-current-track`), so it respects `emms-player-list`. If someone has VLC or another player configured instead of mpv, EMMS will use that for audio. No Jellyfin progress reporting is done for audio playback.

The mpv requirement is only for video. Audio works with whatever EMMS player the user already has configured.

## License

MIT
