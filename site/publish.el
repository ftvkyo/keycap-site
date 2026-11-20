;;; publish.el --- Build keycap's site  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;; emacs --batch --load publish.el, from the repository's root, with
;; keycap, htmlize and nix-mode installed: the Org pages in content/, the
;; manual and the examples of the keycap checkout KEYCAP_DIR, and the
;; models of the checkout KEYCAP_DESIGNS_DIR become plain HTML in public/.

;;; Code:

(require 'ox-publish)
(require 'htmlize)
(require 'cl-lib)
(require 'subr-x)

(defconst keycap-site-root (file-name-directory (or load-file-name buffer-file-name)))

(defun keycap-site-path (&rest parts)
  "PARTS joined under the repository's root."
  (expand-file-name (string-join parts "/") keycap-site-root))

(defconst keycap-site-keycap
  (file-name-as-directory (or (getenv "KEYCAP_DIR") (error "KEYCAP_DIR is not set")))
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

(add-to-list 'load-path (keycap-site-path "tools"))
(require 'ob-keycap)

(setf (alist-get :results org-babel-default-header-args:keycap) "html")
(setq org-confirm-babel-evaluate nil
      ob-keycap-examples-directory (expand-file-name "examples" keycap-site-keycap)
      ob-keycap-cache-directory (getenv "KEYCAP_CACHE")
      ob-keycap-compress (and (getenv "KEYCAP_COMPRESS") t)
      ob-keycap-backend (intern (or (getenv "KEYCAP_BACKEND") "cpu")))

(when-let* ((cores (string-to-number (or (getenv "NIX_BUILD_CORES") "0")))
            ((> cores 0)))
  (setq keycap-server-threads cores))

(defun keycap-site-publish-to-html (plist file directory)
  "Publish the Org FILE to HTML in DIRECTORY, its frames' images in frames/."
  (let ((ob-keycap-image-directory (expand-file-name "frames" directory))
        (ob-keycap-html-directory directory))
    (org-html-publish-to-html plist file directory)))


;; --- Views ---

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

(defun keycap-site-view-settings (view)
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

(defun keycap-site-view-arguments (view)
  "The keycap block's header arguments for VIEW, settings apart by commas."
  (let (overrides arguments)
    (dolist (setting (keycap-site-view-settings view))
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


;; --- Assets ---

;; The stylesheet, the script and the fonts are published under names with
;; their content's hash, so a cached copy is never the wrong one and a
;; changed file is fetched at once; the pages, which Pages caches for ten
;; minutes, are the only thing that can lag.  The dev server (KEYCAP_DEV)
;; keeps the plain names.  The font files are in KEYCAP_FONTS, their licence is KEYCAP_FONTS_LICENCE.
;; default.nix then cuts the fonts down to the characters the pages use,
;; with tools/subset-fonts.py, which renames them and the stylesheet.

(defconst keycap-site-dev (and (getenv "KEYCAP_DEV") t)
  "Whether the site is published for tools/dev.py.")

(defun keycap-site-read (file)
  "The bytes of FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun keycap-site-fingerprint (name data)
  "NAME with the hash of DATA before its extension, or NAME itself in dev."
  (if keycap-site-dev
      name
    (format "%s.%s.%s" (file-name-sans-extension name)
            (substring (secure-hash 'sha256 data) 0 10)
            (file-name-extension name))))

(defconst keycap-site-public (keycap-site-path "public"))

(defconst keycap-site-assets
  (let* ((fonts (mapcar (lambda (face)
                          (let* ((name (format "fonts/MapleMonoNL-%s.woff2" face))
                                 (data (keycap-site-read (expand-file-name
                                                          (format "MapleMonoNL-%s.ttf.woff2" face)
                                                          (or (getenv "KEYCAP_FONTS")
                                                              (error "KEYCAP_FONTS is not set"))))))
                            (list name (keycap-site-fingerprint name data) data)))
                        '("Regular" "Italic" "Bold")))
         (css (keycap-site-read (keycap-site-path "static" "style.css")))
         (js (keycap-site-read (keycap-site-path "static" "copy.js"))))
    (pcase-dolist (`(,name ,published) fonts)
      (setq css (string-replace name published css)))
    `(("style.css" ,(keycap-site-fingerprint "style.css" css) ,css)
      ("copy.js" ,(keycap-site-fingerprint "copy.js" js) ,js)
      ;; The OFL asks for the licence to travel with the faces, under its own name.
      ("fonts/OFL.txt" "fonts/OFL.txt" ,(keycap-site-read (or (getenv "KEYCAP_FONTS_LICENCE")
                                                              (error "KEYCAP_FONTS_LICENCE is not set"))))
      ,@fonts))
  "The files that are published by a hash of their content: their name,
the name they are published under, and their bytes.")

(defun keycap-site-asset (name)
  "The name in the site's root that the asset NAME is published under."
  (nth 1 (assoc name keycap-site-assets)))

(defun keycap-site-publish-assets ()
  "Write the assets into public/."
  (pcase-dolist (`(,_ ,published ,data) keycap-site-assets)
    (let ((file (expand-file-name published keycap-site-public)))
      (make-directory (file-name-directory file) t)
      (let ((coding-system-for-write 'no-conversion))
        (write-region data nil file nil 'silent)))))


;; --- Page frame ---

(defconst keycap-site-nav
  '(("" . "keycap<span class=\"ide\">IDE</span>")
    ("tutorial/index.html" . "Tutorial")
    ("manual/index.html" . "Manual")
    ("gallery/index.html" . "Gallery")
    ("install.html" . "Install")
    ("about.html" . "About"))
  "The header's links, relative to the site's root.")

(defun keycap-site-up (info)
  "The way from the page INFO exports up to the site's root."
  (or (plist-get info :keycap-site-up)
      ;; For a page at the root this is ".", without the slash the other
      ;; levels' "../" have.
      (let ((up (file-name-as-directory
                 (file-relative-name (plist-get info :base-directory)
                                     (file-name-directory (plist-get info :input-file))))))
        (if (equal up "./") "" up))))

(defun keycap-site-page (info)
  "The path in the site of the page INFO exports, such as tutorial/index.html."
  (file-relative-name
   (expand-file-name (concat (file-name-base (plist-get info :input-file)) ".html")
                     (plist-get info :publishing-directory))
   keycap-site-public))

(defun keycap-site-current-p (href page)
  "Whether the header's link to HREF stands for PAGE: it, or its section."
  (or (equal href page)
      (and (string-suffix-p "/index.html" href)
           (string-prefix-p (file-name-directory href) page))))

(defun keycap-site-preamble (info)
  "The header of the page INFO exports."
  (let ((up (keycap-site-up info))
        (page (keycap-site-page info)))
    (concat
     "<a class=\"skip\" href=\"#content\">Skip to the content</a>"
     "<header><nav>"
     (mapconcat (pcase-lambda (`(,href . ,label))
                  (format "<a href=\"%s%s\"%s>%s</a>"
                          up (if (equal href "") "index.html" href)
                          (cond ((equal href "") " class=\"logo\" aria-label=\"keycap IDE\"")
                                ((keycap-site-current-p href page) " aria-current=\"page\"")
                                (t ""))
                          label))
                keycap-site-nav "")
     "</nav></header>")))

(defun keycap-site-ide-title (html _backend _info)
  "The front page's title in HTML as the logo has it, IDE in grey."
  (string-replace "<h1 class=\"title\">keycap</h1>"
                  "<h1 class=\"title\">keycap<span class=\"ide\">IDE</span></h1>"
                  html))

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-ide-title)

(defun keycap-site-postamble (_info)
  "The footer of every page."
  (concat "<footer>"
          "<p>keycap is free software: its Emacs package and manual are GPL-3.0-or-later, its server and prelude MPL-2.0 and its examples 0BSD. "
          "This site's text and Rei's designs are CC BY-SA 4.0, the tutorial's code 0BSD and the site's own code GPL-3.0-or-later.</p>"
          "<p>Written in Org, published by Emacs; one small script, to copy code, and no trackers.</p>"
          "</footer>"))

(defun keycap-site-head (up)
  "The head of a page whose root is UP."
  (concat
   "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
   "<meta name=\"color-scheme\" content=\"dark light\">\n"
   (format "<link rel=\"icon\" type=\"image/svg+xml\" href=\"%sfavicon.svg\">\n" up)
   (format "<link rel=\"stylesheet\" href=\"%s%s\">\n" up (keycap-site-asset "style.css"))
   ;; The face of the code, wanted on every page.
   (format "<link rel=\"preload\" href=\"%s%s\" as=\"font\" type=\"font/woff2\" crossorigin>\n"
           up (keycap-site-asset "fonts/MapleMonoNL-Regular.woff2"))
   (format "<script src=\"%s%s\" defer></script>\n" up (keycap-site-asset "copy.js"))
   (and keycap-site-dev "<script src=\"/__dev.js\" defer></script>\n")))

(defun keycap-site-pager (previous up next)
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
      ;; `keycap-site-head' has it.
      org-html-viewport nil
      org-html-preamble #'keycap-site-preamble
      org-html-postamble #'keycap-site-postamble
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

(defun keycap-site-slug (title)
  "TITLE as an anchor: lower case, runs of other characters as one dash."
  (string-trim (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase title)) "-" "-"))

(defun keycap-site-name-headings (_backend)
  "Give every heading in the buffer being exported a CUSTOM_ID from its title."
  (let ((taken (make-hash-table :test #'equal)))
    (org-map-entries
     (lambda ()
       (unless (org-entry-get nil "CUSTOM_ID")
         (let* ((slug (keycap-site-slug (org-get-heading t t t t)))
                (id slug)
                (n 1))
           (while (gethash id taken)
             (setq id (format "%s-%d" slug (cl-incf n))))
           (puthash id t taken)
           (org-entry-put nil "CUSTOM_ID" id)))))))

(add-hook 'org-export-before-processing-functions #'keycap-site-name-headings)

(defun keycap-site-link-images (html _backend _info)
  "Make every image in HTML but an example's a link to itself: screenshots shrink to fit the page."
  (replace-regexp-in-string
   "\\(<div class=\"example-pic\">[ \t\n]*\\)?<img src=\"\\([^\"]+\\)\"[^>]*>"
   (lambda (match)
     (if (match-beginning 1)
         match
       (format "<a href=\"%s\">%s</a>" (match-string 2 match) match)))
   html t t))

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-link-images)

(defun keycap-site-png-size (file)
  "The width and height of the PNG FILE, from its header."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 24)
    (unless (string-prefix-p "\211PNG" (buffer-string))
      (error "%s is not a PNG" file))
    (cl-flet ((u32 (at) (seq-reduce (lambda (n byte) (+ (* n 256) byte))
                                    (buffer-substring (1+ at) (+ at 5)) 0)))
      (list (u32 16) (u32 20)))))

(defun keycap-site-size-pictures (html _backend info)
  "Give each picture in HTML its size, so the page does not move as they load.
All but the first load lazily, the first early.  The pictures are PNG
files beside the page INFO exports."
  (let ((directory (file-name-directory (expand-file-name (keycap-site-page info) keycap-site-public)))
        (first t))
    (replace-regexp-in-string
     "<img src=\"\\([^\"]+\\)\""
     (lambda (img)
       (pcase-let ((`(,width ,height)
                    (save-match-data (keycap-site-png-size (expand-file-name (match-string 1 img) directory)))))
         (format "%s width=\"%d\" height=\"%d\" %s" img width height
                 (if first
                     (progn (setq first nil) "fetchpriority=\"high\"")
                   "loading=\"lazy\""))))
     html t t)))

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-size-pictures)

(defconst keycap-site-code-columns 32
  "The longest code in text that is kept on one line; longer code may wrap.
It fits on a phone, about 40 columns.")

(defun keycap-site-long-code (html _backend _info)
  "Mark code in the text of HTML that is too long to keep on one line as long."
  (replace-regexp-in-string
   "<code>\\([^<]*\\)</code>"
   (lambda (match)
     (if (> (length (replace-regexp-in-string "&[#[:alnum:]]+;" "&" (match-string 1 match)))
            keycap-site-code-columns)
         (concat "<code class=\"long\">" (substring match 6))
       match))
   html t t))

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-long-code)

(defun keycap-site-map-tables (html _backend _info)
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

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-map-tables)


;; --- Review ---

;; Most of the text is drafted by an AI, and the site says which of it a
;; person has read.  `#+review: reviewed 2026-11-17' at the top of a page,
;; or a `:REVIEW:' property on a heading for its section, marks it
;; reviewed, and `reviewed 2026-11-17 by NAME' names who did; without
;; either, a page is a draft.  A `human' block is a person's own words,
;; and `#+begin_human NAME' names them.

(defvar keycap-site-review nil
  "The `#+review:' value of the page being exported, or nil.")

(defun keycap-site-review-mark (value)
  "The class and the text of the review mark the string VALUE stands for."
  (pcase (if (member value '(nil "")) "draft" (string-trim value))
    ("draft" '("review-draft" . "Drafted with AI, not yet reviewed"))
    ((rx bos "reviewed " (let date (: (= 4 digit) "-" (= 2 digit) "-" (= 2 digit)))
         (? " by " (let name (+ nonl))) eos)
     (cons "review-reviewed" (if name
                                 (format "Reviewed by %s, %s" (string-trim name) date)
                               (format "Reviewed %s" date))))
    (other (error "Unknown review mark: %s" other))))

(defun keycap-site-review-sections (_backend)
  "Read the page's review mark, and put a block with each section's under its heading."
  (setq keycap-site-review (save-excursion
                             (goto-char (point-min))
                             (when (re-search-forward "^#\\+review:[ \t]*\\(.*\\)$" nil t)
                               (match-string 1))))
  (org-map-entries
   (lambda ()
     (when-let* ((value (org-entry-get nil "REVIEW")))
       (pcase-let ((`(,class . ,text) (keycap-site-review-mark value)))
         (org-end-of-meta-data t)
         (insert (format "#+begin_%s\n%s\n#+end_%s\n\n" class text class)))))))

(add-hook 'org-export-before-processing-functions #'keycap-site-review-sections)

(defun keycap-site-review-badge (html _backend _info)
  "Put the page's review mark under the title in HTML."
  (let* ((title (string-search "<h1 class=\"title\">" html))
         (end (and title (string-search "</header>" html title))))
    (if (not end)
        html
      (pcase-let ((`(,class . ,text) (keycap-site-review-mark keycap-site-review)))
        (concat (substring html 0 end)
                (format "<div class=\"%s\"><p>%s</p></div>\n" class text)
                (substring html end))))))

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-review-badge)

(defun keycap-site-human-names (_backend)
  "Carry the name after `#+begin_human' to its HTML, as `data-by'."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^\\([ \t]*\\)#\\+begin_human[ \t]+\\(.*[^ \t]\\)[ \t]*$" nil t)
      (replace-match "\\1#+attr_html: :data-by \\2\n\\1#+begin_human" t))))

(add-hook 'org-export-before-processing-functions #'keycap-site-human-names)

(defun keycap-site-human-block (html _backend _info)
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

(add-to-list 'org-export-filter-special-block-functions #'keycap-site-human-block)


;; --- Tutorial ---

;; Each part is numbered under its title, and ends with the pager the
;; manual's pages have, up to the tutorial's index.

(defconst keycap-site-tutorial-parts
  (mapcar (lambda (file)
            (with-temp-buffer
              (insert-file-contents file)
              (list (file-name-base file)
                    (and (re-search-forward "^#\\+title: \\(.*\\)$" nil t)
                         (match-string 1)))))
          (directory-files (keycap-site-path "content" "tutorial") t "\\`[0-9]+-.*\\.org\\'"))
  "The tutorial's parts, in order, each (ID TITLE).")

(defun keycap-site-tutorial-pager (html _backend info)
  "Number the part of the tutorial in HTML under its title, and end it with the pager.
HTML is the page INFO exports; another page's is left as it is."
  (let* ((file (plist-get info :input-file))
         (n (and (file-equal-p (file-name-directory file) (keycap-site-path "content" "tutorial"))
                 (cl-position (file-name-base file) keycap-site-tutorial-parts :key #'car :test #'equal))))
    (if (not n)
        html
      (let* ((index '("index" "Tutorial"))
             (previous (if (> n 0) (nth (1- n) keycap-site-tutorial-parts) index))
             (next (nth (1+ n) keycap-site-tutorial-parts)))
        (thread-last
          html
          (string-replace "</head>" (concat (format "<link rel=\"prev\" href=\"%s.html\">\n" (car previous))
                                            (if next (format "<link rel=\"next\" href=\"%s.html\">\n" (car next)) "")
                                            "</head>"))
          (string-replace "</h1>" (format "</h1>\n<p class=\"subtitle\">Part %d of %d</p>"
                                          (1+ n) (length keycap-site-tutorial-parts)))
          (string-replace "</main>" (concat (keycap-site-pager previous index next) "\n</main>")))))))

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-tutorial-pager)


;; --- Gallery, manual and field ---

(require 'keycap-site-gallery)
(require 'keycap-site-manual)
(require 'keycap-site-field)


;; --- Projects ---

(defun keycap-site-gallery-projects ()
  "A project for each directory of the gallery's pages, which link up as far as it is deep."
  (let ((gallery (keycap-site-path "content" "gallery")))
    (mapcar (lambda (directory)
              (let ((path (file-relative-name directory (keycap-site-path "content"))))
                ;; Named without slashes, which Org's cache files can't have.
                `(,(string-replace "/" "-" path)
                  :base-directory ,directory
                  :publishing-directory ,(expand-file-name path keycap-site-public)
                  :base-extension "org"
                  :publishing-function keycap-site-publish-to-html
                  :html-head ,(keycap-site-head (keycap-site-up-from path))
                  :keycap-site-up ,(keycap-site-up-from path)
                  :with-toc nil)))
            (cons gallery
                  (sort (seq-filter #'file-directory-p (directory-files-recursively gallery "" t))
                        #'string<)))))

(defun keycap-site-files-project (name directory &optional recursive)
  "A list of the project publishing the scripts in DIRECTORY as NAME/, or nil without it.
With RECURSIVE, those of its subdirectories too."
  (when (and directory (file-directory-p directory))
    `((,name
       :base-directory ,directory
       :publishing-directory ,(expand-file-name name keycap-site-public)
       :recursive ,recursive
       :base-extension "keycap\\|fidget\\|rhai\\|svg"
       :publishing-function org-publish-attachment))))

(defun keycap-site-projects ()
  "The site's projects, in the order they are published.
The gallery's are those of the pages `keycap-site-write-gallery' wrote."
  `(("pages"
     :base-directory ,(keycap-site-path "content")
     :publishing-directory ,keycap-site-public
     :recursive t
     :base-extension "org"
     ;; Published by "tutorial", the gallery's and "manual", whose pages
     ;; link up, and "404".  Matched against the path below content/.
     :exclude "\\`\\(?:\\(?:tutorial\\|gallery\\|manual\\)/\\|404\\.org\\'\\)"
     :publishing-function keycap-site-publish-to-html
     :html-head ,(keycap-site-head "")
     :with-toc nil)
    ;; Served by Pages at any address that has no page, so its links start
    ;; at the root.
    ("404"
     :base-directory ,(keycap-site-path "content")
     :publishing-directory ,keycap-site-public
     :base-extension "org"
     :exclude "."
     :include ("404.org")
     :publishing-function keycap-site-publish-to-html
     :html-head ,(keycap-site-head "/")
     :keycap-site-up "/"
     :html-link-home "/"
     :html-link-use-abs-url t
     ;; Without the links to home and up that `:html-link-home' adds.
     :html-home/up-format ""
     :with-toc nil)
    ("tutorial"
     :base-directory ,(keycap-site-path "content" "tutorial")
     :publishing-directory ,(expand-file-name "tutorial" keycap-site-public)
     :base-extension "org"
     :publishing-function keycap-site-publish-to-html
     :html-head ,(keycap-site-head "../")
     :keycap-site-up "../"
     :with-toc nil)
    ,@(keycap-site-gallery-projects)
    ("manual"
     :base-directory ,(keycap-site-path "content" "manual")
     :publishing-directory ,(expand-file-name "manual" keycap-site-public)
     :base-extension "org"
     :publishing-function keycap-site-publish-to-html
     :html-head ,(keycap-site-head "../")
     :keycap-site-up "../"
     :with-toc nil)
    ("assets"
     :base-directory ,(keycap-site-path "content")
     :publishing-directory ,keycap-site-public
     :recursive t
     :base-extension "png\\|jpg\\|webp\\|svg"
     :publishing-function org-publish-attachment)
    ,@(keycap-site-files-project "examples" (expand-file-name "examples" keycap-site-keycap))
    ,@(keycap-site-files-project "designs" keycap-site-designs t)
    ("static"
     :base-directory ,(keycap-site-path "static")
     :publishing-directory ,keycap-site-public
     :base-extension "svg\\|txt"
     :publishing-function org-publish-attachment)))

(defun keycap-site-publish ()
  "Publish the site into public/: the whole of it, or with KEYCAP_ONLY the Org
files it lists (separated by colons), as tools/dev.py asks for after an edit."
  (let ((org-publish-use-timestamps-flag nil)
        (org-publish-timestamp-directory (make-temp-file "org-timestamps" t))
        (only (getenv "KEYCAP_ONLY")))
    (keycap-site-publish-assets)
    (unless only
      (keycap-site-write-gallery)
      (keycap-site-write-manual)
      (keycap-site-write-field))
    (let ((org-publish-project-alist (keycap-site-projects)))
      (if only
          (dolist (file (split-string only ":" t))
            (when (string-suffix-p ".org" file)
              (org-publish-file file)))
        (dolist (project org-publish-project-alist)
          (org-publish (car project) t))))))

(keycap-site-publish)

;; With KEYCAP_CACHE_OUT, the entries of the render cache this run used are
;; copied there, the cache the next build starts from.
(when-let* ((out (getenv "KEYCAP_CACHE_OUT")))
  (make-directory out t)
  (dolist (file ob-keycap-cache-used)
    (copy-file file (expand-file-name (file-name-nondirectory file) out))))

;;; publish.el ends here
