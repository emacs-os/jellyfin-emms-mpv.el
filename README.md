# jellyfin-emms-mpv.el

Jellyfin API client for Emacs EMMS with mpv.

Browse and play music/video from a Jellyfin server via EMMS + mpv. Tracks playback state via mpv IPC and reports to Jellyfin's session API so "Continue Watching" stays up to date.

## Requirements

- A Jellyfin server
- EMMS
- mpv

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

## License

MIT
