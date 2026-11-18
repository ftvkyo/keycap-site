;;; keycap.el --- Make fidget models: edit, preview and export them  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Rei Stepanenko <rei@ftvkyo.me>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (rhai-ts-mode "0.1"))
;; Keywords: languages, tools
;; URL: https://tangled.org/rei.gay/keycap

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

;; Editing fidget (https://github.com/mkeeter/fidget) scripts -- Rhai
;; programs that build signed distance fields -- with the model rendered
;; beside them.  Each script buffer has its own keycap-server process,
;; which evaluates, renders and meshes the script.
;;
;; - `keycap-mode' -- `rhai-ts-mode' that knows fidget's functions and shapes,
;;   for `.keycap' files and, in fidget's own dialect, `.fidget' files
;; - Flymake reports errors on their token, with the calls that led there
;; - `completion-at-point' and ElDoc over functions, shapes and shape fields
;; - `keycap-describe' -- the reference, grouped by category
;; - `keycap-preview' -- the model, rendered beside the script
;; - `keycap-increase-number' -- nudges the number at point, or under the
;;   mouse with the shifted wheel; the preview follows
;; - `keycap-export-stl' and `keycap-export-2d' -- meshes, and outlines for
;;   laser cutting
;; - `keycap-eval-last-expression', `keycap-guide'

;;; Code:

(require 'filenotify)
(require 'flymake)
(require 'info-look)
(require 'rhai-ts-mode)
(require 'subr-x)

(autoload 'keycap-describe "keycap-describe" nil t)
(autoload 'keycap-set-out-signatures "keycap-describe")
(autoload 'keycap-preview "keycap-preview" nil t)
(autoload 'keycap-preview-cycle-view "keycap-preview" nil t)
(declare-function keycap--insert-description "keycap-describe")

(defconst keycap--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Where the package is installed.")

(defconst keycap--version (package-get-version)
  "The package's version.")


;; --- Customization ---

(defgroup keycap nil
  "Editing fidget scripts."
  :group 'languages
  :link '(url-link "https://github.com/mkeeter/fidget"))

(defvar-local keycap-dialect 'keycap
  "The language of the script: `keycap', or `fidget' for fidget's own.
A `fidget' script calls only what fidget's own CLI and viewer have, and
draws one shape, so that it runs in them unchanged.  `keycap-mode' sets
it from the file's extension, `fidget' for `.fidget' and `keycap' for any
other; a file-local variable overrides it.")
(put 'keycap-dialect 'safe-local-variable (lambda (dialect) (memq dialect '(fidget keycap))))

(defvar-local keycap-overrides nil
  "Other values for the script's top-level constants, such as a variant's.
An alist of names and values, such as ((WIDTH . 2) (LEGENDS . [\"Space\"])):
each `const NAME = ...;' outside any block or function has the value
instead.  A value is a number, a string, t or nil, or a vector of them.")

(defcustom keycap-server-program "keycap-server"
  "The keycap-server executable, which evaluates, renders and meshes scripts."
  :type 'string)

(defcustom keycap-prelude-directory (expand-file-name "prelude" keycap--directory)
  "Directory of Rhai files whose functions every script can call, or nil."
  :type '(choice (const :tag "None" nil) directory))

(defcustom keycap-server-threads nil
  "Threads each server renders on, and exports on, or nil for one per core.
On a machine shared with other work, a few keep the rest of its cores free."
  :type '(choice (const :tag "One per core" nil) (natnum :tag "Threads")))

(defcustom keycap-load-delay 0.3
  "Seconds after a change to the script until the preview follows."
  :type 'number)

(defcustom keycap-signature-width 72
  "Columns a call in a description may take.
A longer one takes a line per parameter."
  :type 'natnum)

(defcustom keycap-export-resolution 10
  "Cells per unit of exports, when the script sets no `resolution'."
  :type 'number)

(defcustom keycap-export-tolerance nil
  "How far, in units, exports may stray as they are simplified.
Nil is a tenth of a cell; 0 keeps every triangle the mesher makes and
every point traced."
  :type '(choice (const :tag "A tenth of a cell" nil) (number :tag "Units")))

(defcustom keycap-export-kerf 0
  "The width, in units, that a laser burns away along a cut.
2D exports grow the shapes drawn to cut by half of it, so that parts
come out to size."
  :type 'number)


;; --- Server ---

(defvar-local keycap--server nil
  "The script's keycap-server process.")

(defvar-local keycap--preview nil
  "The script's preview buffer.")
(put 'keycap--preview 'permanent-local t)

(defvar keycap--request-id 0
  "The id of the last request to any server.")

(defun keycap--command ()
  "The command line to start a server with."
  (append (list keycap-server-program)
          (when (and keycap-prelude-directory (file-directory-p keycap-prelude-directory))
            (list "--prelude" (expand-file-name keycap-prelude-directory)))
          (when keycap-server-threads
            (list "--threads" (number-to-string keycap-server-threads)))))

(defun keycap--server-missing ()
  "Signal that `keycap-server-program' is not there to start."
  (user-error "No %s found: install keycap-server (%s), or set `keycap-server-program'"
              keycap-server-program "https://keycap.rei.gay/install.html"))

(defun keycap--server ()
  "The current buffer's server, started if it is not running."
  (if (process-live-p keycap--server)
      keycap--server
    (let* ((log (generate-new-buffer " *keycap-server log*"))
           (stderr (make-pipe-process :name "keycap-server log" :buffer log :noquery t))
           (process
            (condition-case error
                (make-process
                 :name "keycap-server"
                 :command (keycap--command)
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t
                 :stderr stderr
                 :filter #'keycap--receive
                 :sentinel #'keycap--server-sentinel)
              (file-missing
               (kill-buffer log)
               (keycap--server-missing))
              (error
               (kill-buffer log)
               (signal (car error) (cdr error))))))
      (process-put process 'keycap-callbacks (make-hash-table))
      (process-put process 'keycap-output "")
      (process-put process 'keycap-log log)
      (process-put process 'keycap-buffer (current-buffer))
      (setq keycap--server process))))

(defun keycap--receive (process string)
  "Take the server PROCESS's output STRING, and answer each reply in it."
  (let ((lines (split-string (concat (process-get process 'keycap-output) string) "\n")))
    (process-put process 'keycap-output (car (last lines)))
    (dolist (line (butlast lines))
      (when-let* ((reply (ignore-errors
                           (json-parse-string line :object-type 'alist :array-type 'list
                                              :null-object nil :false-object nil)))
                  (callbacks (process-get process 'keycap-callbacks))
                  (callback (gethash (alist-get 'id reply) callbacks)))
        ;; An export's progress comes before its reply.
        (unless (alist-get 'progress reply)
          (remhash (alist-get 'id reply) callbacks))
        (with-demoted-errors "keycap: %S"
          (funcall callback reply))))))

(defun keycap--server-sentinel (process _event)
  "Fail the requests PROCESS still owes once it is dead."
  (unless (process-live-p process)
    (let* ((log (process-get process 'keycap-log))
           (last (when (buffer-live-p log)
                   (with-current-buffer log
                     (car (last (split-string (buffer-string) "\n" t))))))
           (reply `((error . ,(format "keycap-server stopped: %s"
                                      (or last (format "%s %d" (process-status process)
                                                       (process-exit-status process)))))))
           (callbacks (process-get process 'keycap-callbacks)))
      (process-put process 'keycap-callbacks (make-hash-table))
      (maphash (lambda (_id callback)
                 (with-demoted-errors "keycap: %S"
                   (funcall callback reply)))
               callbacks)
      (when (buffer-live-p log)
        (kill-buffer log)))))

(defun keycap--request (request callback)
  "Send REQUEST, an alist, to the current buffer's server.
CALLBACK is called with the reply, or with an `error' when the server
stops first."
  (let ((process (keycap--server))
        (id (setq keycap--request-id (1+ keycap--request-id))))
    (puthash id callback (process-get process 'keycap-callbacks))
    (process-send-string process (concat (json-serialize (cons (cons 'id id) request)) "\n"))
    id))

(defun keycap--stop-server ()
  "Stop the script's server, unless it is another buffer's."
  (when (and (process-live-p keycap--server)
             (eq (process-get keycap--server 'keycap-buffer) (current-buffer)))
    (delete-process keycap--server)))

(defun keycap-use-server (buffer)
  "Send the current buffer's requests to BUFFER's server, started if need be.
Scripts that share one server this way, such as the many a batch run
renders, leave it running when they are killed."
  (setq keycap--server (with-current-buffer buffer (keycap--server))))

(defun keycap--wait (function &optional timeout)
  "Call FUNCTION with a callback; return what the callback is first called with.
Nil once TIMEOUT seconds, if non-nil, pass without a call."
  (let ((end (and timeout (+ (float-time) timeout)))
        reply done)
    (funcall function (lambda (value)
                        (unless done
                          (setq reply value
                                done t))))
    (while (and (not done) (or (not end) (< (float-time) end)))
      (accept-process-output nil 0.05))
    reply))

(defun keycap-request-sync (request &optional timeout)
  "Send REQUEST, an alist, to the current buffer's server, and return the reply.
The reply comes after an export's progress; it is an `error' when the
server stops first, and nil once TIMEOUT seconds, if non-nil, pass."
  (keycap--wait (lambda (callback)
                  (keycap--request request (lambda (reply)
                                             (unless (alist-get 'progress reply)
                                               (funcall callback reply)))))
                timeout))

(defun keycap-server-batch (requests)
  "Send REQUESTS, alists, to a server started for them, and return its replies.
The replies are in the order of the requests; the server exits once it
has answered them all."
  (with-temp-buffer
    (seq-do-indexed (lambda (request id)
                      (insert (json-serialize (cons (cons 'id id) request)) "\n"))
                    requests)
    (let* ((command (keycap--command))
           (status (condition-case nil
                       (apply #'call-process-region (point-min) (point-max) (car command)
                              t '(t nil) nil (cdr command))
                     (file-missing (keycap--server-missing))))
           (replies (make-vector (length requests) nil)))
      (unless (eql status 0)
        (error "%s exited with %s" (car command) status))
      (goto-char (point-min))
      (while (progn (skip-chars-forward " \t\n") (not (eobp)))
        (let ((reply (json-parse-buffer :object-type 'alist :array-type 'list
                                        :null-object nil :false-object nil)))
          (aset replies (alist-get 'id reply) reply)))
      (append replies nil))))

;;;###autoload
(defun keycap-version ()
  "The versions of keycap, of `keycap-server-program' and of Emacs, in a line.
Interactively, show the line and copy it, for a bug report."
  (interactive)
  (let ((version (format "keycap %s, %s, Emacs %s"
                         keycap--version
                         (condition-case nil
                             (car (process-lines keycap-server-program "--version"))
                           (file-missing (format "no %s" keycap-server-program)))
                         emacs-version)))
    (when (called-interactively-p 'any)
      (kill-new version)
      (message "%s" version))
    version))


;; --- Loading ---

(defvar-local keycap--report nil
  "The server's reply to the last `load'.")

(defvar-local keycap--report-tick nil
  "`buffer-chars-modified-tick' of the text `keycap--report' is about.")

(defvar-local keycap--load-waiting nil
  "While a `load' runs, (TICK . CALLBACKS): its text's tick and who waits for it.")

(defvar-local keycap--load-timer nil)

(defvar-local keycap--load-functions nil
  "Functions called with the reply to every `load', in the script buffer.")

(defun keycap--source ()
  "The current buffer's script."
  (save-restriction
    (widen)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun keycap--path ()
  "The script's file name, for the server."
  (if buffer-file-name (expand-file-name buffer-file-name) :null))

(defun keycap--override-value (value)
  "The value VALUE of `keycap-overrides', for the server: nil as false."
  (cond ((null value) :false)
        ((vectorp value) (vconcat (mapcar #'keycap--override-value value)))
        (t value)))

(defun keycap--overrides ()
  "`keycap-overrides', for the server."
  (mapcar (pcase-lambda (`(,name . ,value)) (cons name (keycap--override-value value)))
          keycap-overrides))

(defun keycap--load (&optional callback)
  "Have the server evaluate the script, unless it has this text already.
CALLBACK, if non-nil, is called with the reply, in the script buffer."
  (let ((tick (buffer-chars-modified-tick)))
    (cond
     ((eql tick keycap--report-tick)
      (when callback
        (funcall callback keycap--report)))
     ((eql tick (car keycap--load-waiting))
      (when callback
        (push callback (cdr keycap--load-waiting))))
     (t
      (let ((source (current-buffer))
            (waiting (list tick)))
        (when callback
          (push callback (cdr waiting)))
        (keycap--request
         `((op . "load") (source . ,(keycap--source)) (path . ,(keycap--path))
           (dialect . ,(symbol-name keycap-dialect)) (overrides . ,(keycap--overrides)))
         (lambda (reply)
           (when (buffer-live-p source)
             (with-current-buffer source
               (let ((current (eq keycap--load-waiting waiting)))
                 (when current
                   (setq keycap--load-waiting nil))
                 ;; A server that stopped is asked again next time, and so
                 ;; is a load overtaken by a change to the files it read.
                 (setq keycap--report reply
                       keycap--report-tick (when (and current (not (alist-get 'error reply)))
                                             (car waiting))))
               (run-hook-with-args 'keycap--load-functions reply)
               (dolist (callback (reverse (cdr waiting)))
                 (funcall callback reply))))))
        (setq keycap--load-waiting waiting))))))

(defun keycap--reload (&optional callback)
  "Have the server evaluate the script, even if it has this text already.
CALLBACK as `keycap--load' takes it."
  (setq keycap--report-tick nil
        keycap--load-waiting nil)
  (keycap--load callback))

(defun keycap-load-sync (&optional reload timeout)
  "Have the server evaluate the script, and return its reply, the `load' report.
Without RELOAD, the report on this text, if there is one already, comes
at once.  Nil once TIMEOUT seconds, if non-nil, pass."
  (keycap--wait (if reload #'keycap--reload #'keycap--load) timeout))

(defun keycap--change (&rest _)
  "Evaluate the script again a moment after a change, when a preview follows it."
  (when (buffer-live-p keycap--preview)
    (when keycap--load-timer
      (cancel-timer keycap--load-timer))
    (setq keycap--load-timer
          (run-with-timer keycap-load-delay nil #'keycap--load-now (current-buffer)))))

(defun keycap--load-now (&optional buffer)
  "Evaluate the script in BUFFER now, if it waits to be."
  (when (buffer-live-p (or buffer (current-buffer)))
    (with-current-buffer (or buffer (current-buffer))
      (when keycap--load-timer
        (cancel-timer keycap--load-timer)
        (setq keycap--load-timer nil)
        (keycap--load)))))

(defun keycap-diagnostic-message (diagnostic)
  "The message of DIAGNOSTIC, without the position Rhai puts after it."
  (replace-regexp-in-string " (line [0-9]+, position [0-9]+)\\'" ""
                            (or (alist-get 'message diagnostic) "")))

(defun keycap-report-failure (report)
  "Why the script failed to load, according to the `load' REPORT; nil if it loaded."
  (cond
   ((alist-get 'error report))
   ((alist-get 'loaded report) nil)
   (t
    (if-let* ((diagnostic (seq-find (lambda (diagnostic)
                                      (equal (alist-get 'severity diagnostic) "error"))
                                    (alist-get 'diagnostics report))))
        (format "%s%s: %s"
                (if-let* ((file (alist-get 'file diagnostic)))
                    (concat (file-name-nondirectory file) ":")
                  "line ")
                (alist-get 'line diagnostic)
                (keycap-diagnostic-message diagnostic))
      "The script failed"))))

(defun keycap-report-flat-p (report)
  "Non-nil when the model of the `load' REPORT is 2D, unbounded along Z."
  (let ((lower (alist-get 'lower (alist-get 'fitted (alist-get 'bounds report)))))
    (and lower (null (nth 2 lower)))))


;; --- Watching ---

(defvar-local keycap--watched nil
  "The files the script read on its last load: imports, SVG files, fonts.")

(defvar-local keycap--watches nil
  "The watches on the directories of `keycap--watched'.
Each is (DIRECTORY . DESCRIPTOR).")

(defun keycap--watch (report)
  "Watch the files the `load' REPORT says the script read, and no others.
A file is watched through its directory, so that a program that saves
it by renaming a new file over it is seen too."
  (when-let* ((files (assq 'files report)))
    (setq keycap--watched (cdr files))
    (let ((buffer (current-buffer))
          (directories (delete-dups (mapcar #'file-name-directory keycap--watched))))
      (dolist (watch keycap--watches)
        (unless (member (car watch) directories)
          (file-notify-rm-watch (cdr watch))))
      (setq keycap--watches
            (delq nil
                  (mapcar (lambda (directory)
                            (or (assoc directory keycap--watches)
                                (when-let* ((descriptor
                                             (ignore-errors
                                               (file-notify-add-watch
                                                directory '(change)
                                                (lambda (event)
                                                  (keycap--watched-changed buffer event))))))
                                  (cons directory descriptor))))
                          directories))))))

(defun keycap--watched-changed (buffer event)
  "Load the script in BUFFER again when the file EVENT is about is one it read."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (pcase-let ((`(,_ ,action ,file . ,renamed) event))
        (when (and (memq action '(created changed deleted renamed))
                   (or (member file keycap--watched)
                       (member (car renamed) keycap--watched)))
          ;; The script is the same but what it reads is not.
          (setq keycap--report-tick nil
                keycap--load-waiting nil)
          (keycap--change))))))

(defun keycap--unwatch ()
  "Stop watching the files the script read."
  (dolist (watch keycap--watches)
    (file-notify-rm-watch (cdr watch)))
  (setq keycap--watches nil
        keycap--watched nil))


;; --- Flymake ---

(defun keycap--position (line &optional column)
  "The buffer position of 1-based LINE and character COLUMN, within the line."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- (max 1 line)))
      (min (+ (point) (max 0 (1- (or column 1)))) (line-end-position)))))

(defun keycap--token (position)
  "The region of the token at POSITION, never empty."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char position)
      (cond
       ((looking-at "[[:alnum:]_]+\\(?:\\.[0-9]+\\)?")
        (cons (point) (match-end 0)))
       ((memq (char-after) '(?\" ?`))
        (cons (point) (or (ignore-errors (forward-sexp) (min (point) (line-end-position)))
                          (1+ (point)))))
       ;; Past the end of a line: its last character.
       ((and (eolp) (not (bolp)))
        (cons (1- (point)) (point)))
       (t
        (cons (point) (min (1+ (point)) (point-max))))))))

(defun keycap--region (location &optional rest)
  "The region of the server's LOCATION, with its `line' and maybe `column'.
The token there; with REST or without a column, the rest of the line
from the column or from the indentation."
  (let ((line (or (alist-get 'line location) 1))
        (column (alist-get 'column location)))
    (if (and column (not rest))
        (keycap--token (keycap--position line column))
      (save-excursion
        (goto-char (keycap--position line column))
        (unless column
          (back-to-indentation))
        (cons (point) (max (line-end-position) (min (1+ (point)) (point-max))))))))

(defun keycap--before (region)
  "The last character before REGION, past blanks and comments.
At the start of the buffer, REGION itself."
  (save-excursion
    (goto-char (car region))
    (forward-comment (- (buffer-size)))
    (if (bobp) region (cons (1- (point)) (point)))))

(defun keycap--here-p (file)
  "Non-nil when FILE, from the server, is nil or the current buffer's script."
  (or (null file)
      (and buffer-file-name (file-equal-p file buffer-file-name))))

(defun keycap--import (file)
  "The region of the `import' of FILE, or nil."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (let (found)
        (while (and (not found)
                    (re-search-forward "\\_<import[ \t]+\"\\([^\"]*\\)\"" nil t))
          (let ((start (match-beginning 0)))
            ;; `syntax-ppss' moves point, which would find this import again.
            (when (and (equal (file-name-base (match-string 1)) (file-name-base file))
                       (not (nth 8 (save-excursion (syntax-ppss start)))))
              (setq found (cons start (line-end-position))))))
        found))))

(defun keycap--trace-text (trace)
  "The trace of an error, TRACE, as a suffix for its message."
  (mapconcat (lambda (frame)
               (format "; %s%s: %s"
                       (if-let* ((file (alist-get 'file frame))
                                 ((not (keycap--here-p file))))
                           (concat (file-name-nondirectory file) ":")
                         "line ")
                       (alist-get 'line frame)
                       (alist-get 'message frame)))
             trace ""))

(defun keycap--diagnostic (diagnostic)
  "Flymake diagnostics for one of the server's DIAGNOSTIC.
An error elsewhere is reported on the call that leads there, or on the
`import' of its file; each call on the way gets a note."
  (let* ((type (pcase (alist-get 'severity diagnostic)
                 ("error" :error)
                 ("warning" :warning)
                 (_ :note)))
         (message (keycap-diagnostic-message diagnostic))
         (trace (alist-get 'trace diagnostic))
         (file (alist-get 'file diagnostic))
         (here (keycap--here-p file))
         (frames (seq-filter (lambda (frame) (keycap--here-p (alist-get 'file frame))) trace))
         (region (cond
                  ;; Rhai points past the statement that lacks its `;'.
                  ((and here (string-match-p "Expecting ';'" message))
                   (keycap--before (keycap--region diagnostic)))
                  (here (keycap--region diagnostic (eq type :warning)))
                  (frames (keycap--region (pop frames)))
                  ((keycap--import file))
                  (t (keycap--region nil)))))
    (cons (flymake-make-diagnostic
           (current-buffer) (car region) (cdr region) type
           (concat (unless here
                     (format "%s:%s: " (file-name-nondirectory file) (alist-get 'line diagnostic)))
                   message
                   (keycap--trace-text trace)))
          (mapcar (lambda (frame)
                    (let ((region (keycap--region frame)))
                      (flymake-make-diagnostic
                       (current-buffer) (car region) (cdr region) :note
                       (format "%s: %s" (alist-get 'message frame) message))))
                  frames))))

(defun keycap-report-diagnostics (report)
  "Flymake diagnostics for the `load' REPORT on the current buffer."
  (mapcan #'keycap--diagnostic (alist-get 'diagnostics report)))

(defvar-local keycap--flymake-report nil
  "The REPORT-FN of the last Flymake check; earlier ones are obsolete.")

(defun keycap-flymake (report-fn &rest _)
  "Flymake backend: evaluate the script and REPORT-FN its diagnostics."
  (setq keycap--flymake-report report-fn)
  (condition-case error
      (keycap--load
       (lambda (reply)
         ;; Flymake signals an error for a check that a newer one replaced.
         (when (eq report-fn keycap--flymake-report)
           (if-let* ((failure (alist-get 'error reply)))
               (funcall report-fn :panic :explanation failure)
             (funcall report-fn (keycap-report-diagnostics reply))))))
    (error
     (funcall report-fn :panic :explanation (error-message-string error)))))


;; --- Documentation ---

(defconst keycap--name-regexp "[[:alpha:]_][[:alnum:]_]*"
  "Matches a Rhai name.")

(defvar keycap--names nil
  "Everything documented, per dialect.
An alist from a `keycap-dialect' to a hash table from name to its
description: the server's, with `class' added, `shape' or `function'.")

(defvar keycap--modules nil
  "The prelude's modules, per dialect: an alist to their names.
A script imports the module `screws' as `import \"keycap/screws\"'.")

(defun keycap-docs (dialect)
  "The server's `docs' reply for DIALECT: the functions and shapes it documents."
  (car (keycap-server-batch `(((op . "docs") (dialect . ,(symbol-name dialect)))))))

(defun keycap--index (docs)
  "The server's DOCS reply as a hash table from name to description."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (function (alist-get 'functions docs))
      (puthash (alist-get 'name function) (cons '(class . function) function) table))
    (dolist (shape (alist-get 'shapes docs))
      (puthash (alist-get 'name shape) (cons '(class . shape) shape) table))
    table))

(defun keycap-names (&optional dialect)
  "The documented names of DIALECT, or of the script's, asking the server once.
A hash table from each name to its entry of `keycap-docs'.  A failed
request leaves nothing behind, so that the next call asks again."
  (let ((dialect (or dialect (buffer-local-value 'keycap-dialect (keycap--script)))))
    (or (alist-get dialect keycap--names)
        (condition-case error
            (let ((docs (keycap-docs dialect)))
              (setf (alist-get dialect keycap--modules)
                    (seq-keep (lambda (section)
                                (when (alist-get 'module section)
                                  (file-name-base (alist-get 'file section))))
                              (alist-get 'sections docs)))
              (setf (alist-get dialect keycap--names) (keycap--index docs)))
          (error
           (display-warning 'keycap (format "Could not list fidget's functions: %s"
                                            (error-message-string error)))
           (make-hash-table :test #'equal))))))

(defvar-local keycap--script-names nil
  "The functions the script defines and imports, as `keycap--names' has them.
From the last `load'; one imported as `keycap' is named `keycap::body'.")

(defvar keycap--described nil
  "The script buffer whose own functions the description being shown may name.")

(defun keycap--remember-functions (reply)
  "Keep the functions of the `load' REPLY in `keycap--script-names'."
  (when-let* ((functions (assq 'functions reply)))
    (setq keycap--script-names (keycap--index (list functions)))))

(defun keycap--script ()
  "The script described, or else this buffer."
  (if (buffer-live-p keycap--described) keycap--described (current-buffer)))

(defun keycap--script-names ()
  "`keycap--script-names' of the script described, or else of this buffer."
  (buffer-local-value 'keycap--script-names (keycap--script)))

(defun keycap--doc (name)
  "The description of NAME, or nil when it is not documented.
The script's own functions come first, as they shadow the others."
  (and name
       (or (when-let* ((names (keycap--script-names)))
             (gethash name names))
           (gethash name (keycap-names)))))

(defun keycap--all-names ()
  "Every documented name, the script's own included."
  (delete-dups (append (when-let* ((names (keycap--script-names)))
                         (hash-table-keys names))
                       (hash-table-keys (keycap-names)))))

(defun keycap--shape-p (name)
  "Non-nil when NAME is a shape."
  (eq (alist-get 'class (keycap--doc name)) 'shape))

(defun keycap--field-text (field)
  "FIELD of a shape as `name: Type = default'."
  (concat (alist-get 'name field) ": " (alist-get 'type field)
          (when-let* ((default (alist-get 'default field)))
            (concat " = " default))))

(defface keycap-tree-type
  '((t :inherit font-lock-type-face :slant italic))
  "The types `Tree' and `Shape' in signatures: values that may vary over space.")

(defconst keycap--signature-font-lock-keywords
  `(("^\\(type\\) \\([[:alnum:]_]+\\)"
     (1 'font-lock-keyword-face)
     (2 'font-lock-type-face))
    (,(concat "^[ \t]*\\(?:\\(" keycap--name-regexp "\\)\\.\\)?"
              "\\(" keycap--name-regexp "\\(?:::" keycap--name-regexp "\\)*\\)(")
     (1 'font-lock-variable-name-face nil t)
     (2 'font-lock-function-name-face))
    ;; Parameters and keys, `name:' and `name?:', but not `module::'
    (,(concat "\\_<\\(" keycap--name-regexp "\\)\\??:\\(?:[^:]\\|$\\)")
     1 'font-lock-variable-name-face)
    ("\\_<\\(?:Tree\\|Shape\\)\\_>" . 'keycap-tree-type)
    ("\\_<\\(?:number\\|string\\|bool\\|int\\|float\\|[[:upper:]][[:alnum:]_]*\\)\\_>"
     . 'font-lock-type-face)
    ("\\_<[0-9]+\\(?:\\.[0-9]+\\)?\\_>" . 'font-lock-number-face))
  "How `keycap-signature-mode' highlights a signature.")

(define-derived-mode keycap-signature-mode prog-mode "Signature"
  "Major mode for the signatures of keycap's reference.
For highlighting them, as `keycap-describe' and the manual's site do."
  (setq-local font-lock-defaults '(keycap--signature-font-lock-keywords)))

(defun keycap--fontify-signature (signature)
  "SIGNATURE highlighted by `keycap-signature-mode'."
  (with-temp-buffer
    (insert signature)
    (delay-mode-hooks (keycap-signature-mode))
    (font-lock-ensure)
    (buffer-string)))

(defun keycap--signatures (name)
  "How NAME is called, as a list of highlighted strings."
  (when-let* ((entry (keycap--doc name)))
    (mapcar #'keycap--fontify-signature
            (or (alist-get 'signatures entry)
                (list (concat name "(...)"))))))

(defun keycap--signature (name)
  "How NAME is usually called, the first of its signatures."
  (car (keycap--signatures name)))

(defun keycap--summary (doc)
  "The first sentence of DOC."
  (when doc
    (let ((paragraph (string-join (split-string (car (split-string doc "\n[ \t]*\n")) "[ \t\n]+" t)
                                  " ")))
      (if (string-match "\\.\\(?: \\|\\'\\)" paragraph)
          (substring paragraph 0 (1+ (match-beginning 0)))
        paragraph))))

(defun keycap--fontify-names ()
  "Highlight the functions and shapes of the script's dialect as builtins."
  (when-let* ((names (alist-get keycap-dialect keycap--names))
              ((treesit-parser-list))
              ((> (hash-table-count names) 0)))
    (setq-local rhai-ts-mode-builtin-functions
                (append (hash-table-keys names)
                        (default-value 'rhai-ts-mode-builtin-functions)))
    (setq-local treesit-font-lock-settings (rhai-ts-mode-font-lock-settings))
    (treesit-font-lock-recompute-features)
    (font-lock-flush)))

(defun keycap--fetch-names (dialect)
  "List the documented names of DIALECT, then highlight them in its scripts."
  (unless (alist-get dialect keycap--names)
    (keycap-names dialect)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'keycap-mode) (eq keycap-dialect dialect))
          (keycap--fontify-names))))))

(defun keycap--use-dialect ()
  "Highlight the names of the script's dialect, listing them the first time."
  (if (alist-get keycap-dialect keycap--names)
      (keycap--fontify-names)
    (run-with-idle-timer 0.1 nil #'keycap--fetch-names keycap-dialect)))


;; --- Scripts ---

;; What a script defines and draws, read from its tree-sitter tree, which
;; rhai-ts-mode keeps up to date in a script buffer; in any other buffer,
;; such as a temporary one holding a script, the first call parses it.

(defun keycap--statements ()
  "The top-level statements of the current buffer's script, as tree-sitter nodes."
  (treesit-filter-child
   (treesit-parser-root-node (treesit-parser-create 'rhai))
   (lambda (node) (equal (treesit-node-type node) "Stmt"))))

(defun keycap--statement-expression (statement)
  "The expression the STATEMENT node is, such as an `ExprFn' or an `ExprCall'.
Past its `///' comment, if it has one."
  (when-let* ((item (treesit-node-child statement 0 t))
              (expression (car (last (treesit-node-children item t)))))
    (treesit-node-child expression 0 t)))

(defun keycap--node-region (node)
  "The region of NODE, as (START . END)."
  (cons (treesit-node-start node) (treesit-node-end node)))

(defun keycap-script-statements ()
  "The top-level statements of the script in the current buffer, in order.
Each is (START . END), past its `;', and a function's from its `///'
comment.  The last may be an expression without a `;'."
  (mapcar #'keycap--node-region (keycap--statements)))

(defun keycap-script-functions ()
  "The functions the script in the current buffer defines, in order.
Each is (NAME START . END), from its `///' comment to its closing brace."
  (seq-keep (lambda (statement)
              (when-let* ((function (keycap--statement-expression statement))
                          ((equal (treesit-node-type function) "ExprFn")))
                (cons (treesit-node-text (treesit-node-child-by-field-name function "fn_name") t)
                      (keycap--node-region statement))))
            (keycap--statements)))

(defun keycap-script-draws ()
  "The top-level `draw' and `draw_rgb' statements of the current buffer's script.
In order, each as (START . END)."
  (seq-keep (lambda (statement)
              (when-let* ((call (keycap--statement-expression statement))
                          ((equal (treesit-node-type call) "ExprCall"))
                          ((member (treesit-node-text (treesit-node-child-by-field-name call "fn_name") t)
                                   '("draw" "draw_rgb"))))
                (keycap--node-region statement)))
            (keycap--statements)))

(defun keycap--definitions ()
  "The script's own names: its functions, variables and constants.
None without the Rhai grammar."
  (when (treesit-ready-p 'rhai t)
    (delete-dups (mapcar (lambda (capture) (treesit-node-text (cdr capture) t))
                         (treesit-query-capture 'rhai '((FnDeclName) @name
                                                        (ExprDeclareVar name: (ident) @name)))))))


;; --- Completion and ElDoc ---

(defun keycap--skip-qualifiers ()
  "Move point back over the `module::' qualifiers before it."
  (while (looking-back (concat "\\_<" keycap--name-regexp "::") (line-beginning-position))
    (goto-char (match-beginning 0))))

(defun keycap--name-bounds ()
  "The bounds of the name at point, with the modules that qualify it.
On `keycap::body', from `keycap' to `body', wherever point is in it."
  (when-let* ((bounds (bounds-of-thing-at-point 'symbol)))
    (save-excursion
      (goto-char (car bounds))
      (keycap--skip-qualifiers)
      (setcar bounds (point))
      (goto-char (cdr bounds))
      (while (looking-at (concat "::\\(" keycap--name-regexp "\\)\\_>"))
        (goto-char (match-end 0))
        (setcdr bounds (point))))
    bounds))

(defun keycap--qualified-name ()
  "The name at point, with the modules that qualify it, or nil."
  (when-let* ((bounds (keycap--name-bounds)))
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(defun keycap--shape-map (&optional position)
  "When POSITION is in a map given to a shape, (SHAPE . OPEN).
OPEN is where the map's `{' is; POSITION defaults to point."
  (save-excursion
    (let ((open (nth 1 (syntax-ppss position))))
      (when (and open (eq (char-after open) ?{) (eq (char-before open) ?#))
        (goto-char (1- open))
        (skip-chars-backward " \t\n")
        (when (eq (char-before) ?\()
          (backward-char)
          (skip-chars-backward " \t")
          (let ((end (point)))
            (skip-chars-backward "[:alnum:]_")
            (let ((name (buffer-substring-no-properties (point) end)))
              (when (keycap--shape-p name)
                (cons name open)))))))))

(defun keycap--key-start ()
  "When point is on a map key, the key's start."
  (save-excursion
    (skip-chars-backward "[:alnum:]_")
    (let ((start (point)))
      (skip-chars-backward " \t\n")
      (when (memq (char-before) '(?{ ?,))
        start))))

(defun keycap--map-keys (open &optional except)
  "The keys of the map whose `{' is at OPEN, but the one at EXCEPT."
  (save-excursion
    (goto-char (1+ open))
    (let ((end (or (ignore-errors (scan-lists open 1 0)) (point-max)))
          keys)
      (while (re-search-forward (concat "\\(" keycap--name-regexp "\\)[ \t\n]*:") end t)
        (unless (or (eq (char-after) ?:)
                    (eql (match-beginning 1) except)
                    (not (eql (nth 1 (syntax-ppss)) open)))
          (push (match-string-no-properties 1) keys)))
      keys)))

(defun keycap--map-key (open)
  "The key of the entry point is in, in the map whose `{' is at OPEN."
  (save-excursion
    (let ((limit (point))
          (start (1+ open)))
      (goto-char start)
      (while (search-forward "," limit t)
        (when (eql (nth 1 (syntax-ppss)) open)
          (setq start (point))))
      (goto-char start)
      (when (looking-at (concat "[ \t\n]*\\(" keycap--name-regexp "\\)"))
        (match-string-no-properties 1)))))

(defun keycap--field (shape name)
  "The field NAME of SHAPE."
  (seq-find (lambda (field) (equal (alist-get 'name field) name))
            (alist-get 'fields (keycap--doc shape))))

(defun keycap--kind (name)
  "NAME's kind, as `company-kind' would have it."
  (pcase (alist-get 'class (keycap--doc name))
    ('shape 'struct)
    ('function 'function)
    (_ 'variable)))

(defun keycap--annotation (name)
  "The completion annotation for NAME: what it is, or where it comes from."
  (when-let* ((entry (keycap--doc name)))
    (concat " " (if (eq (alist-get 'class entry) 'shape)
                    "shape"
                  (alist-get 'source entry)))))

(defun keycap--doc-buffer (name)
  "A buffer describing NAME, for `company-doc-buffer'."
  (when (keycap--doc name)
    (require 'keycap-describe)
    (with-current-buffer (get-buffer-create " *keycap-doc*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (keycap--insert-description name))
      (current-buffer))))

(defun keycap--field-completion (shape start end open)
  "Complete the keys of SHAPE's map at OPEN, from START to END."
  (list start end
        (seq-difference (mapcar (lambda (field) (alist-get 'name field))
                                (alist-get 'fields (keycap--doc shape)))
                        (keycap--map-keys open start))
        :annotation-function
        (lambda (name)
          (when-let* ((field (keycap--field shape name)))
            (substring (keycap--field-text field) (1+ (length name)))))
        :company-kind (lambda (_) 'field)
        :company-docsig
        (lambda (name)
          (keycap--summary (alist-get 'doc (keycap--field shape name))))
        :exit-function
        (lambda (_name status)
          (when (and (eq status 'finished) (not (looking-at-p "[ \t]*:")))
            (insert ": ")))))

(defun keycap--module-completion ()
  "Complete a module of the prelude in `import \"keycap/...\"', or nil."
  (let ((string (nth 8 (syntax-ppss))))
    (when (and string
               (eq (char-after string) ?\")
               (save-excursion
                 (goto-char string)
                 (looking-back "\\_<import[ \t]+" (line-beginning-position))))
      (let ((start (+ string 1 (length "keycap/")))
            (end (save-excursion (skip-chars-forward "^\"\n") (point))))
        (when (and (<= start (point))
                   (string= (buffer-substring-no-properties (1+ string) start) "keycap/"))
          (keycap-names)
          (list start end (alist-get keycap-dialect keycap--modules)
                :company-kind (lambda (_) 'module)))))))

(defun keycap-completion-at-point ()
  "Complete a shape's fields in its map, else names a script can use.
In an import's string, complete the prelude's modules."
  (if (nth 8 (syntax-ppss))
      (keycap--module-completion)
    (let* ((bounds (or (keycap--name-bounds)
                       (save-excursion
                         (keycap--skip-qualifiers)
                         (cons (point) (point)))))
           (map (keycap--shape-map))
           (key (and map (keycap--key-start))))
      (cond
       (key
        (keycap--field-completion (car map) key (cdr bounds) (cdr map)))
       ((not (string-match-p "\\`[0-9]" (buffer-substring (car bounds) (cdr bounds))))
        (list (car bounds) (cdr bounds)
              (append (keycap--definitions) (keycap--all-names))
              :exclusive 'no
              :annotation-function #'keycap--annotation
              :company-kind #'keycap--kind
              :company-docsig #'keycap--signature
              :company-doc-buffer #'keycap--doc-buffer))))))

(defun keycap--out-of-values (position &optional maps)
  "POSITION moved out of the arrays around it, and with MAPS, out of maps."
  (save-excursion
    (let (open)
      (while (and (setq open (nth 1 (syntax-ppss position)))
                  (or (eq (char-after open) ?\[)
                      (and maps (eq (char-after open) ?{) (eq (char-before open) ?#))))
        (setq position open))
      position)))

(defun keycap--call ()
  "The call point is in the arguments of: (NAME . ARGUMENT), or nil.
ARGUMENT counts from 0; a method's receiver is its first argument.
Point may be in an array or a map among the arguments."
  (save-excursion
    (when-let* ((position (keycap--out-of-values (point) t))
                (open (nth 1 (syntax-ppss position)))
                ((eq (char-after open) ?\()))
      (let ((argument 0)
            (limit position))
        (goto-char (1+ open))
        (while (search-forward "," limit t)
          (when (eql (nth 1 (syntax-ppss)) open)
            (setq argument (1+ argument))))
        (goto-char open)
        (skip-chars-backward " \t")
        (let ((end (point)))
          (skip-chars-backward "[:alnum:]_")
          (keycap--skip-qualifiers)
          (unless (= (point) end)
            (cons (buffer-substring-no-properties (point) end)
                  (if (eq (char-before) ?.) (1+ argument) argument))))))))

(defun keycap--highlight-argument (signature argument)
  "SIGNATURE with its parameter number ARGUMENT, from 0, highlighted, or nil.
Past the last parameter, the last one is highlighted when it is `...'."
  (let ((open (string-search "(" signature))
        (depth 0)
        starts close)
    (when open
      (push (1+ open) starts)
      (seq-do-indexed
       (lambda (char index)
         (when (and (> index open) (not close))
           (pcase char
             ((or ?\( ?\[ ?{ ?<) (setq depth (1+ depth)))
             ;; The `>' of a function type's `=>' closes nothing.
             ((and ?> (guard (eq (aref signature (1- index)) ?=))))
             ((or ?\] ?} ?>) (setq depth (1- depth)))
             (?\) (if (zerop depth) (setq close index) (setq depth (1- depth))))
             (?, (when (zerop depth) (push (1+ index) starts))))))
       signature))
    (when-let* ((close)
                (starts (nreverse starts))
                (index (cond
                        ((< argument (length starts)) argument)
                        ((string-match-p "\\.\\.\\." (substring signature (car (last starts)) close))
                         (1- (length starts)))))
                (start (nth index starts))
                (end (if (< (1+ index) (length starts)) (1- (nth (1+ index) starts)) close)))
      (while (eq (aref signature start) ?\s)
        (setq start (1+ start)))
      (when (< start end)
        (setq signature (copy-sequence signature))
        (add-face-text-property start end 'eldoc-highlight-function-argument nil signature)
        signature))))

(defun keycap--call-signature (name argument)
  "The first signature of NAME with its parameter ARGUMENT highlighted.
Without such a parameter, its first signature."
  (let ((signatures (keycap--signatures name)))
    (or (seq-some (lambda (signature) (keycap--highlight-argument signature argument))
                  signatures)
        (car signatures))))

(defun keycap--shape-eldoc (shape key)
  "ElDoc for the map given to SHAPE, with point in the entry for KEY."
  (let* ((fields (alist-get 'fields (keycap--doc shape)))
         (field (keycap--field shape key)))
    (concat (propertize shape 'face 'font-lock-function-name-face)
            "(#{"
            (mapconcat (lambda (field)
                         (let ((text (keycap--field-text field)))
                           (if (equal (alist-get 'name field) key)
                               (propertize text 'face 'eldoc-highlight-function-argument)
                             text)))
                       fields ", ")
            "})"
            (when-let* ((summary (keycap--summary (alist-get 'doc (or field (keycap--doc shape))))))
              (concat "  " summary)))))

(defun keycap-eldoc-function (callback &rest _)
  "ElDoc for CALLBACK: a shape's fields, or a function's signature.
In a map given to a shape, its fields; else the signature and summary
of the function at point or called around it."
  (if-let* ((map (keycap--shape-map (keycap--out-of-values (point)))))
      (funcall callback (keycap--shape-eldoc (car map) (keycap--map-key (cdr map))))
    (let* ((symbol (keycap--qualified-name))
           (call (unless (keycap--doc symbol) (keycap--call)))
           (name (if call (car call) symbol)))
      (when-let* ((signature (if call
                                 (keycap--call-signature name (cdr call))
                               (keycap--signature name))))
        (let ((summary (keycap--summary (alist-get 'doc (keycap--doc name)))))
          (funcall callback (concat signature (when summary (concat "  " summary)))))))))

(defun keycap-name-at-point ()
  "The name at point; on a key of a shape's map, the shape."
  (let ((map (keycap--shape-map)))
    (if (and map (keycap--key-start) (not (keycap--doc (thing-at-point 'symbol t))))
        (car map)
      (keycap--qualified-name))))


;; --- Manual ---

(defconst keycap--manual-file (expand-file-name "keycap.info" keycap--directory)
  "The manual's Info file, when it is installed with the package.")

(defun keycap--manual ()
  "The manual, as Info knows it: its file, else its name on the Info path."
  (if (file-exists-p keycap--manual-file) keycap--manual-file "keycap"))

;;;###autoload
(defun keycap-guide ()
  "Read the keycap manual."
  (interactive)
  (let ((org (expand-file-name "doc/keycap.org" keycap--directory)))
    (condition-case error
        (info (keycap--manual))
      (user-error
       (if (file-exists-p org)
           (view-file org)
         (signal (car error) (cdr error)))))))

(info-lookup-add-help
 :mode 'keycap-mode
 :regexp keycap--name-regexp
 :doc-spec `((,(format "(%s)Function Index" (keycap--manual)) nil "^ -+ .*: " "\\_>")))


;; --- Commands ---

(defun keycap--expression-start (end)
  "Where the expression ending at END begins.
It goes back to the `;', `,', `=' or bracket that ends what comes before."
  (save-excursion
    (goto-char end)
    (let ((limit (or (nth 1 (syntax-ppss)) (point-min)))
          start)
      (while (not start)
        (if (not (re-search-backward "[][(){};,=]" limit t))
            (setq start limit)
          (cond
           ((nth 8 (syntax-ppss)))
           ((memq (char-after) '(?\) ?\]))
            (goto-char (or (ignore-errors (scan-sexps (1+ (point)) -1)) limit)))
           ;; A map belongs to the expression, a block ends a statement.
           ((and (eq (char-after) ?})
                 (when-let* ((open (ignore-errors (scan-sexps (1+ (point)) -1))))
                   (and (eq (char-before open) ?#) (goto-char open)))))
           ;; Comparisons and arrows, not assignments.
           ((and (eq (char-after) ?=)
                 (or (memq (char-before) '(?= ?! ?< ?>))
                     (memq (char-after (1+ (point))) '(?= ?>)))))
           (t
            (setq start (1+ (point)))))))
      (goto-char start)
      (forward-comment (buffer-size))
      (when (looking-at "return\\_>")
        (goto-char (match-end 0))
        (skip-chars-forward " \t\n"))
      (point))))

(defun keycap--last-expression ()
  "The region of the expression before point, or the active region."
  (if (use-region-p)
      (cons (region-beginning) (region-end))
    (let ((end (save-excursion (skip-chars-backward " \t\n;") (point))))
      (cons (min end (keycap--expression-start end)) end))))

(defun keycap-eval-last-expression ()
  "Evaluate the expression before point, in the scope of the whole script.
Like a REPL, the value shows in the echo area.  With an active region,
evaluate it instead."
  (interactive nil keycap-mode)
  (pcase-let ((`(,start . ,end) (keycap--last-expression)))
    (when (= start end)
      (user-error "No expression before point"))
    (keycap--request
     `((op . "eval") (source . ,(keycap--source)) (path . ,(keycap--path))
       (dialect . ,(symbol-name keycap-dialect)) (overrides . ,(keycap--overrides))
       (expression . ,(buffer-substring-no-properties start end)))
     (lambda (reply)
       (message "%s" (cond
                      ((alist-get 'error reply))
                      ((alist-get 'diagnostics reply)
                       (let ((diagnostic (car (alist-get 'diagnostics reply))))
                         ;; The script's own errors are elsewhere than the expression.
                         (if (alist-get 'file diagnostic)
                             (format "The script fails, line %s: %s" (alist-get 'line diagnostic)
                                     (keycap-diagnostic-message diagnostic))
                           (keycap-diagnostic-message diagnostic))))
                      (t (concat "=> " (alist-get 'value reply)))))))))


;; --- Exporting ---

(defvar-local keycap--export nil
  "The export that runs, as (ID FILE START STAGE TOLERANCE).
STAGE is the last one its progress reported, and TOLERANCE the one it
simplifies to, once it does.")

(defconst keycap--export-stages
  '(("octree" . "sampling") ("triangles" . "triangulating")
    ("grid" . "sampling") ("contours" . "tracing")
    ("simplifying" . "simplifying") ("writing" . "writing"))
  "The stages an export reports, and what they are called.")

(defun keycap--export-status ()
  "What the export that runs is doing, such as \"part.stl: sampling, 4 s\", or nil."
  (pcase keycap--export
    (`(,_ ,file ,start ,stage ,tolerance . ,_)
     (format "%s: %s%s, %d s" (file-name-nondirectory file)
             (or (cdr (assoc stage keycap--export-stages)) "starting")
             (if (and tolerance (equal stage "simplifying")) (format " to %g" tolerance) "")
             (round (- (float-time) start))))))

(defun keycap--export-tick (source)
  "Redraw the header line of the preview of SOURCE while it exports."
  (when (buffer-live-p source)
    (with-current-buffer source
      (when (buffer-live-p keycap--preview)
        (with-current-buffer keycap--preview
          (force-mode-line-update))))))

(defun keycap--exported (file reply)
  "Take the server's REPLY, or progress, about the export to FILE."
  (if-let* ((stage (alist-get 'progress reply)))
      (when keycap--export
        (setf (nth 3 keycap--export) stage
              (nth 4 keycap--export) (alist-get 'tolerance reply)))
    (setq keycap--export nil)
    (let ((name (abbreviate-file-name file))
          (triangles (alist-get 'triangles reply))
          (meshed (alist-get 'meshed reply)))
      (cond
       ((alist-get 'cancelled reply)
        (message "Exporting %s cancelled; it is as it was" name))
       ((alist-get 'error reply)
        (message "Exporting failed: %s" (alist-get 'error reply)))
       (triangles
        (message "Exported %s: %d triangles%s in %.1f s" name triangles
                 (if (eql triangles meshed)
                     ""
                   (format " (of %d, within %.2g)" meshed (alist-get 'tolerance reply)))
                 (/ (alist-get 'ms reply) 1000.0)))
       (t
        (message "Exported %s: %d outlines, %d lines and %d arcs in %.1f s" name
                 (alist-get 'outlines reply) (alist-get 'lines reply) (alist-get 'arcs reply)
                 (/ (alist-get 'ms reply) 1000.0))))))
  (keycap--export-tick (current-buffer)))

(defun keycap--export-file (extension prompt)
  "Read the file to export to with PROMPT, by default the script's with EXTENSION."
  (let ((default (concat (file-name-base (or buffer-file-name (buffer-name))) extension)))
    (read-file-name (format-prompt prompt default) nil default nil default)))

(defun keycap--export-arguments ()
  "Read a file, and with a prefix, a resolution, for `keycap-export-stl'."
  (list (keycap--export-file ".stl" "Export STL")
        (when current-prefix-arg
          (read-number "Resolution (cells per unit): "
                       (or (alist-get 'resolution keycap--report) keycap-export-resolution)))))

(defun keycap--export-bounds ()
  "The bounds the preview shows, or `script' without a preview."
  (or (and (buffer-live-p keycap--preview)
           (buffer-local-value 'keycap--preview-bounds keycap--preview))
      'script))

(defun keycap--start-export (file resolution request)
  "Export the script to FILE by REQUEST, an alist with the request's `op'.
The request gets the output FILE, the RESOLUTION, else the script's, else
`keycap-export-resolution', and `keycap-export-tolerance'."
  (when keycap--export
    (user-error "%s exports already; %s cancels it"
                (file-name-nondirectory (nth 1 keycap--export))
                (substitute-command-keys "\\[keycap-export-cancel]")))
  (let ((source (current-buffer))
        (file (expand-file-name file)))
    (keycap--load
     (lambda (report)
       (if-let* ((failure (keycap-report-failure report)))
           (message "Exporting failed: %s" failure)
         (message "Exporting %s..." (abbreviate-file-name file))
         (let (timer)
           (setq keycap--export
                 (list (keycap--request
                        `(,@request
                          (output . ,file)
                          (resolution . ,(or resolution (alist-get 'resolution report)
                                             keycap-export-resolution))
                          ,@(when keycap-export-tolerance
                              `((tolerance . ,keycap-export-tolerance))))
                        (lambda (reply)
                          ;; Even for a killed script, whose server replies as it stops
                          (unless (alist-get 'progress reply)
                            (cancel-timer timer))
                          (when (buffer-live-p source)
                            (with-current-buffer source
                              (keycap--exported file reply)))))
                       file (float-time) nil nil)
                 timer (run-with-timer 1 1 #'keycap--export-tick source)))
         (keycap--export-tick source))))))

(defun keycap-export-stl (file &optional resolution bounds)
  "Mesh the script into the STL FILE.
RESOLUTION, in cells per unit, overrides the script's `resolution' and
`keycap-export-resolution'; interactively, a prefix argument asks for
it.  BOUNDS, `script' or `fitted', defaults to the preview's.  The mesh
is simplified to within `keycap-export-tolerance'.

The export runs beside the editing and the preview, its progress in the
preview's header line; \\[keycap-export-cancel] cancels it."
  (interactive (keycap--export-arguments) keycap-mode)
  (keycap--start-export
   file resolution
   `((op . "mesh") (bounds . ,(symbol-name (or bounds (keycap--export-bounds)))))))

(declare-function keycap--preview-slice-shown "keycap-preview")

(defun keycap--export-2d-arguments ()
  "Read a file, and with a prefix, a kerf, for `keycap-export-2d'."
  (list (keycap--export-file ".svg" "Export SVG or DXF")
        (when current-prefix-arg
          (read-number "Kerf: " keycap-export-kerf))))

(defun keycap--export-format (file)
  "The drawing FILE's extension asks for: \"svg\" or \"dxf\"."
  (let ((extension (downcase (or (file-name-extension file) ""))))
    (if (member extension '("svg" "dxf"))
        extension
      (user-error "Export to an .svg or a .dxf file, not %s" (file-name-nondirectory file)))))

(defun keycap-export-2d (file &optional kerf slice bounds)
  "Trace the outlines of the script's shapes into FILE, an SVG or a DXF.
FILE's extension decides which.  The shapes drawn to cut, score and
engrave are each a group of the SVG, or a layer of the DXF, in the
colour laser software takes for them.

The shapes to cut grow by half of KERF, in units, else of
`keycap-export-kerf'; interactively, a prefix argument asks for it.
SLICE, (AXIS OFFSET TILT), is the plane traced, TILT (RIGHT . UP) in
degrees or nil for a level one: by default the one the preview shows in
its 2D views, otherwise across Z through the middle of the bounds.
BOUNDS, `script' or `fitted', defaults to the preview's.
The outlines are traced on a grid of the script's `resolution', else
`keycap-export-resolution', and fitted with lines and arcs within
`keycap-export-tolerance'.

The export runs as `keycap-export-stl' does; \\[keycap-export-cancel]
cancels it."
  (interactive (keycap--export-2d-arguments) keycap-mode)
  (let ((slice (or slice
                   (and (buffer-live-p keycap--preview)
                        (with-current-buffer keycap--preview
                          (keycap--preview-slice-shown))))))
    (keycap--start-export
     file nil
     `((op . "trace") (format . ,(keycap--export-format file))
       (bounds . ,(symbol-name (or bounds (keycap--export-bounds))))
       (kerf . ,(or kerf keycap-export-kerf))
       ,@(when slice
           (pcase-let ((`(,axis ,offset ,tilt) slice))
             `((slice . ((axis . ,(symbol-name axis))
                         (offset . ,offset)
                         ,@(when tilt
                             `((tilt . ,(vector (car tilt) (cdr tilt))))))))))))))

(defun keycap-exporting-p ()
  "Non-nil while an export of the script runs."
  (and keycap--export t))

(defun keycap-export-cancel ()
  "Cancel the export that runs; the file it was to write stays as it was."
  (interactive nil keycap-mode)
  (unless keycap--export
    (user-error "No export runs"))
  (keycap--request '((op . "cancel")) #'ignore))


;; --- Numbers ---

(defun keycap--number-at-point ()
  "The region of the number around point, or nil."
  (save-excursion
    (let ((point (point))
          found)
      (goto-char (line-beginning-position))
      (while (and (not found)
                  (re-search-forward "\\_<[0-9]+\\(?:\\.[0-9]+\\)?" (line-end-position) t))
        (when (and (<= (match-beginning 0) point (match-end 0))
                   (not (nth 8 (syntax-ppss))))
          (setq found (cons (match-beginning 0) (match-end 0)))))
      found)))

(defun keycap--number-sign (start)
  "The sign in front of the number at START: (POSITION . OPERATOR), or nil.
OPERATOR is non-nil for a binary `+' or `-', which then carries the sign."
  (save-excursion
    (goto-char start)
    (skip-chars-backward " \t")
    (when (memq (char-before) '(?+ ?-))
      (let ((position (1- (point))))
        (goto-char position)
        (skip-chars-backward " \t\n")
        (let ((operator (or (memq (char-syntax (or (char-before) ?\s)) '(?w ?_ ?\) ?\"))
                            (eq (char-before) ?`))))
          (when (or operator (= position (1- start)))
            (cons position operator)))))))

(defun keycap--number-name (start)
  "What the number at START is: the name assigned it, the call it goes to, or nil."
  (save-excursion
    (goto-char start)
    (skip-chars-backward " \t+-")
    (if (looking-back "\\_<\\([[:alpha:]_][[:alnum:]_]*\\)[ \t]*[=:][ \t]*"
                      (line-beginning-position))
        (match-string-no-properties 1)
      (goto-char start)
      (car (keycap--call)))))

(defun keycap--nudge (n)
  "Add N units of the digit before point to the number at point.
Return the number before and after, as written, and the unit, as strings."
  (pcase-let* ((`(,start . ,end) (or (keycap--number-at-point)
                                     (user-error "No number at point")))
               (text (buffer-substring-no-properties start end))
               (dot (string-search "." text))
               (decimals (if dot (- (length text) dot 1) 0))
               ;; The digit before point, else the last one.
               (digit (let ((index (- (point) start 1)))
                        (cond
                         ((< index 0) (1- (length text)))
                         ((eql index dot) (1- index))
                         (t (min index (1- (length text)))))))
               (unit (if (and dot (> digit dot))
                         (- decimals (- digit dot))
                       (+ decimals (- (or dot (length text)) digit 1))))
               (`(,sign . ,operator) (keycap--number-sign start))
               (negative (and sign (eq (char-after sign) ?-)))
               (value (* (if negative -1 1) (string-to-number (string-replace "." "" text))))
               (value (+ value (* n (expt 10 unit))))
               (digits (number-to-string (abs value)))
               (digits (if (> decimals 0)
                           (let ((digits (string-pad digits (1+ decimals) ?0 t)))
                             (concat (substring digits 0 (- decimals)) "."
                                     (substring digits (- decimals))))
                         digits))
               (from-end (- end (point))))
    (cond
     (operator
      (unless (zerop value)
        (save-excursion
          (goto-char sign)
          (delete-char 1)
          (insert (if (< value 0) "-" "+")))))
     (sign (setq start sign)))
    (goto-char start)
    (delete-region start end)
    (insert (if (and (< value 0) (not operator)) "-" "") digits)
    (goto-char (max start (- (point) (max 0 from-end))))
    (list (concat (if negative "-" "") text)
          (concat (if (< value 0) "-" "") digits)
          ;; The unit counts in the number's last decimal.
          (let ((power (- unit decimals)))
            (if (< power 0)
                (format (format "%%.%df" (- power)) (expt 10.0 power))
              (number-to-string (expt 10 power)))))))

(defvar-keymap keycap-number-repeat-map
  :doc "Keys that nudge a number again, right after it was nudged."
  "n" #'keycap-increase-number
  "p" #'keycap-decrease-number)

(defun keycap--nudge-text (name before after unit)
  "What the echo area says of the number NAME going from BEFORE to AFTER by UNIT."
  (format "%s%s → %s (step %s)" (if name (concat name " ") "") before after unit))

(defun keycap-nudge (n)
  "Add N units of the digit before point to the number at point.
Return what the echo area says of it, such as \"width 2.5 → 2.6 (step 0.1)\"."
  (let ((name (when-let* ((number (keycap--number-at-point)))
                (keycap--number-name (car number)))))
    (pcase-let ((`(,before ,after ,unit) (keycap--nudge n)))
      (keycap--nudge-text name before after unit))))

(defun keycap--nudge-and-repeat (n)
  "Nudge the number at point by N units, then let `n' and `p' nudge it again."
  (let ((text (keycap-nudge n)))
    (keycap--load-now)
    (message "%s; %s"
             text
             (substitute-command-keys
              "\\<keycap-number-repeat-map>\\[keycap-increase-number], \\[keycap-decrease-number] again"))
    (set-transient-map keycap-number-repeat-map)))

(defun keycap-increase-number (n)
  "Add N units of the digit before point to the number at point.
Without a digit of the number before point, the unit is its last digit's.
A number after a binary minus counts as negative.  The preview follows.
Then \\<keycap-number-repeat-map>\\[keycap-increase-number] and \\[keycap-decrease-number] \
nudge it again, until another key."
  (interactive "p" keycap-mode)
  (keycap--nudge-and-repeat n))

(defun keycap-decrease-number (n)
  "Subtract N units of the digit before point from the number at point.
See `keycap-increase-number'."
  (interactive "p" keycap-mode)
  (keycap--nudge-and-repeat (- n)))


;; --- Numbers under the mouse ---

;; The mouse nudges the digit it is on, as the keys nudge the digit before
;; point.  Off a number, its gestures do what they would without keycap.

(defun keycap--event-pixel (event)
  "Where the mouse EVENT happened, in pixels from the frame's corner, or nil."
  (let* ((position (event-start event))
         (window (posn-window position))
         (xy (posn-x-y position)))
    (when (and (windowp window) xy)
      (let ((edges (window-inside-pixel-edges window)))
        (cons (+ (car edges) (car xy)) (+ (cadr edges) (cdr xy)))))))

(defun keycap--number-at-mouse (event)
  "The position of the digit the mouse EVENT is on, or nil off a number."
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (position (posn-point posn)))
    (when (and (windowp window) position (not (posn-area posn)))
      (with-current-buffer (window-buffer window)
        (when (derived-mode-p 'keycap-mode)
          (save-excursion
            (goto-char position)
            (when-let* ((number (keycap--number-at-point))
                        ((< position (cdr number))))
              position)))))))

(defun keycap--mouse-fall-through (event)
  "Do with the mouse EVENT what Emacs does with it outside `keycap-mode'."
  (when-let* ((command (global-key-binding (vector (car event)))))
    (call-interactively command nil (vector event))))

(defun keycap--wheel-direction (event)
  "1 for the mouse wheel EVENT turning up, -1 for down."
  (if (eq (event-basic-type event) 'wheel-up) 1 -1))

(defun keycap-mouse-nudge-number (event)
  "Nudge the number under the mouse by a step of the digit under it.
The wheel EVENT turning up adds, down subtracts; the preview follows.
Off a number, the wheel scrolls as it would."
  (interactive "e" keycap-mode)
  (if-let* ((digit (keycap--number-at-mouse event)))
      (with-selected-window (posn-window (event-start event))
        (goto-char (1+ digit))
        (let ((text (keycap-nudge (keycap--wheel-direction event))))
          (keycap--load-now)
          (message "%s" text)))
    (keycap--mouse-fall-through event)))

(defun keycap-mouse-scrub-number (event)
  "Change the number under the mouse as it drags right or left, from EVENT.
Each column the mouse moves is a step of the digit it started on, and
the preview follows as fast as the script evaluates; the whole drag
undoes as one change.  Off a number, the click does what it would."
  (interactive "e" keycap-mode)
  (if-let* ((digit (keycap--number-at-mouse event)))
      (progn
        (select-window (posn-window (event-start event)))
        (goto-char (1+ digit))
        (let ((name (keycap--number-name (car (keycap--number-at-point))))
              (start (car (keycap--event-pixel event)))
              (column (frame-char-width))
              (group (prepare-change-group))
              (steps 0)
              first
              movement)
          (activate-change-group group)
          (unwind-protect
              (track-mouse
                (while (mouse-movement-p (setq movement (read-event)))
                  (when-let* ((now (car (keycap--event-pixel movement)))
                              (n (- (truncate (- now start) column) steps))
                              ((/= n 0)))
                    (pcase-let ((`(,before ,after ,unit) (keycap--nudge n)))
                      (setq steps (+ steps n)
                            first (or first before))
                      (message "%s" (keycap--nudge-text name first after unit)))
                    ;; Loads queue up in the server; one at a time keeps
                    ;; the preview close behind the mouse.
                    (when (and (buffer-live-p keycap--preview) (not keycap--load-waiting))
                      (keycap--load)))))
            (accept-change-group group)
            (undo-amalgamate-change-group group)
            (keycap--load-now))))
    (keycap--mouse-fall-through event)))


;; --- Mode ---

(defvar-keymap keycap-mode-map
  :doc "Keymap for `keycap-mode'."
  "C-c C-c" #'keycap-preview
  "C-c C-v" #'keycap-preview-cycle-view
  "C-c C-e" #'keycap-export-stl
  "C-c C-l" #'keycap-export-2d
  "C-c C-k" #'keycap-export-cancel
  "C-c C-d" #'keycap-describe
  "C-c C-n" #'keycap-increase-number
  "C-c C-p" #'keycap-decrease-number
  "C-x C-e" #'keycap-eval-last-expression
  "S-<wheel-up>" #'keycap-mouse-nudge-number
  "S-<wheel-down>" #'keycap-mouse-nudge-number
  "S-<down-mouse-1>" #'keycap-mouse-scrub-number)

(easy-menu-define keycap-mode-menu keycap-mode-map
  "Menu for `keycap-mode'."
  '("Keycap"
    ["Preview" keycap-preview]
    ["Next View" keycap-preview-cycle-view]
    "---"
    ["Increase Number" keycap-increase-number]
    ["Decrease Number" keycap-decrease-number]
    ["Evaluate Expression" keycap-eval-last-expression]
    "---"
    ["Describe..." keycap-describe]
    ["Reference" (keycap-describe nil (current-buffer)) :keys "C-u C-c C-d"]
    ["Manual" keycap-guide]
    "---"
    ["Export STL..." keycap-export-stl]
    ["Export 2D..." keycap-export-2d]
    ["Cancel Export" keycap-export-cancel :active keycap--export]))

(defun keycap-context-menu (menu click)
  "Add to MENU a description of the name the mouse CLICK is on, if it has one.
For `context-menu-functions'."
  (when-let* ((name (save-excursion
                      (mouse-set-point click)
                      (keycap-name-at-point)))
              ((keycap--doc name)))
    (define-key-after menu [keycap-separator] menu-bar-separator)
    (define-key-after menu [keycap-describe]
      `(menu-item ,(format "Describe %s" name)
                  ,(lambda ()
                     (interactive)
                     (keycap-describe name (current-buffer)))
                  :help "Show its documentation")))
  menu)

;;;###autoload
(define-derived-mode keycap-mode rhai-ts-mode "keycap"
  "Major mode for fidget scripts, in keycap's dialect or in fidget's own.
`.keycap' files are in keycap's, `.fidget' files in fidget's; see
`keycap-dialect'.

\\{keycap-mode-map}"
  (setq keycap-dialect (if (string-match-p "\\.fidget\\'" (or buffer-file-name ""))
                           'fidget
                         'keycap))
  (add-hook 'flymake-diagnostic-functions #'keycap-flymake nil t)
  (add-hook 'completion-at-point-functions #'keycap-completion-at-point nil t)
  (add-hook 'eldoc-documentation-functions #'keycap-eldoc-function nil t)
  (add-hook 'context-menu-functions #'keycap-context-menu 10 t)
  (add-hook 'after-change-functions #'keycap--change nil t)
  (add-hook 'keycap--load-functions #'keycap--watch nil t)
  (add-hook 'keycap--load-functions #'keycap--remember-functions nil t)
  (add-hook 'kill-buffer-hook #'keycap--stop-server nil t)
  (add-hook 'kill-buffer-hook #'keycap--unwatch nil t)
  (add-hook 'change-major-mode-hook #'keycap--stop-server nil t)
  (add-hook 'change-major-mode-hook #'keycap--unwatch nil t)
  ;; Reverted, the script has a preview but no server.
  (when (buffer-live-p keycap--preview)
    (keycap--reload))
  ;; A file-local `keycap-dialect' comes after the mode.
  (add-hook 'hack-local-variables-hook #'keycap--use-dialect nil t)
  (keycap--use-dialect))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.\\(?:keycap\\|fidget\\)\\'" . keycap-mode))

(provide 'keycap)

;;; keycap.el ends here
