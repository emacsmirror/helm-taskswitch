;;; helm-taskswitch-browser.el --- Browser tabs for helm-taskswitch over a WebSocket  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Brian Caruso

;; Author: Brian Caruso <briancaruso@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; Maintainer: Brian Caruso <briancaruso@gmail.com>
;; Created: 2026-11-03
;; URL: https://github.com/bdc34/helm-taskswitch
;; Keywords: frames

;; This file is NOT part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Emacs runs a WebSocket server on 127.0.0.1.  The browser extension in
;; browser-extension/ connects to it, sends the list of tabs whenever
;; tabs change, and runs tab commands that Emacs sends (switch to, close,
;; open, reload, duplicate, mute).
;;
;; Setup:
;;   1. M-x helm-taskswitch-browser-install, which copies the extension
;;      to `helm-taskswitch-browser-extension-dir' (by default
;;      ~/.local/share/helm-taskswitch/browser-extension) and writes its
;;      config.js there with the port and a secret token.
;;   2. In chrome://extensions, turn on Developer mode, then "Load
;;      unpacked" and choose that directory.  After upgrading this
;;      package, run the install command again and reload the extension.
;;   3. M-x helm-taskswitch-browser-status shows connected browsers.
;;
;; Emacs starts listening for the extension the first time you run
;; M-x helm-taskswitch, once the install command has made the token.
;; Nothing needs to go in your init file.
;;
;; Security: the server only listens on 127.0.0.1.  A connection must
;; come from an allowed extension origin (web pages cannot fake the
;; Origin header), and must then prove it knows the token, which only
;; your user can read.  Emacs proves it knows the token too, before the
;; extension sends tabs or runs commands.  The token itself is never
;; sent.  Emacs never runs anything the browser sends.

;;; Code:

(require 'websocket)
(require 'seq)
(require 'subr-x)

(defgroup helm-taskswitch-browser nil
  "Browser tabs for helm-taskswitch, from a browser extension."
  :prefix "helm-taskswitch-browser-"
  :group 'helm-taskswitch)

(defcustom helm-taskswitch-browser-port 62841
  "TCP port on 127.0.0.1 that the browser extension connects to.
If you change it, run `helm-taskswitch-browser-install' again and
reload the extension."
  :type 'integer
  :group 'helm-taskswitch-browser)

