;;; keycap-site-manual.el --- keycap's site: the manual  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

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
;; Reading signatures ends with their legend.  A type in a signature links
;; to its term in the Types list of Concepts, which says what is a type.
;;
;; Loaded by publish.el, on top of its page frame.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ox-html)
(require 'keycap)
(require 'ob-keycap)


;; --- Reference ---

(load (expand-file-name "doc/keycap-reference.el" keycap-site-keycap) nil t)

(defconst keycap-site-manual-docs (keycap-docs 'keycap)
  "The keycap server's `docs' reply, which the reference is written from.")

(defconst keycap-site-manual-table (keycap-reference-entries keycap-site-manual-docs)
  "Every entry of the reference, by name.")

(defun keycap-site-manual-entry (name)
  "The reference's entry of NAME, from the server's docs, or nil."
  (gethash name keycap-site-manual-table))

(defun keycap-site-manual-origin (name)
  "Where NAME comes from: \"fidget\", \"keycap\" or \"rhai\", or nil when unknown."
  (when-let* ((entry (keycap-site-manual-entry name)))
    (if (alist-get 'fields entry)
        "fidget"
      (pcase (alist-get 'source entry)
        ("fidget" "fidget")
        ((or "prelude" "keycap" "module") "keycap")
        ("rhai" "rhai")))))

(defconst keycap-site-manual-legend
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

(defvar keycap-site-manual-types nil
  "The types the manual's Types section lists, as (NAME . PAGE), PAGE its chapter's.")

(defun keycap-site-manual-read-types ()
  "The types the Types section of the manual in the current buffer lists, as (NAME . PAGE).
Each is a term of its list, or one of the names a term lists."
  (when-let* ((heading (org-find-property "CUSTOM_ID" "types")))
    (save-excursion
      (goto-char heading)
      (let ((page (cdr (keycap-site-manual-section)))
            (end (save-excursion (org-end-of-subtree t t)))
            types)
        (while (re-search-forward "^- \\(=[^=\n]+=\\(?:, =[^=\n]+=\\)*\\) ::" end t)
          (dolist (name (split-string (match-string-no-properties 1) "[=, ]+" t))
            (push (cons name page) types)))
        (nreverse types)))))

(defun keycap-site-manual-type-anchors (html _backend _info)
  "Give each name a term of the Types section in HTML lists its anchor, type-NAME."
  (if-let* ((start (string-search "<section id=\"outline-container-types\"" html))
            (end (string-search "</section>" html start)))
      (concat (substring html 0 start)
              (replace-regexp-in-string
               "<dt>\\(?:<code>[^<]+</code>\\(?:, \\)?\\)+</dt>"
               (lambda (dt)
                 (replace-regexp-in-string "<code>\\([^<]+\\)</code>" "<code id=\"type-\\1\">\\1</code>"
                                           dt t))
               (substring html start end) t t)
              (substring html end))
    html))

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-manual-type-anchors)


;; --- Examples ---

(defconst keycap-site-manual-unpictured
  '("and"                               ; 0 or 5, no surface
    "mix"                               ; rand's example
    "svg")                              ; needs a file beside the script
  "Functions whose examples are no shape worth a picture, or need a file; their boxes have code only.")

(defconst keycap-site-manual-plots
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

(defun keycap-site-manual-draws-p (code)
  "Non-nil when CODE draws at its top level."
  (with-temp-buffer
    (insert code)
    (keycap-script-draws)))

(defun keycap-site-manual-statements (code)
  "CODE's statements, each with the comments before it, then its last expression."
  (with-temp-buffer
    (insert code)
    (let ((start (point-min)))
      (mapcar (pcase-lambda (`(,_ . ,end))
                (prog1 (string-trim (buffer-substring-no-properties start end))
                  (setq start end)))
              (keycap-script-statements)))))

(defun keycap-site-manual-draw (code)
  "CODE with its last expression drawn, unless it draws itself."
  (if (keycap-site-manual-draws-p code)
      code
    (let ((statements (keycap-site-manual-statements code)))
      (string-join (append (butlast statements)
                           (list (format "draw(%s);" (car (last statements)))))
                   "\n"))))

(defconst keycap-site-manual-imports
  (mapconcat (lambda (section)
               (format "import \"keycap/%s\" as %s;\n"
                       (file-name-base (alist-get 'file section)) (alist-get 'module section)))
             (seq-filter (lambda (section) (alist-get 'module section))
                         (alist-get 'sections keycap-site-manual-docs))
             "")
  "Every module of the prelude, imported as its section of the reference names it.")

(defun keycap-site-manual-script (name code)
  "The script that draws CODE, the example of NAME: with the modules, for a module's."
  (concat (when (equal (alist-get 'source (keycap-site-manual-entry name)) "module")
            keycap-site-manual-imports)
          (keycap-site-manual-draw code)))

(defvar keycap-site-manual-values (make-hash-table :test #'equal)
  "The value of each example's code, as the server describes it.")

(defun keycap-site-manual-evaluate (codes)
  "Keep the values of CODES, the examples' code, in `keycap-site-manual-values'.
One server evaluates them all, with every module imported."
  (seq-mapn (lambda (code reply)
              (puthash code (alist-get 'value reply) keycap-site-manual-values))
            codes
            (keycap-server-batch (mapcar (lambda (code)
                                           `((op . "eval")
                                             (source . ,keycap-site-manual-imports)
                                             (expression . ,code)))
                                         codes))))

(defun keycap-site-manual-shape-p (code)
  "Non-nil when the example CODE draws or makes a shape, as far as is known.
A tree with nothing inside, such as a factor, is no shape."
  (let ((value (gethash code keycap-site-manual-values)))
    (or (keycap-site-manual-draws-p code)
        (not value)
        (and (string-prefix-p "tree:" value)
             (not (string-suffix-p "; empty" value))))))

(defun keycap-site-manual-value (code)
  "The value of the example CODE, as the box shows it."
  (string-remove-suffix "; empty" (gethash code keycap-site-manual-values)))

(defun keycap-site-manual-sentence (text)
  "TEXT with a capital first letter."
  (if (string-empty-p text)
      text
    (concat (upcase (substring text 0 1)) (substring text 1))))

(defun keycap-site-manual-plain (text)
  "TEXT without Org's markup for code."
  (replace-regexp-in-string "[=~]\\([^=~\n]+\\)[=~]" "\\1" text))

(defconst keycap-site-manual-example-size "\"480 360\""
  "The size of an example box's picture, twice as large as it is shown.")

(defconst keycap-site-manual-example-columns 42
  "The longest line of code that fits beside an example's picture.
An example with a longer one has its picture below the code instead.")

(defconst keycap-site-manual-example-regexp
  (concat "^\\([ \t]*\\)Example:\\(?: \\(.*\\)\\)?\n"
          "[ \t]*#\\+begin_src rhai\n\\(\\(?:.\\|\n\\)*?\\)[ \t]*#\\+end_src\n")
  "An entry's example: its indentation, its caption and its code.")

(defun keycap-site-manual-box (name model caption code &optional script view)
  "An example box, as Org: CAPTION, CODE beside its picture, MODEL the picture's name.
NAME's examples are drawn with its module imported; SCRIPT, if any, is
drawn instead of CODE.  VIEW, as `keycap-site-view-arguments' takes it, sets
the picture's view.  An example of no shape has its value in the
picture's place, one of `keycap-site-manual-unpictured' only its code."
  (let ((value (unless (or script (keycap-site-manual-shape-p code))
                 (keycap-site-manual-value code)))
        (pictured (or script (not (member name keycap-site-manual-unpictured)))))
    (concat (format "#+html: <figure class=\"example%s\"><figcaption><span>Example</span>\n"
                    (if (or value (not pictured)
                            (> (apply #'max (mapcar #'string-width (split-string code "\n")))
                               keycap-site-manual-example-columns))
                        " wide"
                      ""))
            (keycap-site-manual-sentence caption) "\n"
            "#+html: </figcaption><div class=\"example-code\">\n"
            "#+begin_src rhai\n" (org-escape-code-in-string code) "\n#+end_src\n"
            (cond
             (value
              (format "#+html: </div><div class=\"example-value\"><code>%s</code>\n"
                      (org-html-encode-plain-text value)))
             (pictured
              (concat "#+html: </div><div class=\"example-pic\">\n"
                      (format "#+begin_src keycap :model %s :frame no :exports results :size %s %s :alt %s\n"
                              model keycap-site-manual-example-size
                              (if view (keycap-site-view-arguments view) "")
                              (keycap-site-manual-sentence (keycap-site-manual-plain caption)))
                      (org-escape-code-in-string (or script (keycap-site-manual-script name code))) "\n"
                      "#+end_src\n")))
            "#+html: </div></figure>\n")))

(defun keycap-site-manual-box-examples (name model begin end)
  "Box every example between BEGIN and END, as `keycap-site-manual-box' does, NAME's if any.
Their pictures are MODEL, MODEL-2 and on; END is a marker."
  (save-excursion
    (goto-char begin)
    (let ((n 0))
      (while (re-search-forward keycap-site-manual-example-regexp end t)
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
                   (keycap-site-manual-box name (format "%s%s" model (if (> (cl-incf n) 1) (format "-%d" n) ""))
                                           caption code nil view))))))))


;; --- Entries ---

(defvar keycap-site-manual-section-kinds (make-hash-table :test #'equal)
  "The kind of each reference section's entries, by its anchor.")

(defun keycap-site-manual-signature (name)
  "NAME's signatures and types as keycap sets them out, as HTML on one line.
Each line is a span, its indentation and keycap's `wrap-prefix' as
properties, and a parameter's text of the class p, so that a line too
long for the page wraps at a parameter, the rest as far in as that.  A
type of `keycap-site-manual-types' is a link to it.  Nil when it has
none."
  (when-let* ((entry (keycap-site-manual-entry name))
              (signatures (alist-get 'signatures entry)))
    (concat "<code class=\"sig\">"
            (mapconcat (lambda (line)
                         (let ((text (string-trim-left line)))
                           (if (string-empty-p text)
                               "<span class=\"sig-gap\"></span>"
                             (format "<span style=\"--indent: %d; --hang: %d\">%s</span>"
                                     (- (length line) (length text))
                                     (length (get-text-property 0 'wrap-prefix line))
                                     (replace-regexp-in-string
                                      "<span class=\"hl-\\(?:keycap-tree-\\)?type[^\"]*\">\\([^<]+\\)</span>"
                                      (lambda (span)
                                        (if-let* ((page (cdr (assoc (match-string 1 span) keycap-site-manual-types))))
                                            (format "<a class=\"type\" href=\"%s.html#type-%s\">%s</a>"
                                                    page (match-string 1 span) span)
                                          span))
                                      (ob-keycap-html
                                       text (lambda (i)
                                              (and (get-text-property i 'keycap-parameter text) '("p"))))
                                      t t)))))
                       (split-string (keycap-set-out-signatures signatures (alist-get 'types entry)) "\n")
                       "")
            "</code>")))

(defconst keycap-site-manual-parts
  '(("Notes" . "part quiet")
    ("See also" . "part")
    ("References" . "part")
    ("From OpenSCAD" . "part quiet"))
  "The parts of an entry boxed apart from its text, and their classes.")

(defun keycap-site-manual-set-out (name anchor begin end)
  "Box the parts and the examples of NAME's entry ANCHOR, between BEGIN and END.
END is a marker, kept after what is added; a function of a number gets
a box of its graph too."
  (save-excursion
    (keycap-site-manual-box-examples name anchor begin end)
    (when-let* ((plot (assoc name keycap-site-manual-plots)))
      (pcase-let* ((`(,_ ,expression ,lower ,upper) plot)
                   (indent (progn (goto-char begin) (make-string (+ 2 (current-indentation)) ?\s))))
        (goto-char end)
        (insert "\n" (replace-regexp-in-string
                      "^\\(.\\)" (concat indent "\\1")
                      (keycap-site-manual-box name (concat anchor "-graph")
                                              (format "the graph of ~%s~, inside below the curve" name)
                                              expression
                                              (format "bounds(%s, %s);\ndraw(%s);"
                                                      (string-replace "]" ", -1]" (or lower "[-5, -8]"))
                                                      (string-replace "]" ", 1]" (or upper "[25, 28]"))
                                                      expression))))))
    (keycap-site-manual-box-parts begin end)))

(defun keycap-site-manual-box-parts (begin end)
  "Box every part between BEGIN and END, `Notes:' and the others of `keycap-site-manual-parts'.
END is a marker.  A part is its lead and the list or the text after it."
  (save-excursion
    (pcase-dolist (`(,lead . ,class) keycap-site-manual-parts)
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

(defun keycap-site-manual-anchor (name n)
  "The anchor of the Nth entry of NAME, counting from 1: fn-NAME, then fn-NAME-2.
A module's function, `screws::hole', is fn-screws-hole."
  (format "fn-%s%s"
          (mapconcat (lambda (c)
                       (or (alist-get c '((?+ . "plus") (?% . "percent") (?< . "less") (?> . "greater")))
                           (string c)))
                     (string-replace "::" "-" name) "")
          (if (> n 1) (format "-%d" n) "")))

(defconst keycap-site-manual-retired-anchors
  (append
   '(("fn-plane-2" . "fn-plane")
     ("fn-draw-2" . "fn-draw"))
   (mapcar (lambda (name) (cons (keycap-site-manual-anchor name 1) "fn-PI"))
           '("TAU" "E" "PHI" "GOLDEN_RATIO" "SQRT_2" "FRAC_1_SQRT_2" "FRAC_PI_2" "FRAC_PI_3"
             "FRAC_PI_4" "FRAC_PI_6" "FRAC_PI_8" "FRAC_1_PI" "FRAC_2_PI" "FRAC_2_SQRT_PI"
             "LN_2" "LN_10" "LOG2_E" "LOG10_E"))
   (mapcar (lambda (name) (cons (keycap-site-manual-anchor name 1) (keycap-site-manual-anchor "<" 1)))
           '("<=" ">" ">=" "==" "!=")))
  "Anchors of entries the manual no longer has, and the entries that took them in.
`plane''s Plane value is in its shape's entry, `draw''s options in its one entry,
the constants are `PI''s aliases and the comparison operators `<''s.")

(defun keycap-site-manual-section ()
  "The anchors of the heading point is under and of its chapter, as a cons."
  (save-excursion
    (org-back-to-heading t)
    (let ((section (org-entry-get nil "CUSTOM_ID")))
      (while (org-up-heading-safe))
      (cons section (org-entry-get nil "CUSTOM_ID")))))

(defun keycap-site-manual-entries ()
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
      (let ((section (save-match-data (car (keycap-site-manual-section)))))
        (cond
         ((match-beginning 1)
          (let ((name (match-string-no-properties 2)))
            (push (list :name name
                        :anchor (keycap-site-manual-anchor name (cl-incf (gethash name counts 0)))
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
    (keycap-site-manual-evaluate
     (delete-dups (save-excursion
                    (goto-char (point-min))
                    (cl-loop while (re-search-forward keycap-site-manual-example-regexp nil t)
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
             (kind (alist-get 'kind (keycap-site-manual-entry name))))
        (when kind
          (puthash (plist-get entry :section) kind keycap-site-manual-section-kinds))
        (keycap-site-manual-set-out name anchor (point) end)
        ;; Where the anchor goes on the entry's <dt>, with its kind and
        ;; origin, see `keycap-site-manual-anchors'; and the signatures, in place
        ;; of the name.
        (forward-char 2)
        (let ((signature (keycap-site-manual-signature name)))
          (when signature
            (delete-region (point) (save-excursion (search-forward " ::") (match-beginning 0))))
          (insert (format "@@html:<!--%s %s %s-->%s@@"
                          anchor
                          (or kind "-")
                          (or (keycap-site-manual-origin name) "-")
                          (or signature ""))))))
    ;; The hand-written chapters' examples are boxed as the entries' are,
    ;; their pictures named after their sections.
    (let ((counts (make-hash-table :test #'equal)))
      (goto-char (point-min))
      (while (re-search-forward keycap-site-manual-example-regexp nil t)
        (let* ((section (save-match-data (car (keycap-site-manual-section))))
               (n (cl-incf (gethash section counts 0))))
          (keycap-site-manual-box-examples nil (format "ex-%s%s" section (if (> n 1) (format "-%d" n) ""))
                                           (match-beginning 0) (copy-marker (match-end 0) t))))
      ;; And their parts, the entries' being boxed already.
      (keycap-site-manual-box-parts (point-min) (copy-marker (point-max) t)))
    (list (nreverse entries) (nreverse keys) (nreverse concepts))))

(defun keycap-site-manual-anchors (html _backend _info)
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

(defun keycap-site-manual-mark-kinds (html _backend _info)
  "Mark each reference section in HTML, and each item of a list that links to one, with its kind."
  (replace-regexp-in-string
   (concat "<section id=\"outline-container-\\([^\"]+\\)\" class=\"outline-2\""
           "\\|<\\(li\\|dt\\)>\\(\\(?:<span id=\"[^\"]+\"></span>\\)?<a href=\"[^\"#]*#\\([^\"]+\\)\"\\)")
   (lambda (match)
     (let ((kind (gethash (or (match-string 1 match) (match-string 4 match)) keycap-site-manual-section-kinds)))
       (cond
        ((not kind) match)
        ((match-beginning 1)
         (format "<section id=\"outline-container-%s\" class=\"outline-2 k-%s\""
                 (match-string 1 match) kind))
        (t
         (format "<%s class=\"k-%s\">%s" (match-string 2 match) kind (match-string 3 match))))))
   html t t))

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-manual-mark-kinds)

(add-to-list 'org-export-filter-final-output-functions #'keycap-site-manual-anchors)


;; --- Pages ---

(defun keycap-site-manual-link (target title chapter)
  "An Org link to TARGET, a heading's (ID CHAPTER-ID), titled TITLE, from the page CHAPTER."
  (pcase-let ((`(,id ,page) target))
    (cond
     ((equal id page) (format "[[file:%s.org][%s]]" page title))
     ((equal page chapter) (format "[[#%s][%s]]" id title))
     (t (format "[[file:%s.org::#%s][%s]]" page id title)))))

(defun keycap-site-manual-nav (chapters current)
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

(defun keycap-site-manual-chapter (chapter previous next chapters targets)
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
                           (keycap-site-manual-link (or (cdr (assoc heading targets))
                                                        (error "The manual links to no heading %s" heading))
                                                    (or (match-string 2 link) heading)
                                                    id)))
                       text t t)))
               (first (string-match "^\\* " body)))
    ;; The page's contents go after the chapter's opening text, when it
    ;; has two sections or more.
    (when (and first (string-match "\n\\* " body first))
      (setq body (concat (substring body 0 first) "#+toc: headlines 2\n\n" (substring body first))))
    (with-temp-file (keycap-site-path "content" "manual" (concat id ".org"))
      (insert (format "#+title: %s\n" title)
              (format "#+description: %s\n" (or description ""))
              (format "#+html_head_extra: <link rel=\"prev\" href=\"%s.html\">\n" (car previous))
              (if next (format "#+html_head_extra: <link rel=\"next\" href=\"%s.html\">\n" (car next)) "")
              "\n"
              (keycap-site-manual-nav chapters id)
              body
              "\n"
              "#+html: " (keycap-site-pager previous '("index" "Contents") next) "\n"))))

(defun keycap-site-write-manual ()
  "Write content/manual/ from keycap's manual: a page per chapter, and the index."
  (let ((directory (keycap-site-path "content" "manual"))
        headings chapters)
    (delete-directory directory t)
    (make-directory directory)
    (with-temp-buffer
      (insert-file-contents (expand-file-name "doc/keycap.org" keycap-site-keycap))
      (keycap-reference-expand 'html keycap-site-manual-docs)
      (delay-mode-hooks (org-mode))
      (keycap-site-name-headings nil)
      (setq keycap-site-manual-types (keycap-site-manual-read-types))
      ;; The legend of the entries' strips ends Reading signatures.
      (when-let* ((heading (org-find-property "CUSTOM_ID" "reading-signatures")))
        (save-excursion
          (goto-char heading)
          (org-end-of-subtree t t)
          (insert keycap-site-manual-legend "\n")))
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
      (pcase-let ((`(,entries ,keys ,concepts) (keycap-site-manual-entries))
                  (subtitle (cadar (org-collect-keywords '("SUBTITLE")))))
        (org-map-entries
         (lambda ()
           (let ((id (org-entry-get nil "CUSTOM_ID"))
                 (title (org-get-heading t t t t)))
             (push (list (org-current-level) title id (cdr (keycap-site-manual-section))) headings)
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
                   do (keycap-site-manual-chapter chapter (list (car previous) (cadr previous))
                                                  (when next (list (car next) (cadr next)))
                                                  pages targets))
          (keycap-site-write-manual-index subtitle headings pages entries keys concepts))))))

(defun keycap-site-write-manual-index (subtitle headings chapters entries keys concepts)
  "Write the manual's index page, under SUBTITLE.
It lists HEADINGS, (LEVEL TITLE ID CHAPTER-ID) each, ENTRIES, KEYS and
CONCEPTS, as `keycap-site-manual-entries' returns them, and links to CHAPTERS."
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
    (with-temp-file (keycap-site-path "content" "manual" "index.org")
      (insert "#+title: Manual\n"
              (format "#+subtitle: %s\n" subtitle)
              "#+description: keycap's manual: the editor, the language and every function, with pictures.\n"
              (format "#+html_head_extra: <link rel=\"next\" href=\"%s.html\">\n\n" (caar chapters))
              (keycap-site-manual-nav chapters "index")
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
                                                                    keycap-site-manual-retired-anchors)))
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

(provide 'keycap-site-manual)

;;; keycap-site-manual.el ends here
