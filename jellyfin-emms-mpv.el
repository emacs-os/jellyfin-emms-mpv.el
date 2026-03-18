;;; jellyfin-emms-mpv.el --- Jellyfin API client for Emacs EMMS with mpv -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

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
;;   (setq jellyfin-preview t)               — enable poster/description preview
;;   M-x jellyfin-browse-movies             — pick a movie, open mpv
;;   M-x jellyfin-browse-shows              — series -> season -> pick episode, mpv plays through
;;   M-x jellyfin-browse-continue-watching  — resume a movie or show where you left off
;;   M-x jellyfin-browse-albums             — artist -> album -> queue tracks in EMMS
;;   M-x jellyfin-browse-playlists          — pick playlist -> queue tracks in EMMS
;;   M-x jellyfin-browse-songs              — dired-like song picker (cached; instant after first load)
;;   M-x jellyfin-browse-songs-refetch-metadata — re-fetch after adding/removing songs on server
;;
;; EMMS integration:
;;   Audio commands integrate via EMMS's native extension points:
;;   - `emms-info-jellyfin' is an info method (registered in `emms-info-functions')
;;     that resolves Jellyfin stream URLs to standard EMMS metadata (info-title,
;;     info-artist, info-album, info-tracknumber).
;;   - An in-memory item cache (`jellyfin--item-cache') backs metadata lookups so
;;     the info method resolves instantly with no extra API calls.
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

(defcustom jellyfin-preview nil
  "When non-nil, show a preview buffer with posters and descriptions
while browsing movies and shows."
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
Callback just kills the response buffer."
  (let ((url-request-method "POST")
        (url-request-extra-headers
         `(("Content-Type" . "application/json")
           ("X-Emby-Authorization" . ,(jellyfin--auth-header))))
        (url-request-data (json-encode body)))
    (url-retrieve (concat jellyfin-server-url path)
                  (lambda (_status &rest _)
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
  (add-to-list 'emms-info-functions #'emms-info-jellyfin))

(defun jellyfin--add-jellyfin-tracks (items)
  "Add Jellyfin audio ITEMS to the EMMS playlist.
ITEMS is a sequence of Jellyfin item alists.  Each item is cached
so `emms-info-jellyfin' can resolve metadata without API calls."
  (require 'emms)
  (jellyfin--item-cache-populate items)
  (seq-doseq (item items)
    (let* ((id (alist-get 'Id item))
           (url (jellyfin--stream-url id "Audio")))
      (emms-add-url url))))

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

(defun jellyfin--fetch-image (item-id)
  "Fetch poster image for ITEM-ID, returning an image descriptor or nil.
Results are cached in `jellyfin--preview-image-cache'."
  (or (gethash item-id jellyfin--preview-image-cache)
      (condition-case nil
          (let* ((url-show-status nil)
                 (img-url (format "%s/Items/%s/Images/Primary?maxWidth=300&api_key=%s"
                                  jellyfin-server-url item-id jellyfin--token))
                 (tmp-file (make-temp-file "jellyfin-poster-")))
            (url-copy-file img-url tmp-file t)
            (unwind-protect
                (when (and (file-exists-p tmp-file)
                           (> (file-attribute-size (file-attributes tmp-file)) 0))
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
        (error nil))))

(defun jellyfin--fetch-splash-image ()
  "Fetch the Jellyfin server splash screen as a fallback image.
Returns an image descriptor or nil.  Cached under the key `splash'."
  (or (gethash 'splash jellyfin--preview-image-cache)
      (condition-case nil
          (let* ((url-show-status nil)
                 (img-url (format "%s/Branding/Splashscreen?api_key=%s"
                                  jellyfin-server-url jellyfin--token))
                 (tmp-file (make-temp-file "jellyfin-splash-")))
            (url-copy-file img-url tmp-file t)
            (unwind-protect
                (when (and (file-exists-p tmp-file)
                           (> (file-attribute-size (file-attributes tmp-file)) 0))
                  (let* ((data (with-temp-buffer
                                 (set-buffer-multibyte nil)
                                 (insert-file-contents-literally tmp-file)
                                 (buffer-string)))
                         (image (create-image data nil t :width 300)))
                    (when image
                      (puthash 'splash image jellyfin--preview-image-cache)
                      image)))
              (when (file-exists-p tmp-file)
                (delete-file tmp-file))))
        (error nil))))

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
        jellyfin--mpv-play-session-id nil))

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
    (when (and start-secs (> start-secs 0))
      (push (format "--start=%d" start-secs) args))
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

(define-derived-mode jellyfin--preview-mode special-mode "Jellyfin"
  "Mode for the Jellyfin preview buffer."
  (setq truncate-lines nil
        word-wrap t
        scroll-step 1
        scroll-conservatively 10000)
  (define-key jellyfin--preview-mode-map [wheel-up]
              (lambda () (interactive) (scroll-down 1)))
  (define-key jellyfin--preview-mode-map [wheel-down]
              (lambda () (interactive) (scroll-up 1))))

(defun jellyfin--preview-render (matches)
  "Render MATCHES (alist of name.item) into the *Jellyfin* buffer."
  (let ((buf (get-buffer-create "*Jellyfin*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (jellyfin--preview-mode)
        (if (> (length matches) 20)
            (insert (format "%d movies -- type to narrow\n" (length matches)))
          (dolist (entry matches)
            (let* ((name (car entry))
                   (item (cdr entry))
                   (id (alist-get 'Id item))
                   (overview (or (alist-get 'Overview item) "")))
              ;; Poster image (GUI only)
              (when (display-graphic-p)
                (when-let ((image (jellyfin--fetch-image id)))
                  (insert-text-button "[poster]"
                                      'display image
                                      'action (lambda (_btn)
                                                (jellyfin--preview-select name))
                                      'follow-link t)
                  (insert "\n")))
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

(defun jellyfin--preview-update ()
  "Post-command-hook callback: update the preview buffer.
Only shows the preview once the user has typed something.
Uses `completion-all-completions' to respect the user's completion styles."
  (condition-case nil
      (when jellyfin--preview-data
        (let ((input (minibuffer-contents-no-properties)))
          (if (string-empty-p input)
              ;; No input yet -- hide preview if visible
              (when-let ((buf (get-buffer "*Jellyfin*")))
                (when-let ((win (get-buffer-window buf t)))
                  (delete-window win)))
            (let* ((completions (completion-all-completions
                                 input
                                 minibuffer-completion-table
                                 minibuffer-completion-predicate
                                 (length input)))
                   ;; Result is a dotted list; snip the base-size off the last cdr
                   (_ (when (consp completions)
                        (setcdr (last completions) nil)))
                   ;; Apply the display sort function if available
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
              (jellyfin--preview-render matches)))))
    (error nil)))

(defun jellyfin--preview-cleanup ()
  "Minibuffer-exit-hook callback: kill preview buffer and clear state."
  (when-let ((buf (get-buffer "*Jellyfin*")))
    (when-let ((win (get-buffer-window buf t)))
      (when (not (one-window-p t (window-frame win)))
        (delete-window win)))
    (kill-buffer buf))
  (setq jellyfin--preview-data nil))

;;; --- Show preview drill-down ---

(defvar jellyfin--show-preview-result nil
  "Stores the selected result during show preview drill-down.
Set by episode button, read after `recursive-edit' returns.")

(defun jellyfin--show-preview-render-items (items make-action make-label
                                                  &optional header)
  "Render ITEMS into the *Jellyfin* buffer for show drill-down.
MAKE-ACTION is called with an item and returns a button action function.
MAKE-LABEL is called with an item and returns its display label string.
HEADER, if non-nil, is a function called to insert header content at top."
  (let ((buf (get-buffer-create "*Jellyfin*")))
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

(defun jellyfin--show-preview-series (series-alist)
  "Render SERIES-ALIST in the *Jellyfin* buffer.
Each entry is (NAME . item).  Clicking a series drills into seasons."
  (jellyfin--show-preview-render-items
   (mapcar #'cdr series-alist)
   (lambda (item)
     (lambda (_btn)
       (jellyfin--show-preview-season item)))
   (lambda (item)
     (alist-get 'Name item))))

(defun jellyfin--show-preview-season (series-item)
  "Fetch and render seasons for SERIES-ITEM.
Shows series info as header, season list below."
  (let* ((series-id (alist-get 'Id series-item))
         (series-name (alist-get 'Name series-item))
         (seasons (jellyfin--get-seasons series-id)))
    (jellyfin--show-preview-render-items
     (append seasons nil)
     (lambda (item)
       (lambda (_btn)
         (jellyfin--show-preview-episodes series-item item)))
     (lambda (item)
       (alist-get 'Name item))
     (lambda ()
       (when (display-graphic-p)
         (when-let ((image (jellyfin--fetch-image series-id)))
           (insert-image image "[poster]")
           (insert "\n")))
       (insert (propertize series-name 'face 'bold) "\n")
       (let ((overview (or (alist-get 'Overview series-item) "")))
         (unless (string-empty-p overview)
           (insert overview "\n")))))))

(defun jellyfin--show-preview-episodes (series-item season-item)
  "Fetch and render episodes for SERIES-ITEM / SEASON-ITEM.
Shows series+season header, episode list below.
Clicking an episode stores the result and exits recursive-edit."
  (let* ((series-id (alist-get 'Id series-item))
         (series-name (alist-get 'Name series-item))
         (season-id (alist-get 'Id season-item))
         (season-name (alist-get 'Name season-item))
         (season-num (alist-get 'IndexNumber season-item))
         (episodes (jellyfin--get-episodes series-id season-id)))
    (jellyfin--show-preview-render-items
     (append episodes nil)
     (lambda (item)
       (lambda (_btn)
         (setq jellyfin--show-preview-result
               (list series-id season-item item episodes))
         (exit-recursive-edit)))
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
       (insert (propertize season-name 'face 'bold) "\n")))))

(defun jellyfin--show-preview-pick-episode (series-item)
  "Show drill-down buffer for SERIES-ITEM seasons and episodes.
Uses `recursive-edit' to wait for selection.
Returns (SERIES-ID SEASON-ITEM CHOSEN-EP EPISODES) or nil if aborted."
  (setq jellyfin--show-preview-result nil)
  (jellyfin--show-preview-season series-item)
  (condition-case nil
      (progn
        (recursive-edit)
        jellyfin--show-preview-result)
    (quit
     (jellyfin--preview-cleanup)
     nil)))

;;; --- Playlist cover art ---

(defun jellyfin--playlist-insert-cover (item-id &optional fallback-id)
  "Insert or replace cover image at top of EMMS playlist buffer.
Tries ITEM-ID first, then FALLBACK-ID, then the server splash screen.
Requires `jellyfin-preview' and GUI Emacs."
  (when (and jellyfin-preview (display-graphic-p))
    (let ((image (or (and item-id (jellyfin--fetch-image item-id))
                     (and fallback-id (jellyfin--fetch-image fallback-id))
                     (jellyfin--fetch-splash-image))))
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
  "Update playlist cover art when a new track starts playing.
Tries album cover first, falls back to artist image."
  (when (and jellyfin-preview (display-graphic-p))
    (when-let ((track (emms-playlist-current-selected-track)))
      (jellyfin--playlist-insert-cover
       (emms-track-get track 'jellyfin-cover-id)
       (emms-track-get track 'jellyfin-artist-id)))))

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
    (let ((choice (if jellyfin-preview
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

;;;###autoload
(defun jellyfin-browse-albums ()
  "Pick artist -> album -> queue all tracks to EMMS playlist."
  (interactive)
  (jellyfin--ensure-auth)
  (let* (;; Pick artist
         (artists (jellyfin--retry-if-empty #'jellyfin--get-artists))
         (artist-names (mapcar (lambda (a) (cons (alist-get 'Name a) a))
                               artists))
         (artist-choice (completing-read "Artist: "
                                         (mapcar #'car artist-names) nil t))
         (artist (cdr (assoc artist-choice artist-names)))
         (artist-id (alist-get 'Id artist))
         ;; Pick album
         (albums (jellyfin--get-albums-by-artist artist-id))
         (album-names (mapcar (lambda (a) (cons (alist-get 'Name a) a))
                              albums))
         (album-choice (completing-read "Album: "
                                        (mapcar #'car album-names) nil t))
         (album (cdr (assoc album-choice album-names)))
         (album-id (alist-get 'Id album))
         ;; Get tracks
         (tracks (jellyfin--get-album-tracks album-id)))
    (jellyfin--add-jellyfin-tracks tracks)
    (jellyfin--playlist-insert-cover album-id artist-id)
    (add-hook 'emms-player-started-hook #'jellyfin--playlist-track-started)
    (with-current-buffer emms-playlist-buffer
      (goto-char (point-min))
      (emms-playlist-mode-play-current-track))
    (switch-to-buffer emms-playlist-buffer)
    (message "Queued %d tracks from %s — %s"
             (length tracks) artist-choice album-choice)))

;;;###autoload
(defun jellyfin-browse-playlists ()
  "Pick a playlist -> queue all tracks to EMMS playlist."
  (interactive)
  (jellyfin--ensure-auth)
  (let* ((playlists (jellyfin--retry-if-empty #'jellyfin--get-playlists))
         (playlist-names (mapcar (lambda (p) (cons (alist-get 'Name p) p))
                                 playlists))
         (choice (completing-read "Playlist: "
                                  (mapcar #'car playlist-names) nil t))
         (playlist (cdr (assoc choice playlist-names)))
         (playlist-id (alist-get 'Id playlist))
         (tracks (jellyfin--get-playlist-items playlist-id)))
    (jellyfin--add-jellyfin-tracks tracks)
    (let* ((first (aref tracks 0))
           (first-artists (alist-get 'AlbumArtists first))
           (first-artist-id (and (> (length first-artists) 0)
                                 (alist-get 'Id (aref first-artists 0)))))
      (jellyfin--playlist-insert-cover
       (or (alist-get 'AlbumId first) playlist-id) first-artist-id))
    (add-hook 'emms-player-started-hook #'jellyfin--playlist-track-started)
    (with-current-buffer emms-playlist-buffer
      (goto-char (point-min))
      (emms-playlist-mode-play-current-track))
    (switch-to-buffer emms-playlist-buffer)
    (message "Queued %d tracks from %s" (length tracks) choice)))

;;;###autoload
(defun jellyfin-browse-shows ()
  "Browse TV shows: Series -> Season -> Episode, then play in mpv.
When `jellyfin-preview' is non-nil, shows a preview buffer with
images and descriptions.  Series selection uses completing-read with
preview; seasons and episodes use clickable drill-down in the buffer."
  (interactive)
  (jellyfin--ensure-auth)
  (let* ((series (jellyfin--retry-if-empty
                   (lambda () (jellyfin--get-items "Series"))))
         (series-alist (mapcar (lambda (s) (cons (alist-get 'Name s) s))
                               series))
         series-choice series-item series-id
         season-item season-id season-num
         episodes chosen-ep)
    ;; Step 1: Pick series
    (if jellyfin-preview
        (progn
          (setq jellyfin--preview-data series-alist)
          (setq series-choice
                (minibuffer-with-setup-hook
                    (lambda ()
                      (add-hook 'post-command-hook
                                #'jellyfin--preview-update nil t)
                      (add-hook 'minibuffer-exit-hook
                                #'jellyfin--preview-cleanup nil t))
                  (completing-read "Series: "
                                   (mapcar #'car series-alist) nil t))))
      (setq series-choice
            (completing-read "Series: "
                             (mapcar #'car series-alist) nil t)))
    (setq series-item (cdr (assoc series-choice series-alist))
          series-id (alist-get 'Id series-item))
    ;; Step 2: Pick season + episode
    (if jellyfin-preview
        (let ((result (jellyfin--show-preview-pick-episode series-item)))
          (unless result
            (user-error "Aborted"))
          (setq series-id (nth 0 result)
                season-item (nth 1 result)
                chosen-ep (nth 2 result)
                episodes (nth 3 result))
          (jellyfin--preview-cleanup))
      ;; Non-preview: completing-read for season and episode
      (let* ((seasons (jellyfin--get-seasons series-id))
             (season-alist (mapcar (lambda (s) (cons (alist-get 'Name s) s))
                                   seasons))
             (season-choice (completing-read "Season: "
                                             (mapcar #'car season-alist) nil t)))
        (setq season-item (cdr (assoc season-choice season-alist))
              season-id (alist-get 'Id season-item)
              season-num (alist-get 'IndexNumber season-item)
              episodes (jellyfin--get-episodes series-id season-id))
        (let* ((episode-alist
                (mapcar (lambda (ep)
                          (cons (format "S%02dE%02d — %s"
                                        (or season-num 0)
                                        (or (alist-get 'IndexNumber ep) 0)
                                        (alist-get 'Name ep))
                                ep))
                        episodes))
               (ep-choice (completing-read "Episode: "
                                           (lambda (str pred action)
                                             (if (eq action 'metadata)
                                                 '(metadata (display-sort-function . identity))
                                               (complete-with-action
                                                action (mapcar #'car episode-alist)
                                                str pred)))
                                           nil t)))
          (setq chosen-ep (cdr (assoc ep-choice episode-alist))))))
    ;; Step 3: Play from chosen episode onward
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
                                  ("fields" . "MediaSources")))))))
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
         (choice (completing-read "Continue watching: "
                                  (lambda (str pred action)
                                    (if (eq action 'metadata)
                                        '(metadata (display-sort-function . identity))
                                      (complete-with-action action cands str pred)))
                                  nil t))
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
    (define-key map (kbd "m") (lambda () (interactive) (jellyfin--cherry-picker-mark)))
    (define-key map (kbd "u") (lambda () (interactive) (jellyfin--cherry-picker-unmark)))
    (define-key map (kbd "U") (lambda () (interactive) (jellyfin--cherry-picker-unmark-all)))
    (define-key map (kbd "t") (lambda () (interactive) (jellyfin--cherry-picker-toggle-all)))
    (define-key map (kbd "RET") (lambda () (interactive) (jellyfin--cherry-picker-execute)))
    (define-key map (kbd "q") (lambda () (interactive) (jellyfin--cherry-picker-quit)))
    map)
  "Keymap for `jellyfin--cherry-picker-mode'.")

(define-derived-mode jellyfin--cherry-picker-mode special-mode "Jellyfin Songs"
  "Major mode for cherry-picking songs from Jellyfin.
\\{jellyfin--cherry-picker-mode-map}")

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
    (message "%d songs loaded. m=mark, u=unmark, t=toggle, RET=queue, q=quit"
             (length songs))))

(defun jellyfin--cherry-picker-mark ()
  "Mark the song on the current line and advance."
  (let ((inhibit-read-only t))
    (save-excursion
      (beginning-of-line)
      (when (looking-at "\\[ \\]")
        (replace-match "[x]")))
    (forward-line 1)))

(defun jellyfin--cherry-picker-unmark ()
  "Unmark the song on the current line and advance."
  (let ((inhibit-read-only t))
    (save-excursion
      (beginning-of-line)
      (when (looking-at "\\[x\\]")
        (replace-match "[ ]")))
    (forward-line 1)))

(defun jellyfin--cherry-picker-unmark-all ()
  "Unmark all songs in the buffer."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\[x\\]" nil t)
        (replace-match "[ ]")))))

(defun jellyfin--cherry-picker-toggle-all ()
  "Toggle marks on all songs in the buffer."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (cond
         ((looking-at "\\[x\\]") (replace-match "[ ]"))
         ((looking-at "\\[ \\]") (replace-match "[x]")))
        (forward-line 1)))))

(defun jellyfin--cherry-picker-execute ()
  "Append all marked songs to EMMS playlist and close the buffer."
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
      (jellyfin--add-jellyfin-tracks items)
      (let* ((first (car items))
             (first-artists (alist-get 'AlbumArtists first))
             (first-artist-id (and (> (length first-artists) 0)
                                   (alist-get 'Id (aref first-artists 0)))))
        (jellyfin--playlist-insert-cover
         (or (alist-get 'AlbumId first) (alist-get 'Id first))
         first-artist-id))
      (add-hook 'emms-player-started-hook #'jellyfin--playlist-track-started)
      (switch-to-buffer emms-playlist-buffer)
      (message "Queued %d songs." (length items))
      (kill-buffer "*Jellyfin Songs*"))))

(defun jellyfin--cherry-picker-quit ()
  "Quit the cherry picker without queueing anything."
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

(provide 'jellyfin-emms-mpv)
;;; jellyfin-emms-mpv.el ends here
