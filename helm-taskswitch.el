;;; helm-taskswitch.el --- Use helm to switch windows, browser tabs and buffers  -*- lexical-binding: t -*-

;; Copyright (C) 2016-2026 Brian Caruso

;; Author: Brian Caruso <briancaruso@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; Maintainer: Brian Caruso <briancaruso@gmail.com>
;; Created: 2016-05-27
;; URL: https://github.com/bdc34/helm-taskswitch
;; Package-Version: 2.1.0
;; Package-Requires: ((emacs "28.1") (helm "3.0") (websocket "1.15"))
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

;; `helm-taskswitch' switches between desktop windows (X11, or KDE
;; Plasma on Wayland), browser tabs and Emacs buffers with helm.

;; Installation:

;; Install wmctrl and helm.  On KDE Plasma under Wayland, wmctrl only
;; sees XWayland windows, so set `helm-taskswitch-backend' to `kwin'
;; (the default when XDG_SESSION_TYPE is wayland) to list windows
;; through KWin's D-Bus interface instead.

;; Browser tabs: the extension in browser-extension/ sends every tab to
;; Emacs.  Install websocket.el, run M-x helm-taskswitch-browser-install
;; and follow its steps, then turn on `helm-taskswitch-browser-mode' in
;; your init file.  Tabs then show in their own section, most recently
;; used first, with actions to switch to, close, reload, duplicate or
;; mute them, or copy their URL.

;; Usage:

;; To activate use `M-x helm-taskswitch'.

;; Issues / bugs:

;; If you discover an issue or bug in `helm-taskswitch' not already noted:

;; * as a TODO item, or

;; please create a new issue with as much detail as possible, including:

;; * which version of Emacs you're running on which operating system, and

;; * how you installed `helm-taskswitch', wmctrl and helm.

;; TODOs:

;; * handle desktops: Switch to WM desktop withEmacs, bring Emacs to fore on
;; activating, In most cases this already works.

;; * Track or get with focus history and use it to order candidates.
;; There is a start on this commented out at the bottom.  The current
;; order is arbitrary.

;; Interesting blog post about alt-tab, suggests Markov model
;; http://www.azarask.in/blog/post/solving-the-alt-tab-problem/
;; Ideas from that: other hot key for "go back to most recent window"

;; * Dedup WMCLASS
;; WMCLASS is often program.Program, transform theses to just Program

;; * Strip WMCLASS from end of title
;; Title often ends with WMCLASS or something like that.  Try to strip these off.

;; License:

