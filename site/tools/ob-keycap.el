;;; ob-keycap.el --- Org Babel for keycap scripts  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A `keycap' source block is a step of a script: the blocks of one
;; `:model' add up in document order, each block's `draw' lines replacing
;; the last `draw' lines so far, as the tutorial tells the reader to do.
;; Its result is an editor frame -- the script so far beside its preview,
;; as keycap shows them -- or, with `:frame no', the preview's image alone.
;; Everything in a frame comes from keycap itself: the render and the
;; diagnostics from keycap-server, the header line, completion, ElDoc, the
;; reference and the messages from keycap's own functions, run in a
;; buffer set up as the reader's would be.
;;
;; A block without a body adds nothing: it shows the model as it is, or
;; with `:typed', while the reader types its next step.
;;
;; Header arguments:
;;
;; - `:model' NAME, the script the block belongs to, NAME.keycap
;; - `:after' FILE, the Org file whose blocks of the model come first
;; - `:replace' "NAME...", functions the block edits where they are defined
;; - `:typed' TEXT, the next step typed up to the end of TEXT
;; - `:change' "OLD" "NEW", OLD replaced by NEW, as a slip of the keyboard
;; - `:at' "TEXT|TEXT", where point is: `|' in the first match of the text
;; - `:nudge' N, `keycap-increase-number' at point N times (or decrease, < 0)
;; - `:wheel' N, the shifted mouse wheel turned N steps over the digit
;;   before point, the mouse drawn there
;; - `:show' completion, eldoc, describe or export, at point
;; - `:view' shaded, heightmap, sdf or mono; the preview's choice by default
;; - `:camera' "AZIMUTH ELEVATION", or front, right, top or iso
;; - `:slice' "AXIS [OFFSET [RIGHT UP]]", through the middle of the bounds
;;   by default, tilted RIGHT and UP degrees about the image's right and up
;; - `:bounds' script or fitted
;; - `:probe' "RIGHT UP", the mouse over that point of a 2D view's slice
;; - `:pointer' "X Y", the mouse over that point of the image, as
;;   fractions of its width and height from its top left corner
;; - `:menu' context, view, camera or slice: the menu that a right click
;;   on the image opens, at the mouse, or a click on that word of the
;;   header line, under it
;; - `:size' "WIDTH [HEIGHT]" of the image in pixels
;; - `:expect' error or warning, for a script meant to have them; any
;;   other diagnostic fails the block
;; - `:frame' no, for the image alone
;; - `:alt' TEXT, the image's description
;; - `:save' FILE, the block is a file of its own beside the scripts, such
;;   as a module they import; it renders nothing
;; - `:open' FILE, the frame of FILE in `ob-keycap-examples-directory'
;; - `:set' '((NAME . VALUE)...), other values for the script's top-level
;;   constants, as `keycap-overrides' takes them
;;
;; One keycap-server renders every block of an Emacs session, on the
;; backend `ob-keycap-backend'.  Images are named by a hash of what makes
;; them, so an unchanged step keeps its file, and with
;; `ob-keycap-cache-directory' set, its render and its script's evaluation.

;;; Code:

