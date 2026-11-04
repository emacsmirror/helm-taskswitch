;;; helm-taskswitch.el --- Use helm to switch windows and buffers  -*- lexical-binding: t -*-

;; Author: Brian Caruso <briancaruso@gmail.com>
;; Maintainer: Brian Caruso <briancaruso@gmail.com>
;; Created: 2016-05-27
;; URL: https://github.com/bdc34/helm-taskswitch
;; Package-Version: 2.0.0
;; Package-Requires: ((emacs "24")(helm "3.0"))
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

;; `helm-taskswitch' provides an X window and buffer switching with helm.

;; ## Table of Contents

;; - [Installation](#installation)
;; - [Usage](#usage)
;; - [Issues](#issues)
;; - [License](#license)
;; - [TODOs](#TODOs)

;; ## Installation

;; Install wmctrl and helm.  On KDE Plasma under Wayland, wmctrl only
;; sees XWayland windows, so set `helm-taskswitch-backend' to `kwin'
;; (the default when XDG_SESSION_TYPE is wayland) to list windows
;; through KWin's D-Bus interface instead.

;; ## Usage

;; To activate use `M-x helm-task-switcher'.

;; ## Issues / bugs

;; If you discover an issue or bug in `helm-taskswitch' not already noted:

;; * as a TODO item, or

;; please create a new issue with as much detail as possible, including:

;; * which version of Emacs you're running on which operating system, and

;; * how you installed `helm-task-switcher', wmctrl and helm.

;; ## TODOs

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

;; ## License

;; [GNU General Public License version 3]
;; (http://www.gnu.org/licenses/gpl.html), or (at your option) any
;; later version;; Code from https://github.com/flexibeast/ewmctrl is
;; used under GNU 3.

;;; Code:

(require 'helm)
(require 'helm-for-files) ;; needed for helm-source-recentf
(require 'dbus)
(require 'seq)

;; Customisable variables.

(defgroup helm-taskswitch nil
  "Use helm to switch between tasks (X11 windows or buffers)."
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
  "Transform title of a single client window for display in helm selection."
  :group 'helm-taskswitch
  :type '(repeat function))

(defcustom helm-taskswitch-wmclass-width 12
  "Column with of wmclass field when displayed."
  :group 'helm-taskswitch
  :type 'integer)

(defgroup helm-taskswitch-faces nil
  "Customize the appearance of `helm-taskswitch`."
  :prefix "helm-"
  :group 'helm-taskswitch
  :group 'helm-faces)

(defface helm-taskswitch-browser-face
  '((t (:inherit font-lock-constant-face)))
  "Face used for web browsers."
  :group 'helm-taskswitch-faces)

(defface helm-taskswitch-term-face
  '((t (:inherit font-lock-string-face)))
  "Face used for terminals."
  :group 'helm-taskswitch-faces)

(defface helm-taskswitch-emacs-face
  '((t (:inherit font-lock-regexp-grouping-construct)))
  "Face used for Emacs."
  :group 'helm-taskswitch-faces)


;; Internal Code

(defun helm-taskswitch-format-candidate (al)
  "Formats a candidate client window for task switcher.

  AL is the associative list for a window."
  (let* ((ddfmt (format "%d.%d" helm-taskswitch-wmclass-width helm-taskswitch-wmclass-width))
         (wmtitlefmt (concat "%-" ddfmt "s %s"))
         (windowstr (format wmtitlefmt (helm-taskswitch-wmclass al) (helm-taskswitch-title al))))
    (cons windowstr (list al))))

(defun helm-taskswitch-title (al)
  "Formats the title of a window.

  AL is an associative list for a window."
  (let ((title   (cdr (assoc 'title   al))))
    (funcall helm-taskswitch-title-transform
             (replace-regexp-in-string "- Google Chrome" "" title))))

(defun helm-taskswitch-wmclass (al)
  "Gets the WMCLASS for window AL associative list."
  (let ((wmclass (cdr (assoc 'wmclass al)))
        (title (or (cdr (assoc 'title al)) "")))
    ;; The X11 names come from wmctrl; the others are the icon names
    ;; KWin reports for the `kwin' backend.
    (cond ((member wmclass '("google-chrome.Google-chrome" "google-chrome"))
           (propertize "Chrome" 'face 'helm-taskswitch-browser-face ))
          ((string-equal wmclass "terminator.Terminator")
           (propertize "Terminator" 'face 'helm-taskswitch-term-face))
          ((string-equal wmclass "utilities-terminal")
           (propertize "Terminal" 'face 'helm-taskswitch-term-face))
          ((or (string-equal wmclass "emacs.Emacs")
               ;; KWin gives Emacs an empty icon name.
               (and (string-equal wmclass "")
                    (string-match-p "GNU Emacs" title)))
           (propertize "Emacs" 'face 'helm-taskswitch-emacs-face))
          (t wmclass) )))