;; GNU General Public License version 3
;; (http://www.gnu.org/licenses/gpl.html), or (at your option) any
;; later version.  Code from https://github.com/flexibeast/ewmctrl is
;; used under GNU 3.

;;; Code:

(require 'helm)
(require 'helm-for-files) ;; needed for helm-source-recentf
(require 'dbus)
(require 'seq)
(require 'subr-x)

;; Customisable variables.

(defgroup helm-taskswitch nil
  "Use helm to switch between tasks (windows, browser tabs or buffers)."
  :prefix "helm-taskswitch-"
  :group 'external)

(defcustom helm-taskswitch-wmctrl-path "/usr/bin/wmctrl"
  "Absolute path to wmctrl executable."
  :type '(file :must-match t)
  :group 'helm-taskswitch)

(defcustom helm-taskswitch-backend
  (if (equal (getenv "XDG_SESSION_TYPE") "wayland") 'kwin 'wmctrl)
  "How to list and focus windows.
`wmctrl' works on X11.  `kwin' uses KWin's D-Bus window runner and
works on KDE Plasma under Wayland, where wmctrl only sees XWayland
windows."
  :type '(choice (const :tag "wmctrl (X11)" wmctrl)
                 (const :tag "KWin D-Bus (KDE Wayland)" kwin))
  :group 'helm-taskswitch)

(defcustom helm-taskswitch-title-transform 'identity
  "Function that transforms the title of a window for display in helm.
It is called with the title and returns the string to show."
  :group 'helm-taskswitch
  :type 'function)

(defcustom helm-taskswitch-wmclass-width 12
  "Column width of the wmclass field when displayed."
  :group 'helm-taskswitch
  :type 'integer)

(define-obsolete-variable-alias 'helm-taskswitch-open-hooks
  'helm-taskswitch-open-hook "2.1.0")

(defcustom helm-taskswitch-open-hook nil
  "Hook run when `helm-taskswitch' starts, before helm opens."
  :group 'helm-taskswitch
  :type 'hook)

(defgroup helm-taskswitch-faces nil
  "Customize the appearance of `helm-taskswitch'."
  :prefix "helm-taskswitch-"
  :group 'helm-taskswitch
  :group 'helm-faces)

(defface helm-taskswitch-label-browser
  '((t (:inherit font-lock-constant-face)))
  "Face used for the label of web browsers."
  :group 'helm-taskswitch-faces)

(defface helm-taskswitch-label-terminal
  '((t (:inherit font-lock-string-face)))
  "Face used for the label of terminals."
  :group 'helm-taskswitch-faces)

(defface helm-taskswitch-label-emacs
  '((t (:inherit font-lock-regexp-grouping-construct)))
  "Face used for the label of Emacs."
  :group 'helm-taskswitch-faces)

(define-obsolete-face-alias 'helm-taskswitch-browser-face
  'helm-taskswitch-label-browser "2.1.0")
(define-obsolete-face-alias 'helm-taskswitch-term-face
  'helm-taskswitch-label-terminal "2.1.0")
(define-obsolete-face-alias 'helm-taskswitch-emacs-face
  'helm-taskswitch-label-emacs "2.1.0")


;; Internal Code

(defun helm-taskswitch-format-candidate (al)
  "Format a candidate client window for the task switcher.
AL is the associative list for a window."
  (let* ((ddfmt (format "%d.%d" helm-taskswitch-wmclass-width helm-taskswitch-wmclass-width))
         (wmtitlefmt (concat "%-" ddfmt "s %s"))
         (windowstr (format wmtitlefmt (helm-taskswitch-wmclass al) (helm-taskswitch-title al))))
    (cons windowstr (list al))))

(defun helm-taskswitch-title (al)
  "Format the title of a window.
AL is an associative list for a window."
  (let ((title   (cdr (assoc 'title   al))))
    (funcall helm-taskswitch-title-transform
             (replace-regexp-in-string "- Google Chrome" "" title))))

(defun helm-taskswitch-wmclass (al)
  "Return the label for the WMCLASS of window AL, an associative list."
  (let ((wmclass (cdr (assoc 'wmclass al)))
        (title (or (cdr (assoc 'title al)) "")))
    ;; The X11 names come from wmctrl; the others are the icon names
    ;; KWin reports for the `kwin' backend.
    (cond ((member wmclass '("google-chrome.Google-chrome" "google-chrome"))
           (propertize "Chrome" 'face 'helm-taskswitch-label-browser))
          ((string-equal wmclass "terminator.Terminator")
           (propertize "Terminator" 'face 'helm-taskswitch-label-terminal))
          ((string-equal wmclass "utilities-terminal")
           (propertize "Terminal" 'face 'helm-taskswitch-label-terminal))
          ((or (string-equal wmclass "emacs.Emacs")
               ;; KWin gives Emacs an empty icon name.
               (and (string-equal wmclass "")
                    (string-match-p "GNU Emacs" title)))
           (propertize "Emacs" 'face 'helm-taskswitch-label-emacs))
          (t wmclass) )))

(defconst helm-taskswitch--wmctrl-field-count 10)
(defconst helm-taskswitch--wmctrl-field-regex
  (concat "^"
          (mapconcat #'identity (make-list (1- helm-taskswitch--wmctrl-field-count) "\\(\\S-+\\)\\s-+") "")
          "\\(.+\\)"))

(defun helm-taskswitch--list-windows ()
  "Internal function to get a list of desktop windows via `wmctrl'."
  (let ((bfr (generate-new-buffer " *helm-taskswitch-wmctrl-output*"))
        (windows-list '()))
    (with-current-buffer bfr
      (call-process-shell-command (concat helm-taskswitch-wmctrl-path " -lGxp") nil t)
      (goto-char (point-min))
      (while (re-search-forward helm-taskswitch--wmctrl-field-regex nil t)
        (let ((window-id (match-string 1))
              (desktop-number (match-string 2))
              (pid (match-string 3))
              (x-offset (match-string 4))
              (y-offset (match-string 5))
              (width (match-string 6))
              (height (match-string 7))
              (wmclass (match-string 8))
              (client-host (match-string 9))
              (title (match-string 10)))
          (setq windows-list
                (append windows-list
                        (list
                         `((window-id . ,window-id)
                           (desktop-number . ,desktop-number)
                           (pid . ,pid)
                           (x-offset . ,x-offset)
                           (y-offset . ,y-offset)
                           (width . ,width)
                           (height . ,height)
                           (wmclass . ,wmclass)
                           (client-host . ,client-host)
                           (title . ,title))))))))
    (kill-buffer bfr)
    windows-list))

(defun helm-taskswitch--kwin (method &rest args)
  "Call METHOD with ARGS on KWin's D-Bus window runner."
  (apply #'dbus-call-method :session "org.kde.KWin" "/WindowsRunner"
         "org.kde.krunner1" method args))

(defun helm-taskswitch--kwin-list-windows ()
  "Internal function to get a list of desktop windows from KWin.
Uses the window runner that KRunner uses.  Each match is
\(ID TEXT ICON-NAME TYPE RELEVANCE PROPERTIES); ID looks like
\"0_{uuid}\", where 0 means the activate action."
  (let (seen windows)
    (dolist (m (helm-taskswitch--kwin "Match" ""))
      (let ((id (nth 0 m)))
        ;; An empty query returns each window twice with the same id.
        (unless (member id seen)
          (push id seen)
          (push `((window-id . ,id)
                  (title . ,(nth 1 m))
                  ;; An icon name, not a WM_CLASS.  Keep the last part
                  ;; of reverse-DNS names: com.mitchellh.ghostty -> ghostty
                  (wmclass . ,(car (last (split-string (nth 2 m) "\\.")))))
                windows))))
    (nreverse windows)))


(defun helm-taskswitch-focus-window-by-candidate (al)
  "Focus the desktop window specified by AL.
AL is a helm candidate, a list holding a window associative list."
  (let ((id (cdr (assoc 'window-id (car al)))))
    (if (eq helm-taskswitch-backend 'kwin)
        ;; KWin switches to the window's virtual desktop itself.
        (helm-taskswitch--kwin "Run" id "")
      ;; -a switches to the window's desktop itself.  A separate -s
      ;; would fail for sticky windows, whose desktop is -1.
      (call-process-shell-command
       (concat helm-taskswitch-wmctrl-path " -i -a '" id "'")))))


(defun helm-taskswitch-close-candidate (al)
  "Close the window of candidate AL.
AL is a helm candidate, a list holding a window associative list
from `helm-taskswitch--list-windows'."
    (let* ((id (cdr (assoc 'window-id (car al))))
           (cmd (concat helm-taskswitch-wmctrl-path " -i -c '" id "'")))
      (message (concat "helm-taskswitch: closing X client with " cmd))
      (call-process-shell-command cmd)))

(defun helm-taskswitch-close-candidates (_al)
  "Close all selected candidates.
The argument, the current candidate, is ignored; helm passes it."
  (when (eq helm-taskswitch-backend 'kwin)
    (user-error "Closing windows is not supported with the kwin backend yet"))
  (mapc #'helm-taskswitch-close-candidate (helm-marked-candidates)))

(defun helm-taskswitch-client-candidates ()
  "Return a list of windows with title and wmclass."
  (mapcar #'helm-taskswitch-format-candidate
          (if (eq helm-taskswitch-backend 'kwin)
              (helm-taskswitch--kwin-list-windows)
            (helm-taskswitch--list-windows))))

(defvar helm-taskswitch-source-x-windows
      (helm-build-sync-source "X Windows"
        :fuzzy-match t
        :candidates #'helm-taskswitch-client-candidates
        :action `(("Focus window" . ,#'helm-taskswitch-focus-window-by-candidate)
                  ("Close window(s)" . ,#'helm-taskswitch-close-candidates)
                  ("dump client window s-exp" . ,#'prin1)))
      "Helm source that provides X windows and actions.")


;; Browser tabs.  The extension in browser-extension/ sends every tab to
;; Emacs over a WebSocket; helm-taskswitch-browser.el keeps the lists.
;; Turn on `helm-taskswitch-browser-mode' to receive them.

(defvar helm-taskswitch--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory this file was loaded from.")

;; This file is often loaded with `load-file', so its directory may not
;; be on `load-path'; load the browser part from beside it.  Without it
;; (e.g. websocket.el is not installed) the tabs section is just empty.
(condition-case err
    (require 'helm-taskswitch-browser
             (expand-file-name "helm-taskswitch-browser" helm-taskswitch--dir))
  (error (message "helm-taskswitch: browser tabs unavailable: %s"
                  (error-message-string err))))

(declare-function helm-taskswitch-browser-tabs "helm-taskswitch-browser")
(declare-function helm-taskswitch-browser-activate "helm-taskswitch-browser"
                  (tab &optional callback))
(declare-function helm-taskswitch-browser-close "helm-taskswitch-browser")
(declare-function helm-taskswitch-browser-reload "helm-taskswitch-browser")
(declare-function helm-taskswitch-browser-duplicate "helm-taskswitch-browser")
(declare-function helm-taskswitch-browser-toggle-muted "helm-taskswitch-browser")

(defun helm-taskswitch--tab-label (tab)
  "Return the label column for TAB, the name of its browser."
  (let ((browser (alist-get 'browser tab)))
    (propertize (pcase browser
                  ("chrome" "Chrome")
                  ("firefox" "Firefox")
                  (_ (or browser "Browser")))
                'face 'helm-taskswitch-label-browser)))

(defun helm-taskswitch--tab-display (tab)
  "Return the helm display string for TAB."
  (let ((markers (concat (when (alist-get 'pinned tab) "📌")
                         (cond ((alist-get 'muted tab) "🔇")
                               ((alist-get 'audible tab) "🔊")))))
    (format (format "%%-%d.%ds %%s%%s  %%s"
                    helm-taskswitch-wmclass-width
                    helm-taskswitch-wmclass-width)
            (helm-taskswitch--tab-label tab)
            (if (string-empty-p markers) "" (concat markers " "))
            (helm-taskswitch-title tab)
            (propertize (or (alist-get 'url tab) "")
                        'face 'font-lock-comment-face))))

(defun helm-taskswitch--browser-tab-candidates ()
  "Return all browser tabs as helm candidates, most recently used first."
  (when (featurep 'helm-taskswitch-browser)
    (mapcar (lambda (tab) (cons (helm-taskswitch--tab-display tab) tab))
            (helm-taskswitch-browser-tabs))))

(defcustom helm-taskswitch-tab-window-title-suffixes
  '(" - Google Chrome" " - Chromium" " — Mozilla Firefox" " - Mozilla Firefox")
  "Endings a browser adds to its active tab's title to make the window title.
With the `kwin' backend, switching to a tab raises the window whose
title is exactly the tab's title followed by one of these."
  :type '(repeat string)
  :group 'helm-taskswitch)

(defvar helm-taskswitch--raise-tries 10
  "How many more times to look for a tab's window if it is not found.")

(defvar helm-taskswitch--raise-interval 0.1
  "Seconds between looks for a tab's window.")

(defun helm-taskswitch--tab-windows (title windows)
  "Return the windows in WINDOWS displaying the tab titled TITLE.
WINDOWS are window alists from `helm-taskswitch--kwin-list-windows'.
A window matches when its title is TITLE followed by one of
`helm-taskswitch-tab-window-title-suffixes'."
  (seq-filter
   (lambda (w)
     (let ((window-title (or (cdr (assoc 'title w)) "")))
       (seq-some (lambda (suffix)
                   (string= window-title (concat title suffix)))
                 helm-taskswitch-tab-window-title-suffixes)))
   windows))

(defun helm-taskswitch--raise-tab-window (title tries)
  "Ask KWin to activate the window displaying the tab titled TITLE.
The window title can change a little after the browser has switched
tabs, so if no window matches yet, look again up to TRIES more times,
`helm-taskswitch--raise-interval' seconds apart.  When the tab has no
title, or several windows match, raise nothing: raising the wrong
window is worse than raising none."
  (with-demoted-errors "helm-taskswitch: cannot raise the tab's window: %S"
    (if (or (null title) (string-empty-p title))
        (message "helm-taskswitch: the tab has no title, so its window was not raised")
      (let ((matches (helm-taskswitch--tab-windows
                      title (helm-taskswitch--kwin-list-windows)))
            (shown (truncate-string-to-width title 50 nil nil "…")))
        (cond ((cdr matches)
               (message "helm-taskswitch: %d windows match tab %S, so none was raised"
                        (length matches) shown))
              (matches
               (helm-taskswitch--kwin "Run" (cdr (assoc 'window-id (car matches)))
                                      ""))
              ((> tries 0)
               (run-at-time helm-taskswitch--raise-interval nil
                            #'helm-taskswitch--raise-tab-window
                            title (1- tries)))
              (t
               (message "helm-taskswitch: no window matches tab %S; see `helm-taskswitch-tab-window-title-suffixes'"
                        shown)))))))

(defun helm-taskswitch--browser-tab-activate (tab)
  "Switch to the browser TAB and raise its window."
  (if (not (eq helm-taskswitch-backend 'kwin))
      (helm-taskswitch-browser-activate tab)
    ;; On Wayland the browser may not be allowed to raise its own
    ;; window.  Once it replies that the tab is active, find the window
    ;; showing that tab and ask KWin to activate it.
    (let ((title (alist-get 'title tab)))
      (helm-taskswitch-browser-activate
       tab
       (lambda (reply)
         (if (alist-get 'ok reply)
             (helm-taskswitch--raise-tab-window
              title helm-taskswitch--raise-tries)
           (message "helm-taskswitch: %s" (alist-get 'error reply))))))))

(defun helm-taskswitch--browser-tabs-close (_tab)
  "Close the marked tabs, or the selected one."
  (helm-taskswitch-browser-close (helm-marked-candidates)))

(defun helm-taskswitch--browser-tab-copy-url (tab)
  "Put the URL of TAB in the kill ring."
  (let ((url (alist-get 'url tab)))
    (kill-new url)
    (message "Copied %s" url)))

(defun helm-taskswitch--browser-tab-eww (tab)
  "Open the URL of TAB in eww."
  (eww (alist-get 'url tab)))

(defvar helm-taskswitch-source-browser-tabs
  (helm-build-sync-source "Browser tabs"
    :candidates #'helm-taskswitch--browser-tab-candidates
    :fuzzy-match t
    :action `(("Switch to tab" . ,#'helm-taskswitch--browser-tab-activate)
              ("Close tab(s)" . ,#'helm-taskswitch--browser-tabs-close)
              ("Copy URL" . ,#'helm-taskswitch--browser-tab-copy-url)
              ("Reload" . ,#'helm-taskswitch-browser-reload)
              ("Duplicate" . ,#'helm-taskswitch-browser-duplicate)
              ("Mute/unmute" . ,#'helm-taskswitch-browser-toggle-muted)
              ("Open URL in eww" . ,#'helm-taskswitch--browser-tab-eww)))
  "Helm source of browser tabs sent by the helm-taskswitch extension.")


;;;###autoload
(defun helm-taskswitch ()
  "Use helm to switch between tasks (X11 windows, buffers or recentf)."
  (interactive)
  (run-hooks 'helm-taskswitch-open-hook)
  (select-frame-set-input-focus (window-frame (selected-window)))
  (make-frame-visible)
  (unless helm-source-buffers-list
   (setq helm-source-buffers-list
          (helm-make-source "Buffers" 'helm-source-buffers)))
  (helm :sources '(helm-taskswitch-source-x-windows
                   helm-taskswitch-source-browser-tabs
                   helm-source-buffers-list
                   helm-source-recentf
                   ;;helm-chrome-history-source
                   helm-source-buffer-not-found)
        :buffer "*helm-taskswitch*"
        :truncate-lines t))


;; Local Variables:
;; coding: utf-8
;; indent-tabs-mode: nil
;; End:

(provide 'helm-taskswitch)
;;; helm-taskswitch.el ends here
