;;; keycap-describe.el --- The reference of keycap's functions and shapes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; What `keycap-describe' shows of a function or a shape: its kind, its
;; signatures set out for reading, its doc with links to the names it
;; quotes, and a shape's fields; without a name, the whole reference by
;; category.  The manual's site sets out signatures the same way.

;;; Code:

(require 'help-mode)
(require 'keycap)

;; --- Kinds ---

;; Every entry of the reference has a kind, which the file that describes
;; it declares: what its functions make.  The manual's site shows it as a
;; strip in the kind's colour, C-c C-d as a word in it.

(defconst keycap-kinds
  '(("2d" "2D" "a shape in the XY plane")
    ("3d" "3D" "a solid")
    ("extrude" "2D to 3D" "a solid made from 2D shapes: extruded, revolved, lofted or swept")
    ("csg" "CSG" "shapes combined, offset or hollowed")
    ("transform" "transform" "a shape moved, turned, scaled or mirrored")
    ("pattern" "pattern" "copies of a shape")
    ("math" "math" "numbers and expressions: arithmetic, easings, vectors")
    ("script" "script" "what a script draws, and where"))
  "The kinds of the reference's entries, as (KIND LABEL MEANING).
KIND is what a file declares, LABEL what the reference shows; each has
the face `keycap-kind-KIND'.")

(defface keycap-kind-2d
  '((((background dark)) :foreground "#aad94c") (t :foreground "#5b7a00"))
  "The kind of 2D shapes, in descriptions.")

(defface keycap-kind-3d
  '((((background dark)) :foreground "#59c2ff") (t :foreground "#1f6fb5"))
  "The kind of solids, in descriptions.")

(defface keycap-kind-extrude
  '((((background dark)) :foreground "#95e6cb") (t :foreground "#2d8f73"))
  "The kind of solids made from 2D shapes, in descriptions.")

(defface keycap-kind-csg
  '((((background dark)) :foreground "#f07178") (t :foreground "#d33a46"))
  "The kind of combinations and offsets, in descriptions.")

(defface keycap-kind-transform
  '((((background dark)) :foreground "#d2a6ff") (t :foreground "#8a55c4"))
  "The kind of transforms, in descriptions.")

(defface keycap-kind-pattern
  '((((background dark)) :foreground "#ffb454") (t :foreground "#b78300"))
  "The kind of copies, in descriptions.")

(defface keycap-kind-math
  '((t :foreground "#8a9199"))
  "The kind of numbers and expressions, in descriptions.")

(defface keycap-kind-script
  '((((background dark)) :foreground "#ff8cbe") (t :foreground "#d0558f"))
  "The kind of the script API, in descriptions.")

(defun keycap--kind-label (kind)
  "The label of KIND, in its face; nil for no kind."
  (when-let* ((label (cadr (assoc kind keycap-kinds))))
    (propertize label 'face (intern (concat "keycap-kind-" kind)))))


;; --- Signatures ---

;; A description's signatures are set out for reading, by C-c C-d and by
;; the manual's site alike.  Every call has its function's name in the
;; same column, so a plain call stands as far right as the method form's
;; receiver.  A call longer than `keycap-signature-width' takes a line per
;; parameter, and a map type a line per key, their names, types and
;; defaults in columns.  The types follow the calls after a blank line.

(defun keycap--signature-split (text)
  "TEXT split at its commas outside brackets, each part trimmed; no empty ones."
  (let ((depth 0)
        (start 0)
        parts)
    (dotimes (index (length text))
      (pcase (aref text index)
        ((or ?\( ?\[ ?{ ?<) (setq depth (1+ depth)))
        ;; The `>' of `=>' and `->' closes nothing.
        ((and ?> (guard (memq (aref text (max 0 (1- index))) '(?= ?-)))))
        ((or ?\) ?\] ?} ?>) (setq depth (1- depth)))
        ((and ?, (guard (zerop depth)))
         (push (substring text start index) parts)
         (setq start (1+ index)))))
    (push (substring text start) parts)
    (delete "" (mapcar #'string-trim (nreverse parts)))))

(defun keycap--signature-close (text open)
  "The index in TEXT of the bracket that closes the one at OPEN, or nil."
  (let ((depth 0)
        (index open)
        close)
    (while (and (not close) (< index (length text)))
      (pcase (aref text index)
        ((or ?\( ?\[ ?{) (setq depth (1+ depth)))
        ((or ?\) ?\] ?}) (setq depth (1- depth))
         (when (zerop depth)
           (setq close index))))
      (setq index (1+ index)))
    close))

(defun keycap--signature-parameter (text)
  "The parameter or key TEXT as (NAME TYPE DEFAULT); TYPE and DEFAULT may be nil."
  (if (string-match (concat "\\`\\(\\(?:\\.\\.\\.\\)?" keycap--name-regexp "\\??\\): ") text)
      (let* ((name (match-string 1 text))
             (rest (substring text (match-end 0)))
             (equals (string-search " = " rest)))
        (list name
              (if equals (substring rest 0 equals) rest)
              (when equals (substring rest (+ equals 3)))))
    (list text nil nil)))

(defun keycap--signature-parameter-text (parameter)
  "PARAMETER, (NAME TYPE DEFAULT), as it is written on one line."
  (pcase-let ((`(,name ,type ,default) parameter))
    (concat name
            (when type (concat ": " type))
            (when default (concat " = " default)))))

(defun keycap--signature-call (signature)
  "SIGNATURE as (RECEIVER NAME MAP PARAMETERS RETURNS), or nil when it is no call.
RECEIVER is `shape.' or empty; MAP is non-nil for a call that takes one
map, whose keys are then the PARAMETERS; RETURNS is what follows the
parentheses, such as `: Shape'."
  (when (string-match (concat "\\`\\(\\(?:" keycap--name-regexp "\\.\\)?\\)"
                              "\\(" keycap--name-regexp "\\(?:::" keycap--name-regexp "\\)*\\)(")
                      signature)
    (let* ((receiver (match-string 1 signature))
           (name (match-string 2 signature))
           (open (1- (match-end 0)))
           (close (keycap--signature-close signature open))
           (inside (substring signature (1+ open) close))
           (map (and (string-prefix-p "#{" inside) (string-suffix-p "}" inside)
                     (eq (keycap--signature-close inside 1) (1- (length inside))))))
      (list receiver name map
            (mapcar #'keycap--signature-parameter
                    (keycap--signature-split (if map (substring inside 2 -1) inside)))
            (substring signature (1+ close))))))

(defun keycap--signature-columns (parameters)
  "The columns PARAMETERS, each (NAME TYPE DEFAULT), are set out in: (NAME . TYPE).
NAME is the widest name with its colon, TYPE the widest type with a default."
  (cons (apply #'max 0 (mapcar (lambda (parameter)
                                 (if (nth 1 parameter) (1+ (length (car parameter))) 0))
                               parameters))
        (apply #'max 0 (mapcar (lambda (parameter)
                                 (if (nth 2 parameter) (length (nth 1 parameter)) 0))
                               parameters))))

(defun keycap--signature-lines (parameters columns indent)
  "PARAMETERS, each (NAME TYPE DEFAULT), a line each at INDENT, set out in COLUMNS."
  (mapconcat (pcase-lambda (`(,name ,type ,default))
               (concat (make-string indent ?\s)
                       (string-trim-right
                        (concat (if type (string-pad (concat name ":") (car columns)) name)
                                (when type
                                  (concat " " (if default (string-pad type (cdr columns)) type)))
                                (when default
                                  (concat " = " default))))
                       ",\n"))
             parameters ""))

(defun keycap--signature-hang (text column)
  "TEXT, each line with a `wrap-prefix' four columns past COLUMN.
Or past the line's own indentation, when that is further in."
  (mapconcat (lambda (line)
               (propertize line 'wrap-prefix
                           (make-string (+ 4 (max column (- (length line)
                                                            (length (string-trim-left line)))))
                                        ?\s)))
             (split-string text "\n")
             "\n"))

(defun keycap--set-out-call (call column columns)
  "CALL, as `keycap--signature-call' gives it, its name at COLUMN.
Without COLUMNS on one line, its parameters with the property
`keycap-parameter'; else a line per parameter, set out in COLUMNS."
  (pcase-let* ((`(,receiver ,name ,map ,parameters ,returns) call)
               (head (concat (make-string (- column (length receiver)) ?\s) receiver name))
               (line (concat head (if map "(#{ " "(")
                             (mapconcat (lambda (parameter)
                                          (propertize (keycap--signature-parameter-text parameter)
                                                      'keycap-parameter t))
                                        parameters ", ")
                             (if map " })" ")") returns)))
    (if (not columns)
        line
      (concat head (if map "(#{" "(") "\n"
              (keycap--signature-lines parameters columns (+ column 4))
              (make-string column ?\s) (if map "})" ")") returns))))

(defun keycap--set-out-type (type)
  "TYPE, a `type' line; a map a line per key, set out in columns."
  (let ((type (string-join (split-string type "[ \t\n]+" t) " ")))
    (if (string-match "\\`\\(type [^=]+ = #{\\)\\(.*\\)}\\'" type)
        (let ((head (match-string 1 type))
              (keys (mapcar #'keycap--signature-parameter
                            (keycap--signature-split (match-string 2 type)))))
          (concat head "\n" (keycap--signature-lines keys (keycap--signature-columns keys) 4) "}"))
      type)))

(defun keycap-set-out-signatures (signatures &optional types)
  "SIGNATURES and the TYPES they name, set out for reading and highlighted.
One string: the calls, then a blank line before each type.  Each line
has a `wrap-prefix' for a window too narrow for it, and each parameter
of a call on one line the property `keycap-parameter', for the manual's
site to keep it whole."
  (let* ((calls (mapcar (lambda (signature)
                          (let ((signature (string-join (split-string signature "[ \t\n]+" t) " ")))
                            (or (keycap--signature-call signature) signature)))
                        signatures))
         (column (apply #'max 0 (mapcar (lambda (call) (if (consp call) (length (car call)) 0))
                                        calls)))
         (long (seq-filter (lambda (call)
                             (and (consp call)
                                  (nth 3 call)
                                  (> (length (keycap--set-out-call call column nil))
                                     keycap-signature-width)))
                           calls))
         ;; The calls that take a line per parameter share their columns.
         (columns (keycap--signature-columns (apply #'append (mapcar (lambda (call) (nth 3 call))
                                                                     long)))))
    (keycap--fontify-signature
     (concat
      (keycap--signature-hang
       (mapconcat (lambda (call)
                    (if (stringp call)
                        call
                      (keycap--set-out-call call column (and (memq call long) columns))))
                  calls "\n")
       column)
      (mapconcat (lambda (type)
                   (concat "\n\n" (keycap--signature-hang (keycap--set-out-type type) 0)))
                 types "")))))


;; --- Descriptions ---

(define-button-type 'keycap-describe
  :supertype 'help-xref
  'help-function #'keycap-describe
  'help-echo "mouse-2, RET: describe this")

(defun keycap--insert-doc (doc &optional module)
  "Insert DOC, its quoted names linked to their descriptions.
A name is looked up as it is, then qualified with MODULE, such as `keycap::'."
  (let ((start (point)))
    (insert doc)
    (save-excursion
      (goto-char start)
      (while (re-search-forward (concat "`\\(" keycap--name-regexp "\\)") nil t)
        (when-let* ((quoted (match-string-no-properties 1))
                    (name (seq-find #'keycap--doc (list quoted (concat module quoted))))
                    ((eq (char-after) ?`)))
          (make-text-button (match-beginning 1) (match-end 1)
                            'type 'keycap-describe
                            'help-args (list name keycap--described)))))))

(defun keycap--fontify-code (code)
  "CODE highlighted by `rhai-ts-mode', when its grammar is there."
  (with-temp-buffer
    (insert code)
    (when (treesit-ready-p 'rhai t)
      (delay-mode-hooks (rhai-ts-mode))
      (font-lock-ensure))
    (buffer-string)))

(defconst keycap-link-regexp
  "\\[\\([^]\n]+\\)\\](\\([a-z]+://\\(?:[^()\n ]\\|([^()\n ]*)\\)+\\))"
  "A Markdown link in a doc: its text is group 1, its URL group 2.
A URL may hold one level of balanced parentheses, as Wikipedia's do.")

(defun keycap--set-out-doc (start end)
  "Set out the doc between START and END as the manual's entries are.
Its parameters' names are highlighted, the leads of its parts bold, its
notes and its comparison with OpenSCAD quieter, its links buttons, and
the code of its examples, between lines of three backquotes,
highlighted and indented.  Point ends at its end."
  (let ((end (copy-marker end t)))
    (goto-char start)
    (while (re-search-forward "^```\n\\(\\(?:.*\n\\)*?\\)```$" end t)
      (let ((code (string-trim-right (match-string 1))))
        (delete-region (match-beginning 0) (match-end 0))
        (insert (replace-regexp-in-string "^" "  " (keycap--fontify-code code)))))
    (goto-char start)
    (while (re-search-forward keycap-link-regexp end t)
      (let ((url (match-string 2)))
        (replace-match (match-string 1) t t)
        (make-text-button (match-beginning 0) (point) 'type 'help-url 'help-args (list url))))
    ;; An example's view is for the manual's site, which renders it.
    (goto-char start)
    (while (re-search-forward "^\\(Example:.*?\\) *\\[view: [^]\n]+\\]$" end t)
      (replace-match "\\1"))
    (goto-char start)
    (while (re-search-forward (concat "^\\(?:\\(Notes:\\|From OpenSCAD:\\)"
                                      "\\|\\(Example:\\|See also:\\|References:\\)"
                                      "\\|[ \t]*- `\\([^`\n]+\\)`:\\)")
                              end t)
      (cond
       ((match-beginning 1)
        (add-face-text-property (match-beginning 1) (match-end 1) 'bold)
        (add-face-text-property (point) (if (re-search-forward "\n\n" end t) (match-beginning 0) end)
                                'shadow))
       ((match-beginning 2)
        (add-face-text-property (match-beginning 2) (match-end 2) 'bold))
       (t
        (add-face-text-property (match-beginning 3) (match-end 3) 'help-argument-name))))
    (goto-char end)))

(defun keycap--insert-signatures (signatures types)
  "Insert SIGNATURES and the TYPES they name, set out and indented."
  (dolist (line (split-string (keycap-set-out-signatures signatures types) "\n"))
    (unless (string-empty-p line)
      (let ((start (point)))
        (insert "  " line)
        (put-text-property start (point) 'wrap-prefix
                           (concat "  " (get-text-property 0 'wrap-prefix line)))))
    (insert "\n")))

(defun keycap--insert-description (name)
  "Insert the description of NAME at point."
  (let* ((entry (keycap--doc name))
         (shape (eq (alist-get 'class entry) 'shape))
         (kind (keycap--kind-label (alist-get 'kind entry)))
         (category (alist-get 'category entry)))
    (insert (propertize name 'face 'help-for-help-header)
            " is a " (if kind (concat kind " ") "")
            (if shape
                "shape"
              (concat "function from "
                      (pcase (alist-get 'source entry)
                        ("rhai" "Rhai")
                        ("prelude" "the prelude")
                        ("script" "this script")
                        ("import" (alist-get 'file entry))
                        (source source))))
            ;; The kind says what the category would.
            (if (and category (not kind)) (concat ", in " category) "")
            ".\n\n")
    (keycap--insert-signatures (or (alist-get 'signatures entry) (list (concat name "(...)")))
                               (alist-get 'types entry))
    (insert "\n")
    (let ((start (point)))
      (keycap--insert-doc (string-trim (or (alist-get 'doc entry) "Not documented."))
                          (when (string-match ".*::" name)
                            (match-string 0 name)))
      (keycap--set-out-doc start (point)))
    (insert "\n")
    (when shape
      (insert "\nFields:\n")
      (dolist (field (alist-get 'fields entry))
        (insert "\n  " (propertize (alist-get 'name field) 'face 'help-argument-name)
                (substring (keycap--field-text field) (length (alist-get 'name field)))
                "\n")
        (when-let* ((doc (alist-get 'doc field))
                    ((not (string-empty-p doc))))
          (let ((start (point)))
            (keycap--insert-doc (string-trim doc))
            (insert "\n")
            (indent-rigidly start (point) 4)))))))


;; --- Reference ---

(defun keycap--category (entry)
  "The reference's group for ENTRY."
  (or (alist-get 'category entry)
      (if (eq (alist-get 'class entry) 'shape)
          "Shapes"
        (pcase (alist-get 'source entry)
          ("prelude" "Prelude")
          ("keycap" "Script")
          ("rhai" "Rhai")
          ("script" "This script")
          ("import" (concat "Imported from " (alist-get 'file entry)))
          (_ "Functions")))))

(defun keycap--groups ()
  "The documented names, as (CATEGORY . NAMES) in the reference's order.
Shapes first, then the categories as the server lists them."
  (let ((script (keycap--script-names))
        groups)
    (dolist (names (list script (keycap-names)))
      (when names
        (maphash (lambda (name entry)
                   (unless (and (not (eq names script)) script (gethash name script))
                     (let ((category (keycap--category entry)))
                       (if-let* ((group (assoc category groups)))
                           (push name (cdr group))
                         (push (list category name) groups)))))
                 names)))
    (mapcar (lambda (group) (cons (car group) (sort (cdr group) #'string<)))
            (sort (nreverse groups)
                  (lambda (a b) (and (equal (car a) "Shapes") (not (equal (car b) "Shapes"))))))))

(defun keycap--insert-reference ()
  "Insert the reference: every name by category, with its summary."
  (insert (propertize "fidget reference" 'face 'help-for-help-header) "\n")
  (pcase-dolist (`(,category . ,names) (keycap--groups))
    (insert "\n" (propertize category 'face 'help-for-help-header) "\n\n")
    (dolist (name names)
      (let ((signature (keycap--signature name)))
        (insert "  ")
        (help-insert-xref-button name 'keycap-describe name keycap--described)
        (insert (substring signature (min (length name) (length signature))) "\n")
        (when-let* ((summary (keycap--summary (alist-get 'doc (keycap--doc name)))))
          (insert "      " summary "\n"))))))

(defun keycap--read-name (prompt)
  "Read a documented name with PROMPT, grouped like the reference.
Nil for no name, which stands for the whole reference."
  (let* ((names (keycap--all-names))
         (metadata
          `(metadata
            (category . keycap-name)
            (annotation-function
             . ,(lambda (name)
                  (when-let* ((signature (keycap--signature name)))
                    (concat " " (substring signature (min (length name) (length signature)))))))
            (group-function
             . ,(lambda (name transform)
                  (if transform name (keycap--category (keycap--doc name))))))))
    (let ((name (completing-read (format-prompt prompt "the reference")
                                 (lambda (string predicate action)
                                   (if (eq action 'metadata)
                                       metadata
                                     (complete-with-action action names string predicate)))
                                 nil t)))
      (unless (string-empty-p name)
        name))))

(defun keycap--update-script-names ()
  "Bring `keycap--script-names' up to date with the text, waiting a moment for it."
  (ignore-errors
    (keycap-load-sync nil 2)))

;;;###autoload
(defun keycap-describe (name &optional script)
  "Show the documentation of NAME, a fidget function or shape.
Interactively, NAME is the one at point.  Without NAME -- with a prefix
argument, or with point on no name -- show the whole reference.
The functions that SCRIPT, a script buffer, defines and imports are
described too; interactively, SCRIPT is the current buffer."
  (interactive
   (progn
     (when (and (derived-mode-p 'keycap-mode)
                (not (keycap--doc (keycap-name-at-point))))
       (keycap--update-script-names))
     (list (let ((name (keycap-name-at-point)))
             (cond
              (current-prefix-arg nil)
              ((keycap--doc name) name)
              (name (keycap--read-name "Describe"))))
           (current-buffer))))
  (let ((keycap--described (or script keycap--described)))
    (when (and name (not (keycap--doc name)))
      (user-error "%s is not a fidget function or shape" name))
    (help-setup-xref (list #'keycap-describe name keycap--described)
                     (called-interactively-p 'interactive))
    (with-help-window (help-buffer)
      (with-current-buffer standard-output
        (if name
            (keycap--insert-description name)
          (keycap--insert-reference))))))

(provide 'keycap-describe)

;;; keycap-describe.el ends here