(require 'ob)
(require 'ox-html)
(require 'cl-lib)
(require 'subr-x)
(require 'flymake)
(require 'keycap)
(require 'keycap-preview)

(defvar org-babel-default-header-args:keycap
  '((:exports . "both") (:results . "file link") (:model . "model"))
  "A keycap block shows its code and its image.
Exported to HTML with `:results html', the image is a whole frame.")

(defvar ob-keycap-image-directory nil
  "Where images are written, or nil for a directory in `temporary-file-directory'.")

(defvar ob-keycap-html-directory nil
  "The directory of the HTML file a frame goes in, or nil for `default-directory'.
Images are linked relative to it.")

(defvar ob-keycap-cache-directory nil
  "Where renders are kept by their hash, or nil to render every time.")

(defvar ob-keycap-cache-used nil
  "The files of `ob-keycap-cache-directory' used so far, read or written.
A build keeps only these, so the cache holds no step that has changed since.")

(defvar ob-keycap-examples-directory nil
  "Where `:open' finds its files: keycap's examples.")

(defvar ob-keycap-compress nil
  "Whether frames are made smaller as they are written, by pngquant and oxipng.
A palette of 256 colours halves them with no difference to the eye, and
oxipng takes the rest it can without loss; both give the same bytes on
every run.")

(defvar ob-keycap-backend 'cpu
  "The backend images are rendered on.
An image is named after its CPU render either way, which is what a
build without a GPU makes of it.")

(defvar ob-keycap-size 960
  "The width and height in pixels of an image: twice its size on the page.")

(defvar ob-keycap-window-lines 26
  "The lines the code window shows beside a square image.")

(defvar ob-keycap-window-columns 80
  "The columns of the code window, where long lines wrap at the frame's full width.")

(defvar ob-keycap-background "#0b0e14"
  "The background of the preview, Emacs' own; transparent in the image.")

(defconst ob-keycap--directory (file-name-directory (or load-file-name buffer-file-name))
  "This file's directory; ppm2png.py is beside it.")


;; --- Server ---

(defun ob-keycap--request (request)
  "Send REQUEST to the server of the current script buffer, and return the reply."
  (ob-keycap--need-server)
  (keycap-request-sync request))

(defvar ob-keycap--contents (make-hash-table :test #'equal)
  "The hashes `ob-keycap--content' has taken, by path.")

(defun ob-keycap--stored-p (path)
  "Non-nil when PATH is in the Nix store, whose paths change with their contents."
  (and path (string-prefix-p "/nix/store/" (expand-file-name path))))

(defun ob-keycap--content (path)
  "PATH for a hash: as it is in the Nix store, or else its contents' hash.
A directory's contents are every file under it.  A path is hashed once
per Emacs, which is once per publish."
  (if (or (ob-keycap--stored-p path) (not (and path (file-exists-p path))))
      path
    (with-memoization (gethash path ob-keycap--contents)
      (if (file-directory-p path)
          (sha1 (prin1-to-string
                 (mapcar (lambda (file)
                           (cons (file-relative-name file path) (ob-keycap--file-hash file)))
                         (directory-files-recursively path ""))))
        (ob-keycap--file-hash path)))))

(defun ob-keycap--server ()
  "The server and the prelude it runs with, for a hash.
In the Nix store the server's path stands for both, as keycap's server
is built from the source its prelude is in."
  (if (and (ob-keycap--stored-p keycap-server-program)
           (ob-keycap--stored-p keycap-prelude-directory))
      keycap-server-program
    (list (ob-keycap--content (or (executable-find keycap-server-program) keycap-server-program))
          (ob-keycap--content keycap-prelude-directory))))


;; --- Loading ---

;; A `load' reply is kept in `ob-keycap-cache-directory' with the hashes of
;; the files the script read, and a load of the same script takes it while
;; those files are unchanged: a block whose image is cached then runs with
;; no evaluation at all, and its script buffer knows nothing of the reply.
;; A block that needs the server after all, for a render, a probe or an
;; export, or the reply in the buffer, for completion, ElDoc or the
;; reference, runs again with every load evaluated.

(defvar ob-keycap--keep t
  "Whether a load may take a kept reply.")

(defvar ob-keycap--kept nil
  "Whether a load of the block being run took a kept reply.")

(defvar ob-keycap--root nil
  "The new directory the block being run writes its scripts in, or nil.")

(defconst ob-keycap--root-name "/ob-keycap-root"
  "What a kept reply and its hash say instead of `ob-keycap--root'.")

(defun ob-keycap--need-server ()
  "Run the block again, every load evaluated, if a load took a kept reply.
For what needs the server to have the script, or its buffer the reply."
  (when ob-keycap--kept
    (throw 'ob-keycap--evaluate nil)))

(defun ob-keycap--reroot (string from to)
  "STRING with FROM replaced by TO, or as it is outside a block."
  (if ob-keycap--root (string-replace from to string) string))

(defun ob-keycap--timeless (reply)
  "REPLY without its id and its time, so that the same work gives the same bytes."
  (cons '(ms . 0) (seq-remove (lambda (field) (memq (car field) '(id ms)))
                              reply)))

(defun ob-keycap--load ()
  "Load the current script buffer, even if the server has it, and return the reply.
A kept reply is taken instead, if `ob-keycap--keep' allows it."
  (let* ((cache (and ob-keycap-cache-directory
                     (expand-file-name
                      (concat (ob-keycap--hash (ob-keycap--server) keycap-prelude-directory
                                               keycap-dialect keycap-overrides
                                               (ob-keycap--reroot buffer-file-name ob-keycap--root
                                                                  ob-keycap--root-name)
                                               (buffer-substring-no-properties (point-min) (point-max)))
                              "-load.eld")
                      ob-keycap-cache-directory)))
         (kept (and cache ob-keycap--keep (file-exists-p cache)
                    (with-temp-buffer
                      (let ((coding-system-for-read 'utf-8))
                        (insert-file-contents cache))
                      (read (ob-keycap--reroot (buffer-string) ob-keycap--root-name
                                               ob-keycap--root))))))
    (when cache
      (ob-keycap--cache-use cache))
    (if (and kept (equal (car kept) (ignore-errors
                                      (mapcar #'ob-keycap--file-hash (alist-get 'files (cdr kept))))))
        (progn
          (setq ob-keycap--kept t)
          (cdr kept))
      (let ((reply (keycap-load-sync t)))
        (when (and cache (not (alist-get 'error reply)))
          (make-directory ob-keycap-cache-directory t)
          (let ((coding-system-for-write 'utf-8)
                (print-length nil)
                (print-level nil))
            (with-temp-file cache
              (insert (ob-keycap--reroot
                       (prin1-to-string (cons (mapcar #'ob-keycap--file-hash (alist-get 'files reply))
                                              (ob-keycap--timeless reply)))
                       ob-keycap--root ob-keycap--root-name)))))
        reply))))


;; --- Scripts ---

;; A script is read by keycap, from its tree in a buffer that holds it.

(defmacro ob-keycap--with-code (code &rest body)
  "Run BODY in a buffer holding CODE."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,code "\n")
     ,@body))

(defun ob-keycap--whole-lines (region)
  "REGION, (START . END), widened to whole lines, END past its newline."
  (cons (save-excursion (goto-char (car region)) (line-beginning-position))
        (save-excursion (goto-char (cdr region)) (min (point-max) (1+ (line-end-position))))))

(defun ob-keycap--last-draws ()
  "The last top-level `draw' statements, as whole lines (START . END), or nil.
They are the last one and those on the lines right above it, such as a
step's shapes each drawn in its colour."
  (when-let* ((draws (reverse (mapcar #'ob-keycap--whole-lines (keycap-script-draws)))))
    (let ((run (car draws)))
      (dolist (draw (cdr draws))
        (when (= (cdr draw) (car run))
          (setcar run (car draw))))
      run)))

(defun ob-keycap--draws-p (code)
  "Non-nil when CODE has a top-level `draw'."
  (ob-keycap--with-code code (keycap-script-draws)))

(defun ob-keycap--function (name)
  "The definition of the function NAME with its `///' comment, or nil.
As whole lines (START . END)."
  (when-let* ((function (alist-get name (keycap-script-functions) nil nil #'equal)))
    (ob-keycap--whole-lines function)))

(defun ob-keycap--functions ()
  "The names of the functions defined at top level."
  (mapcar #'car (keycap-script-functions)))

(defun ob-keycap--add (script body &optional replace drop-draw)
  "SCRIPT once BODY is typed below it.
The functions named in REPLACE are edited where they are rather than
added.  The last `draw' lines so far go when BODY has one, or with
DROP-DRAW."
  (let ((rest (string-trim body "\n+"))
        (edits nil))
    ;; Take the functions to replace out of the block.
    (dolist (name replace)
      (ob-keycap--with-code rest
        (pcase-let ((`(,start . ,end) (or (ob-keycap--function name)
                                          (error ":replace %s, but the block defines no fn %s"
                                                 name name))))
          (push (cons name (buffer-substring start end)) edits)
          (delete-region start end)
          (setq rest (string-trim (buffer-string) "\n+")))))
    (ob-keycap--with-code script
      (dolist (edit edits)
        (pcase-let ((`(,start . ,end) (or (ob-keycap--function (car edit))
                                          (error ":replace %s, but there is no fn %s to replace"
                                                 (car edit) (car edit)))))
          (delete-region start end)
          (goto-char start)
          (insert (cdr edit))))
      ;; Rhai rejects a second definition; say which block made it.
      (let ((defined (ob-keycap--functions)))
        (dolist (name (ob-keycap--with-code rest (ob-keycap--functions)))
          (when (member name defined)
            (error "fn %s is defined already; name it in :replace to edit it" name))))
      (when (or drop-draw (ob-keycap--draws-p rest))
        (when-let* ((draws (ob-keycap--last-draws)))
          (delete-region (car draws) (cdr draws))))
      (let ((before (string-trim-right (buffer-string))))
        (concat before
                (cond ((string-empty-p rest) "")
                      ((string-empty-p before) rest)
                      (t (concat "\n\n" rest)))
                "\n")))))


;; --- Blocks ---

(defun ob-keycap--param (params name)
  "The header argument NAME of PARAMS, or nil."
  (cdr (assq name params)))

(defun ob-keycap--strings (value)
  "The strings in the header argument VALUE, quoted or not."
  (and value (split-string-and-unquote (format "%s" value))))

(defun ob-keycap--blocks (buffer)
  "The keycap blocks of BUFFER, as (POSITION PARAMS BODY), in order."
  (with-current-buffer buffer
    (org-with-wide-buffer
     (let (blocks)
       (goto-char (point-min))
       (while (re-search-forward "^[ \t]*#\\+begin_src[ \t]+keycap\\_>" nil t)
         (let ((position (match-beginning 0)))
           (when-let* ((info (save-excursion (goto-char position)
                                             (org-babel-get-src-block-info t))))
             (push (list position (nth 2 info) (nth 1 info)) blocks))))
       (nreverse blocks)))))

(defun ob-keycap--step-p (params body)
  "Non-nil when the block of PARAMS and BODY adds BODY to its model."
  (not (or (string-blank-p body)
           (ob-keycap--param params :save)
           (ob-keycap--param params :open))))

(defun ob-keycap--file-blocks (file)
  "The keycap blocks of the Org FILE, read afresh."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((default-directory (file-name-directory (expand-file-name file))))
      (delay-mode-hooks (org-mode))
      (ob-keycap--blocks (current-buffer)))))

(defun ob-keycap--script (blocks model &optional files)
  "The script of MODEL that BLOCKS, from an Org file, add up to.
FILES is where the files saved on the way are put, as (NAME . TEXT)."
  (let ((script ""))
    (pcase-dolist (`(,_ ,params ,body) blocks)
      (when-let* ((save (ob-keycap--param params :save)))
        (push (cons save body) (car files)))
      (when (equal (ob-keycap--param params :model) model)
        (when-let* ((after (ob-keycap--param params :after)))
          (setq script (ob-keycap--script (ob-keycap--file-blocks after) model files)))
        (when (ob-keycap--step-p params body)
          (setq script (ob-keycap--add script body
                                       (ob-keycap--strings (ob-keycap--param params :replace)))))))
    script))

(defun ob-keycap--begin ()
  "Where the block being run begins."
  (save-excursion
    (when org-babel-current-src-block-location
      (goto-char org-babel-current-src-block-location))
    (org-element-begin (org-element-at-point))))

(defun ob-keycap--source ()
  "The buffer and position of the block being run, as they were before an export."
  (let ((begin (ob-keycap--begin)))
    (if-let* ((reference (and (buffer-live-p org-babel-exp-reference-buffer)
                              (get-text-property begin 'org-reference))))
        (cons org-babel-exp-reference-buffer reference)
      (cons (current-buffer) begin))))

(defun ob-keycap--number-lines (_backend)
  "Mark each keycap block with its line in the file, before an export moves it."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*#\\+begin_src[ \t]+keycap\\_>" nil t)
      (put-text-property (match-beginning 0) (match-end 0) 'ob-keycap-line (line-number-at-pos)))))

;; First, before other functions add lines.
(add-hook 'org-export-before-processing-functions #'ob-keycap--number-lines -90)

(defun ob-keycap--where ()
  "The block being run, as FILE:LINE, for an error message."
  (let ((begin (ob-keycap--begin)))
    (format "%s:%d" (abbreviate-file-name (or buffer-file-name (buffer-name)))
            (or (get-text-property begin 'ob-keycap-line) (line-number-at-pos begin)))))


;; --- States ---

;; What a frame shows: a script, its file and point, and the script the
;; preview showed last, which a script that fails leaves up.

(cl-defstruct (ob-keycap--state (:constructor ob-keycap--state-create))
  name path script point previous files overrides)

(defun ob-keycap--point (script at)
  "The position in SCRIPT that AT, \"TEXT|TEXT\", marks, from 1."
  (let* ((bar (or (string-search "|" at) (error ":at %S has no |" at)))
         (text (string-replace "|" "" at))
         (start (or (string-search text script) (error ":at %S is not in the script" at))))
    (+ start bar 1)))

(defun ob-keycap--next-step (blocks position model)
  "The body of the first step of MODEL in BLOCKS after POSITION."
  (or (seq-some (pcase-lambda (`(,start ,params ,body))
                  (and (> start position)
                       (equal (ob-keycap--param params :model) model)
                       (ob-keycap--step-p params body)
                       body))
                blocks)
      (error ":typed, but no step of %s comes after it" model)))

(defun ob-keycap--state (body params directory)
  "The state the block of BODY and PARAMS shows, its files in DIRECTORY."
  (pcase-let* ((`(,buffer . ,position) (ob-keycap--source))
               (blocks (ob-keycap--blocks buffer))
               (before (seq-take-while (lambda (block) (< (car block) position)) blocks))
               (model (ob-keycap--param params :model))
               (files (list nil))
               (so-far (let ((script (ob-keycap--script before model files))
                             (after (ob-keycap--param params :after)))
                         (if after
                             (ob-keycap--script (ob-keycap--file-blocks after) model files)
                           script)))
               (typed (ob-keycap--param params :typed))
               (change (ob-keycap--strings (ob-keycap--param params :change)))
               (at (ob-keycap--param params :at))
               (state (ob-keycap--state-create
                       :name (concat model ".keycap")
                       :previous so-far
                       :overrides (ob-keycap--param params :set))))
    (cond
     ((ob-keycap--param params :open)
      (let ((file (expand-file-name (ob-keycap--param params :open) ob-keycap-examples-directory)))
        (setf (ob-keycap--state-name state) (file-name-nondirectory file)
              (ob-keycap--state-path state) file
              (ob-keycap--state-script state) (with-temp-buffer
                                                (insert-file-contents file)
                                                (buffer-string))
              (ob-keycap--state-previous state) nil)))
     (typed
      (let* ((next (ob-keycap--next-step blocks position model))
             (end (or (string-search typed next) (error ":typed %S is not in the next step" typed)))
             (start (ob-keycap--add so-far "" nil (ob-keycap--draws-p next))))
        ;; The script as it was before typing, without the `draw' lines the step replaces.
        (setf (ob-keycap--state-previous state) start
              (ob-keycap--state-script state)
              (string-trim-right (ob-keycap--add start (substring next 0 (+ end (length typed))))
                                 "\n"))))
     ((ob-keycap--step-p params body)
      (setf (ob-keycap--state-script state)
            (ob-keycap--add so-far body (ob-keycap--strings (ob-keycap--param params :replace)))))
     (t
      (setf (ob-keycap--state-script state) so-far)))
    (when change
      (pcase-let* ((`(,old ,new) change)
                   (script (ob-keycap--state-script state))
                   (start (or (string-search old script) (error ":change %S is not in the script" old))))
        (setf (ob-keycap--state-previous state) script
              (ob-keycap--state-script state)
              (concat (substring script 0 start) new (substring script (+ start (length old)))))))
    (unless (ob-keycap--state-path state)
      (setf (ob-keycap--state-path state) (expand-file-name (ob-keycap--state-name state) directory)))
    (setf (ob-keycap--state-files state) (car files)
          (ob-keycap--state-point state)
          (if at
              (ob-keycap--point (ob-keycap--state-script state) at)
            (1+ (length (ob-keycap--state-script state)))))
    state))


;; --- Buffers ---

(defun ob-keycap--script-buffer (state)
  "A keycap-mode buffer for STATE, its point and server set; its file written."
  (let ((path (ob-keycap--state-path state)))
    ;; The last saved of each name wins.
    (pcase-dolist (`(,name . ,text) (reverse (ob-keycap--state-files state)))
      (with-temp-file (expand-file-name name (file-name-directory path))
        (insert text)))
    (unless (file-exists-p path)
      (with-temp-file path
        (insert (ob-keycap--state-script state))))
    (with-current-buffer (generate-new-buffer " *ob-keycap script*")
      (insert (ob-keycap--state-script state))
      (setq buffer-file-name path
            default-directory (file-name-directory path))
      (let ((treesit-font-lock-level 3))
        ;; The names of the script's dialect, highlighted as builtins.
        (keycap-names (if (string-suffix-p ".fidget" path) 'fidget 'keycap))
        (keycap-mode))
      ;; One server for every block, which killing the script leaves running.
      (keycap-use-server (get-buffer-create " *ob-keycap server*"))
      (setq keycap-overrides (ob-keycap--state-overrides state))
      (goto-char (ob-keycap--state-point state))
      (current-buffer))))

(defun ob-keycap--kill (buffer)
  "Kill the script BUFFER."
  (with-current-buffer buffer
    (set-buffer-modified-p nil)
    (kill-buffer)))

(defun ob-keycap-load (file)
  "The server's `load' reply for the script FILE, as keycap loads it."
  (let ((script (ob-keycap--script-buffer
                 (ob-keycap--state-create :name (file-name-nondirectory file)
                                          :path file
                                          :script (with-temp-buffer
                                                    (insert-file-contents file)
                                                    (buffer-string))
                                          :point 1))))
    (unwind-protect
        (with-current-buffer script
          (ob-keycap--load))
      (ob-keycap--kill script))))

(defun ob-keycap--capture (function)
  "Call FUNCTION; return the last message it showed, or nil."
  (let (shown)
    (cl-letf* ((message (symbol-function 'message))
               ((symbol-function 'message)
                (lambda (format &rest arguments)
                  (when format
                    (setq shown (apply #'format-message format arguments)))
                  (apply message format arguments))))
      (funcall function))
    shown))


;; --- Rendering ---

(defun ob-keycap--camera (camera)
  "The azimuth and elevation CAMERA names, as a list."
  (pcase camera
    ((or 'nil "iso") '(-60 30))
    ("front" '(-90 0))
    ("right" '(0 0))
    ("top" '(-90 90))
    (_ (mapcar #'string-to-number (split-string camera)))))

(defun ob-keycap--size (params)
  "The image's width and height for PARAMS."
  (let ((size (mapcar #'string-to-number (ob-keycap--strings (ob-keycap--param params :size)))))
    (cond
     (size (list (car size) (or (cadr size) (car size))))
     ;; The help window below takes half the height.
     ((equal (ob-keycap--param params :show) "describe")
      (list ob-keycap-size (/ ob-keycap-size 2)))
     (t (list ob-keycap-size ob-keycap-size)))))

(defun ob-keycap--hash (&rest parts)
  "A short name for PARTS, printed."
  (substring (sha1 (prin1-to-string parts)) 0 16))

(defun ob-keycap--cache-use (&rest files)
  "Note FILES of the cache as used, in `ob-keycap-cache-used'."
  (dolist (file files)
    (cl-pushnew file ob-keycap-cache-used :test #'equal)))

(defun ob-keycap--file-hash (file)
  "The hash of FILE's contents."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (sha1 (current-buffer))))

(defun ob-keycap--rgb ()
  "`ob-keycap-background' as the server takes it.
The server rounds it back to the same bytes."
  (vconcat (mapcar (lambda (i)
                     (/ (string-to-number (substring ob-keycap-background i (+ i 2)) 16) 255.0))
                   '(1 3 5))))

(defconst ob-keycap--compressors
  '(("pngquant" "--speed" "1" "--strip" "--force" "--ext" ".png")
    ("oxipng" "-q" "-o" "4" "--strip" "safe"))
  "The commands `ob-keycap-compress' runs on a frame, in order, its file last.")

(defun ob-keycap--compression ()
  "The commands that compress a frame, their programs found; nil if not asked."
  (when ob-keycap-compress
    (mapcar (lambda (command)
              (cons (or (executable-find (car command)) (error "%s is not installed" (car command)))
                    (cdr command)))
            ob-keycap--compressors)))

(defun ob-keycap--png (ppm png)
  "Convert the frame PPM to PNG, its background transparent, compressed if asked."
  (unless (zerop (call-process "python3" nil nil nil
                               (expand-file-name "ppm2png.py" ob-keycap--directory)
                               ppm png (substring ob-keycap-background 1)))
    (error "Could not convert %s" ppm))
  (pcase-dolist (`(,program . ,arguments) (ob-keycap--compression))
    (unless (zerop (apply #'call-process program nil nil nil (append arguments (list png))))
      (error "%s could not compress %s" (file-name-nondirectory program) png))))

(defun ob-keycap--image-directory ()
  "Where images go."
  (or ob-keycap-image-directory
      (expand-file-name "ob-keycap" temporary-file-directory)))

(defun ob-keycap--render (script preview report params)
  "Render the model of the SCRIPT buffer in its snapshot PREVIEW as PARAMS say.
REPORT is the `load' report PREVIEW shows.  Return the image's file.  A
cached render is used unless PARAMS probe it."
  (with-current-buffer preview
    (pcase-let* ((`(,width ,height) (ob-keycap--size params))
                 (request (keycap-preview-request width height))
                 (_ (setf (alist-get 'background request) (ob-keycap--rgb)
                          ;; The same bytes on every run, on either backend.
                          (alist-get 'reproducible request) t))
                 (hash (ob-keycap--hash
                        (ob-keycap--server)
                        (buffer-local-value 'keycap-dialect script)
                        (buffer-local-value 'keycap-overrides script)
                        (with-current-buffer script
                          (buffer-substring-no-properties (point-min) (point-max)))
                        (mapcar #'ob-keycap--file-hash (alist-get 'files report))
                        (ob-keycap--file-hash (expand-file-name "ppm2png.py" ob-keycap--directory))
                        (seq-remove (lambda (field) (memq (car field) '(output backend)))
                                    request)))
                 (name (format "%s-%s.png" (file-name-base (buffer-file-name script)) hash))
                 (png (expand-file-name name (ob-keycap--image-directory)))
                 ;; The image's bytes depend on its compression too, its name not.
                 (cache (and ob-keycap-cache-directory
                             (not (ob-keycap--param params :probe))
                             (expand-file-name (ob-keycap--hash hash (ob-keycap--compression))
                                               ob-keycap-cache-directory)))
                 (cached (and cache (file-exists-p (concat cache ".json")))))
      (make-directory (file-name-directory png) t)
      (when cache
        (make-directory ob-keycap-cache-directory t))
      (if cached
          (keycap-preview-set-frame (json-parse-string
                                     (with-temp-buffer
                                       (insert-file-contents (concat cache ".json"))
                                       (buffer-string))
                                     :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil))
        (setf (alist-get 'backend request) (symbol-name ob-keycap-backend))
        (let ((frame (with-current-buffer script (ob-keycap--request request))))
          (keycap-preview-set-frame frame)
          (ob-keycap--png (alist-get 'output request) (if cache (concat cache ".png") png))
          (when cache
            (with-temp-file (concat cache ".json")
              (insert (json-serialize (ob-keycap--timeless frame)))))))
      (when cache
        (copy-file (concat cache ".png") png t)
        (ob-keycap--cache-use (concat cache ".png") (concat cache ".json")))
      png)))

(defun ob-keycap--preview (script report failure params)
  "A snapshot of the SCRIPT buffer showing REPORT, as PARAMS say.
FAILURE is why the script failed to load, the scene of REPORT shown instead."
  (let ((slice (ob-keycap--strings (ob-keycap--param params :slice))))
    (keycap-preview-snapshot
     script
     :report report
     :failure failure
     :view (cond ((ob-keycap--param params :view) (intern (ob-keycap--param params :view)))
                 (slice 'sdf))
     :camera (ob-keycap--camera (ob-keycap--param params :camera))
     :slice (list (intern (or (car slice) "z"))
                  (and (cadr slice) (string-to-number (cadr slice)))
                  (and (nth 3 slice) (cons (string-to-number (nth 2 slice))
                                           (string-to-number (nth 3 slice)))))
     :bounds (intern (or (ob-keycap--param params :bounds) "script"))
     :backend 'cpu)))

(defun ob-keycap--probe (preview params)
  "Read the model in PREVIEW at the point `:probe' of PARAMS names.
The point is on the slice of a 2D view, as its right and up coordinates.
Return where the mouse is, as fractions of the image's width and height."
  (when-let* ((probe (ob-keycap--strings (ob-keycap--param params :probe))))
    (ob-keycap--need-server)
    (with-current-buffer preview
      (pcase-let* ((`(,width ,height) (ob-keycap--size params))
                   (`(,right ,up) (mapcar #'string-to-number probe))
                   (`(,x . ,y) (keycap-preview-probe-sync right up width height)))
        (list (/ x width) (/ y height))))))

(defun ob-keycap--header (preview)
  "The header line of PREVIEW, without the backend and render time.
The time differs from one render to the next, and so would the page."
  (string-join (seq-remove (lambda (part) (string-match-p "\\`[CG]PU " part))
                           (split-string (with-current-buffer preview (keycap-preview-header))
                                         "  ·  "))
               "  ·  "))


;; --- Extras ---

(defun ob-keycap--completion ()
  "What completion offers at point: the candidates and the column they start at.
Candidates match as orderless matches them, a substring in any case, and
are sorted as Corfu sorts them, shortest first."
  (ob-keycap--need-server)
  (pcase-let* ((`(,start ,end ,table . ,properties) (or (keycap-completion-at-point)
                                                        (error ":show completion, but nothing completes at point")))
               (prefix (buffer-substring-no-properties start end))
               (annotate (plist-get properties :annotation-function))
               (candidates (seq-filter (lambda (candidate)
                                         (string-search (downcase prefix) (downcase candidate)))
                                       (delete-dups (all-completions "" table)))))
    (list (mapcar (lambda (candidate)
                    (cons candidate (and annotate (funcall annotate candidate))))
                  (take 10 (sort candidates
                                 (lambda (a b)
                                   (if (= (length a) (length b))
                                       (string< a b)
                                     (< (length a) (length b)))))))
          start)))

(defun ob-keycap--eldoc ()
  "What ElDoc shows at point."
  (ob-keycap--need-server)
  (let (shown)
    (keycap-eldoc-function (lambda (text &rest _) (setq shown text)))
    (or shown (error ":show eldoc, but ElDoc has nothing at point"))))

(defun ob-keycap--describe (script)
  "The help buffer's text for the name at point in SCRIPT, with its faces."
  (ob-keycap--need-server)
  (let ((name (or (keycap-name-at-point) (error ":show describe, but point is on no name"))))
    (ob-keycap--capture (lambda () (keycap-describe name script)))
    (with-current-buffer (help-buffer)
      (buffer-string))))

(defun ob-keycap--export (report)
  "The message an STL export of the current script ends with, without its time.
REPORT is the script's `load' reply.  A cached message is used if there is one."
  (let* ((cache (and ob-keycap-cache-directory
                     (expand-file-name
                      ;; keycap's library too, which words the message.
                      (concat (ob-keycap--hash (ob-keycap--server)
                                               (ob-keycap--content (locate-library "keycap"))
                                               (buffer-substring-no-properties (point-min) (point-max))
                                               keycap-overrides
                                               (mapcar #'ob-keycap--file-hash (alist-get 'files report)))
                              "-export.txt")
                      ob-keycap-cache-directory)))
         (file (expand-file-name (concat (file-name-base buffer-file-name) ".stl"))))
    (when cache
      (ob-keycap--cache-use cache))
    (if (and cache (file-exists-p cache))
        (with-temp-buffer
          (insert-file-contents cache)
          (buffer-string))
      (ob-keycap--need-server)
      (let ((shown (string-replace (file-name-directory file) ""
                                   (replace-regexp-in-string
                                    " in [0-9.]+ s\\'" ""
                                    (ob-keycap--capture
                                     (lambda ()
                                       (keycap-export-stl file)
                                       (while (keycap-exporting-p)
                                         (accept-process-output nil 0.05))))))))
        (when cache
          (make-directory ob-keycap-cache-directory t)
          (with-temp-file cache
            (insert shown)))
        shown))))


;; --- Mouse ---

(defun ob-keycap--pointer (params)
  "Where `:pointer' of PARAMS puts the mouse, as fractions of the image, or nil."
  (when-let* ((pointer (ob-keycap--strings (ob-keycap--param params :pointer))))
    (mapcar #'string-to-number pointer)))

(defun ob-keycap--menu-item (binding)
  "The HTML of BINDING, an item of a menu keymap, in the current preview."
  (pcase binding
    ((or `(menu-item ,(and (pred (string-prefix-p "--")) _) . ,_)
         `(,(and (pred stringp) (pred (string-prefix-p "--"))) . ,_))
     "<span class=\"ef-separator\"></span>")
    (`(menu-item ,label ,command . ,properties)
     (let ((button (plist-get properties :button))
           (key (and (symbolp command) (where-is-internal command keycap-preview-mode-map t))))
       (format "<span class=\"ef-item%s%s\"><span class=\"ef-mark\"></span><span>%s</span><span class=\"ef-keys\">%s</span></span>"
               (if (or (not (plist-member properties :enable)) (eval (plist-get properties :enable) t))
                   ""
                 " ef-disabled")
               (pcase button
                 (`(,type . ,form) (format " ef-%s%s" (substring (symbol-name type) 1)
                                           (if (eval form t) " ef-on" "")))
                 (_ ""))
               (org-html-encode-plain-text label)
               (if key (org-html-encode-plain-text (key-description key)) ""))))
    (_ "")))

(defun ob-keycap--menu (preview name)
  "The HTML of the menu NAME of PREVIEW, or nil without one; see `:menu'."
  (when name
    (with-current-buffer preview
      (let (items)
        (map-keymap (lambda (_key binding)
                      (push (ob-keycap--menu-item binding) items))
                    (keycap-preview-menu (intern name)))
        (concat "<span class=\"ef-popup ef-menu\">" (string-join (nreverse items)) "</span>")))))

(defun ob-keycap--pointer-html (x y)
  "The mouse pointer at X and Y, CSS lengths from what holds it."
  (format "<span class=\"ef-pointer\" style=\"left: %s; top: %s\">%s</span>" x y ob-keycap--pointer))

(defun ob-keycap--header-html (header menu)
  "The HTML of HEADER; with MENU, (NAME . HTML), the word that opens it hovered.
The menu opens under the word, the mouse on it."
  (let* ((header (string-replace "%%" "%" header))
         (command (and menu (not (equal (car menu) "context"))
                       (intern (format "keycap-preview-%s-menu" (car menu)))))
         (html (ob-keycap-html header (when command
                                        (lambda (i)
                                          (when (eq (get-text-property i 'keycap-command header) command)
                                            '("ef-hover")))))))
    (cond
     ((not command) html)
     ((string-match "class=\"ef-hover\">[^<]*" html)
      (concat (substring html 0 (match-end 0))
              (cdr menu)
              (ob-keycap--pointer-html "60%" "60%")
              (substring html (match-end 0))))
     (t (error ":menu %s, but the header line has no word for it" (car menu))))))

(defun ob-keycap--code-pointer (html)
  "The code window's HTML with the mouse on the character before point."
  (if (string-match "<span class=\"[^\"]*ef-cursor" html)
      (concat (substring html 0 (match-beginning 0))
              "<span class=\"ef-anchor\">" (ob-keycap--pointer-html "-0.5ch" "0.7em") "</span>"
              (substring html (match-beginning 0)))
    html))


;; --- Frame ---

(defun ob-keycap--classes (face)
  "The CSS classes for FACE, a face or a list of them, as htmlize names them."
  (mapcan (lambda (face)
            (when (and face (symbolp face))
              (list (concat "hl-" (string-remove-suffix
                                   "-face" (string-remove-prefix "font-lock-" (symbol-name face)))))))
          (ensure-list face)))

(defun ob-keycap--span (classes text)
  "TEXT as HTML, in a span of CLASSES if there are any."
  (let ((text (org-html-encode-plain-text text)))
    (if classes
        (format "<span class=\"%s\">%s</span>" (string-join classes " ") text)
      text)))

(defun ob-keycap-html (string &optional extra)
  "STRING as HTML, its faces as classes.
EXTRA, called with a position in STRING, returns more classes for it."
  (let ((html "")
        (start 0))
    (while (< start (length string))
      (let* ((end (next-single-property-change start 'face string (length string)))
             (end (if extra
                      (or (seq-find (lambda (i) (not (equal (funcall extra i) (funcall extra start))))
                                    (number-sequence (1+ start) (1- end)))
                          end)
                    end))
             (end (or (next-single-property-change start 'button string end) end)))
        (setq html (concat html (ob-keycap--span
                                 (append (ob-keycap--classes (get-text-property start 'face string))
                                         (and (get-text-property start 'button string) '("ef-button"))
                                         (and extra (funcall extra start)))
                                 (substring-no-properties string start end)))
              start end)))
    html))

(defun ob-keycap--depths ()
  "The nesting depth of every bracket, as rainbow-delimiters counts it."
  (let ((depths (make-hash-table)))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "[][(){}]" nil t)
        (let* ((position (match-beginning 0))
               (state (save-excursion (syntax-ppss position))))
          (unless (nth 8 state)
            (puthash position
                     (if (memq (char-after position) '(?\( ?\[ ?{))
                         (1+ (car state))
                       (car state))
                     depths)))))
    depths))

(defun ob-keycap--window (heights point-line rows)
  "The first and last line that ROWS show, with point on POINT-LINE.
HEIGHTS are the rows each line takes, wrapped.  Point stays a few lines
above the bottom, as `scroll-margin' would keep it."
  (let* ((lines (length heights))
         (last (min lines (+ point-line 3)))
         (first last)
         (used (aref heights (1- last))))
    ;; Up from the last line while there is room, then down again.
    (while (and (> first 1) (<= (+ used (aref heights (- first 2))) rows))
      (setq first (1- first)
            used (+ used (aref heights (1- first)))))
    (while (and (< last lines) (<= (+ used (aref heights last)) rows))
      (setq last (1+ last)
            used (+ used (aref heights (1- last)))))
    (cons first last)))

(defun ob-keycap--position (first last lines)
  "The mode line's position for a window showing FIRST to LAST of LINES."
  (cond ((and (= first 1) (= last lines)) "All")
        ((= first 1) "Top")
        ((= last lines) "Bot")
        (t (format "%d%%" (/ (* 100 (1- first)) lines)))))

(defun ob-keycap--popup (candidates above)
  "Corfu's popup of CANDIDATES, (NAME . ANNOTATION) each, the first selected.
ABOVE, it opens above the line, as Corfu's does without room below."
  (concat (format "<span class=\"ef-popup%s\">" (if above " ef-above" ""))
          (mapconcat (pcase-lambda (`(,name . ,annotation))
                       (format "<span class=\"ef-candidate%s\">%s<span class=\"ef-annotation\">%s</span></span>"
                               (if (eq name (caar candidates)) " ef-selected" "")
                               (org-html-encode-plain-text name)
                               (org-html-encode-plain-text (string-trim (or annotation "")))))
                     candidates "")
          "</span>"))

(defun ob-keycap--code (diagnostics rows &optional popup)
  "The current buffer's text as the code window shows it, ROWS lines high.
DIAGNOSTICS are underlined; POPUP, (CANDIDATES . POSITION), opens at POSITION.
Return the HTML and the mode line's position."
  (font-lock-ensure)
  (let* ((depths (ob-keycap--depths))
         (point (point))
         (lines (line-number-at-pos (point-max)))
         (point-line (line-number-at-pos point))
         (heights (vconcat (mapcar (lambda (line)
                                     (max 1 (ceiling (length line) (float ob-keycap-window-columns))))
                                   (split-string (buffer-string) "\n"))))
         (window (ob-keycap--window heights point-line rows))
         (marked (make-hash-table)))
    (dolist (diagnostic diagnostics)
      (puthash (line-number-at-pos (flymake-diagnostic-beg diagnostic)) (flymake-diagnostic-type diagnostic)
               marked))
    (list
     (concat
      "<div class=\"ef-text\">"
      (mapconcat
       (lambda (n)
         (save-excursion
           (goto-char (point-min))
           (forward-line (1- n))
           (let* ((start (line-beginning-position))
                  (end (line-end-position))
                  (text (buffer-substring start end))
                  (extra (lambda (i)
                           (let ((position (+ start i)))
                             (delq nil
                                   (list
                                    (when-let* ((depth (gethash position depths)))
                                      (format "ef-d%d" (1+ (% (1- (max depth 1)) 6))))
                                    (when-let* ((diagnostic (seq-find (lambda (d)
                                                                        (and (<= (flymake-diagnostic-beg d) position)
                                                                             (< position (flymake-diagnostic-end d))))
                                                                      diagnostics)))
                                      (format "ef-%s" (substring (symbol-name (flymake-diagnostic-type diagnostic)) 1)))
                                    (when (= position point) "ef-cursor"))))))
                  (here (and (= n point-line) (- point start)))
                  (html (if (and here (= here (length text)))
                            ;; Point past the line's end: the cursor on a space.
                            (concat (ob-keycap-html text extra) "<span class=\"ef-cursor\"> </span>")
                          (ob-keycap-html text extra))))
             (when (and popup (= (line-number-at-pos (cdr popup)) n))
               (let ((column (- (cdr popup) start)))
                 (setq html (concat (ob-keycap-html (substring text 0 column) extra)
                                    "<span class=\"ef-anchor\">"
                                    (ob-keycap--popup (car popup)
                                                      (< (- (cdr window) n) (length (car popup))))
                                    "</span>"
                                    (ob-keycap-html (substring text column)
                                                    (lambda (i) (funcall extra (+ i column))))
                                    (if (and here (= here (length text)))
                                        "<span class=\"ef-cursor\"> </span>"
                                      "")))))
             (format "<div class=\"ef-line%s\"><span class=\"ef-fringe%s\"></span><span class=\"ef-ln\">%d</span><span class=\"ef-lc\">%s</span></div>"
                     (if (= n point-line) " ef-current" "")
                     (pcase (gethash n marked)
                       (:error " ef-fringe-error")
                       (:warning " ef-fringe-warning")
                       (_ ""))
                     n html))))
       (number-sequence (car window) (cdr window))
       "")
      "</div>")
     (ob-keycap--position (car window) (cdr window) lines))))

(defun ob-keycap--counters (diagnostics)
  "Flymake's counters in the mode line for DIAGNOSTICS."
  (let ((counts (mapcar (lambda (type)
                          (seq-count (lambda (d) (eq (flymake-diagnostic-type d) type)) diagnostics))
                        '(:error :warning :note))))
    (format (concat "<span class=\"ef-counters\">"
                    "<span class=\"ef-error-count\">⊗%d</span>"
                    "<span class=\"ef-warning-count\">⚠%d</span>"
                    "<span class=\"ef-note-count\"><span class=\"ef-i\">i</span>%d</span></span>")
            (nth 0 counts) (nth 1 counts) (nth 2 counts))))

(defun ob-keycap--modeline (active name position right)
  "A mode line for the buffer NAME, at POSITION, with RIGHT on its right."
  (concat (format "<div class=\"ef-modeline%s\">" (if active "" " ef-inactive"))
          (if active "<span class=\"ef-flag\"></span>" "")
          (format "<span class=\"ef-buffer\">%s</span>" name)
          (format "<span>%s</span>" position)
          "<span class=\"ef-fill\"></span>"
          right
          "</div>"))

(defconst ob-keycap--pointer
  (concat "<svg viewBox=\"-1 -1 14 20\" aria-hidden=\"true\">"
          "<path d=\"M0 0V15.5L3.7 12L6.3 17.8L8.9 16.7L6.4 11H11.5Z\"/>"
          "</svg>")
  "The mouse pointer, an arrow with its tip at the viewBox's origin.
The style sheet fills and outlines it, so that it shows on any image.")

(defun ob-keycap--frame (state png header code-html echo help alt pointer &optional menu)
  "The editor frame for STATE: CODE-HTML beside PNG under HEADER.
ECHO is the echo area's text, HELP the help window's, and POINTER, (X Y),
the mouse over the image.  MENU, (NAME . HTML), is a menu open: the
context menu at the mouse, or a header line word's under it."
  (pcase-let ((`(,code ,position ,counters) code-html)
              (name (ob-keycap--state-name state)))
    (concat
     (format "<figure class=\"ef%s\">" (if help " ef-describe" ""))
     "<div class=\"ef-window ef-code\">"
     (format "<div class=\"ef-tabline\"><span class=\"ef-tab\">%s</span> ×</div>"
             (org-html-encode-plain-text name))
     code
     (ob-keycap--modeline (not help)
                          (format "<span class=\"ef-dir\">%s/</span>%s"
                                  (file-name-nondirectory
                                   (directory-file-name (file-name-directory (ob-keycap--state-path state))))
                                  (org-html-encode-plain-text name))
                          position
                          (concat "<span class=\"ef-mode\">keycap</span>" counters))
     "</div>"
     "<div class=\"ef-window ef-preview\">"
     (format "<div class=\"ef-headerline%s\">%s</div>"
             (if (and menu (not (equal (car menu) "context"))) " ef-open" "")
             (ob-keycap--header-html header menu))
     (format "<div class=\"ef-image\"><img src=\"%s\" alt=\"%s\">%s%s</div>"
             (file-relative-name png (or ob-keycap-html-directory default-directory))
             (org-html-encode-plain-text (or alt ""))
             (if (and menu (equal (car menu) "context") pointer)
                 (format "<span class=\"ef-context\" style=\"left: %s%%; top: %s%%\">%s</span>"
                         (* 100 (car pointer)) (* 100 (cadr pointer)) (cdr menu))
               "")
             (if pointer
                 (ob-keycap--pointer-html (format "%s%%" (* 100 (car pointer)))
                                          (format "%s%%" (* 100 (cadr pointer))))
               ""))
     (ob-keycap--modeline nil (format "*keycap: %s*" (org-html-encode-plain-text name)) "All"
                          "<span>keycap preview</span>")
     "</div>"
     (if help
         (concat "<div class=\"ef-window ef-help\">"
                 (format "<div class=\"ef-text\"><div class=\"ef-lc\"><span class=\"ef-cursor\">%s</span>%s</div></div>"
                         (org-html-encode-plain-text (substring help 0 1))
                         (ob-keycap-html (substring help 1)))
                 (ob-keycap--modeline t "*Help*" "Top" "<span class=\"ef-mode\">Help</span>")
                 "</div>")
       "")
     (format "<div class=\"ef-echo\">%s</div>" (if echo (ob-keycap-html echo) ""))
     "</figure>")))


;; --- Babel ---

(defun ob-keycap--check (report params)
  "Fail unless the diagnostics of the `load' REPORT are the ones PARAMS expect.
Notes, such as a keycap call to prefer, are advice: shown, not failed."
  (let* ((expect (ob-keycap--param params :expect))
         (diagnostics (seq-remove (lambda (d)
                                    (when (equal (alist-get 'severity d) "note")
                                      (message "ob-keycap: %s: note on line %s: %s"
                                               (file-name-nondirectory (or buffer-file-name (buffer-name)))
                                               (alist-get 'line d) (keycap-diagnostic-message d))))
                                  (alist-get 'diagnostics report)))
         (severities (mapcar (lambda (d) (alist-get 'severity d)) diagnostics))
         (first (car diagnostics)))
    (cond
     ((alist-get 'error report)
      (error "%s" (alist-get 'error report)))
     ((and (equal expect "error") (not (member "error" severities)))
      (error "an error was expected, the script has none"))
     ((and (equal expect "warning") (not (member "warning" severities)))
      (error "a warning was expected, the script has none"))
     ((and (equal expect "warning") (member "error" severities))
      (error "a warning was expected, the script has an error: line %s: %s"
             (alist-get 'line first) (keycap-diagnostic-message first)))
     ((and diagnostics (not expect))
      (error "line %s of the script: %s" (alist-get 'line first) (keycap-diagnostic-message first))))))

(defun ob-keycap--execute (body params)
  "The result of the block of BODY and PARAMS: an image's file or a frame."
  (let* ((ob-keycap--root (make-temp-file "ob-keycap" t))
         ;; Named as the page's directory is, for the mode line.
         (directory (expand-file-name (file-name-nondirectory (directory-file-name default-directory))
                                      ob-keycap--root))
         (state (progn (make-directory directory)
                       (ob-keycap--state body params directory)))
         (script (ob-keycap--script-buffer state))
         (show (ob-keycap--param params :show))
         preview)
    (unwind-protect
        (with-current-buffer script
          (let* ((previous (when (and (ob-keycap--param params :expect)
                                      (ob-keycap--state-previous state))
                             ;; What the preview showed last, still up when the script fails.
                             (let ((text (ob-keycap--state-script state)))
                               (erase-buffer)
                               (insert (ob-keycap--state-previous state))
                               (prog1 (ob-keycap--load)
                                 (erase-buffer)
                                 (insert text)
                                 (goto-char (ob-keycap--state-point state))))))
                 (report (ob-keycap--load))
                 (nudged (when-let* ((n (ob-keycap--param params :nudge)))
                           (prog1 (ob-keycap--capture
                                   (lambda ()
                                     (dotimes (_ (abs n))
                                       (if (> n 0) (keycap-increase-number 1) (keycap-decrease-number 1)))))
                             (setq report (ob-keycap--load)))))
                 (wheeled (when-let* ((n (ob-keycap--param params :wheel)))
                            (prog1 (keycap-nudge n)
                              (setq report (ob-keycap--load))))))
            (ob-keycap--check report params)
            (let* ((failure (keycap-report-failure report))
                   (shown (if failure (or previous report) report))
                   (diagnostics (keycap-report-diagnostics report)))
              (setq preview (ob-keycap--preview script shown failure params))
              (let* ((png (ob-keycap--render script preview shown params))
                     (pointer (or (ob-keycap--probe preview params) (ob-keycap--pointer params)))
                     (menu (when-let* ((name (ob-keycap--param params :menu)))
                             (cons (format "%s" name) (ob-keycap--menu preview (format "%s" name))))))
                (message "ob-keycap: %s %s" (ob-keycap--state-name state) (file-name-nondirectory png))
                (cond
                 ((not (member "html" (ob-keycap--param params :result-params)))
                  (message "ob-keycap: %s" (ob-keycap--header preview))
                  png)
                 ((equal (ob-keycap--param params :frame) "no")
                  (format "<img src=\"%s\" alt=\"%s\">"
                          (file-relative-name png (or ob-keycap-html-directory default-directory))
                          (org-html-encode-plain-text (or (ob-keycap--param params :alt) ""))))
                 (t
                  (let* ((completion (when (equal show "completion") (ob-keycap--completion)))
                         (rows (pcase-let ((`(,width ,height) (ob-keycap--size params)))
                                 ;; As high as the image beside it.
                                 (max 8 (round (* ob-keycap-window-lines (/ height (float width)))))))
                         (code (ob-keycap--code diagnostics rows
                                                (when completion
                                                  (cons (car completion) (cadr completion)))))
                         (code (if wheeled
                                   (cons (ob-keycap--code-pointer (car code)) (cdr code))
                                 code))
                         (echo (pcase show
                                 ("eldoc" (ob-keycap--eldoc))
                                 ("export" (ob-keycap--export report))
                                 (_ (or nudged
                                        wheeled
                                        ;; Flymake's ElDoc: the diagnostic at point.
                                        (when-let* ((diagnostic (seq-find (lambda (d)
                                                                            (<= (flymake-diagnostic-beg d) (point)
                                                                                (flymake-diagnostic-end d)))
                                                                          diagnostics)))
                                          (propertize (flymake-diagnostic-text diagnostic)
                                                      'face (if (eq (flymake-diagnostic-type diagnostic) :error)
                                                                'error
                                                              'warning)))))))
                         (help (when (equal show "describe") (ob-keycap--describe script))))
                    (ob-keycap--frame state png (ob-keycap--header preview)
                                      (append code (list (ob-keycap--counters diagnostics)))
                                      echo help (ob-keycap--param params :alt) pointer menu))))))))
      (when (buffer-live-p preview)
        (kill-buffer preview))
      (ob-keycap--kill script)
      (delete-directory ob-keycap--root t))))

(defun ob-keycap--drop-empty (html _backend _info)
  "Nothing for the HTML of a keycap block without code.
Such a block shows only its result."
  (if (string-match-p "<pre class=\"src src-keycap\">[ \t\n]*</pre>" html) "" html))

(add-to-list 'org-export-filter-src-block-functions #'ob-keycap--drop-empty)

(defun org-babel-execute:keycap (body params)
  "Run the keycap block of BODY and PARAMS; see the commentary."
  (if (ob-keycap--param params :save)
      ""
    (condition-case error
        (let ((ob-keycap--kept nil))
          (or (catch 'ob-keycap--evaluate
                (ob-keycap--execute body params))
              (let ((ob-keycap--keep nil)
                    (ob-keycap--kept nil))
                (ob-keycap--execute body params))))
      (error
       (error "%s: keycap block of %s: %s" (ob-keycap--where)
              (ob-keycap--param params :model) (error-message-string error))))))

(provide 'ob-keycap)

;;; ob-keycap.el ends here