(defcustom helm-taskswitch-browser-allowed-origins
  '("chrome-extension://iofbocbifodmmplkphnmicpokfpgiodh")
  "Origins allowed to connect.
The default is the ID of the extension in browser-extension/, which
the key in its manifest.json fixes."
  :type '(repeat string)
  :group 'helm-taskswitch-browser)

(defcustom helm-taskswitch-browser-token-file
  (expand-file-name "helm-taskswitch/token"
                    (or (getenv "XDG_CONFIG_HOME") "~/.config"))
  "File holding the secret token the extension must send.
It is created, readable only by you, the first time it is needed."
  :type 'file
  :group 'helm-taskswitch-browser)

(defvar helm-taskswitch-browser--source-dir
  (expand-file-name "browser-extension"
                    (file-name-directory (or load-file-name buffer-file-name
                                             default-directory)))
  "The extension's files as shipped with this package.")

(defcustom helm-taskswitch-browser-extension-dir
  (expand-file-name "helm-taskswitch/browser-extension"
                    (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Directory Chrome loads the extension from.
`helm-taskswitch-browser-install' copies the extension here and
writes its config.js here.  It is outside the package directory
because package.el deletes that on every upgrade, which would break
the extension in Chrome.

To work on the extension itself, set this to the browser-extension/
directory of your git checkout; install then only writes config.js."
  :type 'directory
  :group 'helm-taskswitch-browser)

(defun helm-taskswitch-browser--manifest-version (dir)
  "Return the version in DIR's manifest.json, or nil."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents (expand-file-name "manifest.json" dir))
      (alist-get 'version (json-parse-buffer :object-type 'alist)))))

(defvar helm-taskswitch-browser--bundled-version
  (helm-taskswitch-browser--manifest-version helm-taskswitch-browser--source-dir)
  "Version of the extension shipped with this package.")

(defcustom helm-taskswitch-browser-log nil
  "When non-nil, log connections and messages with `message'."
  :type 'boolean
  :group 'helm-taskswitch-browser)

(defconst helm-taskswitch-browser-protocol 2
  "Version of the message format; the extension sends it in hello.
Version 2 proves the token with HMAC instead of sending it.")

(defvar helm-taskswitch-browser--hello-timeout 5
  "Seconds a new connection has to send a good hello.")

(defvar helm-taskswitch-browser--server nil
  "The server process, or nil when not running.")

(defvar helm-taskswitch-browser--clients (make-hash-table :test #'eq)
  "Connected clients: websocket -> plist.
Keys: :origin-ok, :authed, :browser, :started-at, :opened, :last-seen,
:tabs (list of alists), :tabs-updated, :hello-timer.")

(defvar helm-taskswitch-browser--next-id 0
  "Id of the last command sent.")

(defvar helm-taskswitch-browser--callbacks (make-hash-table :test #'eql)
  "Command id -> (WEBSOCKET . FUNCTION).
FUNCTION is called with the reply, which must come from WEBSOCKET.")

(defun helm-taskswitch-browser--log (fmt &rest args)
  "Log FMT with ARGS when `helm-taskswitch-browser-log' is on."
  (when helm-taskswitch-browser-log
    (apply #'message (concat "helm-taskswitch-browser: " fmt) args)))

;;;; Token

(defun helm-taskswitch-browser--random-hex (nbytes)
  "Return NBYTES random bytes from /dev/urandom as hex."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (unless (zerop (call-process "head" nil t nil "-c" (number-to-string nbytes)
                                 "/dev/urandom"))
      (error "Could not read /dev/urandom"))
    (unless (= (buffer-size) nbytes)
      (error "Short read from /dev/urandom"))
    (mapconcat (lambda (b) (format "%02x" b)) (buffer-string) "")))

(defun helm-taskswitch-browser--token ()
  "Return the token, creating the token file if needed."
  (let ((file helm-taskswitch-browser-token-file))
    (unless (file-exists-p file)
      (with-file-modes #o700
        (make-directory (file-name-directory file) t))
      (with-file-modes #o600
        (write-region (helm-taskswitch-browser--random-hex 32) nil file
                      nil 'silent)))
    (with-temp-buffer
      (insert-file-contents file)
      (string-trim (buffer-string)))))

;;;; Proving the token
;;
;; Neither side sends the token.  On connect Emacs sends a random
;; challenge nonce.  The extension answers with its own nonce and an
;; HMAC of both nonces keyed with the token; Emacs answers that with an
;; HMAC under a different label.  So a program that takes the port while
;; Emacs is not running learns nothing it can reuse, and the extension
;; sends no tabs and runs no commands until Emacs has proved itself.

(defun helm-taskswitch-browser--hmac (key message)
  "Return the HMAC-SHA256 of MESSAGE keyed with KEY, as lowercase hex.
KEY and MESSAGE are strings, encoded as UTF-8."
  (let* ((key (encode-coding-string key 'utf-8 t))
         (key (if (> (length key) 64)
                  (secure-hash 'sha256 key nil nil t)
                key))
         (key (concat key (make-string (- 64 (length key)) 0)))
         (pad (lambda (byte)
                (apply #'unibyte-string
                       (mapcar (lambda (b) (logxor b byte)) key)))))
    (secure-hash
     'sha256
     (concat (funcall pad #x5c)
             (secure-hash 'sha256
                          (concat (funcall pad #x36)
                                  (encode-coding-string message 'utf-8 t))
                          nil nil t)))))

(defun helm-taskswitch-browser--proof (role server-nonce client-nonce)
  "Return the proof for ROLE, \"client\" or \"server\", over both nonces.
SERVER-NONCE and CLIENT-NONCE are the hex nonces of this connection."
  (helm-taskswitch-browser--hmac
   (helm-taskswitch-browser--token)
   (format "helm-taskswitch %s\n%s\n%s" role server-nonce client-nonce)))

(defun helm-taskswitch-browser--secret-equal (a b)
  "Return non-nil if strings A and B are equal.
The time taken does not depend on where they differ."
  (and (stringp a) (stringp b)
       (= (length a) (length b))
       (let ((diff 0))
         (dotimes (i (length a))
           (setq diff (logior diff (logxor (aref a i) (aref b i)))))
         (zerop diff))))

;;;; Server

(defun helm-taskswitch-browser--state (ws)
  "Return the state plist for WS."
  (gethash ws helm-taskswitch-browser--clients))

(defun helm-taskswitch-browser--put (ws prop value)
  "Set PROP to VALUE in the state of WS."
  (puthash ws (plist-put (helm-taskswitch-browser--state ws) prop value)
           helm-taskswitch-browser--clients))

(defun helm-taskswitch-browser--send-json (ws object)
  "Send OBJECT, an alist, to WS as JSON."
  (when (websocket-openp ws)
    (websocket-send-text ws (json-serialize object))))

(defun helm-taskswitch-browser--refuse (ws reason)
  "Tell WS it is refused because of REASON, then close it."
  (helm-taskswitch-browser--log "refusing %S: %s"
                                (websocket-origin ws) reason)
  (when (plist-get (helm-taskswitch-browser--state ws) :origin-ok)
    ;; Only explain to our own extension, so it can log the reason.
    (helm-taskswitch-browser--send-json
     ws `((type . "error") (message . ,reason))))
  (helm-taskswitch-browser--put ws :origin-ok nil)
  (helm-taskswitch-browser--put ws :authed nil)
  (websocket-close ws))

(defun helm-taskswitch-browser--on-open (ws)
  "Check the origin of a new connection WS."
  ;; websocket.el marks the listening server as noquery, but not the
  ;; connections it accepts, so quitting Emacs asked about killing them.
  ;; Dropping a browser connection is harmless: it reconnects later.
  (set-process-query-on-exit-flag (websocket-conn ws) nil)
  (let ((origin (websocket-origin ws)))
    (puthash ws (list :origin-ok nil :authed nil :opened (current-time))
             helm-taskswitch-browser--clients)
    (if (not (member origin helm-taskswitch-browser-allowed-origins))
        (helm-taskswitch-browser--refuse ws (format "origin %S not allowed"
                                                    origin))
      (helm-taskswitch-browser--put ws :origin-ok t)
      (let ((nonce (helm-taskswitch-browser--random-hex 16)))
        (helm-taskswitch-browser--put ws :nonce nonce)
        (helm-taskswitch-browser--send-json
         ws `((type . "challenge")
              (protocol . ,helm-taskswitch-browser-protocol)
              (nonce . ,nonce))))
      (helm-taskswitch-browser--put
       ws :hello-timer
       (run-at-time helm-taskswitch-browser--hello-timeout nil
                    (lambda ()
                      (when (and (websocket-openp ws)
                                 (not (plist-get
                                       (helm-taskswitch-browser--state ws)
                                       :authed)))
                        (helm-taskswitch-browser--refuse ws "no hello"))))))))

(defun helm-taskswitch-browser--on-close (ws)
  "Forget the closed connection WS."
  (let ((state (helm-taskswitch-browser--state ws)))
    (when-let ((timer (plist-get state :hello-timer)))
      (cancel-timer timer))
    (when (plist-get state :authed)
      (message "helm-taskswitch-browser: %s disconnected"
               (plist-get state :browser))))
  ;; Its replies will never come, so drop the callbacks waiting for them.
  (let (pending)
    (maphash (lambda (id entry)
               (when (eq (car entry) ws)
                 (push id pending)))
             helm-taskswitch-browser--callbacks)
    (dolist (id pending)
      (remhash id helm-taskswitch-browser--callbacks)))
  (remhash ws helm-taskswitch-browser--clients))

(defun helm-taskswitch-browser--on-error (_ws type err)
  "Log errors of TYPE with ERR instead of signaling them."
  (message "helm-taskswitch-browser: %s error: %S" type err))

(defun helm-taskswitch-browser--handle-hello (ws msg)
  "Check the hello MSG from WS and mark it authenticated."
  (let* ((protocol (alist-get 'protocol msg))
         (server-nonce (plist-get (helm-taskswitch-browser--state ws) :nonce))
         (client-nonce (alist-get 'nonce msg)))
    ;; Kept even when refused, so status can show what is connecting.
    (helm-taskswitch-browser--put ws :version (alist-get 'extensionVersion msg))
    (cond
     ;; Checked first: an older extension sends no proof at all.
     ((not (eql protocol helm-taskswitch-browser-protocol))
      (helm-taskswitch-browser--refuse
       ws (format "protocol %S, Emacs speaks %d; run M-x helm-taskswitch-browser-install and reload the extension"
                  protocol helm-taskswitch-browser-protocol)))
     ((not (and (stringp client-nonce)
                (string-match-p "\\`[0-9a-f]\\{32,128\\}\\'" client-nonce)))
      (helm-taskswitch-browser--refuse ws "bad nonce"))
     ((not (helm-taskswitch-browser--secret-equal
            (alist-get 'proof msg)
            (helm-taskswitch-browser--proof "client" server-nonce client-nonce)))
      (helm-taskswitch-browser--refuse ws "wrong token; run M-x helm-taskswitch-browser-install and reload the extension"))
     (t
      (when-let ((timer (plist-get (helm-taskswitch-browser--state ws)
                                   :hello-timer)))
        (cancel-timer timer))
      (helm-taskswitch-browser--put ws :hello-timer nil)
      (helm-taskswitch-browser--put ws :authed t)
      (helm-taskswitch-browser--put ws :browser
                                    (or (alist-get 'browser msg) "browser"))
      (helm-taskswitch-browser--put ws :started-at (alist-get 'startedAt msg))
      ;; The extension resets its retry delay only on this, so a refused
      ;; extension does not reconnect in a tight loop.
      ;; The proof tells the extension it is talking to this Emacs.
      (helm-taskswitch-browser--send-json
       ws `((type . "welcome") (protocol . ,helm-taskswitch-browser-protocol)
            (proof . ,(helm-taskswitch-browser--proof
                       "server" server-nonce client-nonce))))
      (let ((version (alist-get 'extensionVersion msg)))
        (if (and helm-taskswitch-browser--bundled-version
                 (not (equal version helm-taskswitch-browser--bundled-version)))
            (message "helm-taskswitch-browser: %s connected with extension %s, but this package has %s; run M-x helm-taskswitch-browser-install and reload the extension"
                     (alist-get 'browser msg) version
                     helm-taskswitch-browser--bundled-version)
          (message "helm-taskswitch-browser: %s connected"
                   (alist-get 'browser msg))))))))

(defun helm-taskswitch-browser--on-message (ws frame)
  "Handle a message FRAME from WS."
  (let* ((state (helm-taskswitch-browser--state ws))
         (msg (ignore-errors
                (json-parse-string (websocket-frame-text frame)
                                   :object-type 'alist :array-type 'list
                                   :null-object nil :false-object nil)))
         (type (alist-get 'type msg)))
    (cond
     ;; The origin check closes bad connections, but frames that arrived
     ;; with the handshake can still get here; ignore them.  Closed
     ;; connections have no state, and must not get it back.
     ((not (plist-get state :origin-ok)))
     ((progn (helm-taskswitch-browser--put ws :last-seen (current-time))
             nil))
     ((not (plist-get state :authed))
      (if (equal type "hello")
          (helm-taskswitch-browser--handle-hello ws msg)
        (helm-taskswitch-browser--refuse ws "expected hello")))
     ((equal type "tabs")
      (helm-taskswitch-browser--put ws :tabs (alist-get 'tabs msg))
      (helm-taskswitch-browser--put ws :tabs-updated (current-time)))
     ((equal type "ping"))
     ((equal type "reply")
      (let* ((id (alist-get 'id msg))
             (entry (gethash id helm-taskswitch-browser--callbacks))
             ;; Only the browser the command went to may answer it.
             (callback (and (eq (car entry) ws) (cdr entry))))
        (when callback
          (remhash id helm-taskswitch-browser--callbacks))
        (cond (callback (funcall callback msg))
              ((not (alist-get 'ok msg))
               (message "helm-taskswitch-browser: %s"
                        (alist-get 'error msg))))))
     (t (helm-taskswitch-browser--log "unknown message %S" msg)))))

(defun helm-taskswitch-browser-start ()
  "Start the WebSocket server on 127.0.0.1."
  (interactive)
  ;; Emacs 28 and 29 have the native JSON functions only when built with
  ;; libjansson.  Without them every message would fail to parse.
  (unless (json-available-p)
    (user-error "This Emacs has no native JSON support (built without libjansson), which helm-taskswitch-browser needs"))
  (unless helm-taskswitch-browser--server
    (setq helm-taskswitch-browser--server
          (condition-case err
              (websocket-server
               helm-taskswitch-browser-port
               :host 'local
               :on-open #'helm-taskswitch-browser--on-open
               :on-message #'helm-taskswitch-browser--on-message
               :on-close #'helm-taskswitch-browser--on-close
               :on-error #'helm-taskswitch-browser--on-error)
            (file-error
             (user-error "Cannot listen on 127.0.0.1:%d (another Emacs?): %s"
                         helm-taskswitch-browser-port
                         (error-message-string err)))))
    (helm-taskswitch-browser--log "listening on 127.0.0.1:%d"
                                  helm-taskswitch-browser-port)))

(defun helm-taskswitch-browser-stop ()
  "Stop the server and close all browser connections."
  (interactive)
  (when helm-taskswitch-browser--server
    (websocket-server-close helm-taskswitch-browser--server)
    (setq helm-taskswitch-browser--server nil))
  (clrhash helm-taskswitch-browser--clients)
  (clrhash helm-taskswitch-browser--callbacks))

(defvar helm-taskswitch-browser--start-error nil
  "Why the server last failed to start, or nil.")

(defun helm-taskswitch-browser-ensure-started ()
  "Start the server if browser tabs are set up and it is not running.
Tabs are set up once `helm-taskswitch-browser-install' has made the
token file; until then nothing is started.  `helm-taskswitch' calls
this, so it must not signal: if the server cannot start (for example
another Emacs has the port), say why once and carry on without tabs."
  (when (and (not helm-taskswitch-browser--server)
             (file-exists-p helm-taskswitch-browser-token-file))
    (condition-case err
        (progn
          (helm-taskswitch-browser-start)
          (setq helm-taskswitch-browser--start-error nil))
      (error
       (let ((reason (error-message-string err)))
         (unless (equal reason helm-taskswitch-browser--start-error)
           (message "helm-taskswitch-browser: no browser tabs: %s" reason))
         (setq helm-taskswitch-browser--start-error reason))))))

;;;###autoload
(defun helm-taskswitch-browser-mode (&optional arg)
  "Start the server, or stop it when ARG is zero or negative.
This used to be a minor mode.  The server now starts by itself the
first time `helm-taskswitch' runs, so calls to this in init files
are no longer needed; it is kept so that they keep working."
  (interactive)
  (if (and (numberp arg) (<= arg 0))
      (helm-taskswitch-browser-stop)
    (helm-taskswitch-browser-ensure-started)))
(make-obsolete 'helm-taskswitch-browser-mode
               "the server starts when `helm-taskswitch' first runs."
               "2.2.0")

;;;; Using the tabs and sending commands

(defun helm-taskswitch-browser-clients ()
  "Return the authenticated connections, most recently heard from first."
  (let (clients)
    (maphash (lambda (ws state)
               (when (and (plist-get state :authed) (websocket-openp ws))
                 (push ws clients)))
             helm-taskswitch-browser--clients)
    (sort clients
          (lambda (a b)
            (time-less-p (plist-get (helm-taskswitch-browser--state b)
                                    :last-seen)
                         (plist-get (helm-taskswitch-browser--state a)
                                    :last-seen))))))

(defun helm-taskswitch-browser-tabs ()
  "Return all tabs from all connected browsers, most recently used first.
Each tab is an alist with the fields the extension sends (id, windowId,
index, title, url, active, pinned, audible, muted, lastAccessed) plus
`browser' and `connection'."
  (let (tabs)
    (dolist (ws (helm-taskswitch-browser-clients))
      (let ((browser (plist-get (helm-taskswitch-browser--state ws) :browser)))
        (dolist (tab (plist-get (helm-taskswitch-browser--state ws) :tabs))
          (push (append `((browser . ,browser) (connection . ,ws)) tab)
                tabs))))
    (sort tabs (lambda (a b)
                 (> (or (alist-get 'lastAccessed a) 0)
                    (or (alist-get 'lastAccessed b) 0))))))

(defun helm-taskswitch-browser-send (ws cmd &optional args callback)
  "Send command CMD with ARGS (an alist) to WS.
CALLBACK, if given, is called with the reply alist.  Without one, an
error reply is shown with `message'.  Return the command id."
  (unless (websocket-openp ws)
    (user-error "The browser is not connected"))
  (let ((id (setq helm-taskswitch-browser--next-id
                  (1+ helm-taskswitch-browser--next-id))))
    (when callback
      (puthash id (cons ws callback) helm-taskswitch-browser--callbacks))
    (helm-taskswitch-browser--send-json
     ws `((type . "cmd") (id . ,id) (cmd . ,cmd) ,@args))
    id))

(defun helm-taskswitch-browser-tab-command (tab cmd &optional args callback)
  "Send CMD about TAB to the browser it came from.
TAB is an alist from `helm-taskswitch-browser-tabs'.  ARGS and
CALLBACK are as for `helm-taskswitch-browser-send'; tabId is added."
  (helm-taskswitch-browser-send
   (alist-get 'connection tab) cmd
   (cons `(tabId . ,(alist-get 'id tab)) args)
   callback))

(defun helm-taskswitch-browser-activate (tab &optional callback)
  "Switch to TAB and focus its window.
CALLBACK, if given, is called with the reply once the browser has
switched, as for `helm-taskswitch-browser-send'."
  (helm-taskswitch-browser-tab-command tab "activate" nil callback))

(defun helm-taskswitch-browser-close (tabs)
  "Close TABS, grouped by the browser each came from."
  (let ((by-conn (seq-group-by (lambda (tab) (alist-get 'connection tab))
                               tabs)))
    (dolist (group by-conn)
      (helm-taskswitch-browser-send
       (car group) "close"
       `((tabIds . ,(vconcat (mapcar (lambda (tab) (alist-get 'id tab))
                                     (cdr group)))))))))

(defun helm-taskswitch-browser-reload (tab)
  "Reload TAB."
  (helm-taskswitch-browser-tab-command tab "reload"))

(defun helm-taskswitch-browser-duplicate (tab)
  "Duplicate TAB."
  (helm-taskswitch-browser-tab-command tab "duplicate"))

(defun helm-taskswitch-browser-toggle-muted (tab)
  "Mute TAB, or unmute it if it is muted."
  (helm-taskswitch-browser-tab-command
   tab "setMuted" `((muted . ,(if (alist-get 'muted tab) :false t)))))

(defun helm-taskswitch-browser-refresh ()
  "Ask every connected browser to send its tab list again."
  (interactive)
  (dolist (ws (helm-taskswitch-browser-clients))
    (helm-taskswitch-browser-send ws "refresh")))

;;;###autoload
(defun helm-taskswitch-browser-open-url (url)
  "Open URL in a new tab of the most recently heard from browser."
  (interactive
   (list (read-string "Open URL in browser: " (thing-at-point 'url t))))
  (helm-taskswitch-browser-ensure-started)
  (let ((ws (car (helm-taskswitch-browser-clients))))
    (unless ws
      (user-error "No browser is connected"))
    (helm-taskswitch-browser-send ws "open" `((url . ,url)))))

;;;; Install and status

(defun helm-taskswitch-browser--copy-extension (from to)
  "Copy the extension's files FROM the package directory TO.
config.js is never copied, so the one in TO is kept."
  (with-file-modes #o700
    (make-directory to t))
  (dolist (file (directory-files from t directory-files-no-dot-files-regexp))
    (let ((dest (expand-file-name (file-name-nondirectory file) to)))
      (cond ((equal (file-name-nondirectory file) "config.js"))
            ((file-directory-p file)
             (copy-directory file dest nil t t))
            (t (copy-file file dest t t))))))

;;;###autoload
(defun helm-taskswitch-browser-install ()
  "Install the extension's files and config.js, and show how to load it.
Copies the extension from the package to
`helm-taskswitch-browser-extension-dir', and writes config.js there
with the port and token.  Run it again after upgrading this package,
then reload the extension in Chrome."
  (interactive)
  (let* ((from helm-taskswitch-browser--source-dir)
         (to helm-taskswitch-browser-extension-dir)
         (in-place (and (file-directory-p to) (file-equal-p from to)))
         (config (expand-file-name "config.js" to)))
    (unless (file-exists-p (expand-file-name "manifest.json" from))
      (user-error "The extension's files are missing from %s" from))
    (unless in-place
      (helm-taskswitch-browser--copy-extension from to))
    (with-file-modes #o600
      (write-region
       (format "// Written by M-x helm-taskswitch-browser-install.  Do not commit.
self.HELM_TASKSWITCH_CONFIG = {port: %d, token: %S};
"
               helm-taskswitch-browser-port
               (helm-taskswitch-browser--token))
       nil config nil 'silent))
    ;; Listen now, so the extension connects as soon as it is loaded.
    (helm-taskswitch-browser-ensure-started)
    (with-help-window "*helm-taskswitch-browser install*"
      (princ (if in-place
                 (format "Wrote %s\n\n" config)
               (format "Installed extension %s in %s\n\n"
                       helm-taskswitch-browser--bundled-version to)))
      (princ "To load the extension in Chrome:\n")
      (princ "  1. Open chrome://extensions and turn on Developer mode.\n")
      (princ (format "  2. Click \"Load unpacked\" and choose %s\n" to))
      (princ "     If it is already loaded, click its reload button instead.\n")
      (princ (format "  3. Check its ID is %s\n"
                     (string-remove-prefix
                      "chrome-extension://"
                      (car helm-taskswitch-browser-allowed-origins))))
      (princ "  4. M-x helm-taskswitch-browser-status should show the browser\n")
      (princ "     within about 30 seconds.\n\n")
      (princ (if helm-taskswitch-browser--server
                 "Emacs is listening for the extension now.  In later sessions it
starts listening the first time you run M-x helm-taskswitch.\n"
               (format "Emacs could not start listening: %s\n"
                       helm-taskswitch-browser--start-error))))))

(defun helm-taskswitch-browser--ago (time)
  "Describe how long ago TIME was."
  (if time
      (format "%ds ago" (round (float-time (time-subtract nil time))))
    "never"))

;;;###autoload
(defun helm-taskswitch-browser-status ()
  "Show the server and the connected browsers."
  (interactive)
  (with-help-window "*helm-taskswitch-browser status*"
    (princ (cond (helm-taskswitch-browser--server
                  (format "Listening on 127.0.0.1:%d\n\n"
                          helm-taskswitch-browser-port))
                 (helm-taskswitch-browser--start-error
                  (format "Not running: %s\n\n"
                          helm-taskswitch-browser--start-error))
                 ((not (file-exists-p helm-taskswitch-browser-token-file))
                  "Not running; run M-x helm-taskswitch-browser-install first.\n\n")
                 (t
                  "Not running yet; it starts the first time you run M-x helm-taskswitch.\n\n")))
    (if (zerop (hash-table-count helm-taskswitch-browser--clients))
        (princ "No connections.\n")
      (maphash
       (lambda (ws state)
         (princ (format "%s (extension %s)  %s\n  origin: %s\n  connected: %s, last message: %s\n  tabs: %d, list updated %s\n\n"
                        (or (plist-get state :browser) "?")
                        (or (plist-get state :version) "?")
                        (if (plist-get state :authed) "authenticated"
                          "NOT authenticated")
                        (websocket-origin ws)
                        (helm-taskswitch-browser--ago (plist-get state :opened))
                        (helm-taskswitch-browser--ago
                         (plist-get state :last-seen))
                        (length (plist-get state :tabs))
                        (helm-taskswitch-browser--ago
                         (plist-get state :tabs-updated)))))
       helm-taskswitch-browser--clients))))

(provide 'helm-taskswitch-browser)
;;; helm-taskswitch-browser.el ends here
