;;; jellyfin-emms-mpv.el --- Jellyfin API client for Emacs EMMS with mpv -*- lexical-binding: t; -*-

;; Copyright (C) 2026 emacs-os

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Browse and play music/video from a Jellyfin server via EMMS + mpv.
;; Tracks playback state via mpv IPC and reports to Jellyfin's session API
;; so "Continue Watching" stays up to date.
;;
;; Requirements:
;;   - EMMS
;;   - mpv
;;
;; Usage:
;;   (setq jellyfin-completing-read-preview t) — enable poster/description preview
;;   M-x jellyfin-browse-movies             — pick a movie, open mpv
;;   M-x jellyfin-browse-movies-gallery     — visual movie browser with poster grid (GUI only)
;;   M-x jellyfin-browse-shows              — series -> season -> pick episode, mpv plays through
;;   M-x jellyfin-browse-shows-gallery      — visual show browser with poster grid (GUI only)
;;   M-x jellyfin-browse-continue-watching  — resume a movie or show where you left off
;;   M-x jellyfin-browse-albums             — artist -> album -> queue tracks in EMMS
;;   M-x jellyfin-browse-playlists          — pick playlist -> queue tracks in EMMS
;;   M-x jellyfin-browse-songs              — dired-like song picker (cached; instant after first load)
;;   M-x jellyfin-browse-songs-refetch-metadata — re-fetch after adding/removing songs on server
;;   M-x jellyfin-browse-movies-gallery-refetch-metadata — re-fetch movie list and posters
;;   M-x jellyfin-browse-shows-gallery-refetch-metadata  — re-fetch show list and posters
;;
;; mpv integration (video):
;;   Movies and shows spawn mpv directly via `start-process', bypassing EMMS
;;   entirely.  An IPC connection over a Unix socket observes playlist-pos and
;;   pause state in real time.  A 30-second timer polls playback position and
;;   reports progress to Jellyfin's session API (/Sessions/Playing/Progress),
;;   keeping "Continue Watching" accurate.  On mpv exit, a process sentinel
;;   reports the final position (/Sessions/Playing/Stopped).  Shows generate an
;;   m3u playlist from the chosen episode through the end of the season so mpv
;;   plays them in sequence; episode transitions are tracked via playlist-pos
;;   changes over IPC.
;;
;; EMMS integration (audio):
;;   Audio commands integrate via EMMS's native extension points:
;;   - `emms-info-jellyfin' is an info method (registered in `emms-info-functions')
;;     that resolves Jellyfin stream URLs to standard EMMS metadata (info-title,
;;     info-artist, info-album, info-tracknumber).
;;   - An in-memory item cache (`jellyfin--item-cache') backs metadata lookups so
;;     the info method resolves instantly with no extra API calls.
;;   - Playback uses whatever player the user has in `emms-player-list' (mpv,
;;     VLC, etc.); the mpv requirement is only for video.
;;

;;; Code:

