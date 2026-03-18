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
| `M-x jellyfin-browse-songs`            | Dired-like song picker, mark with m, unmark with u, queue tracks in EMMS with RET |
| `M-x jellyfin-browse-songs-refetch-metadata` | Re-fetch song list from server and update cache |

### Song picker cache

`jellyfin-browse-songs` caches the full song list to disk (`jellyfin-songs-cache.el` in `user-emacs-directory`) so only the first invocation is slow. After that the buffer opens instantly.

Run `M-x jellyfin-browse-songs-refetch-metadata` to update the cache when you've added, removed, or renamed songs on your Jellyfin server.

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

## Configuration

| Variable                  | Default | Description                                                      |
|---------------------------|---------|------------------------------------------------------------------|
| `jellyfin-server-url`     | `nil`   | Base URL of your Jellyfin server                                 |
| `jellyfin-preview`        | `nil`   | Show a preview buffer with posters and descriptions when browsing, requires graphical Emacs, fancier, but slower |

When `jellyfin-preview` is enabled:

- **Movies**: a side buffer with poster images, titles, and descriptions updates as you type to narrow results. Clicking a title or poster selects that movie.
- **Shows**: series selection works the same way; after picking a series the buffer becomes a clickable drill-down through seasons and episodes with images and descriptions at each level.
- **Albums/Playlists**: album cover art is displayed at the top of the EMMS playlist buffer and updates dynamically as the current track changes. Falls back to artist image, then the Jellyfin server splash screen if no cover is found.

Works in GUI Emacs (images require graphical display); in terminal Emacs the preview shows titles and descriptions only.

```elisp
(setq jellyfin-preview t)
```

---

## How it Works

**Video** (movies, shows, continue-watching): Spawns mpv directly via `start-process`, completely bypassing EMMS. Movies are a single `completing-read` pick; shows add two more steps (series -> season -> episode), then generate an m3u playlist from the chosen episode through the end of the selected season so mpv plays them in sequence. Playback position is tracked via mpv's IPC socket and reported to Jellyfin's session API for "Continue Watching" progress.

Resuming a movie seeks to the saved position. Resuming an episode fetches the remaining episodes in that season and builds a playlist from the resumed episode through the end of the season, seeking to the saved position in the first entry.

**Audio** (albums, playlists): Uses EMMS's normal player system (`emms-add-url`, `emms-playlist-mode-play-current-track`), so it respects `emms-player-list`. If someone has VLC or another player configured instead of mpv, EMMS will use that for audio. No Jellyfin progress reporting is done for audio playback.

The jellyfin Music library commands use emms-add-url + emms-track-set to manually decorate tracks in EMMS after adding them.

The mpv requirement is only for video. Audio works with whatever EMMS player the user already has configured.

## License

MIT
