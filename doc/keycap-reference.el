;;; keycap-reference.el --- The manual's reference, from the server's docs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The reference chapters of keycap.org write no entries themselves: each
;; section has a line `#+keycap-reference: FILE', FILE the file that
;; describes its functions -- a prelude file, a module, or one of the
;; server's docs/*.toml -- and the server's `docs' reply has their
;; entries, from the prelude's `///' comments, the toml files and fidget's
;; own reflection.  `keycap-reference-expand' writes each section's
;; entries in its line's place, as Org, for Info or for the site:
;;
;;     emacs --batch -l keycap-reference.el --eval \
;;       '(keycap-reference-write "keycap.org" "out.org" (quote texinfo))'
;;
;; An entry's doc is set out as the `///' comments write it: a summary,
;; then parameters (`- `p`: ...'), prose, and the parts `Notes:', `See
;; also:', `References:', `From OpenSCAD:' and `Example:', each a plain
;; text lead that Info shows as it is and the site boxes.

;;; Code:

(require 'keycap)
(require 'keycap-describe)
(require 'org)
(require 'subr-x)


;; --- Entries ---

(defun keycap-reference-entries (docs)
  "The server's DOCS reply as a hash table from name to entry.
Shapes, functions and the modules' functions alike."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (key '(shapes functions modules))
      (dolist (entry (alist-get key docs))
        (puthash (alist-get 'name entry) entry table)))
    table))

(defun keycap-reference--variable-p (entry)
  "Non-nil when ENTRY is a variable: its every signature `name: Type'.
The names may be its aliases'."
  (seq-every-p (lambda (signature)
                 (string-match-p (concat "\\`" keycap--name-regexp ": ") signature))
               (alist-get 'signatures entry)))

(defun keycap-reference--split (doc)
  "DOC as (SUMMARY . REST): its first paragraph on one line, and the others."
  (let* ((doc (string-trim (or doc "")))
         (end (string-match "\n[ \t]*\n" doc)))
    (cons (string-join (split-string (substring doc 0 end) "[ \t\n]+" t) " ")
          (if end (string-trim (substring doc end)) ""))))


;; --- Text ---

;; The `///' comments' text is Markdown's code and links; as Org, code is
;; `~name~' for what the reference describes and `=text=' otherwise, as
;; the hand-written chapters write them.

(defconst keycap-reference--before "-[:space:]('\"{"
  "The characters Org lets stand before inline code; see `org-emphasis-regexp-components'.")

(defconst keycap-reference--after "-[:space:].,:!?;'\")}\\["
  "The characters Org lets stand after inline code.")

(defun keycap-reference--code (code names)
  "CODE, a quoted piece of text, as Org's inline code.
A name in NAMES, a hash table, is `~code~', anything else `=verbatim='."
  (let ((marker (cond ((string-search "~" code) "=")
                      ((string-search "=" code) "~")
                      ((gethash code names) "~")
                      (t "="))))
    (concat marker code marker)))

(defun keycap-reference--inline (text names)
  "TEXT, a line of a doc, as Org: its code and links converted.
Code that Org would not see as code where it stands, as in `[`a`]', is
set apart by a zero-width space.  NAMES are the names the reference
describes."
  (let ((text (replace-regexp-in-string
               keycap-link-regexp "[[\\2][\\1]]" text t))
        (start 0)
        parts)
    (while (string-match "`\\([^`\n]+\\)`" text start)
      (let ((before (and (> (match-beginning 0) 0) (aref text (1- (match-beginning 0)))))
            (after (and (< (match-end 0) (length text)) (aref text (match-end 0))))
            (code (keycap-reference--code (match-string 1 text) names)))
        (push (substring text start (match-beginning 0)) parts)
        (when (and before (not (string-match-p (format "[%s]" keycap-reference--before)
                                               (string before))))
          (push "\u200b" parts))
        (push code parts)
        (when (and after (not (string-match-p (format "[%s]" keycap-reference--after)
                                              (string after))))
          (push "\u200b" parts))
        (setq start (match-end 0))))
    (push (substring text start) parts)
    (let ((line (apply #'concat (nreverse parts))))
      ;; What would start a heading, a comment, a table or a fixed-width
      ;; line in Org is set apart too.
      (if (string-match-p "\\`\\(?:\\*\\|#\\||\\|: \\)" line)
          (concat "\u200b" line)
        line))))

(defun keycap-reference--statements (code)
  "CODE with a line per statement: a newline after each `;' outside brackets."
  (let ((depth 0)
        (parts nil)
        (start 0))
    (dotimes (i (length code))
      (pcase (aref code i)
        ((or ?\( ?\[ ?{) (setq depth (1+ depth)))
        ((or ?\) ?\] ?}) (setq depth (1- depth)))
        ((and ?\; (guard (zerop depth)))
         (push (string-trim (substring code start (1+ i))) parts)
         (setq start (1+ i)))))
    (string-join (nreverse (cons (string-trim (substring code start)) parts)) "\n")))

(defun keycap-reference--example-block (line)
  "LINE, an example in a line, `Example: `code`, what it shows', as a block.
Nil for any other line.  What it shows is the caption; that it is a
value, `is 3.5', is left to the site, which shows the value."
  (when (string-match "\\`Example: `\\([^`\n]+\\)`\\(.*\\)\\'" line)
    (let* ((code (match-string 1 line))
           (rest (string-trim (match-string 2 line)))
           (caption (if (string-match-p "\\`\\(?:is\\|gives\\) " rest)
                        ""
                      (string-trim-left rest "\\(?:,\\|:\\|--\\) *"))))
      (concat "Example:" (if (string-empty-p caption) "" (concat " " caption))
              "\n```\n" (keycap-reference--statements code) "\n```"))))

(defun keycap-reference--org (doc names &optional site)
  "DOC, the text of a `///' comment after its summary, as Org.
Fenced code is a source block, a parameter or key, `- `p`: ...', a
description item.  For the SITE, an example in a line is a block too,
as `keycap-reference--example-block' makes it, and an example's view,
` [view: ...]' at the end of its line, is kept for the site's picture;
for Info it is left out.  NAMES are the names the reference describes."
  (setq doc (mapconcat (lambda (line)
                         (cond
                          ((not site)
                           (replace-regexp-in-string "\\`\\(Example:.*?\\) *\\[view: [^]\n]+\\]\\'"
                                                     "\\1" line))
                          ((keycap-reference--example-block line))
                          (t line)))
                       (split-string doc "\n") "\n"))
  (let (fence lines)
    (dolist (line (split-string doc "\n"))
      (push (cond
             (fence
              (if (string-match-p "\\`[ \t]*```[ \t]*\\'" line)
                  (prog1 (concat fence "#+end_src")
                    (setq fence nil))
                (concat fence (org-escape-code-in-string (string-remove-prefix fence line)))))
             ((string-match "\\`\\([ \t]*\\)```" line)
              (setq fence (match-string 1 line))
              (concat fence "#+begin_src rhai"))
             ((string-match (concat "\\`\\([ \t]*\\)- \\(`[^`\n]+`\\(?:, `[^`\n]+`\\)*\\):"
                                    "\\(?: \\(.*\\)\\)?\\'")
                            line)
              ;; Its name is a parameter's or a key's, whatever else it names.
              (let ((indent (match-string 1 line))
                    (tag (match-string 2 line))
                    (text (match-string 3 line)))
                (concat indent "- " (keycap-reference--inline tag (make-hash-table)) " ::"
                        (when text (concat " " (keycap-reference--inline text names))))))
             ;; An `Example:' line right after other text starts a paragraph
             ;; of its own.
             ((and (string-prefix-p "Example:" line) lines (not (string-empty-p (car lines))))
              (push "" lines)
              (keycap-reference--inline line names))
             (t
              (keycap-reference--inline line names)))
            lines))
    (string-join (nreverse lines) "\n")))


;; --- Info ---

;; Info's entries are Texinfo's generic definitions, a line per call
;; without an index entry each, so the index has each name once, under
;; its full name: `@defline Function offset (shape: Shape, d: Tree): Shape',
;; then `@defline Method shape.offset (d: Tree): Shape'.

(defun keycap-reference--texinfo (text)
  "TEXT with Texinfo's special characters quoted."
  (replace-regexp-in-string "[@{}]" (lambda (c) (concat "@" c)) text t t))

(defun keycap-reference--defline (name signature)
  "The `@defline' of SIGNATURE, a way to call NAME."
  (let ((signature (string-join (split-string signature "[ \t\n]+" t) " ")))
    (cond
     ;; A call, or its method form: the name, then the parameters
     ((string-match (concat "\\`\\(\\(?:" keycap--name-regexp "\\.\\)?\\)"
                            (regexp-quote name) "(")
                    signature)
      (format "%s %s%s %s"
              (if (string-empty-p (match-string 1 signature)) "Function" "Method")
              (match-string 1 signature) name
              (keycap-reference--texinfo (substring signature (1- (match-end 0))))))
     ;; A variable, the name's or an alias's: the name, then its type
     ((string-match (concat "\\`\\(" keycap--name-regexp ":\\) ") signature)
      (format "Variable {%s} %s"
              (keycap-reference--texinfo (match-string 1 signature))
              (keycap-reference--texinfo (substring signature (match-end 0)))))
     ;; An operator: the expression
     (t (format "Operator {%s}" (keycap-reference--texinfo signature))))))

(defun keycap-reference--info-entry (entry names)
  "ENTRY as Org for Info: a Texinfo definition, its doc inside.
NAMES are the names the reference describes."
  (pcase-let* ((name (alist-get 'name entry))
               (`(,summary . ,rest) (keycap-reference--split (alist-get 'doc entry)))
               (types (alist-get 'types entry)))
    (concat (mapconcat (lambda (name) (format "#+findex: %s\n" name))
                       (cons name (alist-get 'aliases entry)) "")
            "#+texinfo: @defblock\n"
            (mapconcat (lambda (signature)
                         (format "#+texinfo: @defline %s\n"
                                 (keycap-reference--defline name signature)))
                       (alist-get 'signatures entry) "")
            (when types
              (concat "#+begin_example\n"
                      (mapconcat (lambda (type)
                                   (org-escape-code-in-string (keycap--set-out-type type)))
                                 types "\n\n")
                      "\n#+end_example\n"))
            (keycap-reference--inline summary names) "\n"
            (unless (string-empty-p rest)
              (concat "\n" (keycap-reference--org rest names) "\n"))
            "#+texinfo: @end defblock\n")))


;; --- Site ---

;; The site's entries are the items of a description list, `- Function:
;; offset :: summary', as Org writes Texinfo's definitions; the site sets
;; out their signatures from the server's docs in place of the name.

(defun keycap-reference--html-entry (entry names)
  "ENTRY as Org for the site: a description item, its doc inside.
Its aliases follow it as `#+findex' lines, which the site's index lists
with the entry they follow; they end the list, so an entry with aliases
had better be its section's last.  NAMES are the names the reference
describes."
  (pcase-let ((`(,summary . ,rest) (keycap-reference--split (alist-get 'doc entry))))
    (concat (format "- %s: %s :: %s\n"
                    (if (keycap-reference--variable-p entry) "Variable" "Function")
                    (alist-get 'name entry)
                    (keycap-reference--inline summary names))
            (unless (string-empty-p rest)
              (concat "\n"
                      (replace-regexp-in-string
                       "^\\(.\\)" "  \\1" (keycap-reference--org rest names t))
                      "\n"))
            (when-let* ((aliases (alist-get 'aliases entry)))
              (concat "\n"
                      (mapconcat (lambda (alias) (format "#+findex: %s\n" alias))
                                 aliases ""))))))


;; --- Sections ---

(defun keycap-reference--section (section entries backend)
  "The entries of SECTION, from the server's `sections', as Org for BACKEND.
ENTRIES are every entry by name; a module's section starts with its
import."
  (let ((module (alist-get 'module section))
        (entry (if (eq backend 'texinfo)
                   #'keycap-reference--info-entry
                 #'keycap-reference--html-entry)))
    (concat
     (when module
       (format "=import \"keycap/%s\" as %s;=\n\n"
               (file-name-base (alist-get 'file section)) module))
     (mapconcat (lambda (name)
                  (funcall entry
                           (or (gethash name entries) (error "%s is not described" name))
                           entries))
                (alist-get 'names section)
                "\n"))))

(defun keycap-reference-expand (backend &optional docs)
  "Write the reference's entries in place of the markers of the current buffer.
BACKEND is `texinfo' for the Info manual or `html' for the site.  DOCS
is the server's `docs' reply, by default the keycap dialect's.  Every
file that describes functions must have its marker, and each only one."
  (let* ((docs (or docs (keycap-docs 'keycap)))
         (entries (keycap-reference-entries docs))
         (sections (alist-get 'sections docs))
         (unplaced (mapcar (lambda (section) (alist-get 'file section)) sections)))
    ;; The hand-written chapters' examples name their pictures' views for
    ;; the site; Info has no pictures.
    (unless (eq backend 'html)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "^\\([ \t]*Example:.*?\\) *\\[view: [^]\n]+\\]$" nil t)
          (replace-match "\\1" t))))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^#\\+keycap-reference: \\(.+\\)$" nil t)
        (let* ((file (string-trim (match-string 1)))
               (section (seq-find (lambda (section) (equal (alist-get 'file section) file))
                                  sections)))
          (unless section
            (error "No section of the server's docs is %s" file))
          (unless (member file unplaced)
            (error "%s has two places in the manual" file))
          (setq unplaced (delete file unplaced))
          (delete-region (match-beginning 0) (match-end 0))
          (insert (string-trim-right (keycap-reference--section section entries backend))))))
    (when unplaced
      (error "The manual has no place for %s" (string-join unplaced ", ")))))

(defun keycap-reference-write (in out backend)
  "Write the Org file IN, its reference expanded for BACKEND, to OUT."
  (with-temp-buffer
    (insert-file-contents in)
    (keycap-reference-expand backend)
    (write-region nil nil out)))

(provide 'keycap-reference)

;;; keycap-reference.el ends here
