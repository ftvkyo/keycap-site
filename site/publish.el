;;; publish.el --- Build keycap's site  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;; emacs --batch --load publish.el, from the repository's root, with keycap
;; and htmlize installed: the Org pages in content/, the manual and the
;; examples of the keycap checkout KEYCAP_DIR, and the models of the
;; checkout KEYCAP_DESIGNS_DIR become plain HTML in public/.

;;; Code:

(require 'ox-publish)
(require 'htmlize)
(require 'cl-lib)
(require 'subr-x)

(defconst fms-root (file-name-directory (or load-file-name buffer-file-name)))

(defun fms-path (&rest parts)
  "PARTS joined under the repository's root."
  (expand-file-name (string-join parts "/") fms-root))

(defconst fms-keycap (file-name-as-directory (or (getenv "KEYCAP_DIR") (error "KEYCAP_DIR is not set")))
  "The keycap checkout whose manual and examples are published.")


;; --- Highlighting ---

;; Code blocks are coloured by rhai-ts-mode and keycap-mode themselves,
;; through htmlize's CSS classes, so the site and Emacs agree on what is a
;; keyword; keycap-mode knows fidget's functions once it has listed them.
;; Signatures are coloured by keycap-signature-mode, as C-c C-d colours them.
;; Nix is coloured by nix-mode.

(require 'keycap)
(require 'nix-mode)
(keycap-names 'keycap)
(add-to-list 'org-src-lang-modes '("rhai" . rhai-ts))
(add-to-list 'org-src-lang-modes '("keycap" . keycap))
(add-to-list 'org-src-lang-modes '("keycap-signature" . keycap-signature))

(setq org-html-htmlize-output-type 'css
      org-html-htmlize-font-prefix "hl-"
      org-src-fontify-natively t
      ;; Every face rhai-ts-mode uses, not only the default level's.
      treesit-font-lock-level 4)


;; --- Renders ---

;; `keycap' blocks are run by ob-keycap at export, in one keycap-server on
;; the CPU, on the build's cores; KEYCAP_BACKEND is for tools/preview.sh,
;; KEYCAP_CACHE for it and for default.nix's frame cache, KEYCAP_COMPRESS
;; for default.nix.

(add-to-list 'load-path (fms-path "tools"))
(require 'ob-keycap)

(setf (alist-get :results org-babel-default-header-args:keycap) "html")
(setq org-confirm-babel-evaluate nil
      ob-keycap-examples-directory (expand-file-name "examples" fms-keycap)
      ob-keycap-cache-directory (getenv "KEYCAP_CACHE")
      ob-keycap-compress (and (getenv "KEYCAP_COMPRESS") t)
      ob-keycap-backend (intern (or (getenv "KEYCAP_BACKEND") "cpu")))

(when-let* ((cores (string-to-number (or (getenv "NIX_BUILD_CORES") "0")))
            ((> cores 0)))
  (setq keycap-server-threads cores))

(defun fms-publish-to-html (plist file directory)
  "Publish the Org FILE to HTML in DIRECTORY, its frames' images in frames/."
  (let ((ob-keycap-image-directory (expand-file-name "frames" directory))
        (ob-keycap-html-directory directory))
    (org-html-publish-to-html plist file directory)))


;; --- Assets ---

;; The stylesheet, the script and the fonts are published under names with
;; their content's hash, so a cached copy is never the wrong one and a
;; changed file is fetched at once; the pages, which Pages caches for ten
;; minutes, are the only thing that can lag.  The dev server (KEYCAP_DEV)
;; keeps the plain names.  The font files are in KEYCAP_FONTS, their licence is KEYCAP_FONTS_LICENCE.
;; default.nix then cuts the fonts down to the characters the pages use,
;; with tools/subset-fonts.py, which renames them and the stylesheet.

(defconst fms-dev (and (getenv "KEYCAP_DEV") t)
  "Whether the site is published for tools/dev.py.")

(defun fms-read (file)
  "The bytes of FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun fms-fingerprint (name data)
  "NAME with the hash of DATA before its extension, or NAME itself in dev."
  (if fms-dev
      name
    (format "%s.%s.%s" (file-name-sans-extension name)
            (substring (secure-hash 'sha256 data) 0 10)
            (file-name-extension name))))

(defconst fms-public (fms-path "public"))

(defconst fms-assets
  (let* ((fonts (mapcar (lambda (face)
                          (let* ((name (format "fonts/MapleMonoNL-%s.woff2" face))
                                 (data (fms-read (expand-file-name
                                                  (format "MapleMonoNL-%s.ttf.woff2" face)
                                                  (or (getenv "KEYCAP_FONTS")
                                                      (error "KEYCAP_FONTS is not set"))))))
                            (list name (fms-fingerprint name data) data)))
                        '("Regular" "Italic" "Bold")))
         (css (fms-read (fms-path "static" "style.css")))
         (js (fms-read (fms-path "static" "copy.js"))))
    (pcase-dolist (`(,name ,published) fonts)
      (setq css (string-replace name published css)))
    `(("style.css" ,(fms-fingerprint "style.css" css) ,css)
      ("copy.js" ,(fms-fingerprint "copy.js" js) ,js)
      ;; The OFL asks for the licence to travel with the faces, under its own name.
      ("fonts/OFL.txt" "fonts/OFL.txt" ,(fms-read (or (getenv "KEYCAP_FONTS_LICENCE")
                                                       (error "KEYCAP_FONTS_LICENCE is not set"))))
      ,@fonts))
  "The files that are published by a hash of their content: their name,
the name they are published under, and their bytes.")

(defun fms-asset (name)
  "The name in the site's root that the asset NAME is published under."
  (nth 1 (assoc name fms-assets)))

(defun fms-publish-assets ()
  "Write the assets into public/."
  (pcase-dolist (`(,_ ,published ,data) fms-assets)
    (let ((file (expand-file-name published fms-public)))
      (make-directory (file-name-directory file) t)
      (let ((coding-system-for-write 'no-conversion))
        (write-region data nil file nil 'silent)))))


;; --- Page frame ---

(defconst fms-nav
  '(("" . "keycap")
    ("tutorial/index.html" . "Tutorial")
    ("manual/index.html" . "Manual")
    ("gallery/index.html" . "Gallery")
    ("install.html" . "Install")
    ("about.html" . "About"))
  "The header's links, relative to the site's root.")

(defun fms-up (info)
  "The way from the page INFO exports up to the site's root."
  (or (plist-get info :fms-up)
      ;; For a page at the root this is ".", without the slash the other
      ;; levels' "../" have.
      (let ((up (file-name-as-directory
                 (file-relative-name (plist-get info :base-directory)
                                     (file-name-directory (plist-get info :input-file))))))
        (if (equal up "./") "" up))))

(defun fms-page (info)
  "The path in the site of the page INFO exports, such as tutorial/index.html."
  (file-relative-name
   (expand-file-name (concat (file-name-base (plist-get info :input-file)) ".html")
                     (plist-get info :publishing-directory))
   fms-public))

(defun fms-current-p (href page)
  "Whether the header's link to HREF stands for PAGE: it, or its section."
  (or (equal href page)
      (and (string-suffix-p "/index.html" href)
           (string-prefix-p (file-name-directory href) page))))

(defun fms-preamble (info)
  "The header of the page INFO exports."
  (let ((up (fms-up info))
        (page (fms-page info)))
    (concat
     "<a class=\"skip\" href=\"#content\">Skip to the content</a>"
     "<header><nav>"
     (mapconcat (pcase-lambda (`(,href . ,label))
                  (format "<a href=\"%s%s\"%s>%s</a>"
                          up (if (equal href "") "index.html" href)
                          (cond ((equal href "") " class=\"logo\"")
                                ((fms-current-p href page) " aria-current=\"page\"")
                                (t ""))
                          label))
                fms-nav "")
     "</nav></header>")))

(defun fms-postamble (_info)
  "The footer of every page."
  (concat "<footer>"
          "<p>keycap is free software: its Emacs package and manual are GPL-3.0-or-later, its server and prelude MPL-2.0 and its examples 0BSD. "
          "This site's text and Rei's designs are CC BY-SA 4.0, the tutorial's code 0BSD and the site's own code GPL-3.0-or-later.</p>"
          "<p>Written in Org, published by Emacs; one small script, to copy code, and no trackers.</p>"
          "</footer>"))

(defun fms-head (up)
  "The head of a page whose root is UP."
  (concat
   "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
   "<meta name=\"color-scheme\" content=\"dark light\">\n"
   (format "<link rel=\"icon\" type=\"image/svg+xml\" href=\"%sfavicon.svg\">\n" up)
   (format "<link rel=\"stylesheet\" href=\"%s%s\">\n" up (fms-asset "style.css"))
   ;; The face of the code, wanted on every page.
   (format "<link rel=\"preload\" href=\"%s%s\" as=\"font\" type=\"font/woff2\" crossorigin>\n"
           up (fms-asset "fonts/MapleMonoNL-Regular.woff2"))
   (format "<script src=\"%s%s\" defer></script>\n" up (fms-asset "copy.js"))
   (and fms-dev "<script src=\"/__dev.js\" defer></script>\n")))

(defun fms-pager (previous up next)
  "Links to the PREVIOUS and NEXT pages and UP, each (ID TITLE) or nil, in HTML."
  (cl-flet ((link (rel label page)
              (if page
                  (format "<a rel=\"%s\" href=\"%s.html\"><span>%s</span> %s</a>"
                          rel (car page) label (org-html-encode-plain-text (cadr page)))
                "<span></span>")))
    (concat "<nav class=\"pager\" aria-label=\"Previous and next\">"
            (link "prev" "Previous" previous)
            (link "up" "Up" up)
            (link "next" "Next" next)
            "</nav>")))

(setq org-html-doctype "html5"
      org-html-html5-fancy t
      org-html-head-include-default-style nil
      org-html-head-include-scripts nil
      org-html-validation-link nil
      ;; `fms-head' has it.
      org-html-viewport nil
      org-html-preamble #'fms-preamble
      org-html-postamble #'fms-postamble
      org-html-divs '((preamble "div" "preamble")
                      (content "main" "content")
                      (postamble "div" "postamble"))
      org-html-container-element "section"
      org-html-metadata-timestamp-format "%Y-%m-%d"
      ;; Without it, Org's `<!-- DATE -->' comment would make the output depend on the build date.
      org-export-time-stamp-file nil
      org-export-with-author nil
      org-export-with-section-numbers nil
      org-export-with-sub-superscripts nil
      org-export-with-smart-quotes t
      org-html-self-link-headlines t
      make-backup-files nil)

;; Org names elements it needs an id for at random (org1a2b3c4); seeded,
;; the same pages get the same ids on every build.
(random "keycap-site")


;; --- Anchors ---

;; Org numbers headings at random on every export; links into the manual
;; need ids that survive, so each heading without one gets its title's.

(defun fms-slug (title)
  "TITLE as an anchor: lower case, runs of other characters as one dash."
  (string-trim (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase title)) "-" "-"))

(defun fms-name-headings (_backend)
  "Give every heading in the buffer being exported a CUSTOM_ID from its title."
  (let ((taken (make-hash-table :test #'equal)))
    (org-map-entries
     (lambda ()
       (unless (org-entry-get nil "CUSTOM_ID")
         (let* ((slug (fms-slug (org-get-heading t t t t)))
                (id slug)
                (n 1))
           (while (gethash id taken)
             (setq id (format "%s-%d" slug (cl-incf n))))
           (puthash id t taken)
           (org-entry-put nil "CUSTOM_ID" id)))))))

(add-hook 'org-export-before-processing-functions #'fms-name-headings)

(defun fms-link-images (html _backend _info)
  "Make every image in HTML but an example's a link to itself: screenshots shrink to fit the page."
  (replace-regexp-in-string
   "\\(<div class=\"example-pic\">[ \t\n]*\\)?<img src=\"\\([^\"]+\\)\"[^>]*>"
   (lambda (match)
     (if (match-beginning 1)
         match
       (format "<a href=\"%s\">%s</a>" (match-string 2 match) match)))
   html t t))

(add-to-list 'org-export-filter-final-output-functions #'fms-link-images)

(defun fms-png-size (file)
  "The width and height of the PNG FILE, from its header."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 24)
    (unless (string-prefix-p "\211PNG" (buffer-string))
      (error "%s is not a PNG" file))
    (cl-flet ((u32 (at) (seq-reduce (lambda (n byte) (+ (* n 256) byte))
                                    (buffer-substring (1+ at) (+ at 5)) 0)))
      (list (u32 16) (u32 20)))))

(defun fms-size-pictures (html _backend info)
  "Give each picture in HTML its size, so the page does not move as they load.
All but the first load lazily, the first early.  The pictures are PNG
files beside the page INFO exports."
  (let ((directory (file-name-directory (expand-file-name (fms-page info) fms-public)))
        (first t))
    (replace-regexp-in-string
     "<img src=\"\\([^\"]+\\)\""
     (lambda (img)
       (pcase-let ((`(,width ,height)
                    (save-match-data (fms-png-size (expand-file-name (match-string 1 img) directory)))))
         (format "%s width=\"%d\" height=\"%d\" %s" img width height
                 (if first
                     (progn (setq first nil) "fetchpriority=\"high\"")
                   "loading=\"lazy\""))))
     html t t)))

(add-to-list 'org-export-filter-final-output-functions #'fms-size-pictures)

(defconst fms-code-columns 32
  "The longest code in text that is kept on one line; longer code may wrap.
It fits on a phone, about 40 columns.")

(defun fms-long-code (html _backend _info)
  "Mark code in the text of HTML that is too long to keep on one line as long."
  (replace-regexp-in-string
   "<code>\\([^<]*\\)</code>"
   (lambda (match)
     (if (> (length (replace-regexp-in-string "&[#[:alnum:]]+;" "&" (match-string 1 match)))
            fms-code-columns)
         (concat "<code class=\"long\">" (substring match 6))
       match))
   html t t))

(add-to-list 'org-export-filter-final-output-functions #'fms-long-code)

(defun fms-map-tables (html _backend _info)
  "Give each cell of a map table in HTML its column's header, as data-label.
A map table, of the class map, maps its first column to the others; on
a phone, each row is stacked, every cell after the first labelled."
  (replace-regexp-in-string
   "<table class=\"map\"[^>]*>\\(?:.\\|\n\\)*?</table>"
   (lambda (table)
     (let ((labels (save-match-data
                     (let ((start 0)
                           labels)
                       (while (string-match "<th[^>]*>\\(.*?\\)</th>" table start)
                         (push (replace-regexp-in-string "<[^>]*>" "" (match-string 1 table)) labels)
                         (setq start (match-end 0)))
                       (nreverse labels)))))
       (replace-regexp-in-string
        "<tr>\\(?:.\\|\n\\)*?</tr>"
        (lambda (row)
          (let ((n -1))
            (replace-regexp-in-string
             "<td" (lambda (_) (format "<td data-label=\"%s\"" (nth (cl-incf n) labels)))
             row t t)))
        table t t)))
   html t t))

(add-to-list 'org-export-filter-final-output-functions #'fms-map-tables)


;; --- Review ---

;; Most of the text is drafted by an AI, and the site says which of it a
;; person has read.  `#+review: reviewed 2026-11-17' at the top of a page,
;; or a `:REVIEW:' property on a heading for its section, marks it
;; reviewed, and `reviewed 2026-11-17 by NAME' names who did; without
;; either, a page is a draft.  A `human' block is a person's own words,
;; and `#+begin_human NAME' names them.

(defvar fms-review nil
  "The `#+review:' value of the page being exported, or nil.")

(defun fms-review-mark (value)
  "The class and the text of the review mark the string VALUE stands for."
  (pcase (if (member value '(nil "")) "draft" (string-trim value))
    ("draft" '("review-draft" . "Drafted with AI, not yet reviewed"))
    ((rx bos "reviewed " (let date (: (= 4 digit) "-" (= 2 digit) "-" (= 2 digit)))
         (? " by " (let name (+ nonl))) eos)
     (cons "review-reviewed" (if name
                                 (format "Reviewed by %s, %s" (string-trim name) date)
                               (format "Reviewed %s" date))))
    (other (error "Unknown review mark: %s" other))))

(defun fms-review-sections (_backend)
  "Read the page's review mark, and put a block with each section's under its heading."
  (setq fms-review (save-excursion
                     (goto-char (point-min))
                     (when (re-search-forward "^#\\+review:[ \t]*\\(.*\\)$" nil t)
                       (match-string 1))))
  (org-map-entries
   (lambda ()
     (when-let* ((value (org-entry-get nil "REVIEW")))
       (pcase-let ((`(,class . ,text) (fms-review-mark value)))
         (org-end-of-meta-data t)
         (insert (format "#+begin_%s\n%s\n#+end_%s\n\n" class text class)))))))

(add-hook 'org-export-before-processing-functions #'fms-review-sections)

(defun fms-review-badge (html _backend _info)
  "Put the page's review mark under the title in HTML."
  (let* ((title (string-search "<h1 class=\"title\">" html))
         (end (and title (string-search "</header>" html title))))
    (if (not end)
        html
      (pcase-let ((`(,class . ,text) (fms-review-mark fms-review)))
        (concat (substring html 0 end)
                (format "<div class=\"%s\"><p>%s</p></div>\n" class text)
                (substring html end))))))

(add-to-list 'org-export-filter-final-output-functions #'fms-review-badge)

(defun fms-human-names (_backend)
  "Carry the name after `#+begin_human' to its HTML, as `data-by'."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^\\([ \t]*\\)#\\+begin_human[ \t]+\\(.*[^ \t]\\)[ \t]*$" nil t)
      (replace-match "\\1#+attr_html: :data-by \\2\n\\1#+begin_human" t))))

(add-hook 'org-export-before-processing-functions #'fms-human-names)

(defun fms-human-block (html _backend _info)
  "Set a `human' block's HTML apart, labelled as a person's own words."
  (if (string-match "\\`<div\\([^>]*\\)>\n" html)
      (let ((attributes (match-string 1 html))
            (body (substring html (match-end 0))))
        (if (not (string-match-p "class=\"human\"" attributes))
            html
          (concat "<aside class=\"human\">\n<p class=\"human-label\">"
                  (if (string-match "data-by=\"\\([^\"]*\\)\"" attributes)
                      (format "Written by %s" (match-string 1 attributes))
                    "Written by hand")
                  "</p>\n"
                  (string-remove-suffix "</div>" body)
                  "</aside>")))
    html))

(add-to-list 'org-export-filter-special-block-functions #'fms-human-block)


;; --- Tutorial ---

;; Each part is numbered under its title, and ends with the pager the
;; manual's pages have, up to the tutorial's index.

(defconst fms-tutorial-parts
  (mapcar (lambda (file)
            (with-temp-buffer
              (insert-file-contents file)
              (list (file-name-base file)
                    (and (re-search-forward "^#\\+title: \\(.*\\)$" nil t)
                         (match-string 1)))))
          (directory-files (fms-path "content" "tutorial") t "\\`[0-9]+-.*\\.org\\'"))
  "The tutorial's parts, in order, each (ID TITLE).")

(defun fms-tutorial-pager (html _backend info)
  "Number the part of the tutorial in HTML under its title, and end it with the pager.
HTML is the page INFO exports; another page's is left as it is."
  (let* ((file (plist-get info :input-file))
         (n (and (file-equal-p (file-name-directory file) (fms-path "content" "tutorial"))
                 (cl-position (file-name-base file) fms-tutorial-parts :key #'car :test #'equal))))
    (if (not n)
        html
      (let* ((index '("index" "Tutorial"))
             (previous (if (> n 0) (nth (1- n) fms-tutorial-parts) index))
             (next (nth (1+ n) fms-tutorial-parts)))
        (thread-last
          html
          (string-replace "</head>" (concat (format "<link rel=\"prev\" href=\"%s.html\">\n" (car previous))
                                            (if next (format "<link rel=\"next\" href=\"%s.html\">\n" (car next)) "")
                                            "</head>"))
          (string-replace "</h1>" (format "</h1>\n<p class=\"subtitle\">Part %d of %d</p>"
                                          (1+ n) (length fms-tutorial-parts)))
          (string-replace "</main>" (concat (fms-pager previous index next) "\n</main>")))))))

(add-to-list 'org-export-filter-final-output-functions #'fms-tutorial-pager)


;; --- Gallery ---

;; Generated from the models, so a new one needs no page of its own:
;; keycap's examples, and Rei's designs (KEYCAP_DESIGNS_DIR), left out when
;; unset.  content/gallery/index.org has a section for the examples and one
;; for her designs, a subsection per group, the directories of
;; keycap-designs: her keycaps first, then the ports of her OpenSCAD
;; designs made for one thing; a group without models has none.  Each card
;; leads to its model's page, laid out as its source is: the opening
;; comment, renders from two sides and a section, its files and its
;; source.  Card and page say who made a model, mark a port of an
;; OpenSCAD design with an icon, the page's a link to the original, and
;; link to the model on Printables if it is there.  A port also says in
;; one line how it compares with its original: an example in its opening
;; comment, a design in its row of PORTS.md.  The renders are keycap
;; blocks; the gallery's directory is written afresh on every build.

(defun fms-source (variable)
  "The directory the environment VARIABLE names, or nil when it is unset."
  (when-let* ((directory (getenv variable)))
    (file-name-as-directory directory)))

(defconst fms-designs (fms-source "KEYCAP_DESIGNS_DIR")
  "The checkout of Rei's designs, keycap-designs, or nil.")

(defconst fms-openscad "https://github.com/ftvkyo/openscad/blob/main/"
  "Rei's OpenSCAD collection, where the originals are, by their path in it.")

(defconst fms-author '("Rei" . "https://ftvkyo.me")
  "Who made the gallery's designs and the originals of its ports, and where she is.")

(defconst fms-examples-author '("keycap" . "https://tangled.org/rei.gay/keycap")
  "Who made the examples that are not ports: keycap, whose examples they are.")

(defconst fms-example-originals
  '(("allen-key-handle" . "src/mods/allen_key_handle.scad")
    ("bed-washers" . "src/printer/bed-washers.scad")
    ("bendy-sheet" . "src/experimental/bendy-sheet.scad")
    ("dna-loop" . "src/shapes/dna-loop.scad")
    ("feather" . "src/feather/feather-bezier.scad")
    ("fidget-flower" . "src/interactive/flower.scad")
    ("fidget-magnetic" . "src/interactive/fidget_magnetic.scad")
    ("gear-involute" . "src/shapes/gear_involute.scad")
    ("hex-bowl" . "src/organisation/hexbowl.scad")
    ("ivar-joiner" . "src/ikea-ivar/joiner.scad")
    ("knob" . "src/interactive/knob.scad")
    ("laptop-stand" . "src/organisation/laptop-stand.scad")
    ("laptop-stand-2" . "src/organisation/laptop_stand_2.scad")
    ("phone-stand" . "src/organisation/phone-stand.scad")
    ("pointer" . "src/experimental/pointer.scad")
    ("scraper" . "src/printer/scraper.scad")
    ("spike" . "src/fabric/spike.scad")
    ("table-cable-hook" . "src/organisation/hook-table-cables.scad")
    ("vase-funky-2" . "src/vases/funky_2.scad")
    ("vase-interpolate" . "src/vases/interpolate.scad")
    ("vase-koch" . "src/vases/koch-snowflake.scad")
    ("vase-practical" . "src/vases/practical.scad")
    ("whistle" . "src/sound/whistle.scad"))
  "The originals of keycap's examples that are ports, by the example's name.
An example's script names its original in prose, if at all.")

;; Printables' pages are drawn by scripts; its GraphQL API lists them:
;; userModels(userId: "2406191") for the models, print(id) for one's
;; description, which names its original in the OpenSCAD collection.
(defconst fms-printables
  '(("vase-koch" . "https://www.printables.com/model/994219")
    ("table-cable-hook" . "https://www.printables.com/model/1016571")
    ("designs/mods/steam_deck_dpad" . "https://www.printables.com/model/1426078"))
  "Models that are also on Printables, by their page in the gallery.")

(defconst fms-port-phrases
  '("[,;][[:space:]]+ported[[:space:]]+from[[:space:]]+OpenSCAD\\(?:,[[:space:]]+where[^.]*\\)?"
    "[,;][[:space:]]+[^,;.]*an[[:space:]]+OpenSCAD[[:space:]]+design[^.]*"
    "[,;][[:space:]]+ported[[:space:]]+from[[:space:]]+=[^=]+="
    "Ported[[:space:]]+from[[:space:]]+=[^=]+=[.;][[:space:]]*")
  "What the first paragraph of a model's opening comment says of its original.
The port's icon says it instead.")

(defconst fms-port-icon
  (concat "<svg viewBox=\"0 0 16 16\" role=\"img\"><title>Ported from OpenSCAD</title>"
          "<rect x=\"1.5\" y=\"1.5\" width=\"6\" height=\"6\" rx=\"0.5\"/>"
          "<circle cx=\"11.5\" cy=\"11.5\" r=\"3\"/>"
          "<path d=\"M8.5 4.5h3v3.5M9.75 6.75l1.75 1.75 1.75-1.75\"/>"
          "</svg>")
  "The mark of a port: a square, OpenSCAD's facets, turning into a circle, a field's curve.")

(defconst fms-keycaps-legends
  '(("cryptodancer.keycap" "A" "N:dot" "Esc" "F1"))
  "Keycap designs shown with some of their legends, as export-legends.py takes them.")

(defun fms-models (root site page original author &optional recursive)
  "The models in the directory ROOT, its files published at SITE.
Their pages are under PAGE in the gallery; with RECURSIVE, those of its
subdirectories too, their pages as deep.  Each model is a plist of
:file, :root, :site, :page, :title, its name, :original, the path in
the OpenSCAD collection that ORIGINAL, a function of its script, gives
for a port, or nil, and :author, a name and a link: `fms-author' for a
port of the collection, Rei's design, else AUTHOR."
  (when (file-directory-p root)
    (mapcar (lambda (file)
              (let ((from (funcall original file)))
                (list :file file
                      :root root
                      :site site
                      :page (concat page (file-name-sans-extension (file-relative-name file root)))
                      :title (file-name-base file)
                      :original from
                      :author (if from fms-author author))))
            (sort (if recursive
                      (directory-files-recursively root "\\.\\(?:keycap\\|fidget\\)\\'")
                    (directory-files root t "\\.\\(?:keycap\\|fidget\\)\\'"))
                  #'string<))))

(defun fms-example-summary (file)
  "The opening comment of the example FILE, as Org paragraphs."
  (with-temp-buffer
    (insert-file-contents file)
    ;; The licence line, and the empty line under it, are not the model's.
    (when (looking-at "// SPDX-License-Identifier: .*\n//\n")
      (goto-char (match-end 0)))
    (let (lines)
      (while (looking-at "// ?\\(.*\\)$")
        (push (match-string 1) lines)
        (forward-line))
      ;; Comments quote code in backticks, Org in equals signs.
      (replace-regexp-in-string "`\\([^`\n]+\\)`" "=\\1=" (string-join (nreverse lines) "\n")))))

(defun fms-model-summary (file)
  "The opening comment of the model FILE, its first paragraph without `fms-port-phrases'."
  (let* ((summary (fms-example-summary file))
         (end (or (string-search "\n\n" summary) (length summary)))
         (first (substring summary 0 end))
         (case-fold-search nil))
    (dolist (phrase fms-port-phrases)
      (setq first (replace-regexp-in-string phrase "" first t t)))
    (concat (string-trim-right first) (substring summary end))))

(defun fms-first-sentence (text)
  "The first sentence of TEXT, on one line."
  (let ((text (string-join (split-string text "[ \t\n]+" t) " ")))
    (if (string-match "\\.\\(?: \\|\\'\\)" text)
        (concat (substring text 0 (match-beginning 0)) ".")
      text)))

(defun fms-example-files (model report)
  "The files of MODEL's source that its `load' REPORT read, besides itself."
  (sort (seq-filter (lambda (read) (file-in-directory-p read (plist-get model :root)))
                    (alist-get 'files report))
        #'string<))

(defun fms-tall-p (report)
  "Non-nil when the model of the `load' REPORT is at least a quarter as tall as it is wide.
The fitted bounds count when they close every side, else the script's own;
a model bounded by neither is not tall."
  (let* ((bounds (alist-get 'bounds report))
         (closed (lambda (region)
                   (and region
                        (seq-every-p #'numberp (append (alist-get 'lower region)
                                                       (alist-get 'upper region)
                                                       nil))
                        region)))
         (region (or (funcall closed (alist-get 'fitted bounds))
                     (funcall closed (alist-get 'script bounds)))))
    (when region
      (pcase-let ((`(,x0 ,y0 ,z0) (alist-get 'lower region))
                  (`(,x1 ,y1 ,z1) (alist-get 'upper region)))
        (>= (* 4 (- z1 z0)) (max (- x1 x0) (- y1 y0)))))))

(defun fms-render (file &rest arguments)
  "A keycap block of the script FILE showing only its image, with header ARGUMENTS."
  (format "#+begin_src keycap :open %s :frame no :exports results %s\n#+end_src\n\n"
          file (string-join arguments " ")))

;; A picture's view is set by hand in the source, as settings apart by
;; commas: `camera 120 30' (or front, right, top, iso), a view of the
;; preview's, `shaded', `heightmap', `sdf' or `mono', `slice z 5', and
;; `NAME = VALUE', another value for the script's top-level `const NAME',
;; written as JSON writes it, which is how Rhai writes numbers, strings,
;; booleans and arrays.
;; A model's `// view: ...' lines give its pictures, the first its card's;
;; `// view LABEL: ...' captions its picture with LABEL, such as one of the
;; design's variants.  An example's ` [view: ...]', at the end of its
;; `Example:' line, gives its own.

(defun fms-view-settings (view)
  "The settings of VIEW: its text apart by the commas outside brackets and strings."
  (with-temp-buffer
    (with-syntax-table (make-syntax-table)
      (insert view)
      (goto-char (point-min))
      (let ((start (point))
            settings)
        (while (search-forward "," nil t)
          (let ((state (syntax-ppss)))
            (unless (or (> (car state) 0) (nth 3 state))
              (push (buffer-substring start (1- (point))) settings)
              (setq start (point)))))
        (push (buffer-substring start (point-max)) settings)
        (seq-remove #'string-empty-p (mapcar #'string-trim (nreverse settings)))))))

(defun fms-view-arguments (view)
  "The keycap block's header arguments for VIEW, settings apart by commas."
  (let (overrides arguments)
    (dolist (setting (fms-view-settings view))
      (pcase (split-string setting)
        ((guard (string-match "\\`\\([[:alpha:]_][[:alnum:]_]*\\) *= *\\(.+\\)\\'" setting))
         (push (cons (intern (match-string 1 setting))
                     (json-parse-string (match-string 2 setting) :array-type 'array :false-object nil))
               overrides))
        (`("camera" . ,rest) (push (format ":camera \"%s\"" (string-join rest " ")) arguments))
        (`("slice" . ,rest) (push (format ":slice \"%s\"" (string-join rest " ")) arguments))
        ((and `(,name) (guard (member name '("shaded" "heightmap" "sdf" "mono"))))
         (push (format ":view %s" name) arguments))
        (_ (error "No view setting %S" setting))))
    (when overrides
      (push (format ":set '%S" (nreverse overrides)) arguments))
    (string-join (nreverse arguments) " ")))

(defun fms-model-views (file)
  "The views the model FILE's `// view:' lines give, in order, each (LABEL . VIEW).
LABEL is nil for a line without one."
  (with-temp-buffer
    (insert-file-contents file)
    (cl-loop while (re-search-forward "^// view\\(?: \\([^:\n]+\\)\\)?:\\(.*\\)$" nil t)
             collect (cons (match-string 1) (string-trim (match-string 2))))))

(defun fms-up-from (page)
  "The way up from the gallery's PAGE to the site's root."
  (apply #'concat (make-list (1+ (cl-count ?/ page)) "../")))

(defun fms-credits (model &optional page)
  "HTML saying who made MODEL, whether it is a port, and where else it is.
For its PAGE, the author and the port's icon are links, the icon's to the original."
  (let ((author (plist-get model :author))
        (original (plist-get model :original))
        (printables (cdr (assoc (plist-get model :page) fms-printables))))
    (concat (cond ((not author) "")
                  (page (format "<span>by <a href=\"%s\">%s</a></span>" (cdr author) (car author)))
                  (t (format "<span>by %s</span>" (car author))))
            (cond ((not original) "")
                  (page (format "<a class=\"port\" href=\"%s%s\">%s<code>%s</code></a>"
                                fms-openscad original fms-port-icon (string-remove-prefix "src/" original)))
                  (t (format "<span class=\"port\">%s</span>" fms-port-icon)))
            (if printables
                (format "<a class=\"printables\" href=\"%s\">Printables</a>" printables)
              ""))))

(defun fms-write-model (model about details)
  "Write the gallery's page of MODEL.
ABOUT, an Org list of how it compares with its original, follows its
opening comment;
DETAILS, Org sections, its renders."
  (let* ((file (plist-get model :file))
         (name (plist-get model :title))
         (report (ob-keycap-load file))
         (summary (fms-model-summary file))
         (up (fms-up-from (plist-get model :page)))
         (page (fms-path "content" "gallery" (concat (plist-get model :page) ".org"))))
    (make-directory (file-name-directory page) t)
    (with-temp-file page
      (insert (format "#+title: %s\n" name)
              (format "#+description: %s\n\n" (fms-first-sentence summary))
              (let ((credits (fms-credits model t)))
                (if (string-empty-p credits)
                    ""
                  (format "#+html: <p class=\"credits\">%s</p>\n\n" credits)))
              summary "\n\n"
              ;; In a box, apart from a list the comment ends with.
              (if about (concat "#+attr_html: :class checked\n" about) "")
              (cond
               ((fms-model-views file)
                (mapconcat (pcase-lambda (`(,label . ,view))
                             (let ((render (fms-render file ":size \"800 600\"" (fms-view-arguments view)
                                                       (format ":alt %s, %s" name (or label view)))))
                               (if label
                                   (concat "#+html: <figure>\n" render
                                           (format "#+html: <figcaption>%s</figcaption></figure>\n"
                                                   (org-html-encode-plain-text label)))
                                 render)))
                           (fms-model-views file) ""))
               ((keycap-report-flat-p report)
                (concat (fms-render file ":size \"800 600\"" (format ":alt %s, its distance field" name))
                        (fms-render file ":size \"800 600\" :view mono"
                                    (format ":alt %s, inside and outside" name))))
               (t
                (concat (fms-render file ":size \"800 600\"" (format ":alt %s, shaded, from the front right" name))
                        (fms-render file ":size \"800 600\" :camera \"120 30\""
                                    (format ":alt %s, shaded, from the back left" name))
                        ;; A slice of a flat part shows little.
                        (when (fms-tall-p report)
                          (fms-render file ":size \"800 600\" :slice y"
                                      (format ":alt %s, its distance field on a slice across Y" name))))))
              (or details "")
              "* Files\n\n"
              (mapconcat (lambda (path)
                           (format "- [[file:%s%s%s][=%s=]]\n"
                                   up (plist-get model :site) (file-relative-name path (plist-get model :root))
                                   (file-relative-name path (file-name-directory file))))
                         (cons file (fms-example-files model report))
                         "")
              "\n* Source\n\n"
              "#+begin_src keycap :exports code\n"
              (org-escape-code-in-string (with-temp-buffer
                                           (insert-file-contents file)
                                           (buffer-string)))
              "#+end_src\n"))))

(defun fms-cards (models)
  "The cards of MODELS on the gallery's index, each a link to its page."
  (concat "#+html: <div class=\"cards\">\n"
          (mapconcat (lambda (model)
                       (let ((file (plist-get model :file))
                             (name (plist-get model :title)))
                         (concat "#+html: <div class=\"card\">\n"
                                 (fms-render file ":size \"480 360\""
                                             (if-let* ((view (car (fms-model-views file))))
                                                 (fms-view-arguments (cdr view))
                                               "")
                                             (format ":alt %s" name))
                                 ;; A long name like singer720_hook_drive_gear may
                                 ;; break after its underscores, not past the card.
                                 (format "#+html: <a class=\"card-name\" href=\"%s.html\">%s</a><p>%s</p>%s</div>\n"
                                         (plist-get model :page)
                                         (string-replace "_" "_<wbr>" name)
                                         (org-html-encode-plain-text
                                          (string-replace "=" "" (fms-first-sentence (fms-model-summary file))))
                                         (let ((credits (fms-credits model)))
                                           (if (string-empty-p credits)
                                               ""
                                             (format "<p class=\"credits\">%s</p>" credits)))))))
                     models "")
          "#+html: </div>\n\n"))

;; How Rei's ports, the keycaps among them, compare with their originals
;; is in PORTS.md, in Markdown.

(defun fms-markdown-org (text)
  "The Markdown TEXT as Org: code as verbatim, links as Org's, a relative one as its text."
  (replace-regexp-in-string
   "\\[\\([^]\n]+\\)\\](\\([^)\n]+\\))"
   (lambda (link)
     (if (string-match-p "\\`[a-z]+:" (match-string 2 link))
         (format "[[%s][%s]]" (match-string 2 link) (match-string 1 link))
       (match-string 1 link)))
   (replace-regexp-in-string "\\*\\*\\([^*\n]+\\)\\*\\*" "*\\1*"
                             (replace-regexp-in-string "`\\([^`\n]+\\)`" "=\\1=" text))
   t t))

(defun fms-markdown-table (file)
  "The rows of the first table in the Markdown FILE, each an alist of its header and cell."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (cl-flet ((cells () (mapcar #'string-trim
                                  (split-string (string-trim (string-trim (buffer-substring (point) (line-end-position)))
                                                             "|" "|")
                                                "|"))))
        (when (re-search-forward "^|" nil t)
          (beginning-of-line)
          (let ((headers (cells))
                rows)
            (forward-line 2)
            (while (looking-at-p "|")
              (push (cl-mapcar #'cons headers (cells)) rows)
              (forward-line))
            (nreverse rows)))))))

(defun fms-port-row (file)
  "The row of PORTS.md for the port FILE, an alist of its header and cell, or nil."
  (let ((port (file-relative-name file fms-designs)))
    (seq-find (lambda (row)
                (seq-some (lambda (cell) (string-search port (cdr cell))) row))
              (fms-markdown-table (expand-file-name "PORTS.md" fms-designs)))))

(defun fms-port-original (file)
  "The original of the port FILE: as PORTS.md names it, else by the port's own path."
  (let ((cell (or (cdr (assoc "Original" (fms-port-row file))) "")))
    (concat "src/"
            (if (string-match "[-_.[:alnum:]]+/[-_.[:alnum:]]+\\.scad" cell)
                (match-string 0 cell)
              (concat (file-name-sans-extension (file-relative-name file fms-designs))
                      ".scad")))))

(defun fms-port-about (model)
  "How the port MODEL compares with its original, as an Org list, if PORTS.md has its row."
  (let ((items (mapconcat (pcase-lambda (`(,header . ,cell))
                            (if (or (member header '("Original" "Port")) (string-empty-p cell))
                                ""
                              (format "- %s: %s\n" header (fms-markdown-org cell))))
                          (fms-port-row (plist-get model :file)) "")))
    (unless (string-empty-p items)
      (concat items "\n"))))

(defun fms-keycap-original (file)
  "The original of the keycap design FILE, as its opening comment names it, or nil."
  (let ((summary (fms-example-summary file)))
    (when (string-match "=\\(src/[^=\n]+\\.scad\\)=" summary)
      (match-string 1 summary))))

(defun fms-keycap-legends (model)
  "A section of renders of the keycap design MODEL with some of its legends, or nil."
  (when-let* ((file (plist-get model :file))
              (legends (cdr (assoc (file-name-nondirectory file) fms-keycaps-legends))))
    (concat "* Legends\n\n"
            "Some of the set, =SYMBOL= and =DOT= set for each as =export-legends.py= sets them.\n\n"
            "#+html: <div class=\"renders\">\n"
            (mapconcat
             (lambda (legend)
               (let* ((symbol (string-remove-suffix ":dot" legend))
                      (dot (not (equal symbol legend)))
                      (caption (format "%s%s" symbol (if dot ", with the dot" ""))))
                 (concat "#+html: <figure>\n"
                         (fms-render file ":size \"480 360\" :camera \"-70 20\""
                                     (format ":set '%S" `((SYMBOL . ,symbol) (DOT . ,dot)))
                                     (format ":alt %s, %s" (plist-get model :title) caption))
                         (format "#+html: <figcaption>%s</figcaption></figure>\n"
                                 (org-html-encode-plain-text caption)))))
             legends "")
            "#+html: </div>\n\n")))

(defun fms-design-groups ()
  "Rei's designs by group, each a directory of keycap-designs and its models, the keycaps first.
A group's designs are published at designs/GROUP/, and have their pages there in the gallery."
  (when fms-designs
    (let ((groups (sort (seq-filter (lambda (name) (file-directory-p (expand-file-name name fms-designs)))
                                    (directory-files fms-designs nil "\\`[^.]"))
                        #'string<)))
      (seq-filter #'cdr
                  (mapcar (lambda (group)
                            (let ((site (concat "designs/" group "/")))
                              (cons group
                                    (fms-models (expand-file-name group fms-designs) site site
                                                (if (equal group "keycaps") #'fms-keycap-original #'fms-port-original)
                                                fms-author))))
                          (if (member "keycaps" groups)
                              (cons "keycaps" (delete "keycaps" groups))
                            groups))))))

(defun fms-write-gallery ()
  "Write content/gallery/ from the models: their cards by source, and a page for each."
  (let ((directory (fms-path "content" "gallery"))
        (examples (fms-models (expand-file-name "examples" fms-keycap) "examples/" ""
                              (lambda (file) (cdr (assoc (file-name-base file) fms-example-originals)))
                              fms-examples-author))
        (designs (fms-design-groups)))
    (delete-directory directory t)
    (make-directory directory)
    (dolist (model examples)
      (fms-write-model model nil nil))
    (pcase-dolist (`(,group . ,models) designs)
      (dolist (model models)
        (if (equal group "keycaps")
            (fms-write-model model (fms-port-about model) (fms-keycap-legends model))
          (fms-write-model model (fms-port-about model) nil))))
    (with-temp-file (expand-file-name "index.org" directory)
      (insert "#+title: Gallery\n"
              "#+description: Models made in keycap, with their source: its examples and my own designs.\n\n"
              "Everything here is rendered by keycap's preview when the site is built.\n"
              "Each model is a script that you can download and open in Emacs.\n\n"
              (format "@@html:<span class=\"port\">%s</span>@@ marks a port of one of [[%s][my OpenSCAD designs]]; its page links to the original.\n\n"
                      fms-port-icon (string-remove-suffix "blob/main/" fms-openscad)))
      (when examples
        (insert "* Examples\n\n"
                "The examples that come with keycap, most of them ports of my general designs.\n\n"
                (fms-cards examples)))
      (when designs
        (insert "* My designs\n\n"
                "Made for something specific of mine.\n\n"))
      (pcase-dolist (`(,group . ,models) designs)
        (insert (format "** %s\n\n" (capitalize group))
                (if (equal group "keycaps")
                    (concat "My keycaps.\n"
                            "The designs share a library, =keycap.rhai=, which each of them imports.\n\n")
                  "")
                (fms-cards models))))))


;; --- Manual ---

;; keycap's manual is one Org file, as Info needs it, its reference
;; written by keycap-reference.el from the server's docs.  The site splits
;; it at its chapters into content/manual/, written afresh on every build,
;; and adds an index page: the contents, and every function, key and
;; concept.  Each heading and function keeps the anchor it had when the
;; manual was a single page: on its own page, and on the index, as a link
;; to that page.
;;
;; A function that makes a shape gets a picture of its example, floating
;; beside its entry: the code block in the entry, or else the first
;; `Example:' of its doc that is not a value, added to the entry as code.
;; Easings and steps get their graph instead.
;;
;; An entry set out as the reference's entries are -- its parameters, its
;; behaviour, and its parts, `Notes:', `See also:', `References:', `From
;; OpenSCAD:' and `Example:' with a caption and a code block -- has its
;; parts in quieter boxes, and its example in a box of its own with the
;; picture, or with its value when it makes no shape.  Its signatures
;; head it, set out by keycap as C-c C-d sets them out.
;;
;; Each entry is beside a strip in the colour of its kind, what it makes,
;; as the file that describes it declares it, and starts with that and
;; where it comes from as a label; its section's mark has the colour too.
;; Reading signatures ends with their legend.

(load (expand-file-name "doc/keycap-reference.el" fms-keycap) nil t)

(defconst fms-manual-docs (keycap-docs 'keycap)
  "The keycap server's `docs' reply, which the reference is written from.")

(defconst fms-manual-table (keycap-reference-entries fms-manual-docs)
  "Every entry of the reference, by name.")

(defun fms-manual-entry (name)
  "The reference's entry of NAME, from the server's docs, or nil."
  (gethash name fms-manual-table))

(defvar fms-manual-section-kinds (make-hash-table :test #'equal)
  "The kind of each reference section's entries, by its anchor.")

(defun fms-manual-origin (name)
  "Where NAME comes from: \"fidget\", \"keycap\" or \"rhai\", or nil when unknown."
  (when-let* ((entry (fms-manual-entry name)))
    (if (alist-get 'fields entry)
        "fidget"
      (pcase (alist-get 'source entry)
        ("fidget" "fidget")
        ((or "prelude" "keycap" "module") "keycap")
        ("rhai" "rhai")))))

(defconst fms-manual-legend
  (concat
   "On this site, the strip beside an entry says what it makes; its label says that, and where it comes from.\n\n"
   "#+html: <dl class=\"legend\">"
   (mapconcat
    (pcase-lambda (`(,kind ,label ,text))
      (format "<div class=\"entry k-%s\"><dt>%s</dt><dd>%s</dd></div>" kind label text))
    keycap-kinds "")
   (mapconcat
    (pcase-lambda (`(,origin . ,text))
      (format "<div class=\"entry\"><dt>%s</dt><dd>%s</dd></div>" origin text))
    '(("fidget" . "fidget’s own, in its viewer and CLI too")
      ("keycap" . "keycap’s, from its prelude or its script API"))
    "")
   "</dl>\n")
  "What the strips and labels of the reference's entries mean, for Reading signatures.")

(defconst fms-manual-unpictured
  '("and"                               ; 0 or 5, no surface
    "mix"                               ; rand's example
    "svg")                              ; needs a file beside the script
  "Functions whose examples are no shape worth a picture, or need a file; their boxes have code only.")

(defconst fms-manual-plots
  '(("sin" "y - 8 * sin(x / 4)" "[-16, -12]" "[16, 12]")
    ("floor" "y - 4 * floor(x / 4)" "[-16, -12]" "[16, 12]")
    ("linstep" "y - 20 * linstep(0, 20, x)")
    ("smoothstep" "y - 20 * smoothstep(0, 20, x)")
    ("smootherstep" "y - 20 * smootherstep(0, 20, x)")
    ("ease_in_sine" "y - 20 * ease_in_sine(x / 20)")
    ("ease_out_sine" "y - 20 * ease_out_sine(x / 20)")
    ("ease_in_out_sine" "y - 20 * ease_in_out_sine(x / 20)")
    ("ease_in_asine" "y - 20 * ease_in_asine(x / 20)")
    ("ease_out_asine" "y - 20 * ease_out_asine(x / 20)")
    ("ease_in_out_asine" "y - 20 * ease_in_out_asine(x / 20)")
    ("ease_in_quadratic" "y - 20 * ease_in_quadratic(x / 20)")
    ("ease_out_quadratic" "y - 20 * ease_out_quadratic(x / 20)")
    ("ease_in_out_quadratic" "y - 20 * ease_in_out_quadratic(x / 20)")
    ("ease_in_cubic" "y - 20 * ease_in_cubic(x / 20)")
    ("ease_out_cubic" "y - 20 * ease_out_cubic(x / 20)")
    ("ease_in_out_cubic" "y - 20 * ease_in_out_cubic(x / 20)")
    ("ease_in_pow" "y - 20 * ease_in_pow(x / 20, 4)")
    ("ease_out_pow" "y - 20 * ease_out_pow(x / 20, 4)")
    ("ease_in_out_pow" "y - 20 * ease_in_out_pow(x / 20, 4)")
    ("ease_in_elastic" "y - 20 * ease_in_elastic(x / 20)")
    ("ease_out_elastic" "y - 20 * ease_out_elastic(x / 20)")
    ("ease_in_out_elastic" "y - 20 * ease_in_out_elastic(x / 20)")
    ("ease_in_bounce" "y - 20 * ease_in_bounce(x / 20)")
    ("ease_out_bounce" "y - 20 * ease_out_bounce(x / 20)")
    ("ease_in_out_bounce" "y - 20 * ease_in_out_bounce(x / 20)")
    ("ease" "y - 20 * ease(\"in_out_cubic\", x / 20)")
    ("keyframes" "y - keyframes(x, [[0, 30], [25, 50, \"out_quadratic\"], [75, 40, \"in_out_sine\"]])"
     "[-10, -5]" "[85, 65]"))
  "Functions of a number shown by their graph too, inside below the curve, in an example box of its own.
Each is (NAME EXPRESSION [LOWER UPPER]), bounded from LOWER to UPPER
in X and Y, by default from (-5, -8) to (25, 28).")

(defun fms-manual-anchor (name n)
  "The anchor of the Nth entry of NAME, counting from 1: fn-NAME, then fn-NAME-2.
A module's function, `screws::hole', is fn-screws-hole."
  (format "fn-%s%s"
          (mapconcat (lambda (c)
                       (or (alist-get c '((?+ . "plus") (?% . "percent") (?< . "less") (?> . "greater")))
                           (string c)))
                     (string-replace "::" "-" name) "")
          (if (> n 1) (format "-%d" n) "")))

(defconst fms-manual-retired-anchors
  (append
   '(("fn-plane-2" . "fn-plane")
     ("fn-draw-2" . "fn-draw"))
   (mapcar (lambda (name) (cons (fms-manual-anchor name 1) "fn-PI"))
           '("TAU" "E" "PHI" "GOLDEN_RATIO" "SQRT_2" "FRAC_1_SQRT_2" "FRAC_PI_2" "FRAC_PI_3"
             "FRAC_PI_4" "FRAC_PI_6" "FRAC_PI_8" "FRAC_1_PI" "FRAC_2_PI" "FRAC_2_SQRT_PI"
             "LN_2" "LN_10" "LOG2_E" "LOG10_E"))
   (mapcar (lambda (name) (cons (fms-manual-anchor name 1) (fms-manual-anchor "<" 1)))
           '("<=" ">" ">=" "==" "!=")))
  "Anchors of entries the manual no longer has, and the entries that took them in.
`plane''s Plane value is in its shape's entry, `draw''s options in its one entry,
the constants are `PI''s aliases and the comparison operators `<''s.")

(defun fms-manual-draws-p (code)
  "Non-nil when CODE draws at its top level."
  (with-temp-buffer
    (insert code)
    (keycap-script-draws)))

(defun fms-manual-statements (code)
  "CODE's statements, each with the comments before it, then its last expression."
  (with-temp-buffer
    (insert code)
    (let ((start (point-min)))
      (mapcar (pcase-lambda (`(,_ . ,end))
                (prog1 (string-trim (buffer-substring-no-properties start end))
                  (setq start end)))
              (keycap-script-statements)))))

(defun fms-manual-draw (code)
  "CODE with its last expression drawn, unless it draws itself."
  (if (fms-manual-draws-p code)
      code
    (let ((statements (fms-manual-statements code)))
      (string-join (append (butlast statements)
                           (list (format "draw(%s);" (car (last statements)))))
                   "\n"))))

(defconst fms-manual-imports
  (mapconcat (lambda (section)
               (format "import \"keycap/%s\" as %s;\n"
                       (file-name-base (alist-get 'file section)) (alist-get 'module section)))
             (seq-filter (lambda (section) (alist-get 'module section))
                         (alist-get 'sections fms-manual-docs))
             "")
  "Every module of the prelude, imported as its section of the reference names it.")

(defun fms-manual-script (name code)
  "The script that draws CODE, the example of NAME: with the modules, for a module's."
  (concat (when (equal (alist-get 'source (fms-manual-entry name)) "module")
            fms-manual-imports)
          (fms-manual-draw code)))

(defvar fms-manual-values (make-hash-table :test #'equal)
  "The value of each example's code, as the server describes it.")

(defun fms-manual-evaluate (codes)
  "Keep the values of CODES, the examples' code, in `fms-manual-values'.
One server evaluates them all, with every module imported."
  (seq-mapn (lambda (code reply)
              (puthash code (alist-get 'value reply) fms-manual-values))
            codes
            (keycap-server-batch (mapcar (lambda (code)
                                           `((op . "eval")
                                             (source . ,fms-manual-imports)
                                             (expression . ,code)))
                                         codes))))

(defun fms-manual-shape-p (code)
  "Non-nil when the example CODE draws or makes a shape, as far as is known.
A tree with nothing inside, such as a factor, is no shape."
  (let ((value (gethash code fms-manual-values)))
    (or (fms-manual-draws-p code)
        (not value)
        (and (string-prefix-p "tree:" value)
             (not (string-suffix-p "; empty" value))))))

(defun fms-manual-value (code)
  "The value of the example CODE, as the box shows it."
  (string-remove-suffix "; empty" (gethash code fms-manual-values)))

(defun fms-manual-sentence (text)
  "TEXT with a capital first letter."
  (if (string-empty-p text)
      text
    (concat (upcase (substring text 0 1)) (substring text 1))))

(defconst fms-manual-example-size "\"480 360\""
  "The size of an example box's picture, twice as large as it is shown.")

(defconst fms-manual-example-columns 42
  "The longest line of code that fits beside an example's picture.
An example with a longer one has its picture below the code instead.")

(defun fms-manual-signature-html (text)
  "TEXT, highlighted by keycap, as HTML: its faces as htmlize's classes.
Each run with the property `keycap-parameter' is a span of the class p."
  (let ((start 0)
        html)
    (while (< start (length text))
      (let* ((end (next-single-property-change start 'keycap-parameter text (length text)))
             (part (substring text start end))
             (runs (let ((at 0)
                         runs)
                     (while (< at (length part))
                       (let* ((next (next-single-property-change at 'face part (length part)))
                              (face (get-text-property at 'face part))
                              (run (org-html-encode-plain-text (substring-no-properties part at next))))
                         (push (if (and face (symbolp face))
                                   (format "<span class=\"hl-%s\">%s</span>"
                                           (string-remove-suffix
                                            "-face" (string-remove-prefix "font-lock-" (symbol-name face)))
                                           run)
                                 run)
                               runs)
                         (setq at next)))
                     (apply #'concat (nreverse runs)))))
        (push (if (get-text-property start 'keycap-parameter text)
                  (format "<span class=\"p\">%s</span>" runs)
                runs)
              html)
        (setq start end)))
    (apply #'concat (nreverse html))))

(defun fms-manual-signature (name)
  "NAME's signatures and types as keycap sets them out, as HTML on one line.
Each line is a span, its indentation and keycap's `wrap-prefix' as
properties, so that a line too long for the page wraps at a parameter,
the rest as far in as that.  Nil when it has none."
  (when-let* ((entry (fms-manual-entry name))
              (signatures (alist-get 'signatures entry)))
    (concat "<code class=\"sig\">"
            (mapconcat (lambda (line)
                         (let ((text (string-trim-left line)))
                           (if (string-empty-p text)
                               "<span class=\"sig-gap\"></span>"
                             (format "<span style=\"--indent: %d; --hang: %d\">%s</span>"
                                     (- (length line) (length text))
                                     (length (get-text-property 0 'wrap-prefix line))
                                     (fms-manual-signature-html text)))))
                       (split-string (keycap-set-out-signatures signatures (alist-get 'types entry)) "\n")
                       "")
            "</code>")))

(defun fms-manual-plain (text)
  "TEXT without Org's markup for code."
  (replace-regexp-in-string "[=~]\\([^=~\n]+\\)[=~]" "\\1" text))

(defconst fms-manual-example-regexp
  (concat "^\\([ \t]*\\)Example:\\(?: \\(.*\\)\\)?\n"
          "[ \t]*#\\+begin_src rhai\n\\(\\(?:.\\|\n\\)*?\\)[ \t]*#\\+end_src\n")
  "An entry's example: its indentation, its caption and its code.")

(defconst fms-manual-parts
  '(("Notes" . "part quiet")
    ("See also" . "part")
    ("References" . "part")
    ("From OpenSCAD" . "part quiet"))
  "The parts of an entry boxed apart from its text, and their classes.")

(defun fms-manual-box (name model caption code &optional script view)
  "An example box, as Org: CAPTION, CODE beside its picture, MODEL the picture's name.
NAME's examples are drawn with its module imported; SCRIPT, if any, is
drawn instead of CODE.  VIEW, as `fms-view-arguments' takes it, sets
the picture's view.  An example of no shape has its value in the
picture's place, one of `fms-manual-unpictured' only its code."
  (let ((value (unless (or script (fms-manual-shape-p code))
                 (fms-manual-value code)))
        (pictured (or script (not (member name fms-manual-unpictured)))))
    (concat (format "#+html: <figure class=\"example%s\"><figcaption><span>Example</span>\n"
                    (if (or value (not pictured)
                            (> (apply #'max (mapcar #'string-width (split-string code "\n")))
                               fms-manual-example-columns))
                        " wide"
                      ""))
            (fms-manual-sentence caption) "\n"
            "#+html: </figcaption><div class=\"example-code\">\n"
            "#+begin_src rhai\n" (org-escape-code-in-string code) "\n#+end_src\n"
            (cond
             (value
              (format "#+html: </div><div class=\"example-value\"><code>%s</code>\n"
                      (org-html-encode-plain-text value)))
             (pictured
              (concat "#+html: </div><div class=\"example-pic\">\n"
                      (format "#+begin_src keycap :model %s :frame no :exports results :size %s %s :alt %s\n"
                              model fms-manual-example-size
                              (if view (fms-view-arguments view) "")
                              (fms-manual-sentence (fms-manual-plain caption)))
                      (org-escape-code-in-string (or script (fms-manual-script name code))) "\n"
                      "#+end_src\n")))
            "#+html: </div></figure>\n")))

(defun fms-manual-box-examples (name model begin end)
  "Box every example between BEGIN and END, as `fms-manual-box' does, NAME's if any.
Their pictures are MODEL, MODEL-2 and on; END is a marker."
  (save-excursion
    (goto-char begin)
    (let ((n 0))
      (while (re-search-forward fms-manual-example-regexp end t)
        (let ((start (match-beginning 0))
              (indent (match-string 1))
              (caption (or (match-string 2) ""))
              (code (string-trim (org-remove-indentation (match-string 3))))
              view)
          ;; The picture's view, set by hand at the caption's end
          (when (string-match " *\\[view: \\([^]\n]+\\)\\]\\'" caption)
            (setq view (match-string 1 caption)
                  caption (substring caption 0 (match-beginning 0))))
          (delete-region start (point))
          (insert (replace-regexp-in-string
                   "^\\(.\\)" (concat indent "\\1")
                   (fms-manual-box name (format "%s%s" model (if (> (cl-incf n) 1) (format "-%d" n) ""))
                                   caption code nil view))))))))

(defun fms-manual-set-out (name anchor begin end)
  "Box the parts and the examples of NAME's entry ANCHOR, between BEGIN and END.
END is a marker, kept after what is added; a function of a number gets
a box of its graph too."
  (save-excursion
    (fms-manual-box-examples name anchor begin end)
    (when-let* ((plot (assoc name fms-manual-plots)))
      (pcase-let* ((`(,_ ,expression ,lower ,upper) plot)
                   (indent (progn (goto-char begin) (make-string (+ 2 (current-indentation)) ?\s))))
        (goto-char end)
        (insert "\n" (replace-regexp-in-string
                      "^\\(.\\)" (concat indent "\\1")
                      (fms-manual-box name (concat anchor "-graph")
                                      (format "the graph of ~%s~, inside below the curve" name)
                                      expression
                                      (format "bounds(%s, %s);\ndraw(%s);"
                                              (string-replace "]" ", -1]" (or lower "[-5, -8]"))
                                              (string-replace "]" ", 1]" (or upper "[25, 28]"))
                                              expression))))))
    (fms-manual-box-parts begin end)))

(defun fms-manual-box-parts (begin end)
  "Box every part between BEGIN and END, `Notes:' and the others of `fms-manual-parts'.
END is a marker.  A part is its lead and the list or the text after it."
  (save-excursion
    (pcase-dolist (`(,lead . ,class) fms-manual-parts)
      (goto-char begin)
      (while (re-search-forward (concat "^\\([ \t]*\\)" lead ":\\(?: \\|\n\\)"
                                        "\\(?:.*\n\\)\\(?:\\1\\(?:- \\|  \\|[^ \t\n]\\).*\n\\)*")
                                end t)
        (let ((indent (match-string 1))
              (part-end (copy-marker (match-end 0))))
          (goto-char (match-beginning 0))
          (looking-at (concat "[ \t]*" lead ":\\(\n\\| \\)"))
          ;; The lead as the box's label; a text after it starts the box.
          (replace-match (concat indent (format "#+html: <div class=\"%s\"><span>%s</span>\n" class lead)
                                 (if (equal (match-string 1) " ") indent ""))
                         t t)
          (goto-char part-end)
          (insert indent "#+html: </div>\n"))))))

(defun fms-manual-section ()
  "The anchors of the heading point is under and of its chapter, as a cons."
  (save-excursion
    (org-back-to-heading t)
    (let ((section (org-entry-get nil "CUSTOM_ID")))
      (while (org-up-heading-safe))
      (cons section (org-entry-get nil "CUSTOM_ID")))))

(defun fms-manual-entries ()
  "Read the manual in the current buffer for its entries; give them anchors and pictures.
Return (ENTRIES KEYS CONCEPTS): each entry a plist of :name, :anchor,
:section, :aliases, the names its `#+findex' lines add, and :position,
which a command only `#+findex' names lacks, its anchor its section's;
each key and concept as (TEXT . SECTION)."
  (let ((counts (make-hash-table :test #'equal))
        entries keys concepts)
    (goto-char (point-min))
    (while (re-search-forward
            (concat "^\\(?:[ \t]*- \\(?:\\(Function\\|Variable\\|Macro\\): \\([^ \t\n]+\\)"
                    "\\|Key: \\(.+?\\) ::\\)"
                    "\\|#\\+\\(findex\\|cindex\\): \\(.+\\)\\)")
            nil t)
      (let ((section (save-match-data (car (fms-manual-section)))))
        (cond
         ((match-beginning 1)
          (let ((name (match-string-no-properties 2)))
            (push (list :name name
                        :anchor (fms-manual-anchor name (cl-incf (gethash name counts 0)))
                        :section section
                        :position (copy-marker (line-beginning-position)))
                  entries)))
         ((match-beginning 3)
          (push (cons (match-string-no-properties 3) section) keys))
         ((equal (match-string 4) "findex")
          (let ((name (match-string-no-properties 5)))
            (if (and entries (equal (plist-get (car entries) :section) section))
                (setf (plist-get (car entries) :aliases)
                      (append (plist-get (car entries) :aliases) (list name)))
              ;; A command the text names, indexed as its section.
              (push (list :name name :anchor section :section section) entries))))
         (t
          (push (cons (match-string-no-properties 5) section) concepts)))))
    ;; Every example's value first, so that one that makes no shape shows
    ;; its value instead of a picture.
    (fms-manual-evaluate
     (delete-dups (save-excursion
                    (goto-char (point-min))
                    (cl-loop while (re-search-forward fms-manual-example-regexp nil t)
                             collect (string-trim (org-remove-indentation
                                                   (match-string-no-properties 3)))))))
    ;; From the last, so that what is added leaves the entries before it in place.
    (dolist (entry (seq-filter (lambda (entry) (plist-get entry :position)) entries))
      (goto-char (plist-get entry :position))
      (skip-chars-forward " \t")
      (let* ((item (org-element-lineage (save-excursion (forward-char 2) (org-element-at-point))
                                        '(item) t))
             (end (copy-marker (org-element-property :contents-end item) t))
             (name (plist-get entry :name))
             (anchor (plist-get entry :anchor))
             (kind (alist-get 'kind (fms-manual-entry name))))
        (when kind
          (puthash (plist-get entry :section) kind fms-manual-section-kinds))
        (fms-manual-set-out name anchor (point) end)
        ;; Where the anchor goes on the entry's <dt>, with its kind and
        ;; origin, see `fms-manual-anchors'; and the signatures, in place
        ;; of the name.
        (forward-char 2)
        (let ((signature (fms-manual-signature name)))
          (when signature
            (delete-region (point) (save-excursion (search-forward " ::") (match-beginning 0))))
          (insert (format "@@html:<!--%s %s %s-->%s@@"
                          anchor
                          (or kind "-")
                          (or (fms-manual-origin name) "-")
                          (or signature ""))))))
    ;; The hand-written chapters' examples are boxed as the entries' are,
    ;; their pictures named after their sections.
    (let ((counts (make-hash-table :test #'equal)))
      (goto-char (point-min))
      (while (re-search-forward fms-manual-example-regexp nil t)
        (let* ((section (save-match-data (car (fms-manual-section))))
               (n (cl-incf (gethash section counts 0))))
          (fms-manual-box-examples nil (format "ex-%s%s" section (if (> n 1) (format "-%d" n) ""))
                                   (match-beginning 0) (copy-marker (match-end 0) t))))
      ;; And their parts, the entries' being boxed already.
      (fms-manual-box-parts (point-min) (copy-marker (point-max) t)))
    (list (nreverse entries) (nreverse keys) (nreverse concepts))))

(defun fms-manual-anchors (html _backend _info)
  "Anchor each entry of the manual in HTML where its marker is.
Its <dt> and <dd> are of the class entry, and of its kind's, and its
<dt> starts with the labels of its kind and origin, and a link to the
entry; its signatures stay text to select.  An entry shown by its
signatures is of the class sig too."
  (replace-regexp-in-string
   (concat "<dt><!--\\(fn-[^ >]+\\) \\([^ >]+\\) \\([^ >]+\\)-->"
           "\\(\\(<code class=\"sig\">\\)?\\(?:.\\|\n\\)*?\\)</dt>\\(<dd>\\)?")
   (lambda (match)
     (let* ((anchor (match-string 1 match))
            (kind (unless (equal (match-string 2 match) "-") (match-string 2 match)))
            (origin (unless (equal (match-string 3 match) "-") (match-string 3 match)))
            (class (concat "entry" (if kind (format " k-%s" kind) ""))))
       (format "<dt id=\"%s\" class=\"%s%s\"><span class=\"label\">%s<a class=\"permalink\" href=\"#%s\" aria-label=\"Link to this entry\">#</a></span>%s</dt>%s"
               anchor class (if (match-beginning 5) " sig" "")
               (string-join (delq nil (list (when kind
                                              (format "<span class=\"kind\">%s</span>"
                                                      (cadr (assoc kind keycap-kinds))))
                                            (pcase origin
                                              ("rhai" "Rhai")
                                              (_ origin))))
                            " · ")
               anchor
               (if (match-beginning 5)
                   (match-string 4 match)
                 ;; The Texinfo line, without the kind the label gives.
                 (replace-regexp-in-string
                  "\\`\\(?:Function\\|Variable\\|Macro\\): \\([^ ]+\\)"
                  "<span class=\"hl-function-name\">\\1</span>" (match-string 4 match)))
               (if (match-beginning 6) (format "<dd class=\"%s\">" class) ""))))
   html t t))

(defun fms-manual-mark-kinds (html _backend _info)
  "Mark each reference section in HTML, and each item of a list that links to one, with its kind."
  (replace-regexp-in-string
   (concat "<section id=\"outline-container-\\([^\"]+\\)\" class=\"outline-2\""
           "\\|<\\(li\\|dt\\)>\\(\\(?:<span id=\"[^\"]+\"></span>\\)?<a href=\"[^\"#]*#\\([^\"]+\\)\"\\)")
   (lambda (match)
     (let ((kind (gethash (or (match-string 1 match) (match-string 4 match)) fms-manual-section-kinds)))
       (cond
        ((not kind) match)
        ((match-beginning 1)
         (format "<section id=\"outline-container-%s\" class=\"outline-2 k-%s\""
                 (match-string 1 match) kind))
        (t
         (format "<%s class=\"k-%s\">%s" (match-string 2 match) kind (match-string 3 match))))))
   html t t))

(add-to-list 'org-export-filter-final-output-functions #'fms-manual-mark-kinds)

(add-to-list 'org-export-filter-final-output-functions #'fms-manual-anchors)

(defun fms-manual-link (target title chapter)
  "An Org link to TARGET, a heading's (ID CHAPTER-ID), titled TITLE, from the page CHAPTER."
  (pcase-let ((`(,id ,page) target))
    (cond
     ((equal id page) (format "[[file:%s.org][%s]]" page title))
     ((equal page chapter) (format "[[#%s][%s]]" id title))
     (t (format "[[file:%s.org::#%s][%s]]" page id title)))))

(defun fms-manual-nav (chapters current)
  "The manual's own navigation: the index and CHAPTERS, (ID TITLE) each, the page CURRENT marked."
  (concat "#+html: <nav class=\"manual-nav\" aria-label=\"Manual\"><ol>"
          (mapconcat (pcase-lambda (`(,id ,title))
                       (format "<li><a href=\"%s.html\"%s>%s</a></li>"
                               id (if (equal id current) " aria-current=\"page\"" "")
                               (org-html-encode-plain-text title)))
                     (cons '("index" "Contents") chapters) "")
          "</ol></nav>\n"))

;; The contents at the top of a chapter's page list its sections; the
;; manual's own contents are the index page.  Only the manual's pages
;; have a table of contents, so Org's title for them all can change.
(push '("Table of Contents" ("en" :default "In this chapter")) org-export-dictionary)

(defun fms-manual-chapter (chapter previous next chapters targets)
  "Write the page of CHAPTER, (ID TITLE DESCRIPTION TEXT), between PREVIOUS and NEXT.
CHAPTERS are every page's (ID TITLE), TARGETS every heading's (TITLE ID CHAPTER-ID)."
  (pcase-let* ((`(,id ,title ,description ,text) chapter)
               ;; The chapter's sections are the page's top level.
               (body (replace-regexp-in-string
                      "^\\*\\(\\*+ \\)" "\\1"
                      (replace-regexp-in-string
                       "\\[\\[\\*\\([^]]+\\)\\]\\(?:\\[\\([^]]+\\)\\]\\)?\\]"
                       (lambda (link)
                         (let ((heading (match-string 1 link)))
                           (fms-manual-link (or (cdr (assoc heading targets))
                                                (error "The manual links to no heading %s" heading))
                                            (or (match-string 2 link) heading)
                                            id)))
                       text t t)))
               (first (string-match "^\\* " body)))
    ;; The page's contents go after the chapter's opening text, when it
    ;; has two sections or more.
    (when (and first (string-match "\n\\* " body first))
      (setq body (concat (substring body 0 first) "#+toc: headlines 2\n\n" (substring body first))))
    (with-temp-file (fms-path "content" "manual" (concat id ".org"))
      (insert (format "#+title: %s\n" title)
              (format "#+description: %s\n" (or description ""))
              (format "#+html_head_extra: <link rel=\"prev\" href=\"%s.html\">\n" (car previous))
              (if next (format "#+html_head_extra: <link rel=\"next\" href=\"%s.html\">\n" (car next)) "")
              "\n"
              (fms-manual-nav chapters id)
              body
              "\n"
              "#+html: " (fms-pager previous '("index" "Contents") next) "\n"))))

(defun fms-write-manual ()
  "Write content/manual/ from keycap's manual: a page per chapter, and the index."
  (let ((directory (fms-path "content" "manual"))
        headings chapters)
    (delete-directory directory t)
    (make-directory directory)
    (with-temp-buffer
      (insert-file-contents (expand-file-name "doc/keycap.org" fms-keycap))
      (keycap-reference-expand 'html fms-manual-docs)
      (delay-mode-hooks (org-mode))
      (fms-name-headings nil)
      ;; The legend of the entries' strips ends Reading signatures.
      (when-let* ((heading (org-find-property "CUSTOM_ID" "reading-signatures")))
        (save-excursion
          (goto-char heading)
          (org-end-of-subtree t t)
          (insert fms-manual-legend "\n")))
      ;; Its tables are map tables, OpenSCAD's names to keycap's.
      (dolist (table (reverse (org-element-map (org-element-parse-buffer 'element) 'table #'identity)))
        (goto-char (org-element-property :post-affiliated table))
        (insert (make-string (current-indentation) ?\s) "#+attr_html: :class map\n"))
      ;; Signatures in the text are set out as the entries' are.
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward (concat "^\\([ \t]*\\)#\\+begin_src keycap-signature\n"
                                          "\\(\\(?:.\\|\n\\)*?\\)[ \t]*#\\+end_src")
                                  nil t)
          (let* ((indent (match-string 1))
                 (start (match-beginning 2))
                 (lines (split-string (delete-and-extract-region start (match-end 2))
                                      "\n" t "[ \t]+"))
                 (types (seq-filter (lambda (line) (string-prefix-p "type " line)) lines)))
            (goto-char start)
            (insert (replace-regexp-in-string
                     "^\\(.\\)" (concat indent "\\1")
                     (concat (substring-no-properties
                              (keycap-set-out-signatures (seq-difference lines types) types))
                             "\n"))))))
      (pcase-let ((`(,entries ,keys ,concepts) (fms-manual-entries))
                  (subtitle (cadar (org-collect-keywords '("SUBTITLE")))))
        (org-map-entries
         (lambda ()
           (let ((id (org-entry-get nil "CUSTOM_ID"))
                 (title (org-get-heading t t t t)))
             (push (list (org-current-level) title id (cdr (fms-manual-section))) headings)
             (when (and (= (org-current-level) 1) (not (org-entry-get nil "INDEX")))
               (push (list id title (org-entry-get nil "DESCRIPTION")
                           (let ((end (save-excursion (org-end-of-subtree t t))))
                             (save-excursion
                               (org-end-of-meta-data)
                               (buffer-substring-no-properties (point) end))))
                     chapters)))))
        (setq headings (nreverse headings)
              chapters (nreverse chapters))
        (let ((targets (mapcar #'cdr headings))
              (pages (mapcar (lambda (chapter) (list (car chapter) (cadr chapter))) chapters)))
          (cl-loop for (previous chapter next) on (cons '("index" "Contents") chapters)
                   while chapter
                   do (fms-manual-chapter chapter (list (car previous) (cadr previous))
                                          (when next (list (car next) (cadr next)))
                                          pages targets))
          (fms-write-manual-index subtitle headings pages entries keys concepts))))))

(defun fms-write-manual-index (subtitle headings chapters entries keys concepts)
  "Write the manual's index page, under SUBTITLE.
It lists HEADINGS, (LEVEL TITLE ID CHAPTER-ID) each, ENTRIES, KEYS and
CONCEPTS, as `fms-manual-entries' returns them, and links to CHAPTERS."
  (let* ((heading (lambda (section) (seq-find (lambda (h) (equal (nth 2 h) section)) headings)))
         (title (lambda (section) (nth 1 (funcall heading section))))
         (link (lambda (section anchor text)
                 (let ((chapter (nth 3 (funcall heading section))))
                   (if (equal anchor chapter)
                       (format "[[file:%s.org][%s]]" chapter text)
                     (format "[[file:%s.org::#%s][%s]]" chapter anchor text)))))
         (count (lambda (name) (cl-count name entries :key (lambda (e) (plist-get e :name)) :test #'equal)))
         (names (sort (cl-loop for entry in entries
                               for name = (plist-get entry :name)
                               for section = (plist-get entry :section)
                               collect (list name (plist-get entry :anchor) section
                                             (when (> (funcall count name) 1) (funcall title section))
                                             (not (plist-get entry :position)))
                               append (mapcar (lambda (alias)
                                                (list alias (plist-get entry :anchor) section nil t))
                                              (plist-get entry :aliases)))
                      (lambda (a b) (string< (downcase (car a)) (downcase (car b)))))))
    (with-temp-file (fms-path "content" "manual" "index.org")
      (insert "#+title: Manual\n"
              (format "#+subtitle: %s\n" subtitle)
              "#+description: keycap's manual: the editor, the language and every function, with pictures.\n"
              (format "#+html_head_extra: <link rel=\"next\" href=\"%s.html\">\n\n" (caar chapters))
              (fms-manual-nav chapters "index")
              "keycap's manual, a page per chapter.\n"
              "Every function that makes a shape has a picture of its example, rendered by keycap.\n"
              "In Emacs, =M-x keycap-guide= opens the same manual in Info.\n\n"
              "* Contents\n:PROPERTIES:\n:CUSTOM_ID: contents\n:END:\n\n"
              "#+html: <span id=\"table-of-contents\"></span>\n"
              "#+attr_html: :class contents\n")
      ;; Each heading's anchor from the single page the manual was, on its line here.
      (pcase-dolist (`(,level ,text ,id ,chapter) headings)
        (when (assoc chapter chapters)
          (insert (make-string (* 2 (1- level)) ?\s)
                  (format "- @@html:<span id=\"%s\"></span>@@" id)
                  (funcall link id id text)
                  "\n")))
      (insert "\n* Functions\n:PROPERTIES:\n:CUSTOM_ID: function-index\n:END:\n\n"
              "** By name\n\n"
              "#+attr_html: :class index\n")
      (pcase-dolist (`(,name ,anchor ,section ,where ,alias) names)
        (insert "- "
                (if alias
                    ""
                  (mapconcat (lambda (id) (format "@@html:<span id=\"%s\"></span>@@" id))
                             (cons anchor (mapcar #'car (seq-filter (lambda (retired)
                                                                      (equal (cdr retired) anchor))
                                                                    fms-manual-retired-anchors)))
                             ""))
                (funcall link section anchor (format "~%s~" name))
                (if where (format " (%s)" where) "")
                "\n"))
      (insert "\n** By topic\n")
      (let (last)
        (dolist (section (delete-dups (mapcar (lambda (entry) (plist-get entry :section)) entries)))
          (let ((chapter (nth 3 (funcall heading section))))
            (unless (equal chapter last)
              (insert (format "\n*** %s\n\n" (funcall title chapter)))
              (setq last chapter))
            (insert "- "
                    (funcall link section section (funcall title section))
                    " :: "
                    (mapconcat (lambda (entry)
                                 (mapconcat (lambda (name)
                                              (funcall link section (plist-get entry :anchor)
                                                       (format "~%s~" name)))
                                            (cons (plist-get entry :name) (plist-get entry :aliases))
                                            ", "))
                               (seq-filter (lambda (entry) (equal (plist-get entry :section) section))
                                           entries)
                               ", ")
                    "\n"))))
      (insert "\n* Keys\n:PROPERTIES:\n:CUSTOM_ID: key-index\n:END:\n\n"
              "#+attr_html: :class index\n")
      (pcase-dolist (`(,key . ,section) (sort (copy-sequence keys) (lambda (a b) (string< (car a) (car b)))))
        (insert (format "- =%s= -- %s\n" key (funcall link section section (funcall title section)))))
      (insert "\n* Concepts\n:PROPERTIES:\n:CUSTOM_ID: concept-index\n:END:\n\n"
              "#+attr_html: :class index\n")
      (pcase-dolist (`(,concept . ,section)
                     (sort (copy-sequence concepts)
                           (lambda (a b) (string< (downcase (car a)) (downcase (car b))))))
        (insert (format "- %s\n" (funcall link section section concept)))))))


;; --- Projects ---

(defun fms-gallery-projects ()
  "A project for each directory of the gallery's pages, which link up as far as it is deep."
  (let ((gallery (fms-path "content" "gallery")))
    (mapcar (lambda (directory)
              (let ((path (file-relative-name directory (fms-path "content"))))
                ;; Named without slashes, which Org's cache files can't have.
                `(,(string-replace "/" "-" path)
                  :base-directory ,directory
                  :publishing-directory ,(expand-file-name path fms-public)
                  :base-extension "org"
                  :publishing-function fms-publish-to-html
                  :html-head ,(fms-head (fms-up-from path))
                  :fms-up ,(fms-up-from path)
                  :with-toc nil)))
            (cons gallery
                  (sort (seq-filter #'file-directory-p (directory-files-recursively gallery "" t))
                        #'string<)))))

(defun fms-files-project (name directory &optional recursive)
  "A list of the project publishing the scripts in DIRECTORY as NAME/, or nil without it.
With RECURSIVE, those of its subdirectories too."
  (when (and directory (file-directory-p directory))
    `((,name
       :base-directory ,directory
       :publishing-directory ,(expand-file-name name fms-public)
       :recursive ,recursive
       :base-extension "keycap\\|fidget\\|rhai\\|svg"
       :publishing-function org-publish-attachment))))

(defun fms-projects ()
  "The site's projects, in the order they are published.
The gallery's are those of the pages `fms-write-gallery' wrote."
  `(("pages"
     :base-directory ,(fms-path "content")
     :publishing-directory ,fms-public
     :recursive t
     :base-extension "org"
     ;; Published by "tutorial", the gallery's and "manual", whose pages
     ;; link up, and "404".  Matched against the path below content/.
     :exclude "\\`\\(?:\\(?:tutorial\\|gallery\\|manual\\)/\\|404\\.org\\'\\)"
     :publishing-function fms-publish-to-html
     :html-head ,(fms-head "")
     :with-toc nil)
    ;; Served by Pages at any address that has no page, so its links start
    ;; at the root.
    ("404"
     :base-directory ,(fms-path "content")
     :publishing-directory ,fms-public
     :base-extension "org"
     :exclude "."
     :include ("404.org")
     :publishing-function fms-publish-to-html
     :html-head ,(fms-head "/")
     :fms-up "/"
     :html-link-home "/"
     :html-link-use-abs-url t
     ;; Without the links to home and up that `:html-link-home' adds.
     :html-home/up-format ""
     :with-toc nil)
    ("tutorial"
     :base-directory ,(fms-path "content" "tutorial")
     :publishing-directory ,(expand-file-name "tutorial" fms-public)
     :base-extension "org"
     :publishing-function fms-publish-to-html
     :html-head ,(fms-head "../")
     :fms-up "../"
     :with-toc nil)
    ,@(fms-gallery-projects)
    ("manual"
     :base-directory ,(fms-path "content" "manual")
     :publishing-directory ,(expand-file-name "manual" fms-public)
     :base-extension "org"
     :publishing-function fms-publish-to-html
     :html-head ,(fms-head "../")
     :fms-up "../"
     :with-toc nil)
    ("assets"
     :base-directory ,(fms-path "content")
     :publishing-directory ,fms-public
     :recursive t
     :base-extension "png\\|jpg\\|webp\\|svg"
     :publishing-function org-publish-attachment)
    ,@(fms-files-project "examples" (expand-file-name "examples" fms-keycap))
    ,@(fms-files-project "designs" fms-designs t)
    ("static"
     :base-directory ,(fms-path "static")
     :publishing-directory ,fms-public
     :base-extension "svg\\|txt"
     :publishing-function org-publish-attachment)))

(defun fms-publish ()
  "Publish the site into public/: the whole of it, or with KEYCAP_ONLY the Org
files it lists (separated by colons), as tools/dev.py asks for after an edit."
  (let ((org-publish-use-timestamps-flag nil)
        (org-publish-timestamp-directory (make-temp-file "org-timestamps" t))
        (only (getenv "KEYCAP_ONLY")))
    (fms-publish-assets)
    (unless only
      (fms-write-gallery)
      (fms-write-manual))
    (let ((org-publish-project-alist (fms-projects)))
      (if only
          (dolist (file (split-string only ":" t))
            (when (string-suffix-p ".org" file)
              (org-publish-file file)))
        (dolist (project org-publish-project-alist)
          (org-publish (car project) t))))))

(fms-publish)

;; With KEYCAP_CACHE_OUT, the entries of the render cache this run used are
;; copied there, the cache the next build starts from.
(when-let* ((out (getenv "KEYCAP_CACHE_OUT")))
  (make-directory out t)
  (dolist (file ob-keycap-cache-used)
    (copy-file file (expand-file-name (file-name-nondirectory file) out))))

;;; publish.el ends here
