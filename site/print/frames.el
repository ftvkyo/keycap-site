;;; frames.el --- the brochure's editor frames, as the site makes them  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;; usage: emacs --batch -l print/frames.el SITE EXAMPLES OUT
;;
;; Runs the front page's keycap block through ob-keycap, the site's own
;; generator, twice: as the front page shows it, and with the mouse over
;; the model and its context menu open.  Writes OUT/NAME.html, each a
;; page of the site's style sheet with one frame, for shoot.py to
;; screenshot, and the frames' images in OUT/frames/.  The menu is
;; ob-keycap's, built from keycap's own keymap, so it stays the one a
;; right click opens.

;;; Code:

(require 'org)
(require 'ox-html)

(pcase-let ((`(,site ,examples ,out) (mapcar #'expand-file-name command-line-args-left)))
  (setq command-line-args-left nil)
  (add-to-list 'load-path (expand-file-name "tools" site))
  (require 'ob-keycap)

  (setf (alist-get :results org-babel-default-header-args:keycap) "html")
  (setq org-confirm-babel-evaluate nil
        treesit-font-lock-level 4
        ob-keycap-examples-directory examples
        ob-keycap-image-directory (expand-file-name "frames" out)
        ob-keycap-html-directory out
        ;; The light scheme's, which the images are shown on.
        ob-keycap-background "#fcfcfc"
        ;; The preview's window, 32rem of 18 px, at shoot.py's three
        ;; pixels to one.
        ob-keycap-size 1728)
  (when-let* ((cores (string-to-number (or (getenv "NIX_BUILD_CORES") "0")))
              ((> cores 0)))
    (setq keycap-server-threads cores))

  (let ((header (with-temp-buffer
                  (insert-file-contents (expand-file-name "content/index.org" site))
                  (re-search-forward "^#\\+begin_src keycap\\(.*\\)$")
                  (match-string 1))))
    ;; NAME, the header arguments added to the front page's, and the
    ;; page's class: `preview' shows the preview's window alone.  Its
    ;; image is taller, so that the menu fits under the mouse.
    (pcase-dolist (`(,name ,extra ,class)
                   '(("frame" "" "")
                     ("frame-menu" " :size \"1728 1944\" :pointer \"0.24 0.27\" :menu context" "preview")))
      (let* ((default-directory (file-name-as-directory out))
             (html (org-export-string-as (format "#+begin_src keycap%s%s\n#+end_src\n" header extra)
                                         'html t)))
        (with-temp-file (expand-file-name (concat name ".html") out)
          (insert "<!doctype html>\n<meta charset=\"utf-8\">\n"
                  "<link rel=\"stylesheet\" href=\"style.css\">\n"
                  "<link rel=\"stylesheet\" href=\"shoot.css\">\n"
                  (format "<body class=\"%s\">\n" class)
                  html))))))

;;; frames.el ends here
