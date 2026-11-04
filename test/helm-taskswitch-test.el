;;; helm-taskswitch-test.el --- Tests for helm-taskswitch  -*- lexical-binding: t -*-

;; Run from the repository root, with helm and websocket installed:
;;   emacs --batch --eval '(package-initialize)' -L . \
;;         -l test/helm-taskswitch-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'helm-taskswitch)

(defun hts-test-window (id title)
  "Return a KWin window alist with ID and TITLE."
  `((window-id . ,id) (title . ,title) (wmclass . "google-chrome")))

(defun hts-test-ids (windows)
  "Return the ids of WINDOWS."
  (mapcar (lambda (w) (cdr (assoc 'window-id w))) windows))

(ert-deftest hts-tab-windows-need-the-whole-title ()
  ;; Other windows' titles also start with "GitHub".
  (let ((windows (list (hts-test-window "a" "GitHub - foo - Google Chrome")
                       (hts-test-window "b" "GitHub — Konsole")
                       (hts-test-window "c" "GitHub - Google Chrome"))))
    (should (equal (hts-test-ids (helm-taskswitch--tab-windows "GitHub" windows))
                   '("c")))))

(ert-deftest hts-tab-windows-finds-every-match ()
  (let ((windows (list (hts-test-window "a" "Inbox - Google Chrome")
                       (hts-test-window "b" "Inbox - Google Chrome"))))
    (should (equal (hts-test-ids (helm-taskswitch--tab-windows "Inbox" windows))
                   '("a" "b")))))

(ert-deftest hts-tab-without-title-is-shown ()
  (let ((row (helm-taskswitch--tab-display
              '((browser . "chrome") (id . 1) (title) (url . "https://a.example/")))))
    (should (string-match-p "https://a.example/" row))))

(ert-deftest hts-wmctrl-focus-only-activates ()
  (let ((helm-taskswitch-backend 'wmctrl)
        (helm-taskswitch-wmctrl-path "/usr/bin/wmctrl")
        (commands nil))
    (cl-letf (((symbol-function 'call-process-shell-command)
               (lambda (cmd &rest _) (push cmd commands) 0)))
      ;; A sticky window: its desktop is -1.
      (helm-taskswitch-focus-window-by-candidate
       '(((window-id . "0x01e00007") (desktop-number . "-1")))))
    (should (equal commands '("/usr/bin/wmctrl -i -a '0x01e00007'")))))

(defmacro hts-test-with-fake-kwin (window-lists &rest body)
  "Run BODY with KWin and the browser faked.
Each look at the windows returns the next list in WINDOW-LISTS (the
last one repeats).  In BODY, `raised' is the list of window ids KWin
was asked to activate, `looks' counts the looks at the windows,
`messages' holds the messages shown, and `reply' is what the browser
replies."
  (declare (indent 1))
  `(let ((lists ,window-lists)
         (raised nil)
         (looks 0)
         (messages nil)
         (reply '((type . "reply") (ok . t)))
         (helm-taskswitch-backend 'kwin)
         (helm-taskswitch--raise-interval 0.01))
     (ignore reply)
     (cl-letf* ((real-message (symbol-function 'message))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages)
                   (apply real-message fmt args)))
                ((symbol-function 'helm-taskswitch--kwin-list-windows)
                 (lambda ()
                   (cl-incf looks)
                   (if (cdr lists) (pop lists) (car lists))))
                ((symbol-function 'helm-taskswitch--kwin)
                 (lambda (method id &rest _)
                   (when (equal method "Run") (push id raised))))
                ((symbol-function 'helm-taskswitch-browser-activate)
                 (lambda (_tab callback)
                   ;; The browser replies later, from the process filter.
                   (run-at-time 0.01 nil callback reply))))
       ,@body)))

(defun hts-test-wait (pred &optional timeout)
  "Run timers until PRED is non-nil or TIMEOUT seconds pass."
  (let ((end (+ (float-time) (or timeout 2))))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.01))
    (funcall pred)))

(defun hts-test-message-p (regexp messages)
  "Return non-nil if one of MESSAGES matches REGEXP."
  (seq-some (lambda (m) (string-match-p regexp m)) messages))

(ert-deftest hts-activate-raises-window-after-reply ()
  ;; KWin still shows the old title on the first two looks.
  (hts-test-with-fake-kwin
      (list (list (hts-test-window "w1" "Old tab - Google Chrome"))
            (list (hts-test-window "w1" "Old tab - Google Chrome"))
            (list (hts-test-window "w1" "Docs - Google Chrome")))
    (helm-taskswitch--browser-tab-activate '((id . 7) (title . "Docs")))
    ;; Nothing happens before the reply arrives.
    (should-not raised)
    (should (hts-test-wait (lambda () raised)))
    (should (equal raised '("w1")))
    (should-not messages)))

(ert-deftest hts-activate-gives-up-with-a-message-when-no-window-matches ()
  (hts-test-with-fake-kwin
      (list (list (hts-test-window "w1" "Something else - Google Chrome")))
    (let ((helm-taskswitch--raise-tries 3))
      (helm-taskswitch--browser-tab-activate '((id . 7) (title . "Docs")))
      ;; One look after the reply, then 3 more.
      (should (hts-test-wait (lambda () messages)))
      (should (= looks 4))
      (sit-for 0.1)
      (should (= looks 4))
      (should (equal (length messages) 1))
      (should (hts-test-message-p "no window matches tab \"Docs\"" messages))
      (should-not raised))))

(ert-deftest hts-activate-several-matches-message-at-once ()
  (hts-test-with-fake-kwin
      (list (list (hts-test-window "a" "Inbox - Google Chrome")
                  (hts-test-window "b" "Inbox - Google Chrome")))
    (helm-taskswitch--browser-tab-activate '((id . 7) (title . "Inbox")))
    (should (hts-test-wait (lambda () messages)))
    ;; Looking again would not help, so it does not.
    (sit-for 0.1)
    (should (= looks 1))
    (should (hts-test-message-p "2 windows match tab \"Inbox\"" messages))
    (should-not raised)))

(ert-deftest hts-activate-untitled-tab-messages-without-looking ()
  (hts-test-with-fake-kwin
      (list (list (hts-test-window "a" " - Google Chrome")))
    (helm-taskswitch--browser-tab-activate '((id . 7) (title . "")))
    (should (hts-test-wait (lambda () messages)))
    (should (= looks 0))
    (should (hts-test-message-p "tab has no title" messages))
    (should-not raised)))

(ert-deftest hts-activate-error-reply-raises-nothing ()
  (hts-test-with-fake-kwin
      (list (list (hts-test-window "w1" "Docs - Google Chrome")))
    ;; As parsed by the server, which reads JSON false as nil.
    (setq reply '((type . "reply") (ok . nil) (error . "No tab with id: 7")))
    (helm-taskswitch--browser-tab-activate '((id . 7) (title . "Docs")))
    (should (hts-test-wait
             (lambda () (member "helm-taskswitch: No tab with id: 7" messages))))
    (should (= looks 0))
    (should-not raised)))

;;; helm-taskswitch-test.el ends here
