;;; helm-taskswitch-browser.el --- Browser tabs for helm-taskswitch over a WebSocket  -*- lexical-binding: t -*-

;; Author: Brian Caruso <briancaruso@gmail.com>
;; URL: https://github.com/bdc34/helm-taskswitch
;; Package-Requires: ((emacs "28.1") (websocket "1.15"))

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
;;   1. M-x helm-taskswitch-browser-install, which writes the extension's
;;      config.js with the port and a secret token.
;;   2. In chrome://extensions, turn on Developer mode, then "Load
;;      unpacked" and choose the browser-extension/ directory.
;;   3. Turn on `helm-taskswitch-browser-mode' (in your init file, so it
;;      is on whenever Emacs runs).
;;   4. M-x helm-taskswitch-browser-status shows connected browsers.
;;
;; Security: the server only listens on 127.0.0.1.  A connection must
;; come from an allowed extension origin (web pages cannot fake the
;; Origin header), and must then send the token, which only your user
;; can read.  Emacs never runs anything the browser sends.

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

(defcustom helm-taskswitch-browser-extension-dir
  (expand-file-name "browser-extension"
                    (file-name-directory (or load-file-name buffer-file-name
                                             default-directory)))
  "Directory of the browser extension, where config.js is written."
  :type 'directory
  :group 'helm-taskswitch-browser)

(defcustom helm-taskswitch-browser-log nil
  "When non-nil, log connections and messages with `message'."
  :type 'boolean
  :group 'helm-taskswitch-browser)

(defconst helm-taskswitch-browser-protocol 1
  "Version of the message format; the extension sends it in hello.")

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
  "Command id -> function called with the reply.")

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
  "Tell WS why it is refused, then close it."
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
  (let ((origin (websocket-origin ws)))
    (puthash ws (list :origin-ok nil :authed nil :opened (current-time))
             helm-taskswitch-browser--clients)
    (if (not (member origin helm-taskswitch-browser-allowed-origins))
        (helm-taskswitch-browser--refuse ws (format "origin %S not allowed"
                                                    origin))
      (helm-taskswitch-browser--put ws :origin-ok t)
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
  (remhash ws helm-taskswitch-browser--clients))

(defun helm-taskswitch-browser--on-error (_ws type err)
  "Log errors of TYPE with ERR instead of signaling them."
  (message "helm-taskswitch-browser: %s error: %S" type err))

(defun helm-taskswitch-browser--handle-hello (ws msg)
  "Check the hello MSG from WS and mark it authenticated."
  (let ((token (alist-get 'token msg))
        (protocol (alist-get 'protocol msg)))
    ;; Kept even when refused, so status can show what is connecting.
    (helm-taskswitch-browser--put ws :version (alist-get 'extensionVersion msg))
    (cond
     ((not (and (stringp token)
                (string= token (helm-taskswitch-browser--token))))
      (helm-taskswitch-browser--refuse ws "wrong token; run M-x helm-taskswitch-browser-install and reload the extension"))
     ((not (eql protocol helm-taskswitch-browser-protocol))
      (helm-taskswitch-browser--refuse
       ws (format "protocol %S, Emacs speaks %d" protocol
                  helm-taskswitch-browser-protocol)))
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
      (helm-taskswitch-browser--send-json
       ws `((type . "welcome") (protocol . ,helm-taskswitch-browser-protocol)))
      (message "helm-taskswitch-browser: %s connected"
               (alist-get 'browser msg))))))

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
             (callback (gethash id helm-taskswitch-browser--callbacks)))
        (remhash id helm-taskswitch-browser--callbacks)
        (cond (callback (funcall callback msg))
              ((not (alist-get 'ok msg))
               (message "helm-taskswitch-browser: %s"
                        (alist-get 'error msg))))))
     (t (helm-taskswitch-browser--log "unknown message %S" msg)))))

(defun helm-taskswitch-browser-start ()
  "Start the WebSocket server on 127.0.0.1."
  (interactive)
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
             (user-error "helm-taskswitch-browser: cannot listen on 127.0.0.1:%d (another Emacs?): %s"
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

;;;###autoload
(define-minor-mode helm-taskswitch-browser-mode
  "Accept tab lists from the helm-taskswitch browser extension.
Runs a WebSocket server on 127.0.0.1, port
`helm-taskswitch-browser-port'."
  :global t
  :group 'helm-taskswitch-browser
  (if helm-taskswitch-browser-mode
      (condition-case err
          (helm-taskswitch-browser-start)
        (error
         (setq helm-taskswitch-browser-mode nil)
         (signal (car err) (cdr err))))
    (helm-taskswitch-browser-stop)))

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
    (user-error "helm-taskswitch-browser: browser is not connected"))
  (let ((id (setq helm-taskswitch-browser--next-id
                  (1+ helm-taskswitch-browser--next-id))))
    (when callback
      (puthash id callback helm-taskswitch-browser--callbacks))
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

(defun helm-taskswitch-browser-activate (tab)
  "Switch to TAB and focus its window."
  (helm-taskswitch-browser-tab-command tab "activate"))

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
  (let ((ws (car (helm-taskswitch-browser-clients))))
    (unless ws
      (user-error "helm-taskswitch-browser: no browser is connected"))
    (helm-taskswitch-browser-send ws "open" `((url . ,url)))))

;;;; Install and status

;;;###autoload
(defun helm-taskswitch-browser-install ()
  "Write the extension's config.js and show how to load the extension."
  (interactive)
  (let ((config (expand-file-name "config.js"
                                  helm-taskswitch-browser-extension-dir)))
    (unless (file-directory-p helm-taskswitch-browser-extension-dir)
      (user-error "No extension directory %s"
                  helm-taskswitch-browser-extension-dir))
    (with-file-modes #o600
      (write-region
       (format "// Written by M-x helm-taskswitch-browser-install.  Do not commit.
self.HELM_TASKSWITCH_CONFIG = {port: %d, token: %S};
"
               helm-taskswitch-browser-port
               (helm-taskswitch-browser--token))
       nil config nil 'silent))
    (with-help-window "*helm-taskswitch-browser install*"
      (princ (format "Wrote %s\n\n" config))
      (princ "To load the extension in Chrome:\n")
      (princ "  1. Open chrome://extensions and turn on Developer mode.\n")
      (princ (format "  2. Click \"Load unpacked\" and choose %s\n"
                     helm-taskswitch-browser-extension-dir))
      (princ "     If it is already loaded, click its reload button instead.\n")
      (princ (format "  3. Check its ID is %s\n"
                     (string-remove-prefix
                      "chrome-extension://"
                      (car helm-taskswitch-browser-allowed-origins))))
      (princ "  4. Turn on helm-taskswitch-browser-mode, e.g. in your init file:\n")
      (princ "       (helm-taskswitch-browser-mode 1)\n")
      (princ "  5. M-x helm-taskswitch-browser-status should show the browser\n")
      (princ "     within about 30 seconds.\n"))))

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
    (princ (if helm-taskswitch-browser--server
               (format "Listening on 127.0.0.1:%d\n\n"
                       helm-taskswitch-browser-port)
             "Not running; turn on helm-taskswitch-browser-mode.\n\n"))
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
