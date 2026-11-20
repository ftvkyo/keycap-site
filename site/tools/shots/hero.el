;;; hero.el --- a real screenshot of keycap, taken in the rig  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;; From an infra checkout with keycap in its Emacs, in a headless session
;; (`just niri headless NAME'):
;;
;;   NIRI_TRY_NAME=NAME RIG_NAME=NAME KEYCAP_DIR=KEYCAP_CHECKOUT \
;;     just emacs rig SITE/tools/shots/hero.el
;;
;; Opens keycap's knob example and its preview, waits for the preview to
;; settle, and screenshots the window into content/images/site/hero.png
;; (or HERO).
(load (expand-file-name "lib.el" (getenv "RIG_LIB_DIR")))

(require 'keycap)
(require 'keycap-preview)

(defconst f/site (expand-file-name "../../" (file-name-directory load-file-name)))
(defconst f/file (expand-file-name "keycap/knob.keycap" h/dir))
(defconst f/shot (or (getenv "HERO") (expand-file-name "content/images/site/hero.png" f/site)))

;; File names are shown from ~, as a reader's would be.
(setenv "HOME" (directory-file-name h/dir))
(setq abbreviated-home-dir nil)

(defun f/take ()
  "Screenshot the window once the preview has been idle a moment, then quit."
  (if (not (keycap-preview-idle-p (get-file-buffer f/file)))
      (run-with-timer 0.5 nil #'f/take)
    (sit-for 1.5)
    (message nil)
    (redisplay t)
    (make-directory (file-name-directory f/shot) t)
    (call-process "niri" nil nil nil "msg" "action" "screenshot-window" "--id"
                  (format "%d" (h/niri-id)) "--show-pointer=false" "--path" f/shot)
    (h/-poll (lambda () (file-exists-p f/shot)) 3)
    (h/log "shot %s" f/shot)
    (kill-emacs 0)))

(defun f/open ()
  "Open a copy of the knob example with its preview."
  (make-directory (file-name-directory f/file) t)
  (copy-file (expand-file-name "examples/knob.keycap" (getenv "KEYCAP_DIR")) f/file t)
  (select-window (window-main-window))
  (delete-other-windows)
  (find-file f/file)
  (keycap-preview)
  (run-with-timer 1 nil #'f/take))

(h/set-width 1440)
(call-process "niri" nil nil nil "msg" "action" "set-window-height"
              "--id" (format "%d" (h/niri-id)) "900")
(if (bound-and-true-p my/startup-done)
    (run-with-timer 0.5 nil #'f/open)
  (add-hook 'emacs-startup-hook (lambda () (run-with-timer 0.5 nil #'f/open)) 90))

;;; hero.el ends here
