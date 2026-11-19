;;; keycap-tests.el --- Tests for keycap  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Unit tests run on their own; the rest needs keycap-server, and is
;; skipped without it.

;;; Code:

(require 'ert)
(require 'flymake)
(require 'lisp-mnt)
(require 'keycap)
(require 'keycap-describe)
(require 'keycap-preview)

;; The manual's generator, from the checkout.
(add-to-list 'load-path (expand-file-name "../doc" (file-name-directory
                                                    (or load-file-name buffer-file-name))))
(require 'keycap-reference)

(defconst keycap-test-server (executable-find keycap-server-program)
  "The server, or nil when the tests that need it are skipped.")

(defconst keycap-test-docs
  '((shapes
     ((name . "circle")
      (doc . "A circle.\n\nIn the XY plane, around its `center`.")
      (signatures "circle(center: Vec2 = [0, 0], radius: f64): Shape"
                  "circle(#{ center?: Vec2, radius: f64 }): Shape")
      (fields
       ((name . "center") (type . "Vec2") (default . "[0, 0]") (doc . "Center of the circle."))
       ((name . "radius") (type . "f64") (doc . "Radius of the circle.")))))
    (functions
     ((name . "min")
      (signatures "min(a: Tree, b: Tree) -> Tree")
      (doc . "The smaller of `a` and `b`.\nFor shapes, their union; see `circle`.")
      (source . "fidget"))
     ((name . "union")
      (signatures "union(a, b, ...) -> Tree")
      (doc . "All the shapes.")
      (source . "fidget"))
     ((name . "ring")
      (signatures "ring(outer: f64, inner: f64) -> Tree" "ring(outer: f64, inner: f64, h: f64) -> Tree")
      (doc . "A ring.")
      (source . "prelude"))
     ((name . "stroke")
      (signatures "stroke(points: Vec2[], width: number | ((t: Tree) => Tree)): Shape")
      (types "type Width = #{\n  w: number,\n}")
      (doc . "A stroke.\n\n- `points`: its points\n\nNotes:\n- Slow.\n\nExample: an S.\n```\nstroke(p, 2)\n```")
      (source . "prelude")
      (kind . "2d"))))
  "A `docs' reply, for the tests that do not need the server.")

(defmacro keycap-test-with-script (script &rest body)
  "Run BODY in a `keycap-mode' buffer holding SCRIPT, with point at `|'.
Without a `|', point is at the start.  Not a temporary buffer: killing
it runs the hooks that stop its server and kill its preview."
  (declare (indent 1))
  (let ((buffer (make-symbol "buffer")))
    `(let ((,buffer (generate-new-buffer "keycap-test")))
       (unwind-protect
           (with-current-buffer ,buffer
             (insert ,script)
             (keycap-mode)
             (goto-char (point-min))
             (when (search-forward "|" nil t)
               (delete-char -1))
             ,@body)
         (kill-buffer ,buffer)))))

(defun keycap-test-fidget-docs ()
  "`keycap-test-docs' as the server documents the fidget dialect: no prelude."
  (list (assq 'shapes keycap-test-docs)
        (cons 'functions (seq-filter (lambda (function)
                                       (equal (alist-get 'source function) "fidget"))
                                     (alist-get 'functions keycap-test-docs)))))

(defmacro keycap-test-with-docs (&rest body)
  "Run BODY with `keycap-test-docs' as what the server documents."
  (declare (indent 0))
  `(let ((keycap--names `((keycap . ,(keycap--index keycap-test-docs))
                          (fidget . ,(keycap--index (keycap-test-fidget-docs)))))
         (keycap--modules '((keycap "lasercut" "screws") (fidget))))
     ,@body))

(defun keycap-test-wait (predicate)
  "Wait until PREDICATE is non-nil, at most 30 seconds."
  (let ((end (+ (float-time) 30)))
    (while (and (not (funcall predicate)) (< (float-time) end))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))


;; --- Numbers ---

(defun keycap-test-nudge (script n)
  "SCRIPT, with `|' as point, after nudging its number by N, `|' again at point."
  (with-temp-buffer
    (insert script)
    (keycap-mode)
    (goto-char (point-min))
    (search-forward "|")
    (delete-char -1)
    (keycap--nudge n)
    (insert "|")
    (buffer-string)))

(ert-deftest keycap-test-nudge-digit ()
  (should (equal (keycap-test-nudge "r = 1.2|5;" 1) "r = 1.3|5;"))
  (should (equal (keycap-test-nudge "r = 1.25|;" 1) "r = 1.26|;"))
  (should (equal (keycap-test-nudge "r = |1.25;" 1) "r = |1.26;"))
  (should (equal (keycap-test-nudge "r = 1|.25;" 1) "r = 2|.25;"))
  (should (equal (keycap-test-nudge "r = 1.|25;" 1) "r = 2.|25;"))
  (should (equal (keycap-test-nudge "r = 1|5;" 1) "r = 2|5;"))
  (should (equal (keycap-test-nudge "r = 15|;" 3) "r = 18|;")))

(ert-deftest keycap-test-nudge-carry ()
  (should (equal (keycap-test-nudge "r = 9|;" 1) "r = 10|;"))
  (should (equal (keycap-test-nudge "r = 0.9|;" 1) "r = 1.0|;"))
  (should (equal (keycap-test-nudge "r = 1.0|;" -1) "r = 0.9|;"))
  (should (equal (keycap-test-nudge "r = 10|;" -1) "r = 9|;")))

(ert-deftest keycap-test-nudge-sign ()
  (should (equal (keycap-test-nudge "r = 0.1|;" -2) "r = -0.1|;"))
  (should (equal (keycap-test-nudge "r = -0.1|;" 1) "r = 0.0|;"))
  (should (equal (keycap-test-nudge "[1, -2|]" 3) "[1, 1|]"))
  (should (equal (keycap-test-nudge "f(-|3)" 1) "f(-|2)"))
  ;; After a binary minus, the number counts as negative.
  (should (equal (keycap-test-nudge "x - 1|" -1) "x - 2|"))
  (should (equal (keycap-test-nudge "x - 1|" 2) "x + 1|"))
  (should (equal (keycap-test-nudge "x + 1|" -1) "x + 0|"))
  (should (equal (keycap-test-nudge "x + 0|" -1) "x - 1|")))

(ert-deftest keycap-test-nudge-message ()
  (pcase-dolist (`(,script ,n ,shown)
                 '(("const PITCH = 1|2;" 1 "PITCH 12 → 22 (step 10)")
                   ("circle(#{radius: 0.5|})" -2 "radius 0.5 → 0.3 (step 0.1)")
                   ("move(s, [12|, 0, 0])" 1 "move 12 → 13 (step 1)")
                   ("x - 1|" -1 "-1 → -2 (step 1)")))
    (with-temp-buffer
      (insert script)
      (keycap-mode)
      (goto-char (point-min))
      (search-forward "|")
      (delete-char -1)
      (let (message)
        (cl-letf (((symbol-function 'message)
                   (lambda (format &rest args) (setq message (apply #'format format args)))))
          (keycap-increase-number n))
        (should (equal message (concat shown "; n, p again")))
        ;; n and p nudge again, whether `repeat-mode' is on or not.
        (should (eq (keymap-lookup overriding-terminal-local-map "n") #'keycap-increase-number))
        (should (eq (keymap-lookup overriding-terminal-local-map "p") #'keycap-decrease-number))))))

(ert-deftest keycap-test-nudge-text ()
  ;; What the shifted wheel says, without the keys that nudge again.
  (keycap-test-with-script "circle(#{radius: 0.5|})"
    (should (equal (keycap-nudge -2) "radius 0.5 → 0.3 (step 0.1)"))
    (should (equal (buffer-string) "circle(#{radius: 0.3})"))))

(ert-deftest keycap-test-nudge-not-a-number ()
  (should-error (keycap-test-nudge "let x1| = y;" 1) :type 'user-error)
  (should-error (keycap-test-nudge "// 1|\n" 1) :type 'user-error)
  (should (equal (keycap-test-nudge "for i in 0..4| {}" 1) "for i in 0..5| {}")))


;; --- Expressions ---

(defun keycap-test-expression (script)
  "The expression before `|' in SCRIPT."
  (keycap-test-with-script script
    (pcase-let ((`(,start . ,end) (keycap--last-expression)))
      (buffer-substring-no-properties start end))))

(ert-deftest keycap-test-last-expression ()
  (should (equal (keycap-test-expression "let r = ring(3, 1)|;") "ring(3, 1)"))
  (should (equal (keycap-test-expression "let r = ring(3, 1);|") "ring(3, 1)"))
  (should (equal (keycap-test-expression "draw(union(a, b|))") "b"))
  (should (equal (keycap-test-expression "let d = x.abs() - 1|;") "x.abs() - 1"))
  (should (equal (keycap-test-expression "a == b|") "a == b"))
  (should (equal (keycap-test-expression "a += [1, 2][0]|") "[1, 2][0]"))
  (should (equal (keycap-test-expression "let c = circle(#{radius: 2})|") "circle(#{radius: 2})"))
  (should (equal (keycap-test-expression "fn f() { 1 }\n// comment\nf()|") "f()"))
  (should (equal (keycap-test-expression "fn f() {\n  return 2 * x|;\n}") "2 * x"))
  (should (equal (keycap-test-expression "let s = \"a;b\" + c|") "\"a;b\" + c")))


;; --- Scripts ---

(ert-deftest keycap-test-script-structure ()
  ;; In any buffer, not only a script's.
  (with-temp-buffer
    (insert "// A model\n"
            "/// Twice `v`.\nfn twice(v) { v * 2 }\n\n"
            "private fn hidden() { draw(sphere(1)); }\n"
            "const A = \"draw(a);\"; // draw(b);\n"
            "draw(twice(1),\n     #{role: \"cut\"});\n"
            "lib::draw(1);\n"
            "draw_rgb(A, 1, 0, 0);\n"
            "twice(2)\n")
    (cl-flet ((text (region) (buffer-substring-no-properties (car region) (cdr region))))
      (should (equal (mapcar #'car (keycap-script-functions)) '("twice" "hidden")))
      (should (equal (text (alist-get "twice" (keycap-script-functions) nil nil #'equal))
                     "/// Twice `v`.\nfn twice(v) { v * 2 }"))
      (should (equal (mapcar #'text (keycap-script-draws))
                     '("draw(twice(1),\n     #{role: \"cut\"});" "draw_rgb(A, 1, 0, 0);")))
      (should (equal (mapcar #'text (keycap-script-statements))
                     '("/// Twice `v`.\nfn twice(v) { v * 2 }"
                       "private fn hidden() { draw(sphere(1)); }"
                       "const A = \"draw(a);\";"
                       "draw(twice(1),\n     #{role: \"cut\"});"
                       "lib::draw(1);"
                       "draw_rgb(A, 1, 0, 0);"
                       "twice(2)"))))))


;; --- Flymake ---

(defun keycap-test-flymake (report)
  "Flymake's diagnostics for the `load' REPORT, as (TYPE TEXT MESSAGE)."
  (mapcar (lambda (d)
            (list (flymake-diagnostic-type d)
                  (buffer-substring-no-properties (flymake-diagnostic-beg d)
                                                  (flymake-diagnostic-end d))
                  (flymake-diagnostic-text d)))
          (keycap-report-diagnostics report)))

(ert-deftest keycap-test-diagnostic-token ()
  (keycap-test-with-script "let a = 1;\nlet b = frobnicate(a, 2);\n"
    (should (equal (keycap-test-flymake
                    '((diagnostics ((severity . "error") (line . 2) (column . 9)
                                    (message . "Function not found: frobnicate (i64, i64) (line 2, position 9)")))))
                   '((:error "frobnicate" "Function not found: frobnicate (i64, i64)")))))
  (keycap-test-with-script "let a = 1\nlet b = 2\n"
    ;; Past the end of a line: its last character.
    (should (equal (mapcar #'butlast
                           (keycap-test-flymake
                            '((diagnostics ((severity . "error") (line . 2) (column . 10)
                                            (message . "Unexpected end of input"))))))
                   '((:error "2")))))
  (keycap-test-with-script "let a = 1 // one\n\nlet b = 2;\n"
    ;; A missing `;': where the statement ends, not on the next one.
    (should (equal (mapcar #'butlast
                           (keycap-test-flymake
                            '((diagnostics ((severity . "error") (line . 3) (column . 1)
                                            (message . "Syntax error: Expecting ';' to terminate this statement"))))))
                   '((:error "1"))))))

(ert-deftest keycap-test-diagnostic-trace ()
  (keycap-test-with-script "fn ring(r) {\n  r + q\n}\n\ndraw(ring(1));\n"
    (should (equal (keycap-test-flymake
                    '((diagnostics ((severity . "error") (line . 2) (column . 7)
                                    (message . "Variable not found: q")
                                    (trace ((line . 5) (column . 6)
                                            (message . "in call to fn ring")))))))
                   '((:error "q" "Variable not found: q; line 5: in call to fn ring")
                     (:note "ring" "in call to fn ring: Variable not found: q"))))))

(ert-deftest keycap-test-diagnostic-import ()
  (keycap-test-with-script "import \"parts\" as parts;\n\ndraw(parts::bolt(3));\n"
    (setq buffer-file-name "/tmp/keycap-test/model.keycap")
    ;; Called from here: on the call.
    (should (equal (keycap-test-flymake
                    '((diagnostics ((severity . "error") (line . 4) (column . 3)
                                    (file . "/tmp/keycap-test/parts.keycap")
                                    (message . "Variable not found: q")
                                    (trace ((line . 3) (column . 6)
                                            (message . "in call to fn bolt")))))))
                   '((:error "parts" "parts.keycap:4: Variable not found: q; line 3: in call to fn bolt"))))
    ;; Failing as it is imported: on the import.
    (should (equal (keycap-test-flymake
                    '((diagnostics ((severity . "error") (line . 1) (column . 1)
                                    (file . "/tmp/keycap-test/parts.keycap")
                                    (message . "Syntax error")))))
                   '((:error "import \"parts\" as parts;" "parts.keycap:1: Syntax error"))))
    (setq buffer-file-name nil))
  ;; Past other imports, one of them commented out.
  (keycap-test-with-script "// import \"parts\" as old;\nimport \"base\" as base;\nimport \"parts\" as parts;\n"
    (should (equal (keycap--import "/tmp/keycap-test/parts.keycap") '(50 . 74)))))

(ert-deftest keycap-test-diagnostic-warning ()
  (keycap-test-with-script "let s = sphere(1);\n  draw(s);\n"
    (should (equal (keycap-test-flymake
                    '((diagnostics ((severity . "warning") (line . 2)
                                    (message . "shape extends past the bounds on +z")))))
                   '((:warning "draw(s);" "shape extends past the bounds on +z"))))))

(ert-deftest keycap-test-failure ()
  (should-not (keycap-report-failure '((loaded . t))))
  (should (equal (keycap-report-failure '((error . "keycap-server stopped: killed"))) "keycap-server stopped: killed"))
  (should (equal (keycap-report-failure '((diagnostics ((severity . "warning") (line . 1) (message . "w"))
                                                 ((severity . "error") (line . 3) (message . "e (line 3, position 1)")))))
                 "line 3: e"))
  (should (equal (keycap-report-failure '((diagnostics ((severity . "error") (line . 2) (file . "/a/parts.keycap")
                                                  (message . "e")))))
                 "parts.keycap:2: e")))


;; --- Completion and ElDoc ---

(defun keycap-test-completions (script &optional dialect)
  "The completions and the annotation of each at `|' in SCRIPT, in DIALECT."
  (keycap-test-with-script script
    (when dialect
      (setq keycap-dialect dialect))
    (pcase-let ((`(,start ,end ,table . ,props) (keycap-completion-at-point)))
      (let ((annotate (plist-get props :annotation-function)))
        (mapcar (lambda (candidate) (cons candidate (funcall annotate candidate)))
                (sort (all-completions (buffer-substring start end) table) #'string<))))))

(ert-deftest keycap-test-complete-names ()
  (keycap-test-with-docs
    (should (equal (keycap-test-completions "fn rounded() {}\nlet ri = 1;\ndraw(r|)")
                   '(("ri") ("ring" . " prelude") ("rounded"))))
    (should (equal (keycap-test-completions "draw(ci|)") '(("circle" . " shape"))))
    (should-not (keycap-test-with-script "let a = 1|2;" (keycap-completion-at-point)))
    (should-not (keycap-test-with-script "// ci|" (keycap-completion-at-point)))))

(ert-deftest keycap-test-complete-dialect ()
  (keycap-test-with-docs
    (should (equal (keycap-test-completions "draw(r|)" 'fidget) nil))
    (should (equal (keycap-test-completions "draw(mi|)" 'fidget) '(("min" . " fidget"))))
    (keycap-test-with-script "draw(ri|ng(3, 1));"
      (setq keycap-dialect 'fidget)
      (should-not (keycap--doc "ring")))))

(ert-deftest keycap-test-complete-fields ()
  (keycap-test-with-docs
    (should (equal (keycap-test-completions "circle(#{|})")
                   '(("center" . " Vec2 = [0, 0]") ("radius" . " f64"))))
    (should (equal (keycap-test-completions "circle(#{center: [1, 2], r|})")
                   '(("radius" . " f64"))))
    (should (equal (keycap-test-completions "let c = circle(#{\n  radius: 2,\n  c|\n});")
                   '(("center" . " Vec2 = [0, 0]"))))
    ;; A value is not a key; neither is a map given to a function.
    (should (assoc "circle" (keycap-test-completions "circle(#{radius: c|})")))
    (should-not (assoc "radius" (keycap-test-completions "min(#{r|})")))
    ;; Completing a key adds its colon.
    (keycap-test-with-script "circle(#{rad|})"
      (pcase-let ((`(,_ ,_ ,_ . ,props) (keycap-completion-at-point)))
        (insert "ius")
        (funcall (plist-get props :exit-function) "radius" 'finished)
        (should (equal (buffer-string) "circle(#{radius: })"))))))

(ert-deftest keycap-test-complete-modules ()
  (keycap-test-with-docs
    (cl-flet ((complete (script &optional dialect)
                (keycap-test-with-script script
                  (when dialect
                    (setq keycap-dialect dialect))
                  (pcase (keycap-completion-at-point)
                    (`(,start ,end ,table . ,_)
                     (list (buffer-substring start end)
                           (all-completions (buffer-substring start (point)) table)))))))
      (should (equal (complete "import \"keycap/s|\" as s;") '("s" ("screws"))))
      (should (equal (complete "import \"keycap/|") '("" ("lasercut" "screws"))))
      (should-not (complete "import \"parts/s|\" as s;"))
      (should-not (complete "let a = \"keycap/s|\";"))
      (should (equal (complete "import \"keycap/|\";" 'fidget) '("" nil))))))

(defun keycap-test-eldoc (script)
  "ElDoc's text at `|' in SCRIPT, the highlighted part in brackets."
  (keycap-test-with-script script
    (let ((point (point))
          doc)
      (keycap-eldoc-function (lambda (string &rest _) (setq doc string)))
      (should (= (point) point))
      (when doc
        (let* ((highlighted (lambda (i)
                              (memq 'eldoc-highlight-function-argument
                                    (ensure-list (get-text-property i 'face doc)))))
               (start (seq-find highlighted (number-sequence 0 (1- (length doc))))))
          (if (not start)
              (substring-no-properties doc)
            (let ((end (or (seq-find (lambda (i) (not (funcall highlighted i)))
                                     (number-sequence start (1- (length doc))))
                           (length doc))))
              (concat (substring-no-properties doc 0 start) "[" (substring-no-properties doc start end) "]"
                      (substring-no-properties doc end)))))))))

(ert-deftest keycap-test-eldoc ()
  (keycap-test-with-docs
    (should (equal (keycap-test-eldoc "mi|n(a, b)")
                   "min(a: Tree, b: Tree) -> Tree  The smaller of `a` and `b`."))
    (should (equal (keycap-test-eldoc "min(a, |b)")
                   "min(a: Tree, [b: Tree]) -> Tree  The smaller of `a` and `b`."))
    (should (equal (keycap-test-eldoc "a.min(|b)")
                   "min(a: Tree, [b: Tree]) -> Tree  The smaller of `a` and `b`."))
    (should (equal (keycap-test-eldoc "union(a, b, c, |d)")
                   "union(a, b, [...]) -> Tree  All the shapes."))
    (should (equal (keycap-test-eldoc "circle(#{center: [0, 0], radius: |1})")
                   "circle(#{center: Vec2 = [0, 0], [radius: f64]})  Radius of the circle."))
    (should (equal (keycap-test-eldoc "circle(#{|})")
                   "circle(#{center: Vec2 = [0, 0], radius: f64})  A circle."))
    ;; In an array or a map among the arguments.
    (should (equal (keycap-test-eldoc "min([a, |b], c)")
                   "min([a: Tree], b: Tree) -> Tree  The smaller of `a` and `b`."))
    (should (equal (keycap-test-eldoc "min(a, #{b: |1})")
                   "min(a: Tree, [b: Tree]) -> Tree  The smaller of `a` and `b`."))
    (should (equal (keycap-test-eldoc "circle(#{center: [0, |0]})")
                   "circle(#{[center: Vec2 = [0, 0]], radius: f64})  Center of the circle."))
    ;; The signature that has the argument.
    (should (equal (keycap-test-eldoc "ring(3, 1, |2)")
                   "ring(outer: f64, inner: f64, [h: f64]) -> Tree  A ring."))
    (should (equal (keycap-test-eldoc "ring(3, 1, 2, |4)")
                   "ring(outer: f64, inner: f64) -> Tree  A ring."))
    ;; Past a function type's arrow
    (should (equal (keycap-test-eldoc "stroke(p, |2)")
                   "stroke(points: Vec2[], [width: number | ((t: Tree) => Tree)]): Shape  A stroke."))
    (should-not (keycap-test-eldoc "frobnicate(|1)"))))


;; --- Reference ---

(ert-deftest keycap-test-describe ()
  (keycap-test-with-docs
    (with-temp-buffer
      (keycap--insert-description "circle")
      (should (equal (buffer-string)
                     (concat "circle is a function from fidget.\n\n"
                             "  circle(center: Vec2 = [0, 0], radius: f64): Shape\n"
                             "  circle(#{ center?: Vec2, radius: f64 }): Shape\n\n"
                             "A circle.\n\nIn the XY plane, around its `center`.\n\n"
                             "Fields:\n\n"
                             "  center: Vec2 = [0, 0]\n    Center of the circle.\n\n"
                             "  radius: f64\n    Radius of the circle.\n"))))
    (with-temp-buffer
      (keycap--insert-description "min")
      (should (string-prefix-p "min is a function from fidget.\n\n  min(a: Tree"
                               (buffer-string)))
      ;; Names in backquotes link to their description.
      (goto-char (point-min))
      (search-forward "`circle")
      (should (equal (button-get (button-at (1- (point))) 'help-args) '("circle" nil)))
      (search-backward "`a`")
      (should-not (button-at (1+ (point)))))
    ;; Signatures highlighted, their types after them, those the manual
    ;; lists buttons to it; the doc set out.
    (with-temp-buffer
      (let ((keycap--types '("number" "Tree" "Shape" "Vec2")))
        (keycap--insert-description "stroke"))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     (concat "stroke is a 2D function from the prelude.\n\n"
                             "  stroke(points: Vec2[], width: number | ((t: Tree) => Tree)): Shape\n\n"
                             "  type Width = #{\n      w: number,\n  }\n\n"
                             "A stroke.\n\n- `points`: its points\n\n"
                             "Notes:\n- Slow.\n\nExample: an S.\n  stroke(p, 2)\n")))
      (cl-flet ((face-at (text)
                  (goto-char (point-min))
                  (search-forward text)
                  (get-text-property (match-beginning 0) 'face)))
        (should (eq (face-at "2D") 'keycap-kind-2d))
        (should (eq (face-at "stroke(") 'font-lock-function-name-face))
        (should (eq (face-at "Vec2") 'font-lock-type-face))
        (should (eq (face-at "Tree") 'keycap-tree-type))
        (should (equal (button-get (button-at (match-beginning 0)) 'help-args) '("Tree")))
        (face-at "Width")
        (should-not (button-at (match-beginning 0)))
        (should (memq 'help-argument-name (ensure-list (face-at "points`:"))))
        (should (memq 'shadow (ensure-list (face-at "Slow"))))))
    ;; The parts of a doc: their leads bold, a comparison quieter, links
    ;; buttons, an example's view for the site only.
    (with-temp-buffer
      (insert "See also: `circle`.\n\nReferences:\n- [Squircle](https://example.org/s), a page\n"
              "- [Nut](https://en.wikipedia.org/wiki/Nut_(hardware)), a part\n\n"
              "From OpenSCAD: `circle(r)`.\n\nExample: a ring. [view: sdf]\n")
      (keycap--set-out-doc (point-min) (point-max))
      (should (equal (buffer-string) (concat "See also: `circle`.\n\nReferences:\n- Squircle, a page\n- Nut, a part\n\n"
                                             "From OpenSCAD: `circle(r)`.\n\nExample: a ring.\n")))
      (goto-char (point-min))
      (search-forward "Squircle")
      (should (equal (button-get (button-at (1- (point))) 'help-args) '("https://example.org/s")))
      (search-forward "Nut")
      (should (equal (button-get (button-at (1- (point))) 'help-args)
                     '("https://en.wikipedia.org/wiki/Nut_(hardware)")))
      (should (memq 'bold (ensure-list (get-text-property 1 'face))))
      (search-forward "circle(r)")
      (should (memq 'shadow (ensure-list (get-text-property (point) 'face)))))))

(ert-deftest keycap-test-set-out-signatures ()
  (cl-flet ((set-out (signatures &optional types)
              (substring-no-properties (keycap-set-out-signatures signatures types))))
    ;; Every call's name in one column.
    (should (equal (set-out '("offset(shape: Shape, d: Tree): Shape" "shape.offset(d: Tree): Shape"))
                   (concat "      offset(shape: Shape, d: Tree): Shape\n"
                           "shape.offset(d: Tree): Shape")))
    ;; A call too long for one line takes a line per parameter, the
    ;; columns shared by the calls that do.
    (let ((keycap-signature-width 40))
      (should (equal (set-out '("rotate_x(shape: Shape, angle: number = 0, center: Vec3 = [0, 0, 0]): Shape"
                                "shape.rotate_x(angle: number = 0): Shape"))
                     (concat "      rotate_x(\n"
                             "          shape:  Shape,\n"
                             "          angle:  number = 0,\n"
                             "          center: Vec3   = [0, 0, 0],\n"
                             "      ): Shape\n"
                             "shape.rotate_x(angle: number = 0): Shape"))))
    ;; A map type a line per key, after a blank line.
    (should (equal (set-out '("loft(slices: Slice[]): Shape")
                            '("type Slice = #{\n  z: number,\n  shape?: Shape, ease?: Ease,\n}"))
                   (concat "loft(slices: Slice[]): Shape\n\n"
                           "type Slice = #{\n"
                           "    z:      number,\n"
                           "    shape?: Shape,\n"
                           "    ease?:  Ease,\n"
                           "}")))
    ;; Each parameter on one line marked whole, and each line's wrap past
    ;; the name.
    (let ((text (keycap-set-out-signatures '("min(a: Tree, b) -> Tree" "a.min(b) -> Tree"))))
      (should (equal (substring-no-properties text) "  min(a: Tree, b) -> Tree\na.min(b) -> Tree"))
      (should (get-text-property (string-search "a: Tree" text) 'keycap-parameter text))
      (should-not (get-text-property (string-search ", b" text) 'keycap-parameter text))
      (should (equal (get-text-property (string-search "a.min" text) 'wrap-prefix text) "      ")))))

(ert-deftest keycap-test-reference ()
  (keycap-test-with-docs
    (should (equal (keycap--groups)
                   '(("Shapes" "circle") ("Functions" "min" "union") ("Prelude" "ring" "stroke"))))
    (with-temp-buffer
      (keycap--insert-reference)
      (should (string-match-p "\nShapes\n\n  circle(center: Vec2 = \\[0, 0\\], radius: f64): Shape\n      A circle\\.\n"
                              (buffer-string)))
      (should (string-match-p "\nPrelude\n\n  ring(outer: f64, inner: f64) -> Tree\n      A ring\\.\n"
                              (buffer-string))))
    ;; On a name that is not documented, an empty answer asks for it too.
    (keycap-test-with-script "let rings = 1;"
      (search-forward "ri")
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
        (call-interactively #'keycap-describe))
      (should (string-prefix-p "fidget reference\n"
                               (with-current-buffer (help-buffer) (buffer-string)))))))

(ert-deftest keycap-test-name-at-point ()
  (keycap-test-with-docs
    (keycap-test-with-script "circle(#{rad|ius: min(a, b)})"
      (should (equal (keycap-name-at-point) "circle")))
    (keycap-test-with-script "circle(#{radius: m|in(a, b)})"
      (should (equal (keycap-name-at-point) "min")))
    (keycap-test-with-script "draw(lib::tw|ice(1.0));"
      (should (equal (keycap-name-at-point) "lib::twice")))
    (keycap-test-with-script "draw(l|ib::twice(1.0));"
      (should (equal (keycap-name-at-point) "lib::twice")))))

(ert-deftest keycap-test-script-functions ()
  (skip-unless keycap-test-server)
  (let ((directory (file-name-as-directory (file-truename (make-temp-file "keycap-test-" t)))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "lib.rhai" directory)
            (insert "/// Twice `v`, as `halve` undoes.\nfn twice(v) { v * 2.0 }\n\n"
                    "/// Half `v`.\nfn halve(v) { v / 2.0 }\n\n"
                    "private fn hidden() { 1.0 }\n"))
          (keycap-test-with-script (concat "import \"lib\" as lib;\n\n"
                                           "/// A sphere twice `r` across.\n"
                                           "fn ball(r) { sphere(lib::twice(r)) }\n\n"
                                           "draw(ball(lib::tw|ice(1.0)));\n")
            (setq buffer-file-name (expand-file-name "model.keycap" directory))
            (unwind-protect
                (progn
                  ;; Not documented until the script is evaluated, which
                  ;; describing it waits for.
                  (call-interactively #'keycap-describe)
                  (with-current-buffer (help-buffer)
                    (should (string-prefix-p (concat "lib::twice is a function from lib.rhai.\n\n"
                                                     "  lib::twice(v)\n\n"
                                                     "Twice `v`, as `halve` undoes.")
                                             (buffer-string)))
                    ;; A name in the same module links to it.
                    (goto-char (point-min))
                    (search-forward "`halve")
                    (should (equal (car (button-get (button-at (1- (point))) 'help-args))
                                   "lib::halve")))
                  (keycap-describe "ball" (current-buffer))
                  (with-current-buffer (help-buffer)
                    (should (string-prefix-p "ball is a function from this script.\n\n  ball(r)\n"
                                             (buffer-string))))
                  (let (doc)
                    (keycap-eldoc-function (lambda (string &rest _) (setq doc string)))
                    (should (equal (substring-no-properties doc)
                                   "lib::twice(v)  Twice `v`, as `halve` undoes.")))
                  (pcase-let ((`(,start ,_ ,names . ,_) (keycap-completion-at-point)))
                    (should (equal (buffer-substring start (+ start 5)) "lib::"))
                    (should (member "lib::halve" names))
                    (should (member "ball" names))
                    (should-not (member "lib::hidden" names))))
              (set-buffer-modified-p nil))))
      (delete-directory directory t))))


;; --- Preview, without a server ---

(defmacro keycap-test-with-preview-state (&rest body)
  "Run BODY in a `keycap-preview-mode' buffer with a 3D model loaded."
  (declare (indent 0))
  `(with-temp-buffer
     (keycap-preview-mode)
     (keycap--preview-reset-camera)
     (setq keycap--preview-view 'shaded
           keycap--preview-bounds 'script
           keycap--preview-backend 'gpu
           keycap--preview-axis 'z
           keycap--preview-offset 0
           keycap--preview-projection 'orthographic
           keycap--preview-report
           '((loaded . t)
             (bounds (script (lower -10 -10 -5) (upper 10 10 5))
                     (fitted (lower -3.1 -3 nil) (upper 3.1 3 nil)))))
     ,@body))

(ert-deftest keycap-test-preview-snapshot ()
  (keycap-test-with-script ""
    (let ((report '((loaded . t)
                    (bounds (script (lower -10 -10 -5) (upper 10 10 5))
                            (fitted (lower -3 -3 nil) (upper 3 3 nil)))))
          (keycap-preview-backend 'gpu)
          directory)
      (let ((snapshot (keycap-preview-snapshot (current-buffer) :report report)))
        (with-current-buffer snapshot
          (setq directory keycap--preview-directory)
          (should (file-directory-p directory))
          ;; A 2D model, sliced through the middle of the script's bounds
          (should (equal (keycap-preview-header) "sdf z = 0"))
          (let ((request (keycap-preview-request 40 30)))
            (should (equal (alist-get 'output request) (expand-file-name "frame.ppm" directory)))
            (should (equal (alist-get 'backend request) "gpu"))
            (should (equal (alist-get 'width request) 40)))
          (keycap-preview-set-frame '((backend . "gpu") (bounds . "script") (ms . 3) (scale . 0.5)))
          (should (equal (keycap-preview-header) "sdf z = 0  ·  script bounds 20 × 20 × 10  ·  GPU 3.0 ms"))
          (should-error (keycap-preview-set-frame '((error . "no scene"))))
          ;; The menus, with their items for this preview
          (should (lookup-key (keycap-preview-menu 'context) [keycap-goto-shape]))
          (should (assq 'Level (keycap-preview-menu 'slice))))
        (kill-buffer snapshot)
        (should-not (file-exists-p directory)))
      (with-current-buffer (keycap-preview-snapshot (current-buffer)
                                                    :report report :view 'shaded :camera '(0 90)
                                                    :slice '(x 2 (10 . 0)) :bounds 'fitted
                                                    :backend 'cpu :failure "line 1: no")
        (unwind-protect
            (progn
              (should (equal (keycap-preview-header) "line 1: no  ·  shaded 0° 90°"))
              (let* ((request (keycap-preview-request 1 1))
                     (slice (alist-get 'slice request)))
                (should (equal (list (alist-get 'elevation (alist-get 'camera request))
                                     (alist-get 'axis slice) (alist-get 'offset slice)
                                     (alist-get 'tilt slice)
                                     (alist-get 'bounds request) (alist-get 'backend request))
                               '(89.9 "x" 2 [10 0] "fitted" "cpu")))))
          (kill-buffer))))))

(ert-deftest keycap-test-preview-buffer ()
  ;; A renamed script's preview keeps its old name; a new script of that
  ;; name gets a preview of its own.
  (let* ((renamed (generate-new-buffer "keycap-test-renamed"))
         (script (generate-new-buffer "keycap-test"))
         (preview (get-buffer-create (format "*keycap: %s*" (buffer-name script))))
         made)
    (unwind-protect
        (progn
          (with-current-buffer preview
            (keycap-preview-mode)
            (setq keycap--preview-source renamed))
          (setq made (keycap--preview-buffer script))
          (should-not (eq made preview))
          (with-current-buffer preview
            (setq keycap--preview-source script))
          (should (eq (keycap--preview-buffer script) preview)))
      (mapc #'kill-buffer (delq nil (list made preview script renamed))))))

(ert-deftest keycap-test-preview-header ()
  (keycap-test-with-preview-state
    (should (equal (keycap-preview-header) "shaded iso"))
    (setq keycap--preview-frame '((backend . "gpu") (bounds . "script") (ms . 12.5) (scale . 0.0123)))
    (should (equal (keycap-preview-header) "shaded iso  ·  script bounds 20 × 20 × 10  ·  GPU 12 ms"))
    (push '(empty . t) keycap--preview-frame)
    (should (string-prefix-p "shaded iso  ·  nothing in view  ·  script bounds" (keycap-preview-header)))
    (setq keycap--preview-frame '((backend . "cpu") (bounds . "fitted") (ms . 1250) (scale . 0.0123))
          keycap--preview-view 'sdf
          keycap--preview-offset 0.5
          keycap--preview-failure "line 3: 100% wrong")
    (keycap--preview-read '((position 1.2345 -0.0001 0.5) (value . -0.21)))
    (should (equal (keycap-preview-header)
                   (concat "line 3: 100%% wrong"
                           "  ·  sdf z = 0.5  ·  x 1.23  y 0.00  = -0.210"
                           "  ·  fitted bounds 6.2 × 6 × ∞  ·  CPU 1.2 s (no GPU)")))
    (push '(fallback . "the GPU's device was lost") keycap--preview-frame)
    (should (string-suffix-p "CPU 1.2 s (the GPU's device was lost)" (keycap-preview-header)))
    ;; Rendering where it is sooner, only a fallback is worth a note.
    (setq keycap--preview-backend 'auto)
    (should (string-suffix-p "CPU 1.2 s (the GPU's device was lost)" (keycap-preview-header)))
    (setq keycap--preview-frame (assq-delete-all 'fallback keycap--preview-frame))
    (should (string-suffix-p "CPU 1.2 s" (keycap-preview-header)))
    (cl-letf (((symbol-function 'keycap--preview-render) #'ignore))
      (keycap-preview-toggle-backend)
      (should (eq keycap--preview-backend 'gpu))
      (keycap-preview-toggle-backend)
      (should (eq keycap--preview-backend 'auto)))
    (setq keycap--preview-backend 'gpu)
    (setq keycap--preview-report
          '((loaded . t)
            (bounds (fitted (lower -3.1 -3 nil) (upper 3.1 3 nil))
                    (loose . "the shapes' intervals are NaN"))))
    (should (string-search "fitted bounds 6.2 × 6 × ∞ (the shapes' intervals are NaN)"
                           (keycap-preview-header)))))

(ert-deftest keycap-test-preview-header-camera ()
  (keycap-test-with-preview-state
    (cl-letf (((symbol-function 'keycap--preview-render) #'ignore))
      (keycap-preview-front)
      (should (equal (keycap-preview-header) "shaded front"))
      (keycap-preview-top)
      (should (equal (keycap-preview-header) "shaded top"))
      ;; Turned, the camera is its angles, the azimuth within ±180°.
      (keycap--preview-look 330 20.4)
      (should (equal (keycap-preview-header) "shaded -30° 20°"))
      (keycap--preview-look 300 30)
      (should (equal (keycap-preview-header) "shaded iso"))
      (keycap-preview-projection)
      (should (equal (keycap-preview-header) "shaded iso perspective")))))

(ert-deftest keycap-test-preview-header-buttons ()
  (keycap-test-with-preview-state
    (setq keycap--preview-frame '((backend . "gpu") (bounds . "script") (ms . 12.5) (scale . 0.0123)))
    (let ((header (keycap-preview-header)))
      ;; Each word that says what is shown runs a command when clicked.
      (pcase-dolist (`(,word . ,command) '(("shaded" . keycap-preview-view-menu)
                                          ("iso" . keycap-preview-camera-menu)
                                          ("script bounds" . keycap-preview-toggle-bounds)
                                          ("GPU" . keycap-preview-toggle-backend)))
        (let ((index (string-search word header)))
          (should (eq (get-text-property index 'keycap-command header) command))
          (should (eq (get-text-property index 'mouse-face header) 'header-line-highlight))
          (should (stringp (get-text-property index 'help-echo header)))))
      (should-not (get-text-property (string-search "·" header) 'keycap-command header)))
    (setq keycap--preview-view 'sdf
          keycap--preview-offset 2.5)
    (let ((header (keycap-preview-header)))
      (should (string-prefix-p "sdf z = 2.5" header))
      (should (eq (get-text-property 4 'keycap-command header) 'keycap-preview-slice-menu))
      ;; The wheel over the offset moves the slice.
      (should (eq (keymap-lookup (get-text-property 8 'local-map header) "<header-line> <wheel-up>")
                  'keycap-preview-mouse-slice-step)))))

(ert-deftest keycap-test-preview-menu ()
  (keycap-test-with-preview-state
    (let ((labels (lambda ()
                    (delq nil (mapcar (lambda (item) (and (vectorp item) (aref item 0)))
                                      (keycap--preview-menu-items))))))
      (should (member "Isometric" (funcall labels)))
      (should-not (member "Across X" (funcall labels)))
      ;; In 2D, the slices take the cameras' place.
      (setq keycap--preview-view 'sdf)
      (should (member "Across X" (funcall labels)))
      (should (member "Level" (funcall labels)))
      (should-not (member "Perspective" (funcall labels))))
    ;; Off the model, the context menu is the preview's menu; on it, it
    ;; starts with the way to the shape's `draw'.
    (let ((menu (keycap--preview-context-menu
                 (make-sparse-keymap)
                 '(mouse-3 (nil 1 (0 . 0) 0 nil 1 nil nil nil nil)))))
      (should-not (assq 'keycap-goto-shape menu))
      (should (assq 'Shaded menu)))
    (let ((menu (keycap--preview-context-menu
                 (make-sparse-keymap)
                 '(mouse-3 (nil 1 (0 . 0) 0 nil 1 nil (image) nil nil)))))
      (should (eq (car (nth 1 menu)) 'keycap-goto-shape)))))

(ert-deftest keycap-test-preview-drawn ()
  (keycap-test-with-preview-state
    (setq keycap--preview-report
          '((loaded . t)
            (shapes ((line . 3) (column . 1) (color))
                    ((line . 7) (column . 5) (color) (file . "/tmp/part.rhai")))))
    (should (equal (keycap--preview-drawn 0) '(nil 3 1)))
    (should (equal (keycap--preview-drawn 1) '("/tmp/part.rhai" 7 5)))
    (should-not (keycap--preview-drawn 2))
    (should-not (keycap--preview-drawn nil))))

(ert-deftest keycap-test-preview-reset-camera ()
  (keycap-test-with-preview-state
    (cl-letf (((symbol-function 'keycap--preview-render) #'ignore))
      (keycap-preview-front)
      (setq keycap--preview-zoom 3.0
            keycap--preview-pan '(0.5 . 0.2))
      (keycap-preview-reset-camera)
      (should (equal (list keycap--preview-azimuth keycap--preview-elevation
                           keycap--preview-zoom keycap--preview-pan)
                     '(-60 30 1.0 (0.0 . 0.0))))
      (setq keycap--preview-view 'sdf)
      (keycap-preview-slice-at 2.5)
      (should (equal keycap--preview-offset 2.5)))))

(ert-deftest keycap-test-preview-flat ()
  (should (keycap-report-flat-p '((bounds (fitted (lower -1 -1 nil) (upper 1 1 nil))))))
  (should-not (keycap-report-flat-p '((bounds (fitted (lower -1 -1 -1) (upper 1 1 1)))))))

(ert-deftest keycap-test-preview-slice-step ()
  (keycap-test-with-preview-state
    ;; Script bounds: 10 along Z, so a step of 0.5.
    (should (equal (keycap--preview-slice-step) 0.5))
    (setq keycap--preview-axis 'x)
    (should (equal (keycap--preview-slice-step) 1.0))
    ;; Fitted ones, unbounded along Z: as the widest bounded axis.
    (setq keycap--preview-bounds 'fitted
          keycap--preview-axis 'z)
    (should (equal (keycap--preview-slice-step) 0.2))))

(ert-deftest keycap-test-preview-slice-scrub ()
  (should (= (keycap--preview-wheel-steps 'S-wheel-up) 1))
  (should (= (keycap--preview-wheel-steps 'S-wheel-down) -1))
  (should (= (keycap--preview-wheel-steps 'M-wheel-up) 10))
  (should (= (keycap--preview-wheel-steps 'M-wheel-down) -10))
  ;; The window's height covers the extent; up is forward.
  (should (= (keycap--preview-scrubbed 2 0 10 500) 2))
  (should (= (keycap--preview-scrubbed 2 -250 10 500) 7))
  (should (= (keycap--preview-scrubbed 2 500 10 500) -8))
  (keycap-test-with-preview-state
    (should (= (keycap--preview-slice-extent) 10))
    (setq keycap--preview-axis 'x)
    (should (= (keycap--preview-slice-extent) 20))))

(ert-deftest keycap-test-preview-slice-middle ()
  (keycap-test-with-preview-state
    (setq keycap--preview-report
          '((loaded . t)
            (bounds (script (lower 0 0 2) (upper 10 20 6))
                    (fitted (lower 1 1 nil) (upper 9 19 nil)))))
    (cl-letf (((symbol-function 'keycap--preview-render) #'ignore))
      ;; From 3D, through the middle of the bounds.
      (keycap-preview-cycle-view)
      (keycap-preview-cycle-view)
      (should (eq keycap--preview-view 'sdf))
      (should (equal keycap--preview-offset 4.0))
      (should (equal (keycap-preview-header) "sdf z = 4"))
      (keycap-preview-front)
      (should (equal (list keycap--preview-axis keycap--preview-offset) '(y 10.0)))
      (keycap-preview-slice-forward)
      (should (equal keycap--preview-offset 11.0))
      ;; An unbounded axis, through 0.
      (setq keycap--preview-bounds 'fitted)
      (keycap-preview-top)
      (should (equal keycap--preview-offset 0)))))

(ert-deftest keycap-test-preview-slice-follows ()
  (keycap-test-with-preview-state
    (setq-local keycap--preview (current-buffer))
    (setq keycap--preview-view 'sdf
          keycap--preview-view-chosen t
          keycap--preview-bounds 'fitted)
    (cl-letf (((symbol-function 'keycap--preview-render) #'ignore)
              ((symbol-function 'keycap--preview-redisplay) #'ignore))
      ;; A profile, unbounded along Z: sliced through 0.
      (keycap--preview-loaded '((loaded . t) (bounds (script) (fitted (lower -3 -3 nil) (upper 3 3 nil)))))
      (should (equal keycap--preview-offset 0))
      ;; Revolved, it spans 0 to 30: the slice keeps to its middle.
      (keycap--preview-loaded '((loaded . t) (bounds (script) (fitted (lower -28 -28 0) (upper 28 28 30)))))
      (should (equal keycap--preview-offset 15.0))
      ;; Once moved by hand, it stays.
      (keycap-preview-slice-forward)
      (let ((offset keycap--preview-offset))
        (keycap--preview-loaded '((loaded . t) (bounds (script) (fitted (lower -28 -28 0) (upper 28 28 40)))))
        (should (equal keycap--preview-offset offset))))))

(ert-deftest keycap-test-preview-drag-resolution ()
  (keycap-test-with-preview-state
    (let ((window (selected-window))
          (keycap--preview-source (current-buffer))
          sent)
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) window))
                ((symbol-function 'window-body-width) (lambda (&rest _) 300))
                ((symbol-function 'window-body-height) (lambda (&rest _) 200))
                ((symbol-function 'frame-scale-factor) (lambda (&rest _) 1))
                ((symbol-function 'process-live-p) (lambda (&rest _) t))
                ((symbol-function 'keycap--preview-send) (lambda (&rest args) (setq sent args))))
        ;; While the mouse drags, frames have half the pixels each way,
        ;; shown twice the size.
        (setq keycap--preview-dragging t
              keycap--preview-drag-share 0.5)
        (keycap--preview-render)
        (should (equal sent '(150 100 0.5 t)))
        ;; A frame far slower than `keycap-preview-drag-frame-time'
        ;; makes the next one smaller.
        (cl-letf (((symbol-function 'keycap--preview-show) #'ignore)
                  ((symbol-function 'float-time) (lambda (&rest _) 0.4)))
          (setq keycap--preview-render-start 0.0)
          (keycap--preview-rendered '((ms . 400)) 0.5 t t "frame-1.ppm"))
        (keycap--preview-render)
        (should (equal sent '(75 50 0.25 t)))
        (setq keycap--preview-dragging nil)
        (keycap--preview-render)
        (should (equal sent '(300 200 1 nil)))))))

(ert-deftest keycap-test-preview-edit-resolution ()
  (keycap-test-with-preview-state
    (setq-local keycap--preview (current-buffer))
    (let ((window (selected-window))
          (keycap--preview-source (current-buffer))
          (keycap-preview-drag-resolution 0.5)
          sent)
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) window))
                ((symbol-function 'window-body-width) (lambda (&rest _) 300))
                ((symbol-function 'window-body-height) (lambda (&rest _) 200))
                ((symbol-function 'window-pixel-height) (lambda (&rest _) 0))
                ((symbol-function 'frame-scale-factor) (lambda (&rest _) 1))
                ((symbol-function 'process-live-p) (lambda (&rest _) t))
                ((symbol-function 'keycap--preview-redisplay) #'ignore)
                ((symbol-function 'keycap--preview-send)
                 (lambda (&rest args)
                   (setq sent args
                         keycap--preview-live (nth 3 args)))))
        ;; Quick frames follow edits in full.
        (setq keycap--preview-full-ms 50)
        (keycap--preview-loaded keycap--preview-report)
        (should (equal sent '(300 200 1 nil)))
        ;; Slow ones in a quarter of the pixels, then in full once the
        ;; script settles.
        (setq keycap--preview-full-ms 900)
        (keycap--preview-loaded keycap--preview-report)
        (should (equal sent '(150 100 0.5 t)))
        (cancel-timer keycap--preview-settle-timer)
        (keycap--preview-settled (current-buffer))
        (should (equal sent '(300 200 1 nil)))
        ;; A frame in full needs none again.
        (setq sent nil)
        (keycap--preview-settled (current-buffer))
        (should-not sent)
        ;; Nor does a camera move have fewer pixels.
        (keycap-preview-orbit-left)
        (should (equal sent '(300 200 1 nil)))))))

(ert-deftest keycap-test-preview-edit-supersedes ()
  (keycap-test-with-preview-state
    (setq-local keycap--preview (current-buffer))
    (let ((window (selected-window))
          (keycap--preview-source (current-buffer))
          (sent 0))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) window))
                ((symbol-function 'process-live-p) (lambda (&rest _) t))
                ((symbol-function 'keycap--preview-redisplay) #'ignore)
                ((symbol-function 'keycap--preview-send) (lambda (&rest _) (setq sent (1+ sent)))))
        ;; A camera move waits for the frame in progress; an edit does not.
        (setq keycap--preview-rendering 1)
        (keycap-preview-orbit-left)
        (should (= sent 0))
        (should keycap--preview-pending)
        (keycap--preview-loaded keycap--preview-report)
        (should (= sent 1))
        ;; An edit that changes nothing drawn keeps the frame.
        (setq keycap--preview-sent-scene (cons nil 4))
        (keycap--preview-loaded (cons '(scene . 4) keycap--preview-report))
        (should (= sent 1))
        (keycap--preview-loaded (cons '(scene . 5) keycap--preview-report))
        (should (= sent 2))))))

(ert-deftest keycap-test-preview-echo-area ()
  (keycap-test-with-preview-state
    (let ((window (selected-window))
          (height 200)
          (echo 20)
          (rendered 0))
      (cl-letf (((symbol-function 'window-buffer) (lambda (&rest _) (current-buffer)))
                ((symbol-function 'window-body-width) (lambda (&rest _) 300))
                ((symbol-function 'window-body-height) (lambda (&rest _) height))
                ((symbol-function 'window-default-line-height) (lambda (&rest _) 20))
                ((symbol-function 'window-pixel-height) (lambda (&rest _) echo))
                ((symbol-function 'window-at-side-p) (lambda (&rest _) t))
                ((symbol-function 'keycap--preview-render)
                 (lambda (&rest _) (setq rendered (1+ rendered)))))
        (setq keycap--preview-size (keycap--preview-window-size window))
        ;; Three lines of ElDoc and back render nothing.
        (setq height 160 echo 60)
        (keycap--preview-resized window)
        (setq height 200 echo 20)
        (keycap--preview-resized window)
        (should (= rendered 0))
        ;; The window itself shrinking does.
        (setq height 150)
        (keycap--preview-resized window)
        (should (= rendered 1))))))

(ert-deftest keycap-test-preview-drag-adapt ()
  (let ((keycap-preview-drag-resolution 0.5)
        (keycap-preview-drag-frame-time 0.05))
    (cl-flet ((drag (seconds)
                ;; The shares of a drag's frames, each taking SECONDS of its share
                (with-temp-buffer
                  (setq keycap--preview-drag-share keycap-preview-drag-resolution)
                  (cl-loop repeat 8
                           collect keycap--preview-drag-share
                           do (keycap--preview-drag-adapt
                               (funcall seconds keycap--preview-drag-share))))))
      ;; A time that goes with the pixels: on to the share that takes 50 ms.
      (should (equal (seq-uniq (drag (lambda (share) (* 0.4 share share))))
                     (list 0.5 (sqrt 0.125))))
      ;; Fast enough: the share stays.
      (should (equal (seq-uniq (drag (lambda (_) 0.01))) '(0.5)))
      ;; A latency that fewer pixels cannot go below: down to the least share.
      (should (equal (car (last (drag (lambda (share) (+ 0.04 (* 0.5 share share)))))) 0.25))
      ;; A time that fewer pixels do not lower: back to the share before.
      (should (equal (drag (lambda (_) 2.4)) '(0.5 0.25 0.5 0.5 0.5 0.5 0.5 0.5)))
      (should (equal (drag (lambda (share) (if (< share 0.5) 0.7 0.56)))
                     '(0.5 0.25 0.5 0.5 0.5 0.5 0.5 0.5)))
      ;; Unless the time to aim at is nil.
      (let ((keycap-preview-drag-frame-time nil))
        (should (equal (seq-uniq (drag (lambda (_) 2.4))) '(0.5)))))))

(ert-deftest keycap-test-preview-keys ()
  (keycap-test-with-preview-state
    (cl-letf (((symbol-function 'keycap--preview-render) #'ignore))
      (keycap-preview-cycle-view)
      (should (eq keycap--preview-view 'heightmap))
      (keycap-preview-cycle-view)
      (should (eq keycap--preview-view 'sdf))
      ;; In 2D, the view keys pick the slice and the arrows move.
      (keycap-preview-front)
      (should (eq keycap--preview-axis 'y))
      (keycap-preview-orbit-left)
      (should (equal keycap--preview-pan '(-0.1 . 0.0)))
      (keycap-preview-slice-forward)
      (should (equal keycap--preview-offset 1.0))
      (keycap-preview-slice-forward -2)
      (should (equal keycap--preview-offset -2))
      (keycap-preview-cycle-view)
      (keycap-preview-cycle-view)
      (should (eq keycap--preview-view 'shaded))
      (should-error (keycap-preview-slice-forward) :type 'user-error)
      (keycap-preview-front)
      (should (equal (list keycap--preview-azimuth keycap--preview-elevation) '(-90 0)))
      (keycap-preview-toggle-bounds)
      (should (eq keycap--preview-bounds 'fitted))
      (keycap-preview-toggle-backend)
      (should (eq keycap--preview-backend 'auto))
      ;; Each view has a key of its own.
      (pcase-dolist (`(,key . ,view) '(("m" . mono) ("z" . heightmap) ("d" . sdf) ("s" . shaded)))
        (funcall (keymap-lookup keycap-preview-mode-map key))
        (should (eq keycap--preview-view view))))))

(ert-deftest keycap-test-preview-tilt ()
  (keycap-test-with-preview-state
    (cl-letf (((symbol-function 'keycap--preview-render) #'ignore))
      (should-error (keycap-preview-tilt-forward) :type 'user-error)
      (setq keycap--preview-view 'sdf
            keycap--preview-offset 4)
      ;; 5° a step, on whole steps, about the image's right with braces
      ;; and about its up with Meta.
      (keycap-preview-tilt-forward)
      (keycap-preview-tilt-forward)
      (keycap-preview-tilt-left)
      (should (equal keycap--preview-tilt '(10 . -5)))
      (setq keycap--preview-tilt '(12.3 . -5))
      (keycap-preview-tilt-backward)
      (should (equal keycap--preview-tilt '(10 . -5)))
      ;; A prefix argument sets the angle; angles stay within ±180°.
      (keycap-preview-tilt-right -30)
      (keycap-preview-tilt-forward 190)
      (should (equal keycap--preview-tilt '(-170 . -30)))
      (should (equal (keymap-lookup keycap-preview-mode-map "M-}") 'keycap-preview-tilt-right))
      (should (equal (keymap-lookup keycap-preview-mode-map "{") 'keycap-preview-tilt-backward))
      ;; Dragging down tilts the top toward you, right the right edge away.
      (should (equal (keycap--preview-tilted '(10 . 0) 50 -25) '(0.0 . 20.0)))
      (should (equal (keymap-lookup keycap-preview-mode-map "C-<down-mouse-1>")
                     'keycap-preview-mouse-tilt))
      (setq keycap--preview-tilt '(12.4 . -30))
      (let ((header (keycap-preview-header)))
        (should (equal header "sdf z ⊥ (12°, -30°) at 4"))
        (should (eq (get-text-property (string-search "(" header) 'keycap-command header)
                    'keycap-preview-level)))
      (should (equal (alist-get 'slice (keycap-preview-request 10 10))
                     '((axis . "z") (offset . 4) (tilt . [12.4 -30]))))
      (should (equal (keycap--preview-slice-shown) '(z 4 (12.4 . -30))))
      ;; Tilted, every coordinate of the point read changes.
      (keycap--preview-read '((position 1 2 3.5) (value . 0.5)))
      (should (string-prefix-p "x 1.00  y 2.00  z 3.50" keycap--preview-readout))
      ;; `r' levels the slice where it is; a digit slices level across
      ;; its axis; `0' faces the iso camera.
      (keycap-preview-reset-camera)
      (should (equal (list keycap--preview-tilt keycap--preview-offset) '((0 . 0) 4)))
      (keycap-preview-tilt-forward)
      (keycap-preview-front)
      (should (equal (list keycap--preview-axis keycap--preview-tilt) '(y (0 . 0))))
      (setq keycap--preview-zoom 2.0)
      (keycap-preview-isometric)
      (should (equal (list keycap--preview-axis keycap--preview-zoom
                           (round (car keycap--preview-tilt)) (round (cdr keycap--preview-tilt)))
                     '(z 2.0 56 26))))))

;; --- Numbers under the mouse ---

(defun keycap-test-mouse-event (type buffer position)
  "A mouse event of TYPE on the character at POSITION of BUFFER's window."
  (let ((window (or (get-buffer-window buffer) (selected-window))))
    (list type (list window position '(0 . 0) 0 nil position nil nil nil nil))))

(ert-deftest keycap-test-mouse-nudge ()
  (save-window-excursion
    (keycap-test-with-script "let r = 12.5;\nlet s = r;\n"
      (set-window-buffer (selected-window) (current-buffer))
      (let ((event (lambda (type text)
                     (keycap-test-mouse-event type (current-buffer)
                                              (save-excursion
                                                (goto-char (point-min))
                                                (search-forward text)
                                                (match-beginning 0))))))
        ;; The digit under the mouse is the one that changes.
        (should (= (keycap--number-at-mouse (funcall event 'S-wheel-up "2.5")) 10))
        (should-not (keycap--number-at-mouse (funcall event 'S-wheel-up "= 12")))
        (should-not (keycap--number-at-mouse (funcall event 'S-wheel-up ";\nlet s")))
        (keycap-mouse-nudge-number (funcall event 'S-wheel-up "2.5"))
        (should (string-prefix-p "let r = 13.5;" (buffer-string)))
        (keycap-mouse-nudge-number (funcall event 'S-wheel-down "5;"))
        (should (string-prefix-p "let r = 13.4;" (buffer-string)))
        (keycap-mouse-nudge-number (funcall event 'S-wheel-down "."))
        (should (string-prefix-p "let r = 12.4;" (buffer-string)))
        ;; Off a number, the wheel does what it would.
        (let (fallen)
          (cl-letf (((symbol-function 'mwheel-scroll) (lambda (&rest _) (interactive) (setq fallen t))))
            (keycap-mouse-nudge-number (funcall event 'S-wheel-up "let s")))
          (should fallen)
          (should (string-prefix-p "let r = 12.4;" (buffer-string))))))))

(ert-deftest keycap-test-mouse-wheel-direction ()
  (should (= (keycap--wheel-direction '(S-wheel-up nil)) 1))
  (should (= (keycap--wheel-direction '(S-wheel-down nil)) -1)))

(ert-deftest keycap-test-menu ()
  (should (keymap-lookup keycap-mode-map "<menu-bar> <Keycap>"))
  (should (eq (keymap-lookup keycap-mode-map "S-<wheel-up>") 'keycap-mouse-nudge-number))
  (should (eq (keymap-lookup keycap-mode-map "S-<down-mouse-1>") 'keycap-mouse-scrub-number))
  (keycap-test-with-docs
    (save-window-excursion
      (keycap-test-with-script "draw(circle(1));\n"
        (set-window-buffer (selected-window) (current-buffer))
        (let ((menu (keycap-context-menu (make-sparse-keymap)
                                         (keycap-test-mouse-event 'mouse-3 (current-buffer) 7))))
          (should (equal (nth 2 (assq 'keycap-describe menu)) "Describe circle")))
        (let ((menu (keycap-context-menu (make-sparse-keymap)
                                         (keycap-test-mouse-event 'mouse-3 (current-buffer) 14))))
          (should-not (assq 'keycap-describe menu)))))))


;; --- Server ---

(ert-deftest keycap-test-command ()
  (let ((keycap-server-program "keycap-server")
        (keycap-prelude-directory nil))
    (should (equal (keycap--command) '("keycap-server")))
    (let ((keycap-server-threads 4))
      (should (equal (keycap--command) '("keycap-server" "--threads" "4"))))))

(ert-deftest keycap-test-names-failed ()
  ;; A server that cannot start lists nothing, and the next call asks again.
  (let ((keycap-server-program "keycap-test-no-such-server")
        (keycap-prelude-directory nil)
        (keycap--names nil)
        (keycap--modules nil))
    (should (zerop (hash-table-count (keycap-names 'keycap))))
    (should-not keycap--names)
    (should-not keycap--modules)))

(ert-deftest keycap-test-server-missing ()
  ;; Either way a server starts, a missing one says what to set.
  (let ((keycap-server-program "keycap-test-no-such-server")
        (keycap-prelude-directory nil))
    (with-temp-buffer
      (dolist (start (list #'keycap--server (lambda () (keycap-docs 'keycap))))
        (should (string-match-p "keycap-server-program"
                                (cadr (should-error (funcall start) :type 'user-error))))))))

(ert-deftest keycap-test-version ()
  ;; keycap.el's header agrees with Cargo.toml, which the package is built with.
  (should (equal (lm-version (expand-file-name "../keycap.el" keycap-test-examples))
                 keycap--version))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "../server/Cargo.toml" keycap-test-examples))
    (should (re-search-forward "^version = \"\\(.*\\)\"$"))
    (should (equal (match-string 1) keycap--version))))

(ert-deftest keycap-test-server-version ()
  (skip-unless keycap-test-server)
  (should (equal (keycap-version)
                 (format "keycap %s, keycap-server %s, Emacs %s"
                         keycap--version keycap--version emacs-version)))
  (let ((kill-ring nil))
    (call-interactively #'keycap-version)
    (should (equal kill-ring (list (keycap-version)))))
  (let ((keycap-server-program "keycap-test-no-such-server"))
    (should (string-search ", no keycap-test-no-such-server," (keycap-version)))))

(ert-deftest keycap-test-dialect ()
  (let* ((directory (make-temp-file "keycap-test-" t))
         (file (lambda (name text)
                 (let ((file (expand-file-name name directory)))
                   (with-temp-file file
                     (insert text))
                   (find-file-noselect file)))))
    (unwind-protect
        (pcase-dolist (`(,name ,text ,mode ,dialect)
                       '(("a.keycap" "" keycap-mode keycap)
                         ("b.fidget" "" keycap-mode fidget)
                         ("c.fidget" "// -*- keycap-dialect: keycap -*-\n" keycap-mode keycap)
                         ("d.rhai" "" rhai-ts-mode keycap)))
          (with-current-buffer (funcall file name text)
            (unwind-protect
                (should (equal (list name major-mode keycap-dialect) (list name mode dialect)))
              (kill-buffer))))
      (delete-directory directory t))))

(defun keycap-test-load ()
  "The diagnostics of the buffer through the Flymake backend, as (TYPE TEXT MESSAGE)."
  (let (result)
    (keycap-flymake (lambda (diagnostics &rest _) (setq result (or diagnostics 'none))))
    (keycap-test-wait (lambda () result))
    (mapcar (lambda (d)
              (list (flymake-diagnostic-type d)
                    (buffer-substring-no-properties (flymake-diagnostic-beg d)
                                                    (flymake-diagnostic-end d))
                    (flymake-diagnostic-text d)))
            (if (eq result 'none) nil result))))

;; --- Manual ---

(defconst keycap-test-reference-docs
  '((functions
     ((name . "offset")
      (signatures "offset(shape: Shape, d: Tree): Shape" "shape.offset(d: Tree): Shape")
      (doc . "Grows a shape by `d`.\n\n- `shape`: the shape\n- `opts`:\n  - `offset`: see [a page](https://example.org/o)\n\nSee also: `x`, [`offset`].\n\nExample: a square. [view: top]\n```\noffset(rect(20), 2)\n```"))
     ((name . "x") (signatures "x: Tree") (doc . "The X coordinate, `x`s and `#{x}`.\n\nExample: `x * 2` is a tree.\nExample: `let a = x; a * 2`, twice X"))
     ((name . "+") (signatures "a + b -> Tree") (doc . "Sum."))
     ((name . "PI") (signatures "PI: number" "TAU: number") (aliases "TAU") (doc . "Constants.")))
    (modules
     ((name . "screws::hole")
      (signatures "screws::hole(d: number, opts: #{ k?: number } = #{}): Shape")
      (types "type T = #{\n  a: number,\n}")
      (doc . "A hole.")))
    (sections
     ((file . "prelude/csg.rhai") (kind . "csg") (names "offset"))
     ((file . "server/docs/constants.toml") (kind . "math") (names "x" "+" "PI"))
     ((file . "prelude/modules/screws.rhai") (kind . "3d") (module . "screws") (names "screws::hole"))))
  "A `docs' reply with sections, for the reference's tests.")

(defconst keycap-test-reference-markers
  (concat "#+keycap-reference: prelude/csg.rhai\n\n"
          "#+keycap-reference: server/docs/constants.toml\n\n"
          "#+keycap-reference: prelude/modules/screws.rhai\n")
  "Where a manual puts `keycap-test-reference-docs''s sections.")

(defun keycap-test-reference (text backend)
  "TEXT with the reference of `keycap-test-reference-docs' written for BACKEND."
  (with-temp-buffer
    (insert text)
    (keycap-reference-expand backend keycap-test-reference-docs)
    (buffer-string)))

(ert-deftest keycap-test-reference-link-parentheses ()
  (should (equal (keycap-reference--inline "a [Nut](https://en.wikipedia.org/wiki/Nut_(hardware)), b" (make-hash-table))
                 "a [[https://en.wikipedia.org/wiki/Nut_(hardware)][Nut]], b")))

(ert-deftest keycap-test-reference-site ()
  (should (equal (keycap-test-reference keycap-test-reference-markers 'html)
                 (concat "- Function: offset :: Grows a shape by =d=.\n\n"
                         "  - =shape= :: the shape\n"
                         "  - =opts= ::\n"
                         "    - =offset= :: see [[https://example.org/o][a page]]\n\n"
                         ;; Code that Org would not see where it stands, set apart
                         "  See also: ~x~, [\u200b~offset~\u200b].\n\n"
                         ;; Its view, for the site's picture
                         "  Example: a square. [view: top]\n"
                         "  #+begin_src rhai\n  offset(rect(20), 2)\n  #+end_src\n\n"
                         "- Variable: x :: The X coordinate, ~x~\u200bs and =#{x}=.\n\n"
                         ;; Examples in a line as blocks, a value without a caption
                         "  Example:\n  #+begin_src rhai\n  x * 2\n  #+end_src\n\n"
                         "  Example: twice X\n  #+begin_src rhai\n  let a = x;\n  a * 2\n  #+end_src\n\n"
                         "- Function: + :: Sum.\n\n"
                         ;; Its aliases, for the site's index
                         "- Variable: PI :: Constants.\n\n"
                         "#+findex: TAU\n\n"
                         "=import \"keycap/screws\" as screws;=\n\n"
                         "- Function: screws::hole :: A hole.\n"))))

(ert-deftest keycap-test-reference-info ()
  (let ((text (keycap-test-reference keycap-test-reference-markers 'texinfo)))
    (should (string-prefix-p
             (concat "#+findex: offset\n"
                     "#+texinfo: @defblock\n"
                     "#+texinfo: @defline Function offset (shape: Shape, d: Tree): Shape\n"
                     "#+texinfo: @defline Method shape.offset (d: Tree): Shape\n"
                     "Grows a shape by =d=.\n\n"
                     "- =shape= :: the shape\n")
             text))
    (should (string-search "\nExample: a square.\n#+begin_src rhai\n" text))
    (should (string-search "#+texinfo: @defline Variable {x:} Tree\n" text))
    (should (string-search "#+texinfo: @defline Operator {a + b -> Tree}\n" text))
    (should (string-search (concat "#+findex: PI\n#+findex: TAU\n"
                                   "#+texinfo: @defblock\n"
                                   "#+texinfo: @defline Variable {PI:} number\n"
                                   "#+texinfo: @defline Variable {TAU:} number\n")
                           text))
    (should (string-search
             (concat "#+findex: screws::hole\n"
                     "#+texinfo: @defblock\n"
                     "#+texinfo: @defline Function screws::hole (d: number, opts: #@{ k?: number @} = #@{@}): Shape\n"
                     "#+begin_example\ntype T = #{\n    a: number,\n}\n#+end_example\n"
                     "A hole.\n"
                     "#+texinfo: @end defblock")
             text)))
  ;; Every section has its one place.
  (should-error (keycap-test-reference "#+keycap-reference: prelude/csg.rhai\n" 'html))
  (should-error (keycap-test-reference (concat keycap-test-reference-markers
                                               "#+keycap-reference: prelude/csg.rhai\n")
                                       'html))
  (should-error (keycap-test-reference (concat keycap-test-reference-markers
                                               "#+keycap-reference: prelude/none.rhai\n")
                                       'html)))

(ert-deftest keycap-test-server-reference ()
  (skip-unless keycap-test-server)
  (let* ((docs (keycap-docs 'keycap))
         (manual (expand-file-name "../doc/keycap.org" keycap-test-examples)))
    (dolist (backend '(html texinfo))
      (with-temp-buffer
        (insert-file-contents manual)
        (keycap-reference-expand backend docs)
        (should-not (string-search "#+keycap-reference:" (buffer-string)))
        (should (string-search (if (eq backend 'html) "- Function: lc::box ::" "@defline Function lc::box (")
                               (buffer-string)))))
    ;; Every entry has a kind the reference knows.
    (maphash (lambda (name entry)
               (when (and (alist-get 'file entry)
                          (not (assoc (alist-get 'kind entry) keycap-kinds)))
                 (ert-fail (list name (alist-get 'kind entry)))))
             (keycap-reference-entries docs))
    (should (member "screws" (let ((keycap--names nil) (keycap--modules nil))
                               (keycap-names 'keycap)
                               (alist-get 'keycap keycap--modules))))))

(ert-deftest keycap-test-server-docs ()
  (skip-unless keycap-test-server)
  (let ((keycap--names nil))
    (let ((circle (keycap--doc "circle")))
      (should (eq (alist-get 'class circle) 'shape))
      (should (equal (mapcar (lambda (field) (alist-get 'name field)) (alist-get 'fields circle))
                     '("center" "radius"))))
    (should (eq (alist-get 'class (keycap--doc "min")) 'function))
    (should (equal (alist-get 'source (keycap--doc "draw")) "keycap"))
    (keycap-test-with-script ""
      (setq keycap-dialect 'fidget)
      (should (equal (alist-get 'source (keycap--doc "draw")) "fidget"))
      (should (keycap--doc "min"))
      (should-not (keycap--doc "text"))
      (should-not (keycap--doc "cuboid")))))

(ert-deftest keycap-test-server-fidget ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script "let a = 1;\ndraw(text(\"A\"));\n"
    (setq keycap-dialect 'fidget)
    (should (equal (keycap-test-load)
                   '((:error "text" "`text` is a keycap extension: rename the file to .keycap")))))
  ;; fidget's viewer draws any number of shapes.
  (keycap-test-with-script "draw(sphere(1));\ndraw(sphere(2));\n"
    (setq keycap-dialect 'fidget)
    (should-not (keycap-test-load)))
  (keycap-test-with-script "draw(sphere(1));\ndraw(text(\"A\").extrude(1));\n"
    (should-not (keycap-test-load))))

(ert-deftest keycap-test-server-clean ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script "draw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
    (should-not (keycap-test-load))))

(ert-deftest keycap-test-server-errors ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script "let a = 1;\nlet b = frobnicate(a);\n"
    (pcase (keycap-test-load)
      (`((:error ,text ,message))
       (should (equal text "frobnicate"))
       (should (string-prefix-p "Function not found: frobnicate" message)))
      (other (ert-fail other))))
  (keycap-test-with-script "fn ring(r) {\n  r + q\n}\n\ndraw(ring(1));\n"
    (pcase (keycap-test-load)
      (`((:error "q" ,message) (:note "ring" ,_))
       (should (string-match-p "Variable not found: q.*; line 5: " message)))
      (other (ert-fail other)))))

(ert-deftest keycap-test-server-warning ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script
      "bounds([-2, -2, -2], [2, 2, 2]);\ndraw(sphere(#{center: [0, 0, 0], radius: 1}));\ndraw(sphere(#{center: [0, 0, 2], radius: 1}));\n"
    (pcase (keycap-test-load)
      (`((:warning ,text ,message))
       (should (string-prefix-p "draw(sphere(#{center: [0, 0, 2]" text))
       (should (string-match-p "+z" message)))
      (other (ert-fail other)))))

(defconst keycap-test-examples
  (expand-file-name "../examples" (file-name-directory (or load-file-name buffer-file-name)))
  "The package's example models.")

(ert-deftest keycap-test-server-examples ()
  (skip-unless (and keycap-test-server (file-directory-p keycap-test-examples)))
  (dolist (file (directory-files keycap-test-examples t "\\.\\(?:keycap\\|fidget\\)\\'"))
    (with-current-buffer (find-file-noselect file)
      (unwind-protect
          (let (report)
            (keycap--load (lambda (reply) (setq report reply)))
            (keycap-test-wait (lambda () report))
            (should (equal (list file (keycap-report-failure report)) (list file nil)))
            (should (alist-get 'shapes report)))
        (kill-buffer)))))

(ert-deftest keycap-test-server-flymake-obsolete ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script "draw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
    (let (first second)
      ;; A check that a newer one replaced while it ran reports nothing.
      (keycap-flymake (lambda (&rest args) (setq first (or args 'none))))
      (goto-char (point-max))
      (insert "draw(q);\n")
      (keycap-flymake (lambda (&rest args) (setq second (or args 'none))))
      (keycap-test-wait (lambda () second))
      (should-not first))))

(ert-deftest keycap-test-server-load-coalesced ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script "draw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
    (let ((replies 0)
          (requests 0))
      (add-hook 'keycap--load-functions (lambda (_) (setq replies (1+ replies))) nil t)
      (cl-letf* ((request (symbol-function 'keycap--request))
                 ((symbol-function 'keycap--request)
                  (lambda (&rest args) (setq requests (1+ requests)) (apply request args))))
        (keycap--load)
        (keycap--load)
        (keycap-test-load)
        (should (= requests 1))
        (should (= replies 1))))))

(ert-deftest keycap-test-server-sync ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script "const N = 2;\ndraw(sphere(N));\n"
    (let ((report (keycap-load-sync)))
      (should (alist-get 'loaded report))
      ;; The same text is not loaded again, unless asked to be.
      (should (eq (keycap-load-sync) report))
      (should-not (eq (keycap-load-sync t) report)))
    (should (equal (alist-get 'value (keycap-request-sync '((op . "eval") (source . "")
                                                            (expression . "1 + 2"))))
                   "3"))
    (should-not (keycap-request-sync '((op . "eval") (source . "") (expression . "1")) 0))))

(ert-deftest keycap-test-server-batch ()
  (skip-unless keycap-test-server)
  (should (equal (mapcar (lambda (reply) (alist-get 'value reply))
                         (keycap-server-batch
                          (mapcar (lambda (expression)
                                    `((op . "eval") (source . "") (expression . ,expression)))
                                  '("1 + 1" "2 * 3" "10 - 1"))))
                 '("2" "6" "9"))))

(ert-deftest keycap-test-server-shared ()
  (skip-unless keycap-test-server)
  (let ((owner (generate-new-buffer " keycap-test-server"))
        server)
    (unwind-protect
        (progn
          (keycap-test-with-script "draw(sphere(1));\n"
            (keycap-use-server owner)
            (setq server keycap--server)
            (should (alist-get 'loaded (keycap-load-sync))))
          ;; Killing the script leaves the server running for the next one.
          (should (process-live-p server))
          (keycap-test-with-script "draw(sphere(2));\n"
            (keycap-use-server owner)
            (should (eq keycap--server server))
            (should (alist-get 'loaded (keycap-load-sync)))))
      (with-current-buffer owner
        (keycap--stop-server))
      (kill-buffer owner))
    (should-not (process-live-p server))))

(ert-deftest keycap-test-server-restart ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script "draw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
    (let (reply)
      (keycap--load (lambda (r) (setq reply r)))
      (delete-process keycap--server)
      (keycap-test-wait (lambda () reply))
      (should (string-prefix-p "keycap-server stopped" (alist-get 'error reply)))
      ;; Asked again, it starts again.
      (should-not (keycap-test-load)))))

(ert-deftest keycap-test-server-eval ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script "fn twice(v) { v * 2 }\nlet a = 20;\ntwice(a + 1)|;\n"
    (let (shown)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq shown (apply #'format-message format args)))))
        (keycap-eval-last-expression)
        (keycap-test-wait (lambda () shown)))
      (should (equal shown "=> 42")))))

(ert-deftest keycap-test-server-overrides ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script "const N = 1;\nconst ON = true;\nconst A = [];\n[N, ON, A]|;\n"
    (setq keycap-overrides '((N . 2) (ON . nil) (A . [1.5 "x" t])))
    (let (shown)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq shown (apply #'format-message format args)))))
        (keycap-eval-last-expression)
        (keycap-test-wait (lambda () shown)))
      (should (equal shown "=> [2, false, [1.5, \"x\", true]]")))
    (setq keycap-overrides '((M . 2)))
    (should (string-match-p "cannot override `M`" (nth 2 (car (keycap-test-load)))))))

(ert-deftest keycap-test-server-export ()
  (skip-unless keycap-test-server)
  (let ((file (make-temp-file "keycap-test-" nil ".stl")))
    (unwind-protect
        (keycap-test-with-script
            "bounds([-2, -2, -2], [2, 2, 2]);\nresolution(4);\ndraw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
          (delete-file file)
          (let (done)
            (cl-letf (((symbol-function 'message)
                       (lambda (format &rest args)
                         (setq done (apply #'format format args)))))
              (keycap-export-stl file)
              (keycap-test-wait (lambda () (and done (not (string-suffix-p "..." done))))))
            (should (string-prefix-p "Exported" done)))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally file)
            ;; A binary STL: 80 bytes of header, a count, 50 bytes a triangle.
            (should (> (buffer-size) 84))
            (should (zerop (% (- (buffer-size) 84) 50)))))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest keycap-test-export-status ()
  (with-temp-buffer
    (should-not (keycap--export-status))
    (setq keycap--export (list 1 "/models/part.stl" (- (float-time) 4.2) nil nil))
    (should (equal (keycap--export-status) "part.stl: starting, 4 s"))
    (keycap--exported "/models/part.stl" '((progress . "octree")))
    (should (equal (keycap--export-status) "part.stl: sampling, 4 s"))
    (keycap--exported "/models/part.stl" '((progress . "simplifying") (tolerance . 0.05)))
    (should (equal (keycap--export-status) "part.stl: simplifying to 0.05, 4 s"))))

(defun keycap-test-export-2d-request (&rest arguments)
  "The request `keycap-export-2d' sends for ARGUMENTS, the script loaded."
  (let (sent)
    (cl-letf (((symbol-function 'keycap--load)
               (lambda (callback) (funcall callback '((loaded . t)))))
              ((symbol-function 'keycap--request)
               (lambda (request _callback) (setq sent request) 1))
              ((symbol-function 'run-with-timer) #'ignore)
              ((symbol-function 'message) #'ignore))
      (apply #'keycap-export-2d arguments)
      (setq keycap--export nil))
    sent))

(ert-deftest keycap-test-export-2d-arguments ()
  (with-temp-buffer
    (let ((keycap-export-kerf 0.15)
          (keycap-export-resolution 20)
          (keycap-export-tolerance nil))
      (should-error (keycap-export-2d "part.png") :type 'user-error)
      (should-error (keycap-export-2d "part") :type 'user-error)
      (let ((request (keycap-test-export-2d-request "/models/part.DXF")))
        (should (equal (alist-get 'op request) "trace"))
        (should (equal (alist-get 'format request) "dxf"))
        (should (equal (alist-get 'output request) "/models/part.DXF"))
        (should (equal (alist-get 'bounds request) "script"))
        (should (equal (alist-get 'kerf request) 0.15))
        (should (equal (alist-get 'resolution request) 20))
        (should-not (assq 'slice request))
        (should-not (assq 'tolerance request)))
      (let ((request (keycap-test-export-2d-request "/models/part.svg" 0.2 '(x 2.5) 'fitted)))
        (should (equal (alist-get 'format request) "svg"))
        (should (equal (alist-get 'kerf request) 0.2))
        (should (equal (alist-get 'slice request) '((axis . "x") (offset . 2.5))))
        (should (equal (alist-get 'bounds request) "fitted")))
      (let ((request (keycap-test-export-2d-request "/models/part.svg" nil '(z 1 (10 . -5)))))
        (should (equal (alist-get 'slice request) '((axis . "z") (offset . 1) (tilt . [10 -5])))))
      ;; One export at a time
      (setq keycap--export (list 1 "/models/part.stl" (float-time) nil nil))
      (should-error (keycap-export-2d "part.svg") :type 'user-error))))

(ert-deftest keycap-test-export-2d-status ()
  (with-temp-buffer
    (let (shown)
      (setq keycap--export (list 1 "/models/part.svg" (- (float-time) 1.2) nil nil))
      (keycap--exported "/models/part.svg" '((progress . "contours")))
      (should (keycap-exporting-p))
      (should (equal (keycap--export-status) "part.svg: tracing, 1 s"))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq shown (apply #'format format args)))))
        (keycap--exported "/models/part.svg"
                          '((outlines . 3) (lines . 4) (arcs . 6) (ms . 250))))
      (should-not (keycap-exporting-p))
      (should (equal shown "Exported /models/part.svg: 3 outlines, 4 lines and 6 arcs in 0.2 s")))))

(ert-deftest keycap-test-server-export-2d ()
  (skip-unless keycap-test-server)
  (let ((file (make-temp-file "keycap-test-" nil ".svg")))
    (unwind-protect
        (keycap-test-with-script
            "draw(difference(sphere(5), sphere(2)));\ndraw(circle([0, 4], 0.5), #{role: \"score\"});\n"
          (delete-file file)
          (let (done)
            (cl-letf (((symbol-function 'message)
                       (lambda (format &rest args)
                         (setq done (apply #'format format args)))))
              (keycap-export-2d file nil '(z 3))
              (keycap-test-wait (lambda () (and done (not (string-suffix-p "..." done))))))
            (should (string-match-p "\\`Exported .*: 2 outlines, 0 lines and 4 arcs" done)))
          (with-temp-buffer
            (insert-file-contents file)
            ;; The sphere's slice at z = 3, a circle of radius 4, to cut
            (should (search-forward "<g id=\"score\" fill=\"none\" stroke=\"#0000ff\"" nil t))
            (should (search-forward "<g id=\"cut\"" nil t))
            (should (search-forward " A 4 4 0 0 0 " nil t))))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest keycap-test-export-print ()
  (let ((buffer (generate-new-buffer "part.keycap")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((keycap-print-layer-heights '(0.25 0.1 0.3))
                (keycap-print-slicer "orca-slicer")
                sent reply opened shown)
            (cl-letf (((symbol-function 'keycap--load)
                       (lambda (callback) (funcall callback '((loaded . t)))))
                      ((symbol-function 'keycap--request)
                       (lambda (request callback) (setq sent request reply callback) 1))
                      ((symbol-function 'run-with-timer) #'ignore)
                      ((symbol-function 'cancel-timer) #'ignore)
                      ((symbol-function 'make-process)
                       (lambda (&rest arguments) (setq opened (plist-get arguments :command))))
                      ((symbol-function 'message)
                       (lambda (format &rest args) (setq shown (apply #'format format args)))))
              (keycap-export-print "/models/part.3mf")
              (should (equal (alist-get 'op sent) "print"))
              (should (equal (alist-get 'name sent) "part"))
              (should (equal (alist-get 'layer_heights sent) [0.25 0.1 0.3]))
              (should (equal (alist-get 'bounds sent) "script"))
              (funcall reply '((progress . "layers")))
              (should (equal (keycap--export-status) "part.3mf: slicing, 0 s"))
              (should-not opened)
              (funcall reply '((triangles . 900) (layers . 50) (points . 4000) (ms . 1500)))
              (should (equal shown "Exported /models/part.3mf: 50 layers on 900 triangles in 1.5 s"))
              (should (equal opened '("orca-slicer" "/models/part.3mf"))))))
      (kill-buffer buffer))))

(ert-deftest keycap-test-server-export-print ()
  (skip-unless keycap-test-server)
  (let ((file (make-temp-file "keycap-test-" nil ".3mf")))
    (unwind-protect
        (keycap-test-with-script "draw(sphere(#{center: [0, 0, 0], radius: 2}));
"
          (delete-file file)
          (let ((keycap-print-slicer nil)
                done)
            (cl-letf (((symbol-function 'message)
                       (lambda (format &rest args)
                         (setq done (apply #'format format args)))))
              (keycap-export-print file 'fitted)
              (keycap-test-wait (lambda () (and done (not (string-suffix-p "..." done))))))
            (should (string-match-p "\\`Exported .*: [0-9]+ layers on [0-9]+ triangles" done)))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally file)
            (should (string-prefix-p "PK\3\4" (buffer-string)))
            (should (search-forward "Metadata/keycap_layers.json" nil t))))
      (when (file-exists-p file)
        (delete-file file)))))


;; --- Resin ---

(defun keycap-test-export-resin-request (command &rest arguments)
  "The request COMMAND sends for ARGUMENTS, the script loaded."
  (let (sent)
    (cl-letf (((symbol-function 'keycap--load)
               (lambda (callback) (funcall callback '((loaded . t)))))
              ((symbol-function 'keycap--request)
               (lambda (request _callback) (setq sent request) 1))
              ((symbol-function 'run-with-timer) #'ignore)
              ((symbol-function 'message) #'ignore))
      (apply command arguments)
      (setq keycap--export nil))
    sent))

(ert-deftest keycap-test-export-resin-arguments ()
  (with-temp-buffer
    (let ((keycap-resin-printer "prusa-sl1s")
          (default-directory "/models/"))
      (let ((request (keycap-test-export-resin-request #'keycap-export-resin "/models/part.sl1")))
        (should (equal (alist-get 'op request) "resin"))
        (should (equal (alist-get 'output request) "/models/part.sl1"))
        (should (equal (alist-get 'printer request) "prusa-sl1s"))
        (should (equal (alist-get 'bounds request) "script"))
        (should-not (assq 'z request)))
      (let ((request (keycap-test-export-resin-request
                      #'keycap-export-resin-layer "/models/layer.png" 2.5 "printers/mine.toml" 'fitted)))
        (should (equal (alist-get 'printer request) "/models/printers/mine.toml"))
        (should (equal (alist-get 'bounds request) "fitted"))
        (should (equal (alist-get 'z request) 2.5))))))

(ert-deftest keycap-test-export-resin-status ()
  (with-temp-buffer
    (let (shown)
      (setq keycap--export (list 1 "/models/part.sl1" (- (float-time) 2.2) nil nil))
      (keycap--exported "/models/part.sl1" '((progress . "layers")))
      (should (equal (keycap--export-status) "part.sl1: slicing, 2 s"))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq shown (apply #'format format args)))))
        (keycap--exported "/models/part.sl1"
                          '((layers . 200) (layer_height . 0.05) (volume . 523.6) (ms . 1430)))
        (should (equal shown "Exported /models/part.sl1: 200 layers of 0.05, 0.5 ml, in 1.4 s"))
        (keycap--exported "/models/layer.png"
                          '((bottom . 1.25) (layer_height . 0.05) (ms . 20)))
        (should (equal shown "Exported /models/layer.png: the layer from 1.250 to 1.300 in 0.0 s"))))))

(ert-deftest keycap-test-server-export-resin ()
  (skip-unless keycap-test-server)
  (let ((file (make-temp-file "keycap-test-" nil ".sl1")))
    (unwind-protect
        (keycap-test-with-script "draw(sphere(#{center: [0, 0, 5], radius: 5}));\n"
          (delete-file file)
          (let (done)
            (cl-letf (((symbol-function 'message)
                       (lambda (format &rest args)
                         (setq done (apply #'format format args)))))
              (keycap-export-resin file "prusa-sl1s")
              (keycap-test-wait (lambda () (and done (not (string-suffix-p "..." done))))))
            (should (string-match-p "\\`Exported .*: 2[0-9][0-9] layers of 0.05, 0.5 ml" done)))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally file)
            ;; A zip, its settings after the layers
            (should (string-prefix-p "PK\3\4" (buffer-string)))
            (should (search-forward "numFast = " nil t))))
      (when (file-exists-p file)
        (delete-file file)))))


;; --- Preview ---

(defun keycap-test-frame-size (preview)
  "The width and height in the header of PREVIEW's PPM frame."
  (let ((file (with-current-buffer preview
                (if keycap--preview-image
                    (image-property keycap--preview-image :file)
                  (keycap--preview-frame-file)))))
    (with-temp-buffer
      (insert-file-contents-literally file nil 0 32)
      (should (looking-at "P6\n\\([0-9]+\\) \\([0-9]+\\)\n255\n"))
      (cons (string-to-number (match-string 1)) (string-to-number (match-string 2))))))

(defmacro keycap-test-with-preview (script &rest body)
  "Run BODY in the preview of a `keycap-mode' buffer holding SCRIPT.
The preview renders into a 300 by 200 window; batch Emacs has none."
  (declare (indent 1))
  `(keycap-test-with-script ,script
     (let ((window (selected-window)))
       (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) window))
                 ((symbol-function 'window-body-width) (lambda (&rest _) 300))
                 ((symbol-function 'window-body-height) (lambda (&rest _) 200))
                 ((symbol-function 'window-default-line-height) (lambda (&rest _) 20))
                 ((symbol-function 'frame-scale-factor) (lambda (&rest _) 1)))
         (let ((preview (keycap--preview-for (current-buffer))))
           (unwind-protect
               (with-current-buffer preview
                 ,@body)
             (kill-buffer preview)))))))

(defun keycap-test-preview-idle ()
  "Wait for the preview's frame, with no load or render left."
  (keycap-test-wait (lambda () (keycap-preview-idle-p keycap--preview-source))))

(ert-deftest keycap-test-preview-render ()
  (skip-unless keycap-test-server)
  (keycap-test-with-preview "draw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
    (keycap-test-preview-idle)
    (should (string-prefix-p (expand-file-name "keycap/" (or (getenv "XDG_RUNTIME_DIR")
                                                                  temporary-file-directory))
                             keycap--preview-directory))
    (should (eq keycap--preview-view 'shaded))
    (should keycap--preview-image)
    (should (equal (keycap-test-frame-size (current-buffer)) '(300 . 200)))
    (should (string-match-p "\\`shaded iso  ·  fitted bounds [0-9.]+ × [0-9.]+ × [0-9.]+  ·  [GC]PU [0-9.]+ m?s\\(?: (no GPU)\\)?\\'"
                            (keycap-preview-header)))
    ;; Requests while one runs wait, and coalesce into one.
    (let ((renders 0))
      (cl-letf* ((send (symbol-function 'keycap--preview-send))
                 ((symbol-function 'keycap--preview-send)
                  (lambda (&rest args) (setq renders (1+ renders)) (apply send args))))
        (keycap-preview-orbit-left)
        (keycap-preview-orbit-left)
        (keycap-preview-orbit-left)
        (should keycap--preview-pending)
        (keycap-test-preview-idle)
        (should (= renders 2))
        (should (= keycap--preview-azimuth -105))))
    ;; One sent at once supersedes the render that runs, which is dropped.
    (let ((shown 0))
      (cl-letf* ((rendered (symbol-function 'keycap--preview-rendered))
                 ((symbol-function 'keycap--preview-rendered)
                  (lambda (&rest args) (setq shown (1+ shown)) (apply rendered args))))
        (keycap-preview-orbit-left)
        (keycap-preview-orbit-left)
        (keycap--preview-render t)
        (should-not keycap--preview-pending)
        (keycap-test-preview-idle)
        (should (= shown 1))))
    ;; Only the frame shown keeps its file.
    (should (equal (directory-files keycap--preview-directory t "\\.ppm\\'")
                   (list (image-property keycap--preview-image :file))))))

(ert-deftest keycap-test-preview-2d ()
  (skip-unless keycap-test-server)
  (keycap-test-with-preview "draw(circle(#{center: [0, 0], radius: 1}));\n"
    (keycap-test-preview-idle)
    (should (eq keycap--preview-view 'sdf))
    (should (string-prefix-p "sdf z = 0  ·  fitted bounds " (keycap-preview-header)))
    ;; The field at the image's centre: the circle's, inside.
    (setq keycap--preview-probe-next '(150 . 100)
          keycap--preview-leave-timer (timer-create))
    (keycap--preview-probe)
    (keycap-test-wait (lambda () keycap--preview-readout))
    (should (string-match-p "\\`x [-0-9.]+  y [-0-9.]+  = -[0-9.]+\\'" keycap--preview-readout))
    ;; A new frame drops the reading of the last one.
    (keycap-preview-orbit-left)
    (keycap-test-preview-idle)
    (should-not keycap--preview-readout)))

(ert-deftest keycap-test-preview-snapshot-render ()
  (skip-unless keycap-test-server)
  (keycap-test-with-script (concat "bounds([-4, -2, -1], [4, 2, 1]);\n"
                                   "draw(circle(#{center: [2, 1], radius: 0.5}));\n")
    (let ((snapshot (keycap-preview-snapshot (current-buffer) :report (keycap-load-sync) :backend 'cpu))
          (script (current-buffer)))
      (cl-flet ((render ()
                  (let ((request (keycap-preview-request 80 40)))
                    (keycap-preview-set-frame (with-current-buffer script
                                                (keycap-request-sync request)))))
                (reading ()
                  ;; Where the reading is, and whether it is inside the circle
                  (should (string-match "\\`x \\([-0-9.]+\\)  y \\([-0-9.]+\\)  = \\(-?\\)"
                                        keycap--preview-readout))
                  (list (< (abs (- (string-to-number (match-string 1 keycap--preview-readout)) 2)) 0.2)
                        (< (abs (- (string-to-number (match-string 2 keycap--preview-readout)) 1)) 0.2)
                        (match-string 3 keycap--preview-readout))))
        (unwind-protect
            (with-current-buffer snapshot
              (render)
              (should (equal (keycap-test-frame-size snapshot) '(80 . 40)))
              (should (string-prefix-p "sdf z = 0  ·  script bounds 8 × 4 × 2  ·  CPU "
                                       (keycap-preview-header)))
              (let ((pixel (keycap-preview-probe-sync 2 1 80 40)))
                (should (equal (reading) '(t t "-")))
                ;; Moved right, the camera sees the circle further left.
                (setq keycap--preview-pan '(0.5 . 0.0))
                (render)
                (should (< (car (keycap-preview-probe-sync 2 1 80 40)) (car pixel)))
                (should (equal (reading) '(t t "-")))))
          (kill-buffer snapshot))))))

(ert-deftest keycap-test-preview-goto-shape ()
  (skip-unless keycap-test-server)
  (keycap-test-with-preview (concat "draw(circle(#{center: [-5, 0], radius: 1}));\n"
                                    "draw(circle(#{center: [5, 0], radius: 1}));\n")
    (keycap-test-preview-idle)
    (let ((preview (current-buffer))
          pixel
          shown)
      (cl-letf (((symbol-function 'keycap--preview-clicked) (lambda (_) preview))
                ((symbol-function 'keycap--preview-image-pixel) (lambda (_) pixel))
                ((symbol-function 'keycap--preview-show-in-script)
                 (lambda (&rest where) (setq shown where))))
        ;; Each side of the image is nearest to the circle drawn there.
        (setq pixel '(299 . 100))
        (keycap-preview-mouse-goto-shape nil)
        (keycap-test-wait (lambda () shown))
        (should (equal shown '(nil 2 1)))
        (setq pixel '(0 . 100)
              shown nil)
        (keycap-preview-mouse-goto-shape nil)
        (keycap-test-wait (lambda () shown))
        (should (equal shown '(nil 1 1)))))))

(ert-deftest keycap-test-preview-failure ()
  (skip-unless keycap-test-server)
  (keycap-test-with-preview "print(\"hello\");\ndraw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
    (keycap-test-preview-idle)
    (should (equal keycap--preview-output '("hello")))
    (should (equal (keycap-test-frame-size (current-buffer)) '(300 . 180)))
    (let ((image keycap--preview-image))
      (with-current-buffer keycap--preview-source
        (goto-char (point-max))
        (insert "draw(q);\n")
        (keycap--reload))
      (keycap-test-wait (lambda () keycap--preview-failure))
      (should (string-match-p "\\`line 3: .*q" keycap--preview-failure))
      ;; The last frame stays.
      (should (eq keycap--preview-image image))
      (should (string-prefix-p keycap--preview-failure (keycap-preview-header))))))

(ert-deftest keycap-test-preview-follows ()
  (skip-unless keycap-test-server)
  (let ((keycap-load-delay 0.01))
    (keycap-test-with-preview "draw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
      (keycap-test-preview-idle)
      (let ((frame keycap--preview-frame))
        (with-current-buffer keycap--preview-source
          (search-forward "radius: ")
          (keycap-increase-number 1))
        (keycap-test-wait (lambda () (not (eq frame keycap--preview-frame))))
        (should (equal (with-current-buffer keycap--preview-source (buffer-string))
                       "draw(sphere(#{center: [0, 0, 0], radius: 2}));\n"))))))

(ert-deftest keycap-test-preview-typing ()
  (skip-unless keycap-test-server)
  ;; While loads, renders, Flymake and ElDoc come and go, what is typed
  ;; stays where it was typed.
  (let ((keycap-load-delay 0.01)
        (text "let a = [\n1,\n#{b: [2, 3]},\n];\nimport \"x\" as x;\ndraw(sphere(a[0]));\n"))
    (keycap-test-with-preview ""
      (with-current-buffer keycap--preview-source
        (dolist (char (string-to-list text))
          (insert char)
          (keycap-eldoc-function #'ignore)
          (keycap-flymake #'ignore)
          (accept-process-output nil 0.005))
        (keycap-test-wait (lambda () (not keycap--load-waiting)))
        (should (equal (buffer-string) text))
        (should (eobp))))))

(ert-deftest keycap-test-preview-export-cancelled ()
  (skip-unless keycap-test-server)
  (let ((file (make-temp-file "keycap-test-" nil ".stl" "an earlier mesh"))
        shown)
    (unwind-protect
        ;; An octree 1024 cells across takes the gyroid many seconds.
        (keycap-test-with-preview
            (concat "let g = sin(x * 30) * cos(y * 30) + sin(y * 30) * cos(z * 30)"
                    " + sin(z * 30) * cos(x * 30);\n"
                    "resolution(600);\ndraw(max(sphere(0.8), abs(g) - 0.2));\n")
          (keycap-test-preview-idle)
          (cl-letf (((symbol-function 'message)
                     (lambda (format &rest args) (setq shown (apply #'format format args)))))
            (with-current-buffer keycap--preview-source
              (keycap-export-stl file)
              (keycap-test-wait (lambda () (nth 3 keycap--export)))
              (should-error (keycap-export-stl file) :type 'user-error))
            (should (string-match-p "\\`shaded iso  ·  Exporting keycap-test-[^ ]+\\.stl: sampling, [0-9]+ s (C-g cancels)"
                                    (keycap-preview-header)))
            ;; The preview renders meanwhile.
            (let ((frame keycap--preview-frame))
              (keycap-preview-orbit-left)
              (keycap-test-wait (lambda () (not (eq frame keycap--preview-frame)))))
            (should (buffer-local-value 'keycap--export keycap--preview-source))
            (keycap-preview-keyboard-quit)
            (keycap-test-wait (lambda () (not (buffer-local-value 'keycap--export
                                                                  keycap--preview-source)))))
          (should (string-match-p "\\`Exporting .* cancelled; it is as it was\\'" shown))
          (should (equal (with-temp-buffer
                           (insert-file-contents-literally file)
                           (buffer-string))
                         "an earlier mesh")))
      (delete-file file))))

(ert-deftest keycap-test-preview-reverted ()
  (skip-unless keycap-test-server)
  (keycap-test-with-preview "draw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
    (keycap-test-preview-idle)
    (let ((frame keycap--preview-frame))
      ;; As `revert-buffer' does: the mode again, its server stopped.
      (with-current-buffer keycap--preview-source
        (keycap-mode))
      (keycap-test-wait (lambda () (not (eq frame keycap--preview-frame)))))))

(defun keycap-test-write-square (file side)
  "Write an SVG of a square SIDE millimetres wide to FILE."
  (with-temp-file file
    (insert (format "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50mm\" height=\"50mm\" viewBox=\"0 0 50 50\"><rect width=\"%d\" height=\"%d\"/></svg>\n"
                    side side))))

(ert-deftest keycap-test-preview-follows-files ()
  (skip-unless keycap-test-server)
  (let* ((directory (file-name-as-directory (file-truename (make-temp-file "keycap-test-" t))))
         (svg (expand-file-name "part.svg" directory))
         (keycap-load-delay 0.01)
         watches)
    (unwind-protect
        (progn
          (keycap-test-write-square svg 10)
          (keycap-test-with-preview (format "draw(svg(%S));\n" svg)
            (keycap-test-preview-idle)
            (let ((frame keycap--preview-frame))
              (with-current-buffer keycap--preview-source
                (should (equal keycap--watched (list svg)))
                (setq watches (mapcar #'cdr keycap--watches))
                (should (= (length watches) 1)))
              ;; Saved as editors save: a new file renamed over the old one
              (keycap-test-write-square (concat svg ".new") 20)
              (rename-file (concat svg ".new") svg t)
              ;; File notifications arrive as input events, which only
              ;; reading input handles.
              (let ((end (+ (float-time) 30)))
                (while (and (eq frame keycap--preview-frame) (< (float-time) end))
                  (read-event nil nil 0.02)))
              (should-not (eq frame keycap--preview-frame))
              (should (> (car (alist-get 'upper (alist-get 'fitted (alist-get 'bounds keycap--preview-report))))
                         19)))))
      (delete-directory directory t))
    ;; Killing the script stops its watches.
    (should watches)
    (should-not (seq-some #'file-notify-valid-p watches))))

(ert-deftest keycap-test-preview-killed ()
  (skip-unless keycap-test-server)
  (let (directory server)
    (keycap-test-with-script "draw(sphere(#{center: [0, 0, 0], radius: 1}));\n"
      (with-current-buffer (keycap--preview-for (current-buffer))
        (setq directory keycap--preview-directory))
      (setq server keycap--server)
      (should (file-directory-p directory)))
    (should-not (file-exists-p directory))
    (should-not (process-live-p server))))

;;; keycap-tests.el ends here