(require 'auth-source)
(require 'json)
(require 'seq)
(require 'url)

(declare-function emms-playlist-current-clear "emms-playlist-mode")
(declare-function emms-add-url "emms")
(declare-function emms-playlist-track-at "emms")
(declare-function emms-track-set "emms")
(declare-function emms-track-get "emms")
(declare-function emms-track "emms")
(declare-function emms-track-type "emms")
(declare-function emms-track-name "emms")
(declare-function emms-playlist-insert-track "emms")
(declare-function emms-playlist-current-selected-track "emms")
(declare-function emms-playlist-mode-play-current-track "emms-playlist-mode")

(defvar url-http-end-of-headers)
(defvar emms-playlist-buffer)
(defvar emms-info-functions)

(defgroup jellyfin nil
  "Jellyfin media server client."
  :group 'multimedia
  :prefix "jellyfin-")

(defcustom jellyfin-server-url nil
  "Base URL of the Jellyfin server (e.g. \"https://host.example.com\")."
  :type 'string)

(define-obsolete-variable-alias 'jellyfin-preview
  'jellyfin-completing-read-preview "0.2.0")

(defcustom jellyfin-completing-read-preview nil
  "When non-nil, show a preview buffer with posters and descriptions
during minibuffer completion in `jellyfin-browse-movies',
`jellyfin-browse-shows', and `jellyfin-browse-continue-watching'.
Has no effect on gallery commands."
  :type 'boolean)

(defcustom jellyfin-preferred-language nil
  "Preferred audio language code (e.g. \"eng\", \"fre\", \"jpn\").
When set, video streams will use the audio track matching this language
if available.  Uses ISO 639-2 three-letter codes as returned by Jellyfin."
  :type '(choice (const nil) string))

(defcustom jellyfin-subtitles nil
  "When non-nil, enable subtitles matching `jellyfin-preferred-language'.
Requires `jellyfin-preferred-language' to be set."
  :type 'boolean)

(defcustom jellyfin-emms-cover-art t
  "When non-nil, show album cover art in the EMMS playlist buffer.
Requires GUI Emacs."
  :type 'boolean)

(defcustom jellyfin-elcava-emms-experimental nil
  "When non-nil, show an embedded elcava spectrum visualizer in the playlist.
Displays a small bar visualizer below the album cover art.
Requires the `elcava' package and `parec'."
  :type 'boolean)

(defvar jellyfin--token nil "Current session access token.")
(defvar jellyfin--user-id nil "Current session user ID.")

(defconst jellyfin--client-name "Emacs")
(defconst jellyfin--client-version "1.0.0")
(defconst jellyfin--device-name (system-name))
(defconst jellyfin--device-id (md5 (system-name)))

;;; --- mpv playback state (one session at a time) ---

(defvar jellyfin--mpv-process nil "The mpv child process.")
(defvar jellyfin--mpv-ipc nil "Unix socket network process to mpv.")
(defvar jellyfin--mpv-timer nil "30-second progress reporting timer.")
(defvar jellyfin--mpv-item-ids nil "Vector of Jellyfin item IDs for current playlist.")
(defvar jellyfin--mpv-position nil "Last known playback position in seconds.")
(defvar jellyfin--mpv-paused nil "Whether mpv is currently paused.")
(defvar jellyfin--mpv-playlist-pos nil "Current playlist index in mpv.")
(defvar jellyfin--mpv-ipc-buf "" "Incomplete IPC data buffer.")
(defvar jellyfin--mpv-socket nil "Path to mpv IPC socket file.")
(defvar jellyfin--mpv-play-session-id nil "Random play session ID for Jellyfin reporting.")
(defvar jellyfin--mpv-start-secs nil "Initial seek position for first playlist item only.")

;;; --- Authentication ---

(defun jellyfin--auth-header ()
  "Build the X-Emby-Authorization header value."
  (format "MediaBrowser Client=\"%s\", Device=\"%s\", DeviceId=\"%s\", Version=\"%s\"%s"
          jellyfin--client-name
          jellyfin--device-name
          jellyfin--device-id
          jellyfin--client-version
          (if jellyfin--token
              (format ", Token=\"%s\"" jellyfin--token)
            "")))

(defun jellyfin--ensure-auth ()
  "Authenticate if we don't have a token yet."
  (unless jellyfin--token
    (jellyfin--authenticate)))

(defun jellyfin--authenticate ()
  "Authenticate with Jellyfin using credentials from auth-source."
  (let* ((host (url-host (url-generic-parse-url jellyfin-server-url)))
         (found (car (auth-source-search :host host :max 1)))
         (user (plist-get found :user))
         (secret (plist-get found :secret))
         (password (if (functionp secret) (funcall secret) secret))
         (url-show-status nil)
         (url-request-noninteractive t)
         (url-request-method "POST")
         (url-request-extra-headers
          `(("Content-Type" . "application/json")
            ("X-Emby-Authorization" . ,(jellyfin--auth-header))))
         (url-request-data
          (json-encode `((Username . ,user) (Pw . ,password))))
         (buf (url-retrieve-synchronously
               (concat jellyfin-server-url "/Users/AuthenticateByName"))))
    (with-current-buffer buf
      (goto-char url-http-end-of-headers)
      (let ((resp (json-read)))
        (setq jellyfin--token (alist-get 'AccessToken resp))
        (setq jellyfin--user-id (alist-get 'Id (alist-get 'User resp))))
      (kill-buffer))))

;;; --- API helpers ---

(defun jellyfin--api-get (path &optional params)
  "GET PATH from the Jellyfin server with optional query PARAMS alist.
Returns parsed JSON."
  (jellyfin--ensure-auth)
  (let* ((query (if params
                    (concat "?" (mapconcat
                                (lambda (p)
                                  (format "%s=%s"
                                          (url-hexify-string (car p))
                                          (url-hexify-string (cdr p))))
                                params "&"))
                  ""))
         (url-show-status nil)
         (url-request-noninteractive t)
         (url-request-method "GET")
         (url-request-extra-headers
          `(("X-Emby-Authorization" . ,(jellyfin--auth-header))))
         (buf (url-retrieve-synchronously
               (concat jellyfin-server-url path query))))
    (with-current-buffer buf
      (goto-char url-http-end-of-headers)
      (prog1 (json-read)
        (kill-buffer)))))

(defun jellyfin--api-post-async (path body)
  "Fire-and-forget async POST to PATH with BODY alist.
Callback kills the response buffer and clears the token on 401."
  (jellyfin--ensure-auth)
  (let ((url-show-status nil)
        (url-request-noninteractive t)
        (url-request-method "POST")
        (url-request-extra-headers
         `(("Content-Type" . "application/json")
           ("X-Emby-Authorization" . ,(jellyfin--auth-header))))
        (url-request-data (json-encode body)))
    (url-retrieve (concat jellyfin-server-url path)
                  (lambda (_status &rest _)
                    (when (and (boundp 'url-http-response-status)
                               (eql url-http-response-status 401))
                      (setq jellyfin--token nil))
                    (when-let ((buf (current-buffer)))
                      (when (buffer-live-p buf)
                        (kill-buffer buf)))))))

(defun jellyfin--stream-url (id media-type)
  "Construct a direct stream URL for item ID of MEDIA-TYPE (Audio or Videos)."
  (format "%s/%s/%s/stream?Static=true&api_key=%s"
          jellyfin-server-url media-type id jellyfin--token))

(defun jellyfin--retry-if-empty (fn &optional max-retries)
  "Call FN.  If the result is an empty sequence, re-authenticate and retry.
Retries up to MAX-RETRIES times (default 2)."
  (let ((result (funcall fn))
        (retries (or max-retries 2))
        (attempts 0))
    (while (and (zerop (length result))
                (< attempts retries))
      (setq attempts (1+ attempts)
            jellyfin--token nil)
      (jellyfin--ensure-auth)
      (setq result (funcall fn)))
    result))

;;; --- Fetching items ---

(defun jellyfin--get-items (media-type &optional parent-id extra-params)
  "Fetch items of MEDIA-TYPE under optional PARENT-ID.
EXTRA-PARAMS is an alist of additional query params.
Returns the Items array."
  (let ((params `(("IncludeItemTypes" . ,media-type)
                  ("Recursive" . "true")
                  ("SortBy" . "SortName")
                  ("SortOrder" . "Ascending")
                  ("Fields" . "MediaSources,Overview"))))
    (when parent-id
      (push `("ParentId" . ,parent-id) params))
    (when extra-params
      (setq params (append extra-params params)))
    (let ((resp (jellyfin--api-get
                 (format "/Users/%s/Items" jellyfin--user-id)
                 params)))
      (alist-get 'Items resp))))

(defun jellyfin--get-artists ()
  "Fetch all album artists."
  (let ((resp (jellyfin--api-get
               (format "/Artists/AlbumArtists")
               `(("UserId" . ,jellyfin--user-id)
                 ("SortBy" . "SortName")
                 ("SortOrder" . "Ascending")))))
    (alist-get 'Items resp)))

(defun jellyfin--get-albums-by-artist (artist-id)
  "Fetch albums for ARTIST-ID."
  (jellyfin--get-items "MusicAlbum" nil
                       `(("AlbumArtistIds" . ,artist-id))))

(defun jellyfin--get-playlists ()
  "Fetch all playlists."
  (jellyfin--get-items "Playlist"))

(defun jellyfin--get-playlist-items (playlist-id)
  "Fetch items in PLAYLIST-ID, preserving playlist order."
  (let ((resp (jellyfin--api-get
               (format "/Playlists/%s/Items" playlist-id)
               `(("UserId" . ,jellyfin--user-id)
                 ("Fields" . "MediaSources")))))
    (alist-get 'Items resp)))

(defun jellyfin--get-album-tracks (album-id)
  "Fetch tracks in ALBUM-ID, sorted by index."
  (let ((resp (jellyfin--api-get
               (format "/Users/%s/Items" jellyfin--user-id)
               `(("ParentId" . ,album-id)
                 ("IncludeItemTypes" . "Audio")
                 ("SortBy" . "IndexNumber")
                 ("SortOrder" . "Ascending")
                 ("Fields" . "MediaSources")))))
    (alist-get 'Items resp)))

(defun jellyfin--get-item-by-id (id)
  "Fetch a single item by ID from Jellyfin."
  (jellyfin--ensure-auth)
  (jellyfin--api-get (format "/Users/%s/Items/%s" jellyfin--user-id id)))

;;; --- EMMS integration (info method + source) ---

(defvar jellyfin--item-cache (make-hash-table :test 'equal)
  "Hash table mapping Jellyfin item IDs to item alists.")

(defun jellyfin--item-cache-populate (items)
  "Populate the item ID cache from ITEMS sequence."
  (seq-doseq (item items)
    (puthash (alist-get 'Id item) item jellyfin--item-cache)))

(defun jellyfin--extract-item-id (url)
  "Extract the Jellyfin item ID from a stream URL."
  (when (string-match "/Audio/\\([^/]+\\)/stream" url)
    (match-string 1 url)))

(defun jellyfin--lookup-item-by-url (url)
  "Look up a Jellyfin item by its stream URL.
Checks the in-memory item cache first, falls back to API."
  (when-let ((id (jellyfin--extract-item-id url)))
    (or (gethash id jellyfin--item-cache)
        (let ((item (jellyfin--get-item-by-id id)))
          (when item
            (puthash id item jellyfin--item-cache))
          item))))

(defun emms-info-jellyfin (track)
  "Add Jellyfin metadata to TRACK if it is a Jellyfin stream URL.
This is a suitable element for `emms-info-functions'."
  (when (and jellyfin-server-url
             (eq (emms-track-type track) 'url)
             (string-prefix-p jellyfin-server-url (emms-track-name track)))
    (when-let ((item (jellyfin--lookup-item-by-url (emms-track-name track))))
      (let* ((artists (alist-get 'AlbumArtists item))
             (artist-name (and (> (length artists) 0)
                               (alist-get 'Name (aref artists 0))))
             (artist-id (and (> (length artists) 0)
                             (alist-get 'Id (aref artists 0)))))
        (emms-track-set track 'info-title (alist-get 'Name item))
        (when artist-name
          (emms-track-set track 'info-artist artist-name))
        (when (alist-get 'Album item)
          (emms-track-set track 'info-album (alist-get 'Album item)))
        (when (alist-get 'IndexNumber item)
          (emms-track-set track 'info-tracknumber
                          (number-to-string (alist-get 'IndexNumber item))))
        (emms-track-set track 'jellyfin-cover-id
                        (or (alist-get 'AlbumId item) (alist-get 'Id item)))
        (when artist-id
          (emms-track-set track 'jellyfin-artist-id artist-id))))))

(with-eval-after-load 'emms
  (add-to-list 'emms-info-functions #'emms-info-jellyfin)
  (when (display-graphic-p)
    (define-key emms-playlist-mode-map (kbd "!") #'jellyfin--emms-playlist-song-info)))

(defun jellyfin--add-jellyfin-tracks (items)
  "Add Jellyfin audio ITEMS to the EMMS playlist.
ITEMS is a sequence of Jellyfin item alists.  Each item is cached
so `emms-info-jellyfin' can resolve metadata without API calls.
Cover-art properties are set synchronously on each track so they
are available immediately when `emms-player-started-hook' fires,
regardless of whether `emms-info-asynchronously' is non-nil."
  (require 'emms)
  (jellyfin--item-cache-populate items)
  (seq-doseq (item items)
    (let* ((id (alist-get 'Id item))
           (url (jellyfin--stream-url id "Audio"))
           (artists (alist-get 'AlbumArtists item))
           (artist-id (and (> (length artists) 0)
                           (alist-get 'Id (aref artists 0)))))
      (emms-add-url url)
      ;; Set cover-art properties synchronously so the track-started
      ;; hook can find them even before the async info method runs.
      (with-current-buffer emms-playlist-buffer
        (save-excursion
          (goto-char (point-max))
          (forward-line -1)
          (when-let ((emms-track (emms-playlist-track-at (point))))
            (emms-track-set emms-track 'jellyfin-cover-id
                            (or (alist-get 'AlbumId item) id))
            (emms-track-set emms-track 'jellyfin-artist-id artist-id)))))))

;;; --- Fetching shows/seasons/episodes ---

(defun jellyfin--get-seasons (series-id)
  "Fetch seasons for SERIES-ID."
  (let ((resp (jellyfin--api-get
               (format "/Shows/%s/Seasons" series-id)
               `(("userId" . ,jellyfin--user-id)
                 ("Fields" . "Overview")))))
    (alist-get 'Items resp)))

(defun jellyfin--get-episodes (series-id season-id)
  "Fetch episodes for SERIES-ID in SEASON-ID."
  (let ((resp (jellyfin--api-get
               (format "/Shows/%s/Episodes" series-id)
               `(("userId" . ,jellyfin--user-id)
                 ("seasonId" . ,season-id)
                 ("Fields" . "MediaSources,Overview")))))
    (alist-get 'Items resp)))

;;; --- Image fetching ---

(defvar jellyfin--preview-image-cache (make-hash-table :test 'equal)
  "Cache of item-id -> image data, persists across calls.")

(defun jellyfin--image-cache-dir ()
  "Return the path to the image cache directory, creating it if needed."
  (let ((dir (expand-file-name "jellyfin-image-cache/" user-emacs-directory)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun jellyfin--fetch-image (item-id)
  "Fetch poster image for ITEM-ID, returning an image descriptor or nil.
Results are cached in memory (`jellyfin--preview-image-cache') and
on disk (`jellyfin-image-cache/' in `user-emacs-directory')."
  (or (gethash item-id jellyfin--preview-image-cache)
      (let ((disk-file (expand-file-name (format "%s" item-id)
                                         (jellyfin--image-cache-dir))))
        (if (and (file-exists-p disk-file)
                 (> (file-attribute-size (file-attributes disk-file)) 0))
            ;; Load from disk cache
            (condition-case nil
                (let* ((data (with-temp-buffer
                               (set-buffer-multibyte nil)
                               (insert-file-contents-literally disk-file)
                               (buffer-string)))
                       (image (create-image data nil t :width 300)))
                  (when image
                    (puthash item-id image jellyfin--preview-image-cache)
                    image))
              (error nil))
          ;; Fetch from API and save to disk
          (condition-case nil
              (let* ((url-show-status nil)
                     (url-request-noninteractive t)
                     (_auth (jellyfin--ensure-auth))
                     (img-url (format "%s/Items/%s/Images/Primary?maxWidth=300&api_key=%s"
                                      jellyfin-server-url item-id jellyfin--token))
                     (tmp-file (make-temp-file "jellyfin-poster-")))
                (let ((inhibit-message t))
                  (url-copy-file img-url tmp-file t))
                (unwind-protect
                    (when (and (file-exists-p tmp-file)
                               (> (file-attribute-size (file-attributes tmp-file)) 0))
                      (let ((inhibit-message t))
                        (copy-file tmp-file disk-file t))
                      (let* ((data (with-temp-buffer
                                     (set-buffer-multibyte nil)
                                     (insert-file-contents-literally tmp-file)
                                     (buffer-string)))
                             (image (create-image data nil t :width 300)))
                        (when image
                          (puthash item-id image jellyfin--preview-image-cache)
                          image)))
                  (when (file-exists-p tmp-file)
                    (delete-file tmp-file))))
            (error nil))))))

(defun jellyfin--fetch-image-type (item-id image-type &optional max-width)
  "Fetch IMAGE-TYPE image for ITEM-ID, returning an image descriptor or nil.
IMAGE-TYPE is e.g. \"Primary\", \"Backdrop\".  MAX-WIDTH defaults to 300.
Results are cached in memory and on disk."
  (let* ((width (or max-width 300))
         (cache-key (format "%s-%s" item-id image-type)))
    (or (gethash cache-key jellyfin--preview-image-cache)
        (let ((disk-file (expand-file-name cache-key (jellyfin--image-cache-dir))))
          (if (and (file-exists-p disk-file)
                   (> (file-attribute-size (file-attributes disk-file)) 0))
              (condition-case nil
                  (let* ((data (with-temp-buffer
                                 (set-buffer-multibyte nil)
                                 (insert-file-contents-literally disk-file)
                                 (buffer-string)))
                         (image (create-image data nil t :width width)))
                    (when image
                      (puthash cache-key image jellyfin--preview-image-cache)
                      image))
                (error nil))
            (condition-case nil
                (let* ((url-show-status nil)
                       (url-request-noninteractive t)
                       (_auth (jellyfin--ensure-auth))
                       (img-url (format "%s/Items/%s/Images/%s?maxWidth=%d&api_key=%s"
                                        jellyfin-server-url item-id image-type
                                        width jellyfin--token))
                       (tmp-file (make-temp-file "jellyfin-img-")))
                  (let ((inhibit-message t))
                    (url-copy-file img-url tmp-file t))
                  (unwind-protect
                      (when (and (file-exists-p tmp-file)
                                 (> (file-attribute-size (file-attributes tmp-file)) 0))
                        (let ((inhibit-message t))
                          (copy-file tmp-file disk-file t))
                        (let* ((data (with-temp-buffer
                                       (set-buffer-multibyte nil)
                                       (insert-file-contents-literally tmp-file)
                                       (buffer-string)))
                               (image (create-image data nil t :width width)))
                          (when image
                            (puthash cache-key image jellyfin--preview-image-cache)
                            image)))
                    (when (file-exists-p tmp-file)
                      (delete-file tmp-file))))
              (error nil)))))))

(defun jellyfin--music-placeholder-image ()
  "Return a generated SVG music note image as a fallback placeholder."
  (or (gethash 'music-placeholder jellyfin--preview-image-cache)
      (let* ((svg "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 300 300\">
  <rect width=\"300\" height=\"300\" rx=\"8\" fill=\"#1c2a3a\"/>
  <g transform=\"translate(90,80)\" fill=\"#4a6a8a\">
    <rect x=\"38\" y=\"0\" width=\"6\" height=\"100\"/>
    <rect x=\"108\" y=\"20\" width=\"6\" height=\"80\"/>
    <polygon points=\"38,0 114,20 114,28 38,8\"/>
    <ellipse cx=\"24\" cy=\"100\" rx=\"24\" ry=\"16\" transform=\"rotate(-20,24,100)\"/>
    <ellipse cx=\"94\" cy=\"100\" rx=\"24\" ry=\"16\" transform=\"rotate(-20,94,100)\"/>
  </g>
</svg>")
             (image (create-image svg 'svg t :width 300)))
        (when image
          (puthash 'music-placeholder image jellyfin--preview-image-cache))
        image)))

(defun jellyfin--poster-placeholder-image ()
  "Return a generated SVG placeholder for poster images (seasons, shows)."
  (or (gethash 'poster-placeholder jellyfin--preview-image-cache)
      (let* ((svg "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 300 450\">
  <rect width=\"300\" height=\"450\" rx=\"8\" fill=\"#1c2a3a\"/>
  <g transform=\"translate(100,160)\" fill=\"#4a6a8a\">
    <rect x=\"0\" y=\"0\" width=\"100\" height=\"80\" rx=\"6\"/>
    <rect x=\"10\" y=\"10\" width=\"80\" height=\"50\" rx=\"2\" fill=\"#1c2a3a\"/>
    <polygon points=\"40,25 40,50 60,37.5\" fill=\"#4a6a8a\"/>
    <circle cx=\"20\" cy=\"75\" r=\"8\"/>
    <circle cx=\"80\" cy=\"75\" r=\"8\"/>
    <rect x=\"0\" y=\"85\" width=\"100\" height=\"6\" rx=\"3\"/>
    <rect x=\"15\" y=\"97\" width=\"70\" height=\"6\" rx=\"3\"/>
  </g>
</svg>")
             (image (create-image svg 'svg t :width 300)))
        (when image
          (puthash 'poster-placeholder image jellyfin--preview-image-cache))
        image)))

;;; --- Playback reporting ---

(defun jellyfin--report-playing (item-id &optional position-secs)
  "Report playback started for ITEM-ID at POSITION-SECS."
  (jellyfin--api-post-async
   "/Sessions/Playing"
   `((ItemId . ,item-id)
     (MediaSourceId . ,item-id)
     (PlaySessionId . ,jellyfin--mpv-play-session-id)
     (PlayMethod . "DirectPlay")
     (CanSeek . t)
     (IsPaused . :json-false)
     (PositionTicks . ,(* (or position-secs 0) 10000000)))))

(defun jellyfin--report-progress (item-id position-secs)
  "Report playback progress for ITEM-ID at POSITION-SECS."
  (jellyfin--api-post-async
   "/Sessions/Playing/Progress"
   `((ItemId . ,item-id)
     (MediaSourceId . ,item-id)
     (PlaySessionId . ,jellyfin--mpv-play-session-id)
     (PlayMethod . "DirectPlay")
     (CanSeek . t)
     (IsPaused . ,(if jellyfin--mpv-paused t :json-false))
     (PositionTicks . ,(* (truncate position-secs) 10000000)))))

(defun jellyfin--report-stopped (item-id position-secs)
  "Report playback stopped for ITEM-ID at POSITION-SECS."
  (jellyfin--api-post-async
   "/Sessions/Playing/Stopped"
   `((ItemId . ,item-id)
     (MediaSourceId . ,item-id)
     (PlaySessionId . ,jellyfin--mpv-play-session-id)
     (PositionTicks . ,(* (truncate (or position-secs 0)) 10000000)))))

;;; --- mpv IPC & lifecycle ---

(defun jellyfin--mpv-cleanup ()
  "Tear down mpv session: timer, IPC, process, socket."
  (when jellyfin--mpv-timer
    (cancel-timer jellyfin--mpv-timer)
    (setq jellyfin--mpv-timer nil))
  (when (and jellyfin--mpv-ipc (process-live-p jellyfin--mpv-ipc))
    (delete-process jellyfin--mpv-ipc))
  (setq jellyfin--mpv-ipc nil)
  (let ((proc jellyfin--mpv-process))
    (setq jellyfin--mpv-process nil)
    (when (and proc (process-live-p proc))
      (delete-process proc)))
  (when (and jellyfin--mpv-socket (file-exists-p jellyfin--mpv-socket))
    (delete-file jellyfin--mpv-socket))
  (setq jellyfin--mpv-socket nil
        jellyfin--mpv-ipc-buf ""
        jellyfin--mpv-position nil
        jellyfin--mpv-paused nil
        jellyfin--mpv-playlist-pos nil
        jellyfin--mpv-play-session-id nil
        jellyfin--mpv-start-secs nil))

(defun jellyfin--mpv-ipc-filter (_proc output)
  "Process OUTPUT from mpv IPC socket, handling partial reads."
  (setq jellyfin--mpv-ipc-buf (concat jellyfin--mpv-ipc-buf output))
  (let ((lines (split-string jellyfin--mpv-ipc-buf "\n")))
    ;; Last element is either "" (complete) or a partial line
    (setq jellyfin--mpv-ipc-buf (car (last lines)))
    (setq lines (butlast lines))
    (dolist (line lines)
      (when (> (length line) 0)
        (condition-case nil
            (let ((msg (json-read-from-string line)))
              (cond
               ;; Response to get_property playback-time (request_id=1)
               ((and (alist-get 'request_id msg)
                     (= (alist-get 'request_id msg) 1)
                     (alist-get 'data msg))
                (let ((pos (alist-get 'data msg)))
                  (when (numberp pos)
                    (setq jellyfin--mpv-position pos)
                    (when-let ((item-id (and jellyfin--mpv-playlist-pos
                                             jellyfin--mpv-item-ids
                                             (aref jellyfin--mpv-item-ids
                                                   jellyfin--mpv-playlist-pos))))
                      (jellyfin--report-progress item-id pos)))))
               ;; Property change events
               ((equal (alist-get 'event msg) "property-change")
                (let ((name (alist-get 'name msg))
                      (data (alist-get 'data msg)))
                  (cond
                   ((equal name "playlist-pos")
                    (when (and (integerp data) (>= data 0)
                               (not (eql data jellyfin--mpv-playlist-pos)))
                      ;; Report stopped for old episode
                      (when (and jellyfin--mpv-playlist-pos
                                 jellyfin--mpv-item-ids
                                 (< jellyfin--mpv-playlist-pos
                                    (length jellyfin--mpv-item-ids)))
                        (jellyfin--report-stopped
                         (aref jellyfin--mpv-item-ids
                               jellyfin--mpv-playlist-pos)
                         (or jellyfin--mpv-position 0)))
                      ;; Update position and report playing for new episode
                      (setq jellyfin--mpv-playlist-pos data
                            jellyfin--mpv-position 0)
                      (when (< data (length jellyfin--mpv-item-ids))
                        (jellyfin--report-playing
                         (aref jellyfin--mpv-item-ids data)))))
                   ((equal name "pause")
                    (setq jellyfin--mpv-paused (eq data t))))))))
          (error nil))))))

(defun jellyfin--mpv-poll ()
  "Timer callback: request current playback-time from mpv via IPC."
  (when (and jellyfin--mpv-ipc (process-live-p jellyfin--mpv-ipc))
    (process-send-string
     jellyfin--mpv-ipc
     "{\"command\":[\"get_property\",\"playback-time\"],\"request_id\":1}\n")))

(defun jellyfin--mpv-connect (&optional retries)
  "Connect to mpv IPC socket.  Retry up to RETRIES times (default 10)."
  (let ((retries (or retries 10)))
    (condition-case nil
        (progn
          (setq jellyfin--mpv-ipc
                (make-network-process
                 :name "jellyfin-mpv-ipc"
                 :family 'local
                 :service jellyfin--mpv-socket
                 :remote jellyfin--mpv-socket
                 :filter #'jellyfin--mpv-ipc-filter
                 :noquery t))
          ;; Observe playlist-pos and pause
          (process-send-string
           jellyfin--mpv-ipc
           "{\"command\":[\"observe_property\",1,\"playlist-pos\"]}\n")
          (process-send-string
           jellyfin--mpv-ipc
           "{\"command\":[\"observe_property\",2,\"pause\"]}\n")
          ;; Start progress timer
          (setq jellyfin--mpv-timer
                (run-at-time 5 30 #'jellyfin--mpv-poll))
          ;; Seek to resume position for first episode only, then clear
          (when jellyfin--mpv-start-secs
            (process-send-string
             jellyfin--mpv-ipc
             (format "{\"command\":[\"seek\",\"%d\",\"absolute\"]}\n"
                     jellyfin--mpv-start-secs))
            (setq jellyfin--mpv-start-secs nil))
          ;; Report initial playing state
          (setq jellyfin--mpv-playlist-pos 0)
          (when (and jellyfin--mpv-item-ids
                     (> (length jellyfin--mpv-item-ids) 0))
            (jellyfin--report-playing (aref jellyfin--mpv-item-ids 0))))
      (error
       (if (> retries 0)
           (run-at-time 0.5 nil #'jellyfin--mpv-connect (1- retries))
         (message "jellyfin: failed to connect to mpv IPC socket"))))))

(defun jellyfin--mpv-process-sentinel (proc event)
  "Handle mpv PROC exit EVENT: report stopped, clean up."
  (when (and (eq proc jellyfin--mpv-process)
             (string-match-p "\\(?:finished\\|exited\\|killed\\)" event))
    ;; Report stopped for current episode
    (when (and jellyfin--mpv-playlist-pos
               jellyfin--mpv-item-ids
               (< jellyfin--mpv-playlist-pos
                  (length jellyfin--mpv-item-ids)))
      (jellyfin--report-stopped
       (aref jellyfin--mpv-item-ids jellyfin--mpv-playlist-pos)
       (or jellyfin--mpv-position 0)))
    (jellyfin--mpv-cleanup)
    (message "jellyfin: mpv exited")))

(defun jellyfin--mpv-play (urls item-ids &optional start-secs)
  "Launch mpv with URLS and track playback for ITEM-IDS (vector).
When START-SECS is non-nil, seek to that position on launch.
Cleans up any existing session first."
  (jellyfin--mpv-cleanup)
  (let* ((sock (format "/tmp/emacs-jellyfin-mpv-%d.sock"
                        (emacs-pid)))
         (args (list (concat "--input-ipc-server=" sock))))
    (when jellyfin-preferred-language
      (push (format "--alang=%s" jellyfin-preferred-language) args)
      (when jellyfin-subtitles
        (push (format "--slang=%s" jellyfin-preferred-language) args)))
    (setq jellyfin--mpv-start-secs (when (and start-secs (> start-secs 0))
                                     start-secs))
    (setq jellyfin--mpv-socket sock
          jellyfin--mpv-item-ids item-ids
          jellyfin--mpv-ipc-buf ""
          jellyfin--mpv-play-session-id (md5 (format "%s%s" (random) (current-time))))
    (if (= (length urls) 1)
        (setq args (append args (list (car urls))))
      ;; Write m3u playlist for multiple URLs
      (let ((m3u-path "/tmp/jellyfin-shows.m3u"))
        (with-temp-file m3u-path
          (insert "#EXTM3U\n")
          (dolist (url urls)
            (insert url "\n")))
        (setq args (append args (list (concat "--playlist=" m3u-path))))))
    (setq jellyfin--mpv-process
          (apply #'start-process "jellyfin-mpv" nil "mpv" args))
    (set-process-sentinel jellyfin--mpv-process
                          #'jellyfin--mpv-process-sentinel)
    (set-process-query-on-exit-flag jellyfin--mpv-process nil)
    ;; Give mpv time to create the socket
    (run-at-time 1 nil #'jellyfin--mpv-connect)))

;;; --- Movie preview buffer ---

(defvar jellyfin--preview-data nil
  "Alist of (NAME . item) used during movie completion.")

(defvar jellyfin--preview-timer nil
  "Idle timer used to debounce preview updates.")

(defvar-local jellyfin--parent-buffer nil
  "Buffer to return to when navigating up from a drill-down buffer.")

(defun jellyfin--browse-up ()
  "Kill current buffer and switch to parent buffer, if alive."
  (interactive)
  (let ((parent jellyfin--parent-buffer))
    (kill-buffer (current-buffer))
    (when (and parent (buffer-live-p parent))
      (switch-to-buffer parent))))

(defvar jellyfin--preview-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map [wheel-up] (lambda () (interactive) (scroll-down 1)))
    (define-key map [wheel-down] (lambda () (interactive) (scroll-up 1)))
    (define-key map (kbd "q") #'jellyfin--browse-up)
    (define-key map (kbd "^") #'jellyfin--browse-up)
    map)
  "Keymap for the Jellyfin preview buffer.")

(defun jellyfin--preview-mode ()
  "Set up the current buffer as a Jellyfin preview buffer."
  (special-mode)
  (use-local-map jellyfin--preview-mode-map)
  (setq mode-name "Jellyfin"
        truncate-lines nil
        word-wrap t
        scroll-step 1
        scroll-conservatively 10000))

(defun jellyfin--preview-render (matches)
  "Render MATCHES (alist of name.item) into the *Jellyfin* buffer."
  (let ((buf (get-buffer-create "*Jellyfin*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (jellyfin--preview-mode)
        (if (> (length matches) 20)
            (insert (format "%d items -- type to narrow\n" (length matches)))
          (dolist (entry matches)
            (let* ((name (car entry))
                   (item (cdr entry))
                   (id (alist-get 'Id item))
                   (image-id (or (alist-get 'SeriesId item) id))
                   (overview (or (alist-get 'Overview item) "")))
              ;; Poster image (GUI only)
              (when (display-graphic-p)
                (let ((image (or (jellyfin--fetch-image image-id)
                                 (jellyfin--fetch-image id)
                                 (jellyfin--music-placeholder-image))))
                  (when image
                    (insert-text-button "[poster]"
                                        'display image
                                        'action (lambda (_btn)
                                                  (jellyfin--preview-select name))
                                        'follow-link t)
                    (insert "\n"))))
              ;; Clickable title
              (insert-text-button name
                                  'action (lambda (_btn)
                                            (jellyfin--preview-select name))
                                  'follow-link t
                                  'face 'bold)
              (insert "\n")
              ;; Overview
              (unless (string-empty-p overview)
                (insert overview "\n"))
              (insert "\n")))))
      (goto-char (point-min)))
    (display-buffer buf
                    '(display-buffer-use-some-window
                      (inhibit-same-window . t)))))

(defun jellyfin--preview-select (name)
  "Insert NAME into the active minibuffer and exit."
  (when-let ((mini (active-minibuffer-window)))
    (with-selected-window mini
      (delete-minibuffer-contents)
      (insert name)
      (exit-minibuffer))))

(defvar jellyfin--preview-last-input nil
  "Last input string that triggered a preview update.
Used to avoid redundant renders when input hasn't changed.")

(defun jellyfin--preview-update ()
  "Post-command-hook callback: schedule a debounced preview update.
Waits for 0.15 seconds of idle time before rendering so Emacs
stays responsive while the user types."
  (when jellyfin--preview-timer
    (cancel-timer jellyfin--preview-timer)
    (setq jellyfin--preview-timer nil))
  (setq jellyfin--preview-timer
        (run-with-idle-timer 0.15 nil #'jellyfin--preview-update-now)))

(defun jellyfin--preview-update-now ()
  "Actually update the preview buffer.
Uses `completion-all-completions' to respect the user's completion styles."
  (setq jellyfin--preview-timer nil)
  (condition-case nil
      (when (and jellyfin--preview-data (minibufferp (current-buffer)))
        (let ((input (minibuffer-contents-no-properties)))
          (if (string-empty-p input)
              (unless (equal input jellyfin--preview-last-input)
                (setq jellyfin--preview-last-input input)
                (jellyfin--preview-render jellyfin--preview-data))
            (unless (equal input jellyfin--preview-last-input)
              (setq jellyfin--preview-last-input input)
              (let* ((completions (completion-all-completions
                                   input
                                   minibuffer-completion-table
                                   minibuffer-completion-predicate
                                   (length input)))
                     (_ (when (consp completions)
                          (setcdr (last completions) nil)))
                     (md (completion-metadata
                          input
                          minibuffer-completion-table
                          minibuffer-completion-predicate))
                     (sort-fn (or (completion-metadata-get md 'display-sort-function)
                                  #'identity))
                     (sorted (funcall sort-fn completions))
                     (matches (delq nil
                                  (mapcar (lambda (c)
                                            (assoc c jellyfin--preview-data))
                                          sorted))))
                (jellyfin--preview-render matches))))))
    (error nil)))

(defun jellyfin--preview-cleanup ()
  "Minibuffer-exit-hook callback: kill preview buffer and clear state."
  (when jellyfin--preview-timer
    (cancel-timer jellyfin--preview-timer)
    (setq jellyfin--preview-timer nil))
  (setq jellyfin--preview-last-input nil)
  (when-let ((buf (get-buffer "*Jellyfin*")))
    (when-let ((win (get-buffer-window buf t)))
      (when (not (one-window-p t (window-frame win)))
        (delete-window win)))
    (kill-buffer buf))
  (remove-hook 'window-size-change-functions #'jellyfin--grid-resize-handler)
  (setq jellyfin--preview-data nil))

;;; --- Show preview drill-down ---

(defun jellyfin--show-preview-render-items (items make-action make-label
                                                  &optional header buffer-name)
  "Render ITEMS into a Jellyfin buffer for show drill-down.
MAKE-ACTION is called with an item and returns a button action function.
MAKE-LABEL is called with an item and returns its display label string.
HEADER, if non-nil, is a function called to insert header content at top.
BUFFER-NAME defaults to \"*Jellyfin*\"."
  (let ((buf (get-buffer-create (or buffer-name "*Jellyfin*"))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (jellyfin--preview-mode)
        (when header
          (funcall header)
          (insert "\n"))
        (dolist (item items)
          (let ((id (alist-get 'Id item))
                (overview (or (alist-get 'Overview item) ""))
                (action (funcall make-action item))
                (label (funcall make-label item)))
            (when (display-graphic-p)
              (when-let ((image (jellyfin--fetch-image id)))
                (insert-text-button "[poster]"
                                    'display image
                                    'action action
                                    'follow-link t)
                (insert "\n")))
            (insert-text-button label
                                'action action
                                'follow-link t
                                'face 'bold)
            (insert "\n")
            (unless (string-empty-p overview)
              (insert overview "\n"))
            (insert "\n"))))
      (goto-char (point-min)))
    (switch-to-buffer buf)))

(defun jellyfin--image-rescale (image width)
  "Return a copy of IMAGE displayed at WIDTH pixels.
Returns nil if IMAGE is nil."
  (when image
    (cons 'image (plist-put (copy-sequence (cdr image)) :width width))))

(defvar-local jellyfin--grid-state nil
  "Buffer-local state for re-rendering the grid on window resize.
A plist (:items ITEMS :make-action FN :make-label FN) or nil.")

(defun jellyfin--grid-resize-handler (_frame)
  "Re-render grids in all live Jellyfin buffers that have grid state."
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (buffer-local-value 'jellyfin--grid-state buf))
      (when-let ((win (get-buffer-window buf t)))
        (with-selected-window win
          (let ((state (buffer-local-value 'jellyfin--grid-state buf)))
            (jellyfin--show-dired-render-grid
             (plist-get state :items)
             (plist-get state :make-action)
             (plist-get state :make-label)
             (plist-get state :buffer-name))))))))

(defun jellyfin--show-dired-render-grid (items make-action make-label
                                               &optional buffer-name)
  "Render ITEMS as a responsive grid of posters and titles.
Column count adapts to window width; images stay 200px with even spacing.
Re-renders automatically when the window is resized.
BUFFER-NAME defaults to \"*Jellyfin*\"."
  (let* ((buf (get-buffer-create (or buffer-name "*Jellyfin*")))
         (img-w 200)
         (min-gap 20))
    (switch-to-buffer buf)
    (with-current-buffer buf
      (setq jellyfin--grid-state
            (list :items items :make-action make-action :make-label make-label
                  :buffer-name (or buffer-name "*Jellyfin*")))
      (add-hook 'window-size-change-functions #'jellyfin--grid-resize-handler))
    (let* ((win-w (window-body-width nil t))
           (cols (max 1 (/ win-w (+ img-w min-gap))))
           (col-w (/ win-w cols))
           (groups (seq-partition items cols))
           (inhibit-read-only t))
      (erase-buffer)
      (jellyfin--preview-mode)
      (dolist (group groups)
        ;; Image row
        (let ((idx 0))
          (dolist (item group)
            (let* ((id (alist-get 'Id item))
                   (action (funcall make-action item))
                   (image (jellyfin--image-rescale
                           (jellyfin--fetch-image id) img-w)))
              (when (> idx 0)
                (insert (propertize " " 'display
                                    `(space :align-to (,(* idx col-w))))))
              (insert-text-button "[poster]"
                                  'display (or image
                                               (jellyfin--image-rescale
                                                (jellyfin--poster-placeholder-image)
                                                img-w))
                                  'action action
                                  'follow-link t))
            (setq idx (1+ idx))))
        (insert "\n")
        ;; Title row
        (let ((idx 0))
          (dolist (item group)
            (let* ((action (funcall make-action item))
                   (label (funcall make-label item)))
              (when (> idx 0)
                (insert (propertize " " 'display
                                    `(space :align-to (,(* idx col-w))))))
              (insert-text-button label
                                  'action action
                                  'follow-link t
                                  'face 'bold))
            (setq idx (1+ idx))))
        (insert "\n\n"))
      (goto-char (point-min)))))

(defun jellyfin--show-preview-season (series-item)
  "Fetch and render seasons for SERIES-ITEM in *Jellyfin Seasons*."
  (let* ((parent (current-buffer))
         (series-id (alist-get 'Id series-item))
         (seasons (jellyfin--get-seasons series-id)))
    (jellyfin--show-dired-render-grid
     (append seasons nil)
     (lambda (item)
       (lambda (_btn)
         (jellyfin--show-preview-episodes series-item item)))
     (lambda (item)
       (alist-get 'Name item))
     "*Jellyfin Seasons*")
    (setq jellyfin--parent-buffer parent)))

(defun jellyfin--show-preview-episodes (series-item season-item)
  "Fetch and render episodes for SERIES-ITEM / SEASON-ITEM in *Jellyfin Episodes*.
Clicking an episode plays it directly in mpv."
  (let* ((parent (current-buffer))
         (series-id (alist-get 'Id series-item))
         (series-name (alist-get 'Name series-item))
         (season-id (alist-get 'Id season-item))
         (season-name (alist-get 'Name season-item))
         (season-num (alist-get 'IndexNumber season-item))
         (episodes (jellyfin--get-episodes series-id season-id)))
    (jellyfin--show-preview-render-items
     (append episodes nil)
     (lambda (item)
       (let ((eps episodes))
         (lambda (_btn)
           (let* ((chosen-id (alist-get 'Id item))
                  (found nil)
                  (urls nil)
                  (ep-ids nil))
             (seq-doseq (ep eps)
               (when (or found (equal (alist-get 'Id ep) chosen-id))
                 (setq found t)
                 (push (jellyfin--stream-url (alist-get 'Id ep) "Videos") urls)
                 (push (alist-get 'Id ep) ep-ids)))
             (setq urls (nreverse urls)
                   ep-ids (nreverse ep-ids))
             (jellyfin--mpv-play urls (apply #'vector ep-ids))
             (message "Playing %s — %s + %d more"
                      series-name
                      (alist-get 'Name item)
                      (1- (length urls)))))))
     (lambda (item)
       (format "S%02dE%02d — %s"
               (or season-num 0)
               (or (alist-get 'IndexNumber item) 0)
               (alist-get 'Name item)))
     (lambda ()
       (insert (propertize series-name 'face 'bold) "\n")
       (when (display-graphic-p)
         (when-let ((image (jellyfin--fetch-image season-id)))
           (insert-image image "[poster]")
           (insert "\n")))
       (insert (propertize season-name 'face 'bold) "\n"))
     "*Jellyfin Episodes*")
    (setq jellyfin--parent-buffer parent)))

;;; --- Playlist cover art ---

(defun jellyfin--playlist-insert-cover (item-id)
  "Insert or replace cover image at top of EMMS playlist buffer.
Tries ITEM-ID first, falls back to a generic placeholder.
Requires `jellyfin-emms-cover-art' and GUI Emacs."
  (when (and jellyfin-emms-cover-art (display-graphic-p))
    (let ((image (or (and item-id (jellyfin--fetch-image item-id))
                     (jellyfin--music-placeholder-image))))
      (with-current-buffer emms-playlist-buffer
        (let ((inhibit-read-only t))
          ;; Always remove existing cover region
          (goto-char (point-min))
          (let ((end (point-min)))
            (while (and (< end (point-max))
                        (get-text-property end 'jellyfin-cover))
              (setq end (next-single-property-change end 'jellyfin-cover
                                                     nil (point-max))))
            (when (> end (point-min))
              (delete-region (point-min) end)))
          ;; Insert new cover at top if we have one
          (when image
            (goto-char (point-min))
            (let ((start (point)))
              (insert-image image "[cover]")
              (insert "\n")
              (put-text-property start (point) 'jellyfin-cover t)))
          ;; Force window to show the update
          (when-let ((win (get-buffer-window emms-playlist-buffer t)))
            (set-window-point win (point-min))))))))

(defun jellyfin--playlist-track-started ()
  "Update playlist cover art when a new track starts playing."
  (when (and jellyfin-emms-cover-art (display-graphic-p))
    (when-let ((track (emms-playlist-current-selected-track)))
      (jellyfin--playlist-insert-cover
       (emms-track-get track 'jellyfin-cover-id)))))

;;; --- Interactive commands ---

;;;###autoload
(defun jellyfin-browse-movies ()
  "Pick a movie from Jellyfin and play it in mpv.
Shows a preview buffer with posters and descriptions as you type."
  (interactive)
  (jellyfin--ensure-auth)
  (let* ((items (jellyfin--retry-if-empty
                 (lambda () (jellyfin--get-items "Movie"))))
         (names (mapcar (lambda (item)
                          (cons (alist-get 'Name item) item))
                        items)))
    (let ((choice (if jellyfin-completing-read-preview
                      (progn
                        (setq jellyfin--preview-data names)
                        (minibuffer-with-setup-hook
                            (lambda ()
                              (add-hook 'post-command-hook
                                        #'jellyfin--preview-update nil t)
                              (add-hook 'minibuffer-exit-hook
                                        #'jellyfin--preview-cleanup nil t))
                          (completing-read "Play movie: "
                                           (mapcar #'car names) nil t)))
                    (completing-read "Play movie: "
                                     (mapcar #'car names) nil t))))
      (when-let* ((item (cdr (assoc choice names)))
                  (id (alist-get 'Id item))
                  (url (jellyfin--stream-url id "Videos")))
        (jellyfin--mpv-play (list url) (vector id))
        (message "Playing movie: %s" choice)))))

(defvar jellyfin--movies-gallery-cache nil
  "Cached list of movie items from the Jellyfin server.")

(defun jellyfin--movies-gallery-cache-file ()
  "Return the path to the movies gallery cache file."
  (expand-file-name "jellyfin-movies-gallery-cache.el" user-emacs-directory))

(defun jellyfin--movies-gallery-cache-save ()
  "Write `jellyfin--movies-gallery-cache' to disk."
  (when jellyfin--movies-gallery-cache
    (with-temp-file (jellyfin--movies-gallery-cache-file)
      (prin1 jellyfin--movies-gallery-cache (current-buffer)))))

(defun jellyfin--movies-gallery-cache-load ()
  "Load `jellyfin--movies-gallery-cache' from disk if the file exists."
  (let ((file (jellyfin--movies-gallery-cache-file)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (setq jellyfin--movies-gallery-cache (read (current-buffer))))
      (jellyfin--item-cache-populate jellyfin--movies-gallery-cache))))

;;;###autoload
(defun jellyfin-browse-movies-gallery ()
  "Browse movies as a responsive poster grid in a *Jellyfin* buffer.
Clicking a poster plays that movie in mpv.  Requires graphical Emacs.
Uses cached metadata when available; run
`jellyfin-browse-movies-gallery-refetch-metadata' to refresh."
  (interactive)
  (unless (display-graphic-p)
    (user-error "jellyfin-browse-movies-gallery requires graphical Emacs"))
  (unless jellyfin--movies-gallery-cache
    (jellyfin--movies-gallery-cache-load))
  (unless jellyfin--movies-gallery-cache
    (jellyfin-browse-movies-gallery-refetch-metadata))
  (if (zerop (length jellyfin--movies-gallery-cache))
      (message "No movies found on server.")
    (jellyfin--show-dired-render-grid
     (append jellyfin--movies-gallery-cache nil)
     (lambda (item)
       (lambda (_btn)
         (let* ((id (alist-get 'Id item))
                (url (jellyfin--stream-url id "Videos")))
           (jellyfin--mpv-play (list url) (vector id))
           (message "Playing movie: %s" (alist-get 'Name item)))))
     (lambda (item)
       (alist-get 'Name item))
     "*Jellyfin Movies*")))

;;;###autoload
(defun jellyfin-browse-movies-gallery-refetch-metadata ()
  "Fetch all movies from the Jellyfin server and update the local cache.
Also clears cached poster images for movies so they are re-fetched."
  (interactive)
  (jellyfin--ensure-auth)
  (message "Fetching movies...")
  ;; Clear disk-cached images for old items
  (when jellyfin--movies-gallery-cache
    (let ((dir (jellyfin--image-cache-dir)))
      (seq-doseq (item jellyfin--movies-gallery-cache)
        (let ((file (expand-file-name (alist-get 'Id item) dir)))
          (when (file-exists-p file)
            (delete-file file))
          (remhash (alist-get 'Id item) jellyfin--preview-image-cache)))))
  (setq jellyfin--movies-gallery-cache
        (append (jellyfin--retry-if-empty
                 (lambda () (jellyfin--get-items "Movie")))
                nil))
  (jellyfin--movies-gallery-cache-save)
  (jellyfin--item-cache-populate jellyfin--movies-gallery-cache)
  (message "Cached %d movies." (length jellyfin--movies-gallery-cache))
  (jellyfin-browse-movies-gallery))

;;;###autoload
(defun jellyfin-browse-albums ()
  "Pick artist -> album -> queue all tracks to EMMS playlist.
When `jellyfin-completing-read-preview' is non-nil, shows a preview
buffer with images and descriptions that narrows as you type."
  (interactive)
  (jellyfin--ensure-auth)
  (let* (;; Pick artist
         (artists (jellyfin--retry-if-empty #'jellyfin--get-artists))
         (artist-names (mapcar (lambda (a) (cons (alist-get 'Name a) a))
                               artists))
         (artist-choice
          (if jellyfin-completing-read-preview
              (progn
                (setq jellyfin--preview-data artist-names)
                (minibuffer-with-setup-hook
                    (lambda ()
                      (add-hook 'post-command-hook
                                #'jellyfin--preview-update nil t)
                      (add-hook 'minibuffer-exit-hook
                                #'jellyfin--preview-cleanup nil t))
                  (completing-read "Artist: "
                                   (mapcar #'car artist-names) nil t)))
            (completing-read "Artist: "
                             (mapcar #'car artist-names) nil t)))
         (artist (cdr (assoc artist-choice artist-names)))
         (artist-id (alist-get 'Id artist))
         ;; Pick album
         (albums (jellyfin--get-albums-by-artist artist-id))
         (album-names (mapcar (lambda (a) (cons (alist-get 'Name a) a))
                              albums))
         (album-choice
          (if jellyfin-completing-read-preview
              (progn
                (setq jellyfin--preview-data album-names)
                (minibuffer-with-setup-hook
                    (lambda ()
                      (add-hook 'post-command-hook
                                #'jellyfin--preview-update nil t)
                      (add-hook 'minibuffer-exit-hook
                                #'jellyfin--preview-cleanup nil t))
                  (completing-read "Album: "
                                   (mapcar #'car album-names) nil t)))
            (completing-read "Album: "
                             (mapcar #'car album-names) nil t)))
         (album (cdr (assoc album-choice album-names)))
         (album-id (alist-get 'Id album))
         ;; Get tracks
         (tracks (jellyfin--get-album-tracks album-id)))
    (jellyfin--add-jellyfin-tracks tracks)
    (add-hook 'emms-player-started-hook #'jellyfin--playlist-track-started)
    (add-hook 'emms-player-started-hook #'jellyfin--elcava-track-started)
    (switch-to-buffer emms-playlist-buffer)
    (message "Queued %d tracks from %s — %s"
             (length tracks) artist-choice album-choice)))

;;;###autoload
(defun jellyfin-browse-playlists ()
  "Pick a playlist -> queue all tracks to EMMS playlist.
When `jellyfin-completing-read-preview' is non-nil, shows a preview
buffer with images and descriptions that narrows as you type."
  (interactive)
  (jellyfin--ensure-auth)
  (let* ((playlists (jellyfin--retry-if-empty #'jellyfin--get-playlists))
         (playlist-names (mapcar (lambda (p) (cons (alist-get 'Name p) p))
                                 playlists))
         (choice
          (if jellyfin-completing-read-preview
              (progn
                (setq jellyfin--preview-data playlist-names)
                (minibuffer-with-setup-hook
                    (lambda ()
                      (add-hook 'post-command-hook
                                #'jellyfin--preview-update nil t)
                      (add-hook 'minibuffer-exit-hook
                                #'jellyfin--preview-cleanup nil t))
                  (completing-read "Playlist: "
                                   (mapcar #'car playlist-names) nil t)))
            (completing-read "Playlist: "
                             (mapcar #'car playlist-names) nil t)))
         (playlist (cdr (assoc choice playlist-names)))
         (playlist-id (alist-get 'Id playlist))
         (tracks (jellyfin--get-playlist-items playlist-id)))
    (jellyfin--add-jellyfin-tracks tracks)
    (add-hook 'emms-player-started-hook #'jellyfin--playlist-track-started)
    (add-hook 'emms-player-started-hook #'jellyfin--elcava-track-started)
    (switch-to-buffer emms-playlist-buffer)
    (message "Queued %d tracks from %s" (length tracks) choice)))

;;;###autoload
(defun jellyfin-browse-shows ()
  "Browse TV shows: Series -> Season -> Episode, then play in mpv.
When `jellyfin-completing-read-preview' is non-nil, shows a preview buffer with
images and descriptions that narrows as you type, like
`jellyfin-browse-movies'.  All three steps use completing-read."
  (interactive)
  (jellyfin--ensure-auth)
  (let* ((series (jellyfin--retry-if-empty
                   (lambda () (jellyfin--get-items "Series"))))
         (series-alist (mapcar (lambda (s) (cons (alist-get 'Name s) s))
                               series))
         ;; Step 1: Pick series
         (series-choice
          (if jellyfin-completing-read-preview
              (progn
                (setq jellyfin--preview-data series-alist)
                (minibuffer-with-setup-hook
                    (lambda ()
                      (add-hook 'post-command-hook
                                #'jellyfin--preview-update nil t)
                      (add-hook 'minibuffer-exit-hook
                                #'jellyfin--preview-cleanup nil t))
                  (completing-read "Series: "
                                   (mapcar #'car series-alist) nil t)))
            (completing-read "Series: "
                             (mapcar #'car series-alist) nil t)))
         (series-item (cdr (assoc series-choice series-alist)))
         (series-id (alist-get 'Id series-item))
         ;; Step 2: Pick season
         (seasons (jellyfin--get-seasons series-id))
         (season-alist (mapcar (lambda (s) (cons (alist-get 'Name s) s))
                               seasons))
         (season-choice
          (if jellyfin-completing-read-preview
              (progn
                (setq jellyfin--preview-data season-alist)
                (minibuffer-with-setup-hook
                    (lambda ()
                      (add-hook 'post-command-hook
                                #'jellyfin--preview-update nil t)
                      (add-hook 'minibuffer-exit-hook
                                #'jellyfin--preview-cleanup nil t))
                  (completing-read "Season: "
                                   (mapcar #'car season-alist) nil t)))
            (completing-read "Season: "
                             (mapcar #'car season-alist) nil t)))
         (season-item (cdr (assoc season-choice season-alist)))
         (season-id (alist-get 'Id season-item))
         (season-num (alist-get 'IndexNumber season-item))
         ;; Step 3: Pick episode
         (episodes (jellyfin--get-episodes series-id season-id))
         (episode-alist
          (mapcar (lambda (ep)
                    (cons (format "S%02dE%02d — %s"
                                  (or season-num 0)
                                  (or (alist-get 'IndexNumber ep) 0)
                                  (alist-get 'Name ep))
                          ep))
                  episodes))
         (ep-table (lambda (str pred action)
                     (if (eq action 'metadata)
                         '(metadata (display-sort-function . identity))
                       (complete-with-action
                        action (mapcar #'car episode-alist)
                        str pred))))
         (ep-choice
          (if jellyfin-completing-read-preview
              (progn
                (setq jellyfin--preview-data episode-alist)
                (minibuffer-with-setup-hook
                    (lambda ()
                      (add-hook 'post-command-hook
                                #'jellyfin--preview-update nil t)
                      (add-hook 'minibuffer-exit-hook
                                #'jellyfin--preview-cleanup nil t))
                  (completing-read "Episode: " ep-table nil t)))
            (completing-read "Episode: " ep-table nil t)))
         (chosen-ep (cdr (assoc ep-choice episode-alist))))
    ;; Play from chosen episode onward
    (let ((chosen-id (alist-get 'Id chosen-ep))
          (found nil)
          (urls nil)
          (ep-ids nil))
      (seq-doseq (ep episodes)
        (when (or found (equal (alist-get 'Id ep) chosen-id))
          (setq found t)
          (push (jellyfin--stream-url (alist-get 'Id ep) "Videos") urls)
          (push (alist-get 'Id ep) ep-ids)))
      (setq urls (nreverse urls)
            ep-ids (nreverse ep-ids))
      (jellyfin--mpv-play urls (apply #'vector ep-ids))
      (message "Playing %s — %s + %d more"
               series-choice
               (alist-get 'Name chosen-ep)
               (1- (length urls))))))

(defvar jellyfin--shows-gallery-cache nil
  "Cached list of series items from the Jellyfin server.")

(defun jellyfin--shows-gallery-cache-file ()
  "Return the path to the shows gallery cache file."
  (expand-file-name "jellyfin-shows-gallery-cache.el" user-emacs-directory))

(defun jellyfin--shows-gallery-cache-save ()
  "Write `jellyfin--shows-gallery-cache' to disk."
  (when jellyfin--shows-gallery-cache
    (with-temp-file (jellyfin--shows-gallery-cache-file)
      (prin1 jellyfin--shows-gallery-cache (current-buffer)))))

(defun jellyfin--shows-gallery-cache-load ()
  "Load `jellyfin--shows-gallery-cache' from disk if the file exists."
  (let ((file (jellyfin--shows-gallery-cache-file)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (setq jellyfin--shows-gallery-cache (read (current-buffer))))
      (jellyfin--item-cache-populate jellyfin--shows-gallery-cache))))

;;;###autoload
(defun jellyfin-browse-shows-gallery ()
  "Browse TV shows as a responsive poster grid in a *Jellyfin* buffer.
Like `jellyfin-browse-shows' but fully buffer-based with clickable
poster images.  Requires graphical Emacs.
Uses cached metadata when available; run
`jellyfin-browse-shows-gallery-refetch-metadata' to refresh."
  (interactive)
  (unless (display-graphic-p)
    (user-error "jellyfin-browse-shows-gallery requires graphical Emacs"))
  (unless jellyfin--shows-gallery-cache
    (jellyfin--shows-gallery-cache-load))
  (unless jellyfin--shows-gallery-cache
    (jellyfin-browse-shows-gallery-refetch-metadata))
  (if (zerop (length jellyfin--shows-gallery-cache))
      (message "No shows found on server.")
    (jellyfin--show-dired-render-grid
     (append jellyfin--shows-gallery-cache nil)
     (lambda (item)
       (lambda (_btn)
         (jellyfin--show-preview-season item)))
     (lambda (item)
       (alist-get 'Name item))
     "*Jellyfin Shows*")))

;;;###autoload
(defun jellyfin-browse-shows-gallery-refetch-metadata ()
  "Fetch all shows from the Jellyfin server and update the local cache.
Also clears cached poster images for shows so they are re-fetched."
  (interactive)
  (jellyfin--ensure-auth)
  (message "Fetching shows...")
  ;; Clear disk-cached images for old items
  (when jellyfin--shows-gallery-cache
    (let ((dir (jellyfin--image-cache-dir)))
      (seq-doseq (item jellyfin--shows-gallery-cache)
        (let ((file (expand-file-name (alist-get 'Id item) dir)))
          (when (file-exists-p file)
            (delete-file file))
          (remhash (alist-get 'Id item) jellyfin--preview-image-cache)))))
  (setq jellyfin--shows-gallery-cache
        (append (jellyfin--retry-if-empty
                 (lambda () (jellyfin--get-items "Series")))
                nil))
  (jellyfin--shows-gallery-cache-save)
  (jellyfin--item-cache-populate jellyfin--shows-gallery-cache)
  (message "Cached %d shows." (length jellyfin--shows-gallery-cache))
  (jellyfin-browse-shows-gallery))

;;;###autoload
(defun jellyfin-browse-continue-watching ()
  "Resume a movie or show from Jellyfin's Continue Watching list."
  (interactive)
  (jellyfin--ensure-auth)
  (let* ((items (jellyfin--retry-if-empty
                  (lambda ()
                    (alist-get 'Items
                               (jellyfin--api-get
                                "/UserItems/Resume"
                                `(("userId" . ,jellyfin--user-id)
                                  ("enableUserData" . "true")
                                  ("mediaTypes" . "Video")
                                  ("limit" . "20")
                                  ("fields" . "MediaSources,Overview")))))))
         (labels (mapcar
                  (lambda (item)
                    (let* ((type (alist-get 'Type item))
                           (name (alist-get 'Name item))
                           (ticks (alist-get 'PlaybackPositionTicks
                                             (alist-get 'UserData item)))
                           (pos-min (/ (or ticks 0) 600000000))
                           (label
                            (if (equal type "Episode")
                                (format "%s — S%02dE%02d — %s  [%dm in]"
                                        (or (alist-get 'SeriesName item) "?")
                                        (or (alist-get 'ParentIndexNumber item) 0)
                                        (or (alist-get 'IndexNumber item) 0)
                                        name pos-min)
                              (format "%s  [%dm in]" name pos-min))))
                      (cons label item)))
                  items))
         (cands (mapcar #'car labels))
         (choice (if jellyfin-completing-read-preview
                     (progn
                       (setq jellyfin--preview-data labels)
                       (minibuffer-with-setup-hook
                           (lambda ()
                             (add-hook 'post-command-hook
                                       #'jellyfin--preview-update nil t)
                             (add-hook 'minibuffer-exit-hook
                                       #'jellyfin--preview-cleanup nil t))
                         (completing-read "Continue watching: "
                                          (lambda (str pred action)
                                            (if (eq action 'metadata)
                                                '(metadata (display-sort-function . identity))
                                              (complete-with-action action cands str pred)))
                                          nil t)))
                   (completing-read "Continue watching: "
                                    (lambda (str pred action)
                                      (if (eq action 'metadata)
                                          '(metadata (display-sort-function . identity))
                                        (complete-with-action action cands str pred)))
                                    nil t)))
         (item (cdr (assoc choice labels)))
         (type (alist-get 'Type item))
         (id (alist-get 'Id item))
         (ticks (alist-get 'PlaybackPositionTicks
                           (alist-get 'UserData item)))
         (start-secs (/ (or ticks 0) 10000000)))
    (if (equal type "Movie")
        ;; Movie: resume at saved position
        (let ((url (jellyfin--stream-url id "Videos")))
          (jellyfin--mpv-play (list url) (vector id) start-secs)
          (message "Resuming movie: %s at %dm%ds"
                   (alist-get 'Name item)
                   (/ start-secs 60) (mod start-secs 60)))
      ;; Episode: fetch remaining episodes in season, resume first one
      (let* ((series-id (alist-get 'SeriesId item))
             (season-id (alist-get 'SeasonId item))
             (episodes (jellyfin--get-episodes series-id season-id))
             (found nil)
             (urls nil)
             (ep-ids nil))
        ;; Collect this episode + all remaining
        (seq-doseq (ep episodes)
          (when (or found (equal (alist-get 'Id ep) id))
            (setq found t)
            (push (jellyfin--stream-url (alist-get 'Id ep) "Videos") urls)
            (push (alist-get 'Id ep) ep-ids)))
        (setq urls (nreverse urls))
        (setq ep-ids (nreverse ep-ids))
        (jellyfin--mpv-play urls (apply #'vector ep-ids) start-secs)
        (message "Resuming %s — S%02dE%02d + %d more at %dm%ds"
                 (or (alist-get 'SeriesName item) "?")
                 (or (alist-get 'ParentIndexNumber item) 0)
                 (or (alist-get 'IndexNumber item) 0)
                 (1- (length urls))
                 (/ start-secs 60) (mod start-secs 60))))))

;;; --- Cherry Picker (dired-like song selection) ---

(defvar jellyfin--songs-cache nil
  "Cached vector of song items from the Jellyfin server.
Populated by `jellyfin-browse-songs-refetch-metadata'.")

(defun jellyfin--songs-cache-file ()
  "Return the path to the songs cache file."
  (expand-file-name "jellyfin-songs-cache.el" user-emacs-directory))

(defun jellyfin--songs-cache-save ()
  "Write `jellyfin--songs-cache' to disk."
  (when jellyfin--songs-cache
    (with-temp-file (jellyfin--songs-cache-file)
      (prin1 jellyfin--songs-cache (current-buffer)))))

(defun jellyfin--songs-cache-load ()
  "Load `jellyfin--songs-cache' from disk if the file exists."
  (let ((file (jellyfin--songs-cache-file)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (setq jellyfin--songs-cache (read (current-buffer))))
      (jellyfin--item-cache-populate jellyfin--songs-cache))))

(defvar jellyfin--cherry-picker-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "m") #'jellyfin--cherry-picker-mark)
    (define-key map (kbd "u") #'jellyfin--cherry-picker-unmark)
    (define-key map (kbd "U") #'jellyfin--cherry-picker-unmark-all)
    (define-key map (kbd "M") #'jellyfin--cherry-picker-mark-all)
    (define-key map (kbd "RET") #'jellyfin--cherry-picker-execute)
    (define-key map (kbd "q") #'jellyfin--cherry-picker-quit)
    (when (display-graphic-p)
      (define-key map (kbd "!") #'jellyfin--cherry-picker-song-info))
    map)
  "Keymap for the Jellyfin cherry picker buffer.")

(defun jellyfin--cherry-picker-mode ()
  "Set up the current buffer as a Jellyfin cherry picker buffer."
  (special-mode)
  (use-local-map jellyfin--cherry-picker-mode-map)
  (setq mode-name "Jellyfin Songs"
        header-line-format
        (substitute-command-keys
         (concat " \\<jellyfin--cherry-picker-mode-map>\\[jellyfin--cherry-picker-mark] mark  \\[jellyfin--cherry-picker-unmark] unmark  \\[jellyfin--cherry-picker-mark-all] mark all  \\[jellyfin--cherry-picker-unmark-all] unmark all  \\[jellyfin--cherry-picker-execute] queue"
                 (when (display-graphic-p)
                   "  \\[jellyfin--cherry-picker-song-info] info")
                 "  \\[jellyfin--cherry-picker-quit] quit"))))

(defun jellyfin--cherry-picker-render (songs)
  "Render SONGS into the *Jellyfin Songs* buffer."
  (let ((buf (get-buffer-create "*Jellyfin Songs*")))
    (with-current-buffer buf
      (jellyfin--cherry-picker-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (seq-doseq (item songs)
          (let* ((artists (alist-get 'AlbumArtists item))
                 (artist (if (and artists (> (length artists) 0))
                             (alist-get 'Name (aref artists 0))
                           "Unknown Artist"))
                 (album (or (alist-get 'Album item) "Unknown Album"))
                 (index (alist-get 'IndexNumber item))
                 (title (alist-get 'Name item))
                 (title-str (if index
                                (format "%02d. %s" index title)
                              title))
                 (line (format "[ ]  %s — %s — %s" artist album title-str))
                 (start (point)))
            (insert line)
            (put-text-property start (point) 'jellyfin-item item)
            (insert "\n")))
        (goto-char (point-min))))
    (switch-to-buffer buf)
    (message "%d songs loaded." (length songs))))

(defun jellyfin--cherry-picker-mark ()
  "Mark the song on the current line and advance."
  (interactive)
  (let ((inhibit-read-only t))
    (save-excursion
      (beginning-of-line)
      (when (looking-at "\\[ \\]")
        (replace-match "[x]")))
    (forward-line 1)))

(defun jellyfin--cherry-picker-unmark ()
  "Unmark the song on the current line and advance."
  (interactive)
  (let ((inhibit-read-only t))
    (save-excursion
      (beginning-of-line)
      (when (looking-at "\\[x\\]")
        (replace-match "[ ]")))
    (forward-line 1)))

(defun jellyfin--cherry-picker-unmark-all ()
  "Unmark all songs in the buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\[x\\]" nil t)
        (replace-match "[ ]")))))

(defun jellyfin--cherry-picker-mark-all ()
  "Mark all songs in the buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\[ \\]" nil t)
        (replace-match "[x]")))))

(defun jellyfin--cherry-picker-execute ()
  "Append marked songs to EMMS playlist, unmark them, and switch to EMMS.
The *Jellyfin Songs* buffer stays open so you can return and queue more."
  (interactive)
  (let ((items nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (looking-at "\\[x\\]")
          (push (get-text-property (+ (line-beginning-position) 5)
                                   'jellyfin-item)
                items))
        (forward-line 1)))
    (if (null items)
        (message "No songs marked.")
      (setq items (nreverse items))
      (jellyfin--cherry-picker-unmark-all)
      (jellyfin--add-jellyfin-tracks items)
      (add-hook 'emms-player-started-hook #'jellyfin--playlist-track-started)
      (add-hook 'emms-player-started-hook #'jellyfin--elcava-track-started)
      (switch-to-buffer emms-playlist-buffer)
      (message "Queued %d songs." (length items)))))

(defun jellyfin--cherry-picker-quit ()
  "Quit the cherry picker without queueing anything."
  (interactive)
  (kill-buffer (current-buffer)))

;;;###autoload
(defun jellyfin-browse-songs ()
  "Open a dired-like buffer listing all songs for cherry-picking.
Uses cached metadata when available; run
`jellyfin-browse-songs-refetch-metadata' to refresh."
  (interactive)
  (unless jellyfin--songs-cache
    (jellyfin--songs-cache-load))
  (unless jellyfin--songs-cache
    (jellyfin-browse-songs-refetch-metadata))
  (if (zerop (length jellyfin--songs-cache))
      (message "No songs found on server.")
    (jellyfin--cherry-picker-render jellyfin--songs-cache)))

;;;###autoload
(defun jellyfin-browse-songs-refetch-metadata ()
  "Fetch all songs from the Jellyfin server and update the local cache."
  (interactive)
  (jellyfin--ensure-auth)
  (message "Fetching songs...")
  (setq jellyfin--songs-cache
        (jellyfin--retry-if-empty
         (lambda ()
           (alist-get 'Items
             (jellyfin--api-get
              (format "/Users/%s/Items" jellyfin--user-id)
              '(("IncludeItemTypes" . "Audio")
                ("Recursive" . "true")
                ("SortBy" . "AlbumArtist,Album,IndexNumber")
                ("SortOrder" . "Ascending")
                ("Fields" . "MediaSources")))))))
  (jellyfin--songs-cache-save)
  (jellyfin--item-cache-populate jellyfin--songs-cache)
  (message "Cached %d songs." (length jellyfin--songs-cache)))

;;; --- Song Info popup ---

(defun jellyfin--format-ticks (ticks)
  "Format Jellyfin RunTimeTicks (100ns units) as \"M:SS\" or \"H:MM:SS\"."
  (let* ((total-secs (/ (or ticks 0) 10000000))
         (hours (/ total-secs 3600))
         (mins (/ (mod total-secs 3600) 60))
         (secs (mod total-secs 60)))
    (if (> hours 0)
        (format "%d:%02d:%02d" hours mins secs)
      (format "%d:%02d" mins secs))))

(defvar jellyfin--song-info-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "q") #'jellyfin--song-info-quit)
    (define-key map (kbd "RET") #'jellyfin--song-info-queue-album)
    (define-key map [mouse-1] #'jellyfin--song-info-queue-album)
    (define-key map [wheel-up] (lambda () (interactive) (scroll-down 3)))
    (define-key map [wheel-down] (lambda () (interactive) (scroll-up 3)))
    map)
  "Keymap for the Jellyfin song info buffer.
Only `q', RET, mouse-1 and mouse scrolling are active; all other keys are suppressed.")

(defun jellyfin--song-info-mode ()
  "Set up the current buffer as a Jellyfin song info buffer."
  (special-mode)
  (use-local-map jellyfin--song-info-mode-map)
  (setq mode-name "Jellyfin Song Info"
        cursor-type nil
        truncate-lines nil
        word-wrap t))

(defun jellyfin--song-info-quit ()
  "Kill the song info buffer and return to the cherry picker."
  (interactive)
  (let ((parent jellyfin--parent-buffer))
    (kill-buffer (current-buffer))
    (when (and parent (buffer-live-p parent))
      (switch-to-buffer parent))))

(defun jellyfin--song-info-queue-album ()
  "Queue the album at point to EMMS and dismiss the song info buffer."
  (interactive)
  (if-let ((album-id (get-text-property (point) 'jellyfin-album-id)))
      (let ((tracks (jellyfin--get-album-tracks album-id)))
        (if (and tracks (> (length tracks) 0))
            (progn
              (jellyfin--add-jellyfin-tracks tracks)
              (add-hook 'emms-player-started-hook
                        #'jellyfin--playlist-track-started)
              (add-hook 'emms-player-started-hook
                        #'jellyfin--elcava-track-started)
              (let ((parent jellyfin--parent-buffer))
                (kill-buffer (current-buffer))
                (switch-to-buffer emms-playlist-buffer))
              (message "Queued %d tracks" (length tracks)))
          (message "No tracks found for this album.")))
    (message "No album at point.")))

(defun jellyfin--song-info-render (item)
  "Render a detailed song info buffer for ITEM."
  (let* ((parent (current-buffer))
         (song-name (alist-get 'Name item))
         (album-id (alist-get 'AlbumId item))
         (artists (alist-get 'AlbumArtists item))
         (artist-name (if (and artists (> (length artists) 0))
                          (alist-get 'Name (aref artists 0))
                        "Unknown Artist"))
         (artist-id (and artists (> (length artists) 0)
                         (alist-get 'Id (aref artists 0))))
         (index (alist-get 'IndexNumber item))
         (ticks (alist-get 'RunTimeTicks item))
         (artist-data (when artist-id
                        (condition-case nil
                            (jellyfin--get-item-by-id artist-id)
                          (error nil))))
         (genres (when artist-data
                   (alist-get 'Genres artist-data)))
         (overview (when artist-data
                     (alist-get 'Overview artist-data)))
         (buf (get-buffer-create "*Jellyfin Song Info*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (jellyfin--song-info-mode)
        ;; Artist backdrop
        (when (and (display-graphic-p) artist-id)
          (when-let ((backdrop (jellyfin--fetch-image-type
                                artist-id "Backdrop" 600)))
            (insert-image backdrop "[backdrop]")
            (insert "\n\n")))
        ;; Artist image + name + genres
        (when (and (display-graphic-p) artist-id)
          (when-let ((artist-img (jellyfin--fetch-image-type
                                  artist-id "Primary" 150)))
            (insert-image artist-img "[artist]")
            (insert "\n")))
        (insert (propertize artist-name
                            'face '(:weight bold :height 1.4))
                "\n")
        (when (and genres (> (length genres) 0))
          (insert (propertize (mapconcat #'identity (append genres nil) " / ")
                              'face '(:foreground "gray60"))
                  "\n"))
        (insert "\n")
        ;; Song title
        (insert (propertize song-name
                            'face '(:weight bold))
                "\n")
        ;; Track number + duration
        (let ((parts nil))
          (when index
            (push (format "Track %d" index) parts))
          (when ticks
            (push (jellyfin--format-ticks ticks) parts))
          (when parts
            (insert (mapconcat #'identity (nreverse parts) "  |  ") "\n")))
        ;; Discography (grid layout)
        (when artist-id
          (let ((disco-albums (condition-case nil
                                  (jellyfin--get-albums-by-artist artist-id)
                                (error nil))))
            (when (and disco-albums (> (length disco-albums) 0))
              (insert "\n"
                      (propertize "Discography"
                                  'face '(:weight bold :height 1.1))
                      "  "
                      (propertize "(click album to send to EMMS)"
                                  'face '(:foreground "gray60" :slant italic))
                      "\n\n")
              (let* ((img-w 150)
                     (min-gap 20)
                     (win-w (window-body-width nil t))
                     (cols (max 1 (/ win-w (+ img-w min-gap))))
                     (col-w (/ win-w cols))
                     (rows (seq-partition (append disco-albums nil) cols)))
                (dolist (row rows)
                  ;; Cover row
                  (let ((idx 0))
                    (dolist (alb row)
                      (let* ((alb-id (alist-get 'Id alb))
                             (img (or (and alb-id
                                          (jellyfin--fetch-image-type
                                           alb-id "Primary" img-w))
                                      (jellyfin--image-rescale
                                       (jellyfin--music-placeholder-image)
                                       img-w))))
                        (when (> idx 0)
                          (insert (propertize
                                   " " 'display
                                   `(space :align-to (,(* idx col-w))))))
                        (when img
                          (let ((start (point)))
                            (insert-image img "[album]")
                            (put-text-property start (point)
                                              'jellyfin-album-id alb-id))))
                      (setq idx (1+ idx))))
                  (insert "\n")
                  ;; Title row
                  (let ((idx 0))
                    (dolist (alb row)
                      (let* ((alb-id (alist-get 'Id alb))
                             (alb-name (or (alist-get 'Name alb)
                                           "Unknown Album"))
                             (alb-year (alist-get 'ProductionYear alb))
                             (current-p (and album-id
                                             (string= alb-id album-id))))
                        (when (> idx 0)
                          (insert (propertize
                                   " " 'display
                                   `(space :align-to (,(* idx col-w))))))
                        (let ((start (point)))
                          (insert (propertize alb-name
                                              'face '(:weight bold)))
                          (when alb-year
                            (insert (propertize (format "  (%d)" alb-year)
                                                'face '(:foreground "gray60"))))
                          (when current-p
                            (insert (propertize
                                     "  <--"
                                     'face '(:foreground "gold"
                                             :weight bold))))
                          (put-text-property start (point)
                                            'jellyfin-album-id alb-id)))
                      (setq idx (1+ idx))))
                  (insert "\n\n"))))))
        ;; Artist bio
        (when (and overview (not (string-empty-p overview)))
          (insert "\n"
                  (propertize "About the Artist"
                              'face '(:weight bold :height 1.1))
                  "\n"
                  overview "\n"))
        (goto-char (point-min))))
    (switch-to-buffer buf)
    (setq jellyfin--parent-buffer parent)))

(defun jellyfin--cherry-picker-song-info ()
  "Show detailed info for the song on the current line."
  (interactive)
  (if-let ((item (get-text-property (point) 'jellyfin-item)))
      (jellyfin--song-info-render item)
    (message "No song on this line.")))

(defun jellyfin--emms-playlist-song-info ()
  "Show detailed Jellyfin song info for the track at point in the EMMS playlist."
  (interactive)
  (if-let* ((track (emms-playlist-track-at (point)))
            (url (emms-track-name track))
            (item (jellyfin--lookup-item-by-url url)))
      (jellyfin--song-info-render item)
    (message "No Jellyfin track on this line.")))

;;; --- Embedded elcava visualizer ---
;;
;; Uses elcava.el as the underlying DSP library.  Configures it for
;; 12 bars / 30 fps, reuses its FFT + smoothing pipeline, and renders
;; into the EMMS playlist buffer instead of *elcava*.

(defvar elcava--process)
(defvar elcava--bars)
(defvar elcava--colors)
(defvar elcava--raw)
(defvar elcava-bars)
(defvar elcava-framerate)
(declare-function elcava--cleanup "elcava")
(declare-function elcava--init-tables "elcava")
(declare-function elcava--init-freq-map "elcava")
(declare-function elcava--init-smoothing "elcava")
(declare-function elcava--init-colors "elcava")
(declare-function elcava--init-char-cache "elcava")
(declare-function elcava--start-capture "elcava")
(declare-function elcava--drain-samples "elcava")
(declare-function elcava--fft "elcava")
(declare-function elcava--compute-bars "elcava")
(declare-function elcava--smooth-bars "elcava")

(defvar jellyfin--elcava-timer nil "Render timer for embedded visualizer.")
(defvar jellyfin--elcava-rows 6 "Number of text rows for embedded visualizer.")

(defun jellyfin--elcava-render ()
  "Timer callback: compute spectrum via elcava, render into playlist buffer."
  (condition-case nil
      (when (and elcava--process
                 (process-live-p elcava--process)
                 (buffer-live-p emms-playlist-buffer))
        ;; DSP: drain → FFT → bars → smooth (all elcava internals)
        (if (elcava--drain-samples)
            (progn (elcava--fft) (elcava--compute-bars))
          (dotimes (i elcava-bars) (aset elcava--raw i 0.0)))
        (elcava--smooth-bars)
        ;; Render into playlist buffer (preserve cursor position)
        (with-current-buffer emms-playlist-buffer
          (let ((inhibit-read-only t)
                (saved-pt (point))
                (saved-win-pt (when-let ((w (get-buffer-window
                                             emms-playlist-buffer t)))
                                (cons w (window-point w))))
                (blocks " ▁▂▃▄▅▆▇█")
                (nbars elcava-bars)
                (rows jellyfin--elcava-rows)
                (bars elcava--bars)
                (colors elcava--colors))
            (save-excursion
              (goto-char (point-min))
              (let ((cover-end (point-min)))
                ;; Skip past cover region
                (while (and (< cover-end (point-max))
                            (get-text-property cover-end 'jellyfin-cover))
                  (setq cover-end (next-single-property-change
                                   cover-end 'jellyfin-cover nil (point-max))))
                ;; Remove old elcava region
                (let ((elcava-start cover-end)
                      (elcava-end cover-end))
                  (while (and (< elcava-end (point-max))
                              (get-text-property elcava-end 'jellyfin-elcava))
                    (setq elcava-end (next-single-property-change
                                      elcava-end 'jellyfin-elcava nil (point-max))))
                  (when (> elcava-end elcava-start)
                    (delete-region elcava-start elcava-end)))
                ;; Insert new bars
                (goto-char cover-end)
                (let ((start (point)))
                  (dotimes (r rows)
                    (let ((row-bottom (* (- rows r 1) 8)))
                      (dotimes (b nbars)
                        (let* ((h (* (aref bars b) rows 8.0))
                               (fill (min 8 (max 0 (truncate (- h row-bottom)))))
                               (ch (char-to-string (aref blocks fill)))
                               (color (aref colors b)))
                          (insert (if (> fill 0)
                                      (propertize ch 'face `(:foreground ,color))
                                    ch))
                          (when (< b (1- nbars))
                            (insert " ")))))
                    (insert "\n"))
                  (put-text-property start (point) 'jellyfin-elcava t))))
            ;; Restore window point so cursor doesn't jump
            (goto-char saved-pt)
            (when saved-win-pt
              (set-window-point (car saved-win-pt) (cdr saved-win-pt))))))
    (error nil)))

(defun jellyfin--elcava-start ()
  "Start embedded elcava visualizer in the EMMS playlist buffer.
Requires the `elcava' package."
  (when (and jellyfin-elcava-emms-experimental
             (not jellyfin--elcava-timer))
    (require 'elcava)
    (unless (executable-find "parec")
      (user-error "parec not found; install PipeWire or PulseAudio"))
    ;; Configure elcava for embedded use
    (elcava--cleanup)
    (setq elcava-bars 24
          elcava-framerate 30)
    (elcava--init-tables)
    (elcava--init-freq-map)
    (elcava--init-smoothing)
    (elcava--init-colors)
    (elcava--init-char-cache)
    (elcava--start-capture)
    (setq jellyfin--elcava-timer
          (run-at-time 0 (/ 1.0 elcava-framerate)
                       #'jellyfin--elcava-render))))

(defun jellyfin--elcava-stop ()
  "Stop embedded elcava visualizer and clean up."
  (when jellyfin--elcava-timer
    (cancel-timer jellyfin--elcava-timer)
    (setq jellyfin--elcava-timer nil))
  (when (fboundp 'elcava--cleanup)
    (elcava--cleanup))
  ;; Remove elcava region from playlist buffer
  (when (and (boundp 'emms-playlist-buffer)
             (buffer-live-p emms-playlist-buffer))
    (with-current-buffer emms-playlist-buffer
      (let ((inhibit-read-only t))
        (goto-char (point-min))
        (let ((start (point-min))
              (end (point-min)))
          (while (and (< end (point-max))
                      (not (get-text-property end 'jellyfin-elcava)))
            (setq end (next-single-property-change
                       end 'jellyfin-elcava nil (point-max))))
          (when (get-text-property end 'jellyfin-elcava)
            (setq start end)
            (while (and (< end (point-max))
                        (get-text-property end 'jellyfin-elcava))
              (setq end (next-single-property-change
                         end 'jellyfin-elcava nil (point-max))))
            (delete-region start end)))))))

(defun jellyfin--elcava-track-started ()
  "Start embedded elcava when a track starts (if enabled)."
  (when jellyfin-elcava-emms-experimental
    (jellyfin--elcava-stop)
    (jellyfin--elcava-start)))

(provide 'jellyfin-emms-mpv)
;;; jellyfin-emms-mpv.el ends here