(defconst helm-taskswitch--wmctrl-field-count 10)
(defconst helm-taskswitch--wmctrl-field-regex
  (concat "^"
          (mapconcat 'identity (make-list (1- helm-taskswitch--wmctrl-field-count) "\\(\\S-+\\)\\s-+") "")
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
  "Internal function to focus the desktop window specified by AL, a window associative list."
  (let ((id (cdr (assoc 'window-id (car al)))))
    (if (eq helm-taskswitch-backend 'kwin)
        ;; KWin switches to the window's virtual desktop itself.
        (helm-taskswitch--kwin "Run" id "")
      (let ((desktop-id (cdr (assoc 'desktop-number (car al)))))
        (call-process-shell-command
         (concat helm-taskswitch-wmctrl-path " -s '" desktop-id "'"))
        (call-process-shell-command
         (concat helm-taskswitch-wmctrl-path " -i -a '" id "'"))))))


(defun helm-taskswitch-close-candidate (al)
  "Closes a candidate AL, a window associative list from ‘helm-taskswitch--list-windows’."
    (let* ((id (cdr (assoc 'window-id (car al))))
           (cmd (concat helm-taskswitch-wmctrl-path " -i -c '" id "'")))
      (message (concat "helm-taskswitch: closing X client with " cmd))
      (call-process-shell-command cmd)))

(defun helm-taskswitch-close-candidates (_al)
  "Closes all selected candidates.  AL is ignored but seems to be needed by helm."
  (when (eq helm-taskswitch-backend 'kwin)
    (user-error "helm-taskswitch: closing windows is not supported with the kwin backend yet"))
  (mapc 'helm-taskswitch-close-candidate (helm-marked-candidates)))

(defun helm-taskswitch-client-candidates ()
  "Return a list windows with title and wmclass."
  (mapcar 'helm-taskswitch-format-candidate
          (if (eq helm-taskswitch-backend 'kwin)
              (helm-taskswitch--kwin-list-windows)
            (helm-taskswitch--list-windows))))

(defvar helm-taskswitch-source-x-windows
      (helm-build-sync-source "X Windows"
        :fuzzy-match t
        :candidates 'helm-taskswitch-client-candidates
        :action '(("Focus window" . helm-taskswitch-focus-window-by-candidate )
                  ("Close window(s)" . helm-taskswitch-close-candidates)
                  ("dump client window s-exp" . prin1 )))
      "Helm source that provides X windows and actions.")


;; Browser tabs from KDE Plasma Browser Integration.  This needs the
;; "Plasma Integration" browser extension; its native host then serves
;; the same krunner1 D-Bus interface that KRunner uses to search tabs.

(defconst helm-taskswitch--tabs-service "org.kde.plasma.browser_integration")

(defun helm-taskswitch--tabs (method &rest args)
  "Call METHOD with ARGS on Plasma Browser Integration's tabs runner."
  (apply #'dbus-call-method :session helm-taskswitch--tabs-service
         "/TabsRunner" "org.kde.krunner1" method args))

(defun helm-taskswitch--tabs-query ()
  "Return the word of `helm-pattern' to send to the tabs runner, or nil.
The runner treats its query as one string, so \"wom 80\" would match
nothing.  Send only the longest word, which narrows the most, and
let helm match the whole pattern against what comes back.  The
runner refuses queries shorter than 3 characters."
  (let ((word (car (sort (split-string helm-pattern " " t)
                         (lambda (a b) (> (length a) (length b)))))))
    (when (and word (>= (length word) 3))
      ;; Drop helm's "!" negation prefix if that is the longest word.
      (string-remove-prefix "!" word))))

(defun helm-taskswitch--browser-tab-candidates ()
  "Return browser tabs for the longest word in `helm-pattern'.
Helm then filters these with the full pattern."
  (when-let ((query (helm-taskswitch--tabs-query))
             ((member helm-taskswitch--tabs-service
                      (dbus-list-names :session))))
    (mapcar
     (lambda (m)
       ;; m is (ID TITLE ICON-NAME TYPE RELEVANCE PROPERTIES).
       (let* ((url (car (cadr (assoc "subtext" (nth 5 m)))))
              (al `((tab-id . ,(nth 0 m))
                    (title . ,(nth 1 m))
                    (wmclass . ,(nth 2 m))
                    (url . ,url))))
         (cons (format (format "%%-%d.%ds %%s  %%s"
                               helm-taskswitch-wmclass-width
                               helm-taskswitch-wmclass-width)
                       (helm-taskswitch-wmclass al)
                       (helm-taskswitch-title al)
                       (propertize (or url "") 'face 'font-lock-comment-face))
               al)))
     (ignore-errors (helm-taskswitch--tabs "Match" query)))))

(defun helm-taskswitch--browser-tab-activate (al)
  "Switch to the browser tab AL and raise its window."
  (helm-taskswitch--tabs "Run" (cdr (assoc 'tab-id al)) "")
  ;; On Wayland the browser may not be allowed to raise its own window.
  ;; Once the tab is active the window title starts with the tab title,
  ;; so find that window and ask KWin to activate it.
  (when (eq helm-taskswitch-backend 'kwin)
    (sit-for 0.3)
    (let* ((title (cdr (assoc 'title al)))
           (win (seq-find (lambda (w)
                            (string-prefix-p title (cdr (assoc 'title w))))
                          (helm-taskswitch--kwin-list-windows))))
      (when win
        (helm-taskswitch--kwin "Run" (cdr (assoc 'window-id win)) "")))))

(defvar helm-taskswitch-source-browser-tabs
  (helm-build-sync-source "Browser tabs"
    :candidates #'helm-taskswitch--browser-tab-candidates
    ;; Fetch again on each change of the pattern, then let helm match
    ;; the full pattern (fuzzy for one word, each word for several).
    :volatile t
    :fuzzy-match t
    :requires-pattern 3
    :action '(("Switch to tab" . helm-taskswitch--browser-tab-activate)
              ("Copy URL" . (lambda (al) (kill-new (cdr (assoc 'url al)))))))
  "Helm source of browser tabs from KDE Plasma Browser Integration.")


;;;###autoload
(defun helm-taskswitch ()
  "Use helm to switch between tasks (X11 windows, buffers or recentf)."
  (interactive)
  (run-hooks 'helm-taskswitch-open-hooks )
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
