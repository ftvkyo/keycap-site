;;; keycap-site-gallery.el --- keycap's site: the gallery  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

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
;;
;; Loaded by publish.el, on top of its page frame.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ox-html)
(require 'keycap)
(require 'ob-keycap)


;; --- Models ---

(defun keycap-site-source (variable)
  "The directory the environment VARIABLE names, or nil when it is unset."
  (when-let* ((directory (getenv variable)))
    (file-name-as-directory directory)))

(defconst keycap-site-designs (keycap-site-source "KEYCAP_DESIGNS_DIR")
  "The checkout of Rei's designs, keycap-designs, or nil.")

(defun keycap-site-models (root site page original author &optional recursive)
  "The models in the directory ROOT, its files published at SITE.
Their pages are under PAGE in the gallery; with RECURSIVE, those of its
subdirectories too, their pages as deep.  Each model is a plist of
:file, :root, :site, :page, :title, its name, :original, the path in
the OpenSCAD collection that ORIGINAL, a function of its script, gives
for a port, or nil, and :author, a name and a link: `keycap-site-author' for a
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
                      :author (if from keycap-site-author author))))
            (sort (if recursive
                      (directory-files-recursively root "\\.\\(?:keycap\\|fidget\\)\\'")
                    (directory-files root t "\\.\\(?:keycap\\|fidget\\)\\'"))
                  #'string<))))

(defun keycap-site-example-summary (file)
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

(defun keycap-site-model-summary (file)
  "The opening comment of the model FILE, its first paragraph without `keycap-site-port-phrases'."
  (let* ((summary (keycap-site-example-summary file))
         (end (or (string-search "\n\n" summary) (length summary)))
         (first (substring summary 0 end))
         (case-fold-search nil))
    (dolist (phrase keycap-site-port-phrases)
      (setq first (replace-regexp-in-string phrase "" first t t)))
    (concat (string-trim-right first) (substring summary end))))

(defun keycap-site-first-sentence (text)
  "The first sentence of TEXT, on one line."
  (let ((text (string-join (split-string text "[ \t\n]+" t) " ")))
    (if (string-match "\\.\\(?: \\|\\'\\)" text)
        (concat (substring text 0 (match-beginning 0)) ".")
      text)))

(defun keycap-site-example-files (model report)
  "The files of MODEL's source that its `load' REPORT read, besides itself."
  (sort (seq-filter (lambda (read) (file-in-directory-p read (plist-get model :root)))
                    (alist-get 'files report))
        #'string<))

(defun keycap-site-tall-p (report)
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

(defun keycap-site-model-views (file)
  "The views the model FILE's `// view:' lines give, in order, each (LABEL . VIEW).
LABEL is nil for a line without one."
  (with-temp-buffer
    (insert-file-contents file)
    (cl-loop while (re-search-forward "^// view\\(?: \\([^:\n]+\\)\\)?:\\(.*\\)$" nil t)
             collect (cons (match-string 1) (string-trim (match-string 2))))))


;; --- Credits ---

(defconst keycap-site-openscad "https://github.com/ftvkyo/openscad/blob/main/"
  "Rei's OpenSCAD collection, where the originals are, by their path in it.")

(defconst keycap-site-author '("Rei" . "https://ftvkyo.me")
  "Who made the gallery's designs and the originals of its ports, and where she is.")

(defconst keycap-site-examples-author '("keycap" . "https://tangled.org/rei.gay/keycap")
  "Who made the examples that are not ports: keycap, whose examples they are.")

(defconst keycap-site-example-originals
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
(defconst keycap-site-printables
  '(("vase-koch" . "https://www.printables.com/model/994219")
    ("table-cable-hook" . "https://www.printables.com/model/1016571")
    ("designs/mods/steam_deck_dpad" . "https://www.printables.com/model/1426078"))
  "Models that are also on Printables, by their page in the gallery.")

(defconst keycap-site-port-phrases
  '("[,;][[:space:]]+ported[[:space:]]+from[[:space:]]+OpenSCAD\\(?:,[[:space:]]+where[^.]*\\)?"
    "[,;][[:space:]]+[^,;.]*an[[:space:]]+OpenSCAD[[:space:]]+design[^.]*"
    "[,;][[:space:]]+ported[[:space:]]+from[[:space:]]+=[^=]+="
    "Ported[[:space:]]+from[[:space:]]+=[^=]+=[.;][[:space:]]*")
  "What the first paragraph of a model's opening comment says of its original.
The port's icon says it instead.")

(defconst keycap-site-port-icon
  (concat "<svg viewBox=\"0 0 16 16\" role=\"img\"><title>Ported from OpenSCAD</title>"
          "<rect x=\"1.5\" y=\"1.5\" width=\"6\" height=\"6\" rx=\"0.5\"/>"
          "<circle cx=\"11.5\" cy=\"11.5\" r=\"3\"/>"
          "<path d=\"M8.5 4.5h3v3.5M9.75 6.75l1.75 1.75 1.75-1.75\"/>"
          "</svg>")
  "The mark of a port: a square, OpenSCAD's facets, turning into a circle, a field's curve.")

(defun keycap-site-credits (model &optional page)
  "HTML saying who made MODEL, whether it is a port, and where else it is.
For its PAGE, the author and the port's icon are links, the icon's to the original."
  (let ((author (plist-get model :author))
        (original (plist-get model :original))
        (printables (cdr (assoc (plist-get model :page) keycap-site-printables))))
    (concat (cond ((not author) "")
                  (page (format "<span>by <a href=\"%s\">%s</a></span>" (cdr author) (car author)))
                  (t (format "<span>by %s</span>" (car author))))
            (cond ((not original) "")
                  (page (format "<a class=\"port\" href=\"%s%s\">%s<code>%s</code></a>"
                                keycap-site-openscad original keycap-site-port-icon
                                (string-remove-prefix "src/" original)))
                  (t (format "<span class=\"port\">%s</span>" keycap-site-port-icon)))
            (if printables
                (format "<a class=\"printables\" href=\"%s\">Printables</a>" printables)
              ""))))


;; --- Ports ---

;; How Rei's ports, the keycaps among them, compare with their originals
;; is in PORTS.md, in Markdown.

(defun keycap-site-markdown-org (text)
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

(defun keycap-site-markdown-table (file)
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

(defun keycap-site-port-row (file)
  "The row of PORTS.md for the port FILE, an alist of its header and cell, or nil."
  (let ((port (file-relative-name file keycap-site-designs)))
    (seq-find (lambda (row)
                (seq-some (lambda (cell) (string-search port (cdr cell))) row))
              (keycap-site-markdown-table (expand-file-name "PORTS.md" keycap-site-designs)))))

(defun keycap-site-port-original (file)
  "The original of the port FILE: as PORTS.md names it, else by the port's own path."
  (let ((cell (or (cdr (assoc "Original" (keycap-site-port-row file))) "")))
    (concat "src/"
            (if (string-match "[-_.[:alnum:]]+/[-_.[:alnum:]]+\\.scad" cell)
                (match-string 0 cell)
              (concat (file-name-sans-extension (file-relative-name file keycap-site-designs))
                      ".scad")))))

(defun keycap-site-port-about (model)
  "How the port MODEL compares with its original, as an Org list, if PORTS.md has its row."
  (let ((items (mapconcat (pcase-lambda (`(,header . ,cell))
                            (if (or (member header '("Original" "Port")) (string-empty-p cell))
                                ""
                              (format "- %s: %s\n" header (keycap-site-markdown-org cell))))
                          (keycap-site-port-row (plist-get model :file)) "")))
    (unless (string-empty-p items)
      (concat items "\n"))))

(defun keycap-site-keycap-original (file)
  "The original of the keycap design FILE, as its opening comment names it, or nil."
  (let ((summary (keycap-site-example-summary file)))
    (when (string-match "=\\(src/[^=\n]+\\.scad\\)=" summary)
      (match-string 1 summary))))

(defconst keycap-site-keycaps-legends
  '(("cryptodancer.keycap" "A" "N:dot" "Esc" "F1"))
  "Keycap designs shown with some of their legends, as export-legends.py takes them.")


;; --- Pages ---

(defun keycap-site-render (file &rest arguments)
  "A keycap block of the script FILE showing only its image, with header ARGUMENTS."
  (format "#+begin_src keycap :open %s :frame no :exports results %s\n#+end_src\n\n"
          file (string-join arguments " ")))

(defun keycap-site-keycap-legends (model)
  "A section of renders of the keycap design MODEL with some of its legends, or nil."
  (when-let* ((file (plist-get model :file))
              (legends (cdr (assoc (file-name-nondirectory file) keycap-site-keycaps-legends))))
    (concat "* Legends\n\n"
            "Some of the set, =SYMBOL= and =DOT= set for each as =export-legends.py= sets them.\n\n"
            "#+html: <div class=\"renders\">\n"
            (mapconcat
             (lambda (legend)
               (let* ((symbol (string-remove-suffix ":dot" legend))
                      (dot (not (equal symbol legend)))
                      (caption (format "%s%s" symbol (if dot ", with the dot" ""))))
                 (concat "#+html: <figure>\n"
                         (keycap-site-render file ":size \"480 360\" :camera \"-70 20\""
                                             (format ":set '%S" `((SYMBOL . ,symbol) (DOT . ,dot)))
                                             (format ":alt %s, %s" (plist-get model :title) caption))
                         (format "#+html: <figcaption>%s</figcaption></figure>\n"
                                 (org-html-encode-plain-text caption)))))
             legends "")
            "#+html: </div>\n\n")))

(defun keycap-site-up-from (page)
  "The way up from the gallery's PAGE to the site's root."
  (apply #'concat (make-list (1+ (cl-count ?/ page)) "../")))

(defun keycap-site-write-model (model about details)
  "Write the gallery's page of MODEL.
ABOUT, an Org list of how it compares with its original, follows its
opening comment;
DETAILS, Org sections, its renders."
  (let* ((file (plist-get model :file))
         (name (plist-get model :title))
         (report (ob-keycap-load file))
         (summary (keycap-site-model-summary file))
         (up (keycap-site-up-from (plist-get model :page)))
         (page (keycap-site-path "content" "gallery" (concat (plist-get model :page) ".org"))))
    (make-directory (file-name-directory page) t)
    (with-temp-file page
      (insert (format "#+title: %s\n" name)
              (format "#+description: %s\n\n" (keycap-site-first-sentence summary))
              (let ((credits (keycap-site-credits model t)))
                (if (string-empty-p credits)
                    ""
                  (format "#+html: <p class=\"credits\">%s</p>\n\n" credits)))
              summary "\n\n"
              ;; In a box, apart from a list the comment ends with.
              (if about (concat "#+attr_html: :class checked\n" about) "")
              (cond
               ((keycap-site-model-views file)
                (mapconcat (pcase-lambda (`(,label . ,view))
                             (let ((render (keycap-site-render file ":size \"800 600\""
                                                               (keycap-site-view-arguments view)
                                                               (format ":alt %s, %s" name (or label view)))))
                               (if label
                                   (concat "#+html: <figure>\n" render
                                           (format "#+html: <figcaption>%s</figcaption></figure>\n"
                                                   (org-html-encode-plain-text label)))
                                 render)))
                           (keycap-site-model-views file) ""))
               ((keycap-report-flat-p report)
                (concat (keycap-site-render file ":size \"800 600\"" (format ":alt %s, its distance field" name))
                        (keycap-site-render file ":size \"800 600\" :view mono"
                                            (format ":alt %s, inside and outside" name))))
               (t
                (concat (keycap-site-render file ":size \"800 600\""
                                            (format ":alt %s, shaded, from the front right" name))
                        (keycap-site-render file ":size \"800 600\" :camera \"120 30\""
                                            (format ":alt %s, shaded, from the back left" name))
                        ;; A slice of a flat part shows little.
                        (when (keycap-site-tall-p report)
                          (keycap-site-render file ":size \"800 600\" :slice y"
                                              (format ":alt %s, its distance field on a slice across Y" name))))))
              (or details "")
              "* Files\n\n"
              (mapconcat (lambda (path)
                           (format "- [[file:%s%s%s][=%s=]]\n"
                                   up (plist-get model :site) (file-relative-name path (plist-get model :root))
                                   (file-relative-name path (file-name-directory file))))
                         (cons file (keycap-site-example-files model report))
                         "")
              "\n* Source\n\n"
              "#+begin_src keycap :exports code\n"
              (org-escape-code-in-string (with-temp-buffer
                                           (insert-file-contents file)
                                           (buffer-string)))
              "#+end_src\n"))))

(defun keycap-site-cards (models)
  "The cards of MODELS on the gallery's index, each a link to its page."
  (concat "#+html: <div class=\"cards\">\n"
          (mapconcat (lambda (model)
                       (let ((file (plist-get model :file))
                             (name (plist-get model :title)))
                         (concat "#+html: <div class=\"card\">\n"
                                 (keycap-site-render file ":size \"480 360\""
                                                     (if-let* ((view (car (keycap-site-model-views file))))
                                                         (keycap-site-view-arguments (cdr view))
                                                       "")
                                                     (format ":alt %s" name))
                                 ;; A long name like singer720_hook_drive_gear may
                                 ;; break after its underscores, not past the card.
                                 (format "#+html: <a class=\"card-name\" href=\"%s.html\">%s</a><p>%s</p>%s</div>\n"
                                         (plist-get model :page)
                                         (string-replace "_" "_<wbr>" name)
                                         (org-html-encode-plain-text
                                          (string-replace "=" "" (keycap-site-first-sentence
                                                                  (keycap-site-model-summary file))))
                                         (let ((credits (keycap-site-credits model)))
                                           (if (string-empty-p credits)
                                               ""
                                             (format "<p class=\"credits\">%s</p>" credits)))))))
                     models "")
          "#+html: </div>\n\n"))

(defun keycap-site-design-groups ()
  "Rei's designs by group, each a directory of keycap-designs and its models, the keycaps first.
A group's designs are published at designs/GROUP/, and have their pages there in the gallery."
  (when keycap-site-designs
    (let ((groups (sort (seq-filter (lambda (name) (file-directory-p (expand-file-name name keycap-site-designs)))
                                    (directory-files keycap-site-designs nil "\\`[^.]"))
                        #'string<)))
      (seq-filter #'cdr
                  (mapcar (lambda (group)
                            (let ((site (concat "designs/" group "/")))
                              (cons group
                                    (keycap-site-models (expand-file-name group keycap-site-designs) site site
                                                        (if (equal group "keycaps")
                                                            #'keycap-site-keycap-original
                                                          #'keycap-site-port-original)
                                                        keycap-site-author))))
                          (if (member "keycaps" groups)
                              (cons "keycaps" (delete "keycaps" groups))
                            groups))))))

(defun keycap-site-write-gallery ()
  "Write content/gallery/ from the models: their cards by source, and a page for each."
  (let ((directory (keycap-site-path "content" "gallery"))
        (examples (keycap-site-models (expand-file-name "examples" keycap-site-keycap) "examples/" ""
                                      (lambda (file)
                                        (cdr (assoc (file-name-base file) keycap-site-example-originals)))
                                      keycap-site-examples-author))
        (designs (keycap-site-design-groups)))
    (delete-directory directory t)
    (make-directory directory)
    (dolist (model examples)
      (keycap-site-write-model model nil nil))
    (pcase-dolist (`(,group . ,models) designs)
      (dolist (model models)
        (if (equal group "keycaps")
            (keycap-site-write-model model (keycap-site-port-about model) (keycap-site-keycap-legends model))
          (keycap-site-write-model model (keycap-site-port-about model) nil))))
    (with-temp-file (expand-file-name "index.org" directory)
      (insert "#+title: Gallery\n"
              "#+description: Models made in keycap, with their source: its examples and my own designs.\n\n"
              "Everything here is rendered by keycap's preview when the site is built.\n"
              "Each model is a script that you can download and open in Emacs.\n\n"
              (format "@@html:<span class=\"port\">%s</span>@@ marks a port of one of [[%s][my OpenSCAD designs]]; its page links to the original.\n\n"
                      keycap-site-port-icon (string-remove-suffix "blob/main/" keycap-site-openscad)))
      (when examples
        (insert "* Examples\n\n"
                "The examples that come with keycap, most of them ports of my general designs.\n\n"
                (keycap-site-cards examples)))
      (when designs
        (insert "* My designs\n\n"
                "Made for something specific of mine.\n\n"))
      (pcase-dolist (`(,group . ,models) designs)
        (insert (format "** %s\n\n" (capitalize group))
                (if (equal group "keycaps")
                    (concat "My keycaps.\n"
                            "The designs share a library, =keycap.rhai=, which each of them imports.\n\n")
                  "")
                (keycap-site-cards models))))))

(provide 'keycap-site-gallery)

;;; keycap-site-gallery.el ends here
