# jellyfin-emms-mpv.el

Jellyfin API client for Emacs EMMS with mpv.

Browse and play music/video from a Jellyfin server via EMMS + mpv. Tracks playback state via mpv IPC and reports to Jellyfin's session API so "Continue Watching" stays up to date.

## Assumptions

- Your Jellyfin libraries are named "Movies", "Shows", and "Playlists"
- EMMS is installed
- mpv is installed

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

### With Elpaca

```elisp
(use-package jellyfin-emms-mpv
  :ensure (:host github :repo "emacs-os/jellyfin-emms-mpv.el")
  :commands (jellyfin-browse-movies jellyfin-browse-albums
             jellyfin-browse-playlists jellyfin-browse-shows
             jellyfin-browse-continue-watching)
  :custom
  (jellyfin-server-url "https://your-server.example.com"))
```

## License

MIT
