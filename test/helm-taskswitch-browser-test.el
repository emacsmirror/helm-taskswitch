;;; helm-taskswitch-browser-test.el --- Tests for helm-taskswitch-browser  -*- lexical-binding: t -*-

;; Run from the repository root:
;;   emacs --batch -L . -L <websocket dir> -l test/helm-taskswitch-browser-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; Each test runs the real server and a fake extension (websocket.el's
;; client) in this Emacs, on a port other than the real one so a running
;; browser cannot connect.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'helm-taskswitch-browser)

(defconst htb-test-port 62899)
(defconst htb-test-origin
  (car helm-taskswitch-browser-allowed-origins))

(defun htb-test-wait (pred &optional timeout)
  "Process network input until PRED is non-nil or TIMEOUT seconds pass."
  (let ((end (+ (float-time) (or timeout 2))))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defmacro htb-test-with-server (&rest body)
  "Run BODY with a fresh server, token file and client table."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "htb-test" t))
          (helm-taskswitch-browser-port htb-test-port)
          (helm-taskswitch-browser-token-file (expand-file-name "token" dir))
          (helm-taskswitch-browser--server nil)
          (helm-taskswitch-browser--clients (make-hash-table :test #'eq))
          (helm-taskswitch-browser--callbacks (make-hash-table :test #'eql)))
     (unwind-protect
         (progn (helm-taskswitch-browser-start) ,@body)
       (helm-taskswitch-browser-stop)
       (delete-directory dir t))))

(cl-defstruct htb-client ws (messages nil) (closed nil))

(defun htb-test-connect (&optional origin)
  "Connect a fake extension with ORIGIN; return an `htb-client'."
  (let* ((client (make-htb-client))
         (opened nil)
         (ws (websocket-open
              (format "ws://127.0.0.1:%d" htb-test-port)
              :custom-header-alist `(("Origin" . ,(or origin htb-test-origin)))
              :on-open (lambda (_ws) (setq opened t))
              :on-message
              (lambda (_ws frame)
                (setf (htb-client-messages client)
                      (append (htb-client-messages client)
                              (list (json-parse-string
                                     (websocket-frame-text frame)
                                     :object-type 'alist :array-type 'list
                                     :false-object nil)))))
              :on-close (lambda (_ws) (setf (htb-client-closed client) t)))))
    (setf (htb-client-ws client) ws)
    (htb-test-wait (lambda () opened))
    client))

(defun htb-test-send (client object)
  (websocket-send-text (htb-client-ws client) (json-serialize object)))

(defun htb-test-hello (client &optional token protocol)
  (htb-test-send client
                 `((type . "hello") (browser . "test")
                   (protocol . ,(or protocol 1))
                   (token . ,(or token (helm-taskswitch-browser--token)))
                   (startedAt . 1))))

(defun htb-test-authed-client ()
  "Connect, say hello, send two tabs, and wait until the server has them."
  (let ((client (htb-test-connect)))
    (htb-test-hello client)
    (should (htb-test-wait
             (lambda () (equal (alist-get 'type (car (htb-client-messages client)))
                               "welcome"))))
    (htb-test-send client
                   '((type . "tabs")
                     (tabs . [((id . 1) (windowId . 10) (title . "Older")
                               (url . "https://a.example/") (muted . :false)
                               (lastAccessed . 100))
                              ((id . 2) (windowId . 10) (title . "Newer")
                               (url . "https://b.example/") (muted . t)
                               (lastAccessed . 200))])))
    (should (htb-test-wait
             (lambda () (= 2 (length (helm-taskswitch-browser-tabs))))))
    client))

(defun htb-test-last-message (client)
  (car (last (htb-client-messages client))))

(defun htb-test-server-client-count ()
  (hash-table-count helm-taskswitch-browser--clients))

;;;; Refusing connections

(ert-deftest htb-wrong-origin-is-closed ()
  (htb-test-with-server
    (let ((client (htb-test-connect "https://evil.example")))
      (should (htb-test-wait (lambda () (htb-client-closed client))))
      ;; It is not told why, and the server keeps nothing about it.
      (should (null (htb-client-messages client)))
      (should (zerop (htb-test-server-client-count))))))

(ert-deftest htb-wrong-token-is-closed ()
  (htb-test-with-server
    (let ((client (htb-test-connect)))
      (htb-test-hello client "not-the-token")
      (should (htb-test-wait (lambda () (htb-client-closed client))))
      (should (equal (alist-get 'type (htb-test-last-message client)) "error"))
      (should (null (helm-taskswitch-browser-clients))))))

(ert-deftest htb-wrong-protocol-is-closed ()
  (htb-test-with-server
    (let ((client (htb-test-connect)))
      (htb-test-hello client nil 99)
      (should (htb-test-wait (lambda () (htb-client-closed client))))
      (should (string-match-p "protocol"
                              (alist-get 'message
                                         (htb-test-last-message client)))))))

(ert-deftest htb-message-before-hello-is-closed ()
  (htb-test-with-server
    (let ((client (htb-test-connect)))
      (htb-test-send client '((type . "tabs") (tabs . [])))
      (should (htb-test-wait (lambda () (htb-client-closed client))))
      (should (null (helm-taskswitch-browser-tabs))))))

(ert-deftest htb-no-hello-times-out ()
  (htb-test-with-server
    (let* ((helm-taskswitch-browser--hello-timeout 0.3)
           (client (htb-test-connect)))
      (should (htb-test-wait (lambda () (htb-client-closed client)) 2))
      (should (zerop (htb-test-server-client-count))))))

(ert-deftest htb-token-file-is-private ()
  (htb-test-with-server
    (let ((token (helm-taskswitch-browser--token)))
      (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" token))
      (should (= (file-modes helm-taskswitch-browser-token-file) #o600))
      ;; The same token is read back, not made again.
      (should (equal token (helm-taskswitch-browser--token))))))

;;;; Tabs and commands

(ert-deftest htb-tabs-are-stored-most-recent-first ()
  (htb-test-with-server
    (htb-test-authed-client)
    (let ((tabs (helm-taskswitch-browser-tabs)))
      (should (equal (mapcar (lambda (tab) (alist-get 'title tab)) tabs)
                     '("Newer" "Older")))
      (should (equal (alist-get 'browser (car tabs)) "test")))))

(ert-deftest htb-commands-are-sent ()
  (htb-test-with-server
    (let* ((client (htb-test-authed-client))
           (tabs (helm-taskswitch-browser-tabs))
           (newer (car tabs)))
      (helm-taskswitch-browser-activate newer)
      (should (htb-test-wait
               (lambda () (equal (alist-get 'type (htb-test-last-message client))
                                 "cmd"))))
      (let ((msg (htb-test-last-message client)))
        (should (equal (alist-get 'type msg) "cmd"))
        (should (equal (alist-get 'cmd msg) "activate"))
        (should (equal (alist-get 'tabId msg) 2))
        (should (integerp (alist-get 'id msg))))

      (helm-taskswitch-browser-close tabs)
      (should (htb-test-wait
               (lambda () (equal (alist-get 'cmd (htb-test-last-message client))
                                 "close"))))
      (should (equal (sort (alist-get 'tabIds (htb-test-last-message client)) #'<)
                     '(1 2)))

      ;; "Newer" is muted, so toggling unmutes it.
      (helm-taskswitch-browser-toggle-muted newer)
      (should (htb-test-wait
               (lambda () (equal (alist-get 'cmd (htb-test-last-message client))
                                 "setMuted"))))
      (should (eq (alist-get 'muted (htb-test-last-message client)) nil))

      (helm-taskswitch-browser-open-url "https://c.example/")
      (should (htb-test-wait
               (lambda () (equal (alist-get 'url (htb-test-last-message client))
                                 "https://c.example/")))))))

(ert-deftest htb-reply-reaches-callback ()
  (htb-test-with-server
    (let* ((client (htb-test-authed-client))
           (reply nil)
           (id (helm-taskswitch-browser-send
                (car (helm-taskswitch-browser-clients)) "refresh" nil
                (lambda (msg) (setq reply msg)))))
      (htb-test-send client `((type . "reply") (id . ,id) (ok . t)))
      (should (htb-test-wait (lambda () reply)))
      (should (eq (alist-get 'ok reply) t))
      ;; Each callback is used once.
      (should (null (gethash id helm-taskswitch-browser--callbacks))))))

(ert-deftest htb-disconnect-forgets-tabs ()
  (htb-test-with-server
    (let ((client (htb-test-authed-client)))
      (websocket-close (htb-client-ws client))
      (should (htb-test-wait (lambda () (zerop (htb-test-server-client-count)))))
      (should (null (helm-taskswitch-browser-tabs))))))

;;;; Installing the extension

(defmacro htb-test-with-install-dirs (&rest body)
  "Run BODY with a fake shipped extension in `from' and an empty `to'."
  (declare (indent 0))
  `(let* ((root (make-temp-file "htb-install" t))
          (from (expand-file-name "pkg/browser-extension/" root))
          (to (expand-file-name "share/browser-extension/" root))
          (helm-taskswitch-browser--source-dir from)
          (helm-taskswitch-browser-extension-dir to)
          (helm-taskswitch-browser-token-file (expand-file-name "token" root)))
     (make-directory from t)
     (write-region "{\"version\": \"0.2\"}" nil (expand-file-name "manifest.json" from))
     (write-region "// background" nil (expand-file-name "background.js" from))
     ;; A developer's own config.js in the checkout must never be copied.
     (write-region "SOURCE-SECRET" nil (expand-file-name "config.js" from))
     (unwind-protect
         (cl-letf (((symbol-function 'with-help-window-internal) #'ignore))
           (save-window-excursion ,@body))
       (delete-directory root t))))

(defun htb-test-read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest htb-install-copies-extension-and-writes-config ()
  (htb-test-with-install-dirs
    (helm-taskswitch-browser-install)
    (should (file-exists-p (expand-file-name "manifest.json" to)))
    (should (file-exists-p (expand-file-name "background.js" to)))
    (let ((config (expand-file-name "config.js" to)))
      (should (string-match-p (regexp-quote (helm-taskswitch-browser--token))
                              (htb-test-read config)))
      (should-not (string-match-p "SOURCE-SECRET" (htb-test-read config)))
      (should (= (file-modes config) #o600)))))

(ert-deftest htb-install-again-updates-files-keeps-token ()
  (htb-test-with-install-dirs
    (helm-taskswitch-browser-install)
    (let ((token (helm-taskswitch-browser--token)))
      ;; A package upgrade ships a new background.js.
      (write-region "// background v2" nil (expand-file-name "background.js" from))
      (helm-taskswitch-browser-install)
      (should (equal (htb-test-read (expand-file-name "background.js" to))
                     "// background v2"))
      (should (string-match-p (regexp-quote token)
                              (htb-test-read (expand-file-name "config.js" to)))))))

(ert-deftest htb-install-in-place-only-writes-config ()
  (htb-test-with-install-dirs
    (let ((helm-taskswitch-browser-extension-dir from))
      (helm-taskswitch-browser-install)
      (should (string-match-p (regexp-quote (helm-taskswitch-browser--token))
                              (htb-test-read (expand-file-name "config.js" from))))
      (should-not (file-exists-p to)))))

(ert-deftest htb-old-extension-version-is-reported ()
  (htb-test-with-server
    (let ((helm-taskswitch-browser--bundled-version "0.3")
          (messages nil)
          (client (htb-test-connect)))
      (cl-letf* ((real-message (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (push (apply #'format fmt args) messages)
                    (apply real-message fmt args))))
        (htb-test-send client
                       `((type . "hello") (browser . "test") (protocol . 1)
                         (token . ,(helm-taskswitch-browser--token))
                         (extensionVersion . "0.2")))
        (should (htb-test-wait (lambda () (helm-taskswitch-browser-clients)))))
      ;; Still accepted, but told to update.
      (should (seq-some (lambda (m) (string-match-p "extension 0.2.*has 0.3.*install" m))
                        messages)))))

(ert-deftest htb-mode-warns-instead-of-signaling-when-port-is-taken ()
  ;; The test server holds the port, so a second server cannot listen.
  (htb-test-with-server
    (let ((first-server helm-taskswitch-browser--server)
          (helm-taskswitch-browser-mode nil)
          (warnings nil))
      (let ((helm-taskswitch-browser--server nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (type msg &rest _) (push (list type msg) warnings))))
          (unwind-protect
              (progn
                ;; Must not signal, so the rest of an init file still loads.
                (helm-taskswitch-browser-mode 1)
                (should-not helm-taskswitch-browser-mode)
                (should-not helm-taskswitch-browser--server))
            (when helm-taskswitch-browser--server
              (websocket-server-close helm-taskswitch-browser--server)))))
      (should (equal (caar warnings) 'helm-taskswitch-browser))
      (should (string-match-p "Cannot listen" (cadar warnings)))
      ;; The server that holds the port is untouched.
      (should (eq helm-taskswitch-browser--server first-server)))))

;;; helm-taskswitch-browser-test.el ends here
