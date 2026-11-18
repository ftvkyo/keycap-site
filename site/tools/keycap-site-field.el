;;; keycap-site-field.el --- keycap's site: the front page's field  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rei Stepanenko
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The field at the top of the front page is content/field.keycap, its
;; distance bands drawn in characters: a frame for each step of its `T'
;; through the loop, all of them in one block that the stylesheet moves up
;; a frame at a time behind a window a frame high.  The values are the
;; server's, probed at the middle of each character.  content/field.html
;; is written afresh on every build.
;;
;; Loaded by publish.el, on top of its page frame.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'keycap)

(defconst keycap-site-field-frames 36
  "The frames of the loop.
The box's corners, the fastest points, move about a column from one to
the next, a step as fine as the characters can show.")

(defconst keycap-site-field-columns 70)

(defconst keycap-site-field-lines 15)

(defconst keycap-site-field-cell '(13 . 25)
  "A character's width and height in the probed render's pixels.
Odd, so that a pixel's middle is the character's; their ratio is that of
the field's line height, 1.15em, to Maple Mono's advance, 0.6em, so the
shapes are not squashed.")

(defconst keycap-site-field-bands " .:-=+*"
  "The marks of the bands outside the surface, each 1.6 wide, the nearest last.
Every other band is left blank.")

(defun keycap-site-field-char (value)
  "The character for the field's VALUE: a mark of the surface or of its band."
  (let ((bands (length keycap-site-field-bands)))
    (cond ((<= value -1.2) ?@)
          ((<= value 0) ?#)
          (t (let ((band (floor value 1.6)))
               (if (and (cl-evenp band) (< band bands))
                   (aref keycap-site-field-bands (- bands 1 band))
                 ?\s))))))

(defun keycap-site-field-probes ()
  "A probe of the middle of each character, line by line."
  (pcase-let ((`(,width . ,height) keycap-site-field-cell))
    (cl-loop for line below keycap-site-field-lines
             append (cl-loop for column below keycap-site-field-columns
                             collect `((op . "probe")
                                       (x . ,(+ (* column width) (/ width 2)))
                                       (y . ,(+ (* line height) (/ height 2))))))))

(defun keycap-site-field-values (file)
  "The field of the script FILE in each frame: a list of values for each line.
One server loads the script with each frame's `T' and probes it.  A probe
finds its point in the last render, so the first frame's is the only one,
its image not needed: the bounds, and so the render's view, stay put."
  (pcase-let* ((`(,width . ,height) keycap-site-field-cell)
               (source (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))
               (image (make-temp-file "keycap-site-field" nil ".ppm"))
               (probes (keycap-site-field-probes))
               (replies
                (unwind-protect
                    (keycap-server-batch
                     (cl-loop for frame below keycap-site-field-frames
                              append `(((op . "load")
                                        (source . ,source)
                                        (path . ,file)
                                        (dialect . "keycap")
                                        (overrides . ((T . ,(/ (float frame) keycap-site-field-frames)))))
                                       ,@(when (= frame 0)
                                           `(((op . "render")
                                              (output . ,image)
                                              (width . ,(* keycap-site-field-columns width))
                                              (height . ,(* keycap-site-field-lines height))
                                              (view . "mono")
                                              (backend . "cpu"))))
                                       ,@probes)))
                  (delete-file image))))
    (cl-flet ((next ()
                (let ((reply (pop replies)))
                  (when-let* ((failure (if (assq 'loaded reply)
                                           (keycap-report-failure reply)
                                         (alist-get 'error reply))))
                    (error "%s: %s" file failure))
                  reply)))
      (cl-loop for frame below keycap-site-field-frames
               collect (progn
                         (next)
                         (when (= frame 0)
                           (next))
                         (seq-partition (cl-loop repeat (length probes)
                                                 collect (alist-get 'value (next)))
                                        keycap-site-field-columns))))))

(defun keycap-site-field-line (values)
  "The line of the field's VALUES in HTML, each run of the surface in a span."
  (let ((line (string-trim-right (apply #'string (mapcar #'keycap-site-field-char values)))))
    (replace-regexp-in-string "[#@]+" "<span class=\"surface\">\\&</span>" line)))

(defun keycap-site-write-field ()
  "Write content/field.html, the frames of content/field.keycap."
  (let ((file (keycap-site-path "content" "field.keycap")))
    (with-temp-file (keycap-site-path "content" "field.html")
      (insert (format "<pre class=\"field\" aria-hidden=\"true\" style=\"--frames: %d\"><span>"
                      keycap-site-field-frames)
              (mapconcat (lambda (lines)
                           (mapconcat #'keycap-site-field-line lines "\n"))
                         (keycap-site-field-values file)
                         "\n")
              "</span></pre>\n"))))

(provide 'keycap-site-field)

;;; keycap-site-field.el ends here
