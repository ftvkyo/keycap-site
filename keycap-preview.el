;;; keycap-preview.el --- Model preview for keycap  -*- lexical-binding: t; -*-

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

;; The model of a `keycap-mode' script, rendered beside it by the
;; script's keycap-server process: shaded or as a heightmap in 3D, as an
;; sdf (the distance field) or mono (inside and outside) on a slice in
;; 2D.  It follows the script as it changes; the mouse turns, moves and
;; zooms it, reads the model under the pointer into the header line, and
;; goes from a shape to its `draw'.

;;; Code:

(require 'color)
(require 'keycap)
(require 'pulse)

;; Defined only in Emacs built with image support, which a preview needs.
(declare-function image-flush "image.c")
(declare-function image-size "image.c")


;; --- Customization ---

(defcustom keycap-preview-view 'shaded
  "The preview's view of a 3D model.
A 2D model, unbounded along Z, starts in `sdf' instead."
  :type '(choice (const :tag "Shaded" shaded)
                 (const :tag "Heightmap, the depth as grey" heightmap)
                 (const :tag "SDF, the distance field on a slice" sdf)
                 (const :tag "Mono, inside and outside on a slice" mono))
  :group 'keycap)

(defcustom keycap-preview-bounds 'script
  "Which bounds the preview shows: the script's or ones fitted to the model.
Without a `bounds' call in the script, the fitted ones stand in."
  :type '(choice (const script) (const fitted))
  :group 'keycap)

(defcustom keycap-preview-backend 'gpu
  "Where the preview renders; without a GPU, the CPU stands in."
  :type '(choice (const gpu) (const cpu))
  :group 'keycap)

(defcustom keycap-preview-projection 'orthographic
  "The projection of the 3D views."
  :type '(choice (const orthographic) (const perspective))
  :group 'keycap)

(defcustom keycap-preview-output-lines 4
  "Lines of the script's `print' output shown below the model, at most."
  :type 'natnum
  :group 'keycap)

(defcustom keycap-preview-drag-resolution 0.5
  "The share of the full resolution a camera drag's frames start at.
Fewer pixels render sooner and follow the mouse more closely; as the
drag goes on, the share follows `keycap-preview-drag-frame-time', never
above this.  The frame the drag ends on is in full."
  :type 'number
  :group 'keycap)

(defcustom keycap-preview-drag-frame-time 0.05
  "Seconds a frame should take while the mouse drags the camera, or nil.
Slower frames have fewer pixels, down to a quarter of the full
resolution each way, or to the share below which they rendered no
sooner; faster ones have more, up to `keycap-preview-drag-resolution'.
nil keeps every frame of a drag at that share."
  :type '(choice number (const nil))
  :group 'keycap)

(defcustom keycap-preview-probe-interval 0.05
  "Seconds between two readings of the model under the mouse."
  :type 'number
  :group 'keycap)


;; --- State ---

(defconst keycap--preview-views '(shaded heightmap sdf mono)
  "The preview's views, in the order they cycle in.")

(defconst keycap--preview-step 15
  "Degrees one orbit command turns the camera.")

(defconst keycap--preview-tilt-step 5
  "Degrees one tilt command turns the slice.")

(defconst keycap--preview-drag-least 0.25
  "The least share of the full resolution a drag's frames go down to.")

(defconst keycap--preview-cameras
  '((front -90 0) (right 0 0) (top -90 90) (iso -60 30))
  "The cameras with a name, each (NAME AZIMUTH ELEVATION).")

(defconst keycap--preview-display-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . right)
    (window-width . 0.5))
  "How the preview is shown, unless `display-buffer-alist' says otherwise.")

(defvar-local keycap--preview-source nil
  "The preview's script buffer.")

(defvar-local keycap--preview-directory nil
  "Where the preview keeps its frame.")

(defvar-local keycap--preview-report nil
  "The server's reply to the last `load' that succeeded.")

(defvar-local keycap--preview-output nil
  "The lines the script printed when it was last evaluated.")

(defvar-local keycap--preview-failure nil
  "Why the script fails to load, or nil.")

(defvar-local keycap--preview-frame nil
  "The server's reply to the render shown.")

(defvar-local keycap--preview-render-error nil
  "Why the last render failed, or nil.")

(defvar-local keycap--preview-rendering nil
  "While a render runs, the id of its request.")
(defvar-local keycap--preview-render-start nil)
(defvar-local keycap--preview-sent-scene nil
  "The server and scene of the last render sent, as (PROCESS . SCENE).")
(defvar-local keycap--preview-pending nil
  "Non-nil when the preview needs another render once this one is done.")

(defvar-local keycap--preview-dragging nil
  "Non-nil while the mouse drags the camera.")
(defvar-local keycap--preview-drag-share nil
  "The share of the full resolution the drag's next frame has.")
(defvar-local keycap--preview-drag-floor nil
  "The least share the drag goes down to, when it found one.")
(defvar-local keycap--preview-drag-last nil
  "The drag's last frame, as (SHARE . SECONDS), or nil.")

(defvar-local keycap--preview-image nil)
(defvar-local keycap--preview-scale nil
  "How much denser than the window the image shown is.")
(defvar-local keycap--preview-size nil
  "The window size, as `keycap--preview-window-size' has it, of the last render.")

(defvar-local keycap--preview-view nil)
(defvar-local keycap--preview-view-chosen nil
  "Non-nil once the view was picked by hand rather than for the model.")
(defvar-local keycap--preview-bounds nil)
(defvar-local keycap--preview-backend nil)
(defvar-local keycap--preview-azimuth nil)
(defvar-local keycap--preview-elevation nil)
(defvar-local keycap--preview-zoom nil)
(defvar-local keycap--preview-pan nil
  "(RIGHT . UP), in halves of the image's height.")
(defvar-local keycap--preview-projection nil)
(defvar-local keycap--preview-axis nil
  "The axis the slice of the 2D views is normal to.")
(defvar-local keycap--preview-offset nil
  "Where the slice of the 2D views lies along `keycap--preview-axis'.")
(defvar-local keycap--preview-offset-chosen nil
  "Non-nil once the slice was moved by hand rather than kept in the middle.")
(defvar-local keycap--preview-tilt nil
  "(RIGHT . UP), the degrees the slice turns about the image's right, then up.
It turns about the middle of the bounds, by the right-hand rule.")

(defvar-local keycap--preview-readout nil
  "The reading of the model under the mouse, for the header line.")
(defvar-local keycap--preview-probing nil
  "Non-nil while a reading runs, or waits out `keycap-preview-probe-interval'.")
(defvar-local keycap--preview-probe-next nil
  "The pixel to read once the reading that runs is done.")
(defvar-local keycap--preview-leave-timer nil)

(defun keycap--preview-2d-p ()
  "Non-nil when the preview is of a slice."
  (memq keycap--preview-view '(sdf mono)))

(defun keycap--preview-tilted-p ()
  "Non-nil when the slice is tilted."
  (not (and (zerop (car keycap--preview-tilt)) (zerop (cdr keycap--preview-tilt)))))

(defun keycap--preview-frame-file ()
  "Where the server writes the frame."
  (expand-file-name "frame.ppm" keycap--preview-directory))

(defun keycap--preview-region ()
  "The bounds in use, as (LOWER UPPER), unbounded axes nil, or nil."
  (let* ((bounds (alist-get 'bounds keycap--preview-report))
         (kind (if keycap--preview-frame
                   (alist-get 'bounds keycap--preview-frame)
                 (symbol-name keycap--preview-bounds)))
         (used (or (and (equal kind "script") (alist-get 'script bounds))
                   (alist-get 'fitted bounds))))
    (when used
      (list (alist-get 'lower used) (alist-get 'upper used)))))

(defun keycap--preview-middle (axis)
  "The middle of the bounds in use along AXIS, or 0 where they are unbounded."
  (pcase-let* ((`(,lower ,upper) (keycap--preview-region))
               (i (seq-position '(x y z) axis)))
    (if (and (nth i lower) (nth i upper))
        (/ (+ (nth i lower) (nth i upper)) 2.0)
      0)))


;; --- Loading ---

(put 'keycap--preview-loaded 'permanent-local-hook t)
(defun keycap--preview-loaded (reply)
  "Take the script's `load' REPLY into its preview, and render it."
  (when (buffer-live-p keycap--preview)
    (with-current-buffer keycap--preview
      (setq keycap--preview-failure (keycap-report-failure reply))
      (unless (alist-get 'error reply)
        (setq keycap--preview-output (alist-get 'output reply)))
      (unless keycap--preview-failure
        (setq keycap--preview-report reply)
        (unless keycap--preview-view-chosen
          (keycap--preview-set-view (if (keycap-report-flat-p reply) 'sdf keycap-preview-view)))
        ;; A 2D script that grew a third dimension would be sliced at its base.
        (unless keycap--preview-offset-chosen
          (setq keycap--preview-offset (keycap--preview-middle keycap--preview-axis)))
        ;; The frame in progress shows the script as it was, unless the
        ;; edit changed nothing drawn.
        (unless (and (alist-get 'scene reply)
                     (equal (keycap--preview-scene reply) keycap--preview-sent-scene))
          (keycap--preview-render t))
        (keycap--preview-hint))
      (keycap--preview-redisplay)
      (force-mode-line-update))))

(defun keycap--preview-scene (report)
  "The server and scene of the `load' REPORT, as (PROCESS . SCENE)."
  (cons (buffer-local-value 'keycap--server keycap--preview-source)
        (alist-get 'scene report)))

(defun keycap--preview-set-view (view)
  "Show VIEW; from 3D to 2D, slice through the middle of the bounds."
  (when (and (memq view '(sdf mono)) (not (keycap--preview-2d-p)))
    (setq keycap--preview-offset (keycap--preview-middle keycap--preview-axis)))
  (setq keycap--preview-view view))


;; --- Rendering ---

(defun keycap--preview-output-shown ()
  "The lines of output shown below the image."
  (last keycap--preview-output keycap-preview-output-lines))

(defun keycap--preview-window-size (window)
  "The body size of WINDOW in pixels, as if the echo area had one line.
It is (WIDTH . HEIGHT).  A message of several lines, such as ElDoc's,
takes them from the windows above the echo area for a while; a frame
cut off at the bottom meanwhile is better than two renders."
  (let ((echo (minibuffer-window (window-frame window))))
    (cons (window-body-width window t)
          (+ (window-body-height window t)
             (if (and (eq (window-frame echo) (window-frame window))
                      (window-at-side-p window 'bottom))
                 (max 0 (- (window-pixel-height echo) (window-default-line-height echo)))
               0)))))

(defun keycap--preview-image-size (window)
  "The size in pixels of the image WINDOW has room for above the output."
  (pcase-let ((`(,width . ,height) (keycap--preview-window-size window)))
    (cons width
          (max 1 (- height
                    (* (length (keycap--preview-output-shown))
                       (window-default-line-height window)))))))

(defun keycap--preview-render (&optional now)
  "Render the model into the preview, or once it is in a window.
While a render runs, this waits for it, then renders what is current;
with NOW, it renders at once, and the server drops the render that runs."
  (let ((window (get-buffer-window (current-buffer) t)))
    (cond
     ((not keycap--preview-report))
     ;; A server that stopped lost the script; its next `load' renders.
     ((not (process-live-p (buffer-local-value 'keycap--server keycap--preview-source)))
      (with-current-buffer keycap--preview-source
        (keycap--reload)))
     ;; `keycap--preview-resized' renders once a window shows it.
     ((not window) (setq keycap--preview-size nil))
     ((and keycap--preview-rendering (not now)) (setq keycap--preview-pending t))
     (t
      (let ((scale (* (frame-scale-factor (window-frame window))
                      (if keycap--preview-dragging keycap--preview-drag-share 1)))
            (size (keycap--preview-image-size window)))
        (setq keycap--preview-size (keycap--preview-window-size window))
        (keycap--preview-send (round (* scale (car size))) (round (* scale (cdr size)))
                              scale))))
    (force-mode-line-update)))

(defun keycap-preview-request (width height)
  "The `render' request for a WIDTH by HEIGHT frame of what the preview shows."
  `((op . "render")
    (output . ,(keycap--preview-frame-file))
    (width . ,width)
    (height . ,height)
    (view . ,(symbol-name keycap--preview-view))
    (bounds . ,(symbol-name keycap--preview-bounds))
    (backend . ,(symbol-name keycap--preview-backend))
    (camera . ((azimuth . ,keycap--preview-azimuth)
               (elevation . ,keycap--preview-elevation)
               (zoom . ,keycap--preview-zoom)
               (pan . ,(vector (car keycap--preview-pan) (cdr keycap--preview-pan)))
               (orthographic . ,(if (eq keycap--preview-projection 'orthographic) t :false))))
    (slice . ((axis . ,(symbol-name keycap--preview-axis))
              (offset . ,keycap--preview-offset)
              (tilt . ,(vector (car keycap--preview-tilt) (cdr keycap--preview-tilt)))))
    (background . ,(keycap--preview-background))))

(defun keycap--preview-background ()
  "Emacs' background, as an RGB vector of 0 to 1."
  (vconcat (or (color-name-to-rgb (face-background 'default nil t))
               '(0 0 0))))

(defun keycap--preview-send (width height scale)
  "Ask the server for a WIDTH by HEIGHT frame, to show SCALE times denser."
  (let ((preview (current-buffer))
        (request (keycap-preview-request width height))
        (dragged keycap--preview-dragging)
        id)
    (condition-case error
        (progn
          (setq id (with-current-buffer keycap--preview-source
                     (keycap--request request
                                      (lambda (reply)
                                        (when (buffer-live-p preview)
                                          (with-current-buffer preview
                                            ;; Unless a newer render superseded it
                                            (when (eql id keycap--preview-rendering)
                                              (keycap--preview-rendered reply scale dragged))))))))
          (setq keycap--preview-rendering id
                keycap--preview-pending nil
                keycap--preview-render-start (float-time)
                keycap--preview-sent-scene (keycap--preview-scene keycap--preview-report))
          ;; Quick renders would only flicker in the header line.
          (run-with-timer 0.3 nil #'keycap--preview-update preview))
      (error
       (setq keycap--preview-render-error
             (propertize (error-message-string error) 'face 'error))))))

(defun keycap--preview-update (preview)
  "Redraw the header line of PREVIEW, if it is alive."
  (when (buffer-live-p preview)
    (with-current-buffer preview
      (force-mode-line-update))))

(defun keycap--preview-rendered (reply scale dragged)
  "Show the frame the server's REPLY is about, rendered SCALE times denser.
DRAGGED is non-nil for a frame of a drag.  Then render again if needed."
  (setq keycap--preview-rendering nil)
  (cond
   ;; Neither shows the scene it was sent for, which an edit then renders.
   ((alist-get 'cancelled reply)
    (setq keycap--preview-sent-scene nil))
   ((alist-get 'error reply)
    (setq keycap--preview-sent-scene nil
          keycap--preview-render-error (propertize (alist-get 'error reply) 'face 'error)))
   (t
    (when dragged
      (keycap--preview-drag-adapt (- (float-time) keycap--preview-render-start)))
    (setq keycap--preview-frame reply
          keycap--preview-render-error nil
          keycap--preview-readout nil)
    (keycap--preview-show scale)
    ;; The reading was of the last frame; the mouse may still be over this one.
    (when-let* ((keycap--preview-leave-timer)
                (window (get-buffer-window (current-buffer) t))
                (pixel (keycap--preview-mouse-pixel window)))
      (setq keycap--preview-probe-next pixel)
      (unless keycap--preview-probing
        (keycap--preview-probe)))))
  (when keycap--preview-pending
    (setq keycap--preview-pending nil)
    (keycap--preview-render))
  (force-mode-line-update))

(defun keycap--preview-drag-adapt (seconds)
  "Pick the share of the drag's next frame, its last having taken SECONDS.
The time goes with the pixels, so with the square of the share; once a
share renders hardly sooner than the larger one before it, the drag goes
no lower than that."
  (let ((share keycap--preview-drag-share)
        (last keycap--preview-drag-last)
        (target keycap-preview-drag-frame-time))
    (setq keycap--preview-drag-last (cons share seconds))
    (cond
     ((not target))
     ((and last (< share (* 0.9 (car last))) (> seconds (* 0.9 (cdr last))))
      (setq keycap--preview-drag-floor (car last)
            keycap--preview-drag-share (car last)))
     ;; Near enough: a frame size that stays keeps the server's buffers.
     ((< 0.8 (/ seconds target) 1.25))
     (t
      (setq keycap--preview-drag-share
            (min keycap-preview-drag-resolution
                 (max (or keycap--preview-drag-floor keycap--preview-drag-least)
                      (* share (sqrt (/ target seconds))))))))))

(defun keycap--preview-flush ()
  "Drop the shown frame from the image cache."
  (when (and keycap--preview-image (display-images-p))
    (image-flush keycap--preview-image)))

(defun keycap--preview-show (scale)
  "Show the frame, rendered for a SCALE times denser display."
  (keycap--preview-flush)
  (let ((file (keycap--preview-frame-file)))
    (setq keycap--preview-scale scale
          keycap--preview-image
          (create-image (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally file)
                          (buffer-string))
                        'pbm t :scale (/ 1.0 scale))))
  (keycap--preview-redisplay))

(defun keycap--preview-redisplay ()
  "Fill the preview with the frame, then the script's output."
  (let ((inhibit-read-only t))
    (erase-buffer)
    ;; Not `insert-image', whose keys and menu would turn and scale the
    ;; frame rather than the camera.
    (when keycap--preview-image
      (insert (propertize " " 'display keycap--preview-image 'help-echo #'keycap--preview-hover)))
    (dolist (line (keycap--preview-output-shown))
      (insert (if (bobp) "" "\n") (propertize line 'face 'shadow)))
    (goto-char (point-min))))

(defun keycap--preview-resized (window)
  "Render again when WINDOW, showing the preview, changed its size."
  (with-current-buffer (window-buffer window)
    (unless (equal keycap--preview-size (keycap--preview-window-size window))
      (keycap--preview-render))))


;; --- Readout ---

(defun keycap--preview-mouse-pixel (window)
  "The frame's pixel under the mouse in WINDOW, as (X . Y), or nil."
  (pcase-let ((`(,frame ,x . ,y) (mouse-pixel-position)))
    (when (and keycap--preview-image x (eq frame (window-frame window)))
      (pcase-let ((`(,left ,top . ,_) (window-inside-pixel-edges window))
                  (`(,width . ,height) (image-size keycap--preview-image t (window-frame window))))
        (let ((x (- x left))
              (y (- y top)))
          (when (and (<= 0 x) (< x width) (<= 0 y) (< y height))
            (cons (floor (* x keycap--preview-scale))
                  (floor (* y keycap--preview-scale)))))))))

(defun keycap--preview-hover (window _object _position)
  "Read the model under the mouse in WINDOW; as `help-echo', show nothing."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when-let* (((derived-mode-p 'keycap-preview-mode))
                  (pixel (keycap--preview-mouse-pixel window)))
        (setq keycap--preview-probe-next pixel)
        (unless keycap--preview-probing
          (keycap--preview-probe))
        (unless keycap--preview-leave-timer
          (setq keycap--preview-leave-timer
                (run-with-timer 0.2 0.2 #'keycap--preview-left (current-buffer)))))))
  nil)

(defun keycap--preview-probe ()
  "Read the model at `keycap--preview-probe-next', if any.
The next reading waits for this one and `keycap-preview-probe-interval'."
  (if-let* ((pixel keycap--preview-probe-next)
            ((buffer-live-p keycap--preview-source)))
      (let ((preview (current-buffer))
            (frame keycap--preview-frame))
        (setq keycap--preview-probe-next nil
              keycap--preview-probing t)
        (with-current-buffer keycap--preview-source
          (keycap--request
           `((op . "probe") (x . ,(car pixel)) (y . ,(cdr pixel)))
           (lambda (reply)
             (when (buffer-live-p preview)
               (with-current-buffer preview
                 (when (and (eq frame keycap--preview-frame) keycap--preview-leave-timer)
                   (keycap--preview-read reply))
                 (run-with-timer keycap-preview-probe-interval nil
                                 #'keycap--preview-probe-again preview)))))))
    (setq keycap--preview-probing nil)))

(defun keycap--preview-probe-again (preview)
  "Read the model in PREVIEW again, if the mouse moved meanwhile."
  (when (buffer-live-p preview)
    (with-current-buffer preview
      (keycap--preview-probe))))

(defun keycap--preview-digits ()
  "How many decimals tell one pixel of the frame from the next."
  (let ((scale (alist-get 'scale keycap--preview-frame)))
    (if (and scale (> scale 0))
        (max 0 (min 6 (- (floor (log scale 10)))))
      2)))

(defun keycap--preview-decimal (number digits)
  "NUMBER with DIGITS decimals, and no sign when it rounds to zero."
  (let ((text (format (format "%%.%df" digits) number)))
    (if (string-match-p "\\`-[0.]+\\'" text) (substring text 1) text)))

(defun keycap--preview-read (reply)
  "Show the server's REPLY to a probe in the header line.
The coordinate along a level slice's axis in 2D views goes without
saying, and so does the field on the surface, about 0, in 3D ones."
  (let ((position (alist-get 'position reply))
        (value (alist-get 'value reply))
        (digits (keycap--preview-digits)))
    (setq keycap--preview-readout
          (when position
            (concat (string-join
                     (delq nil (seq-mapn (lambda (axis coordinate)
                                           (unless (and (keycap--preview-2d-p)
                                                        (not (keycap--preview-tilted-p))
                                                        (eq axis keycap--preview-axis))
                                             (format "%s %s" axis (keycap--preview-decimal
                                                                   coordinate digits))))
                                         '(x y z) position))
                     "  ")
                    (when (and value (keycap--preview-2d-p))
                      (concat "  = " (keycap--preview-decimal value (1+ digits)))))))
    (force-mode-line-update)))

(defun keycap--preview-left (preview)
  "Clear the reading of PREVIEW once the mouse left its image."
  (when (buffer-live-p preview)
    (with-current-buffer preview
      (unless (seq-some #'keycap--preview-mouse-pixel (get-buffer-window-list preview nil t))
        (cancel-timer keycap--preview-leave-timer)
        (setq keycap--preview-leave-timer nil
              keycap--preview-readout nil)
        (force-mode-line-update)))))


;; --- Header line ---

;; The header line's words for the view, the camera or slice, the bounds
;; and the backend are buttons: a click switches what they say, or offers
;; the choices in a menu, as the mode line's do.

(defvar-keymap keycap--preview-button-map
  :doc "Keys of the buttons in the preview's header line."
  "<header-line> <mouse-1>" #'keycap-preview-header-click)

(defvar-keymap keycap--preview-offset-map
  :doc "Keys of the slice's offset in the preview's header line."
  :parent keycap--preview-button-map
  "<header-line> <wheel-up>" #'keycap-preview-mouse-slice-step
  "<header-line> <wheel-down>" #'keycap-preview-mouse-slice-step)

(defun keycap--preview-button (text command help &optional map)
  "TEXT as a header line button that runs COMMAND, HELP saying what it does.
MAP is its keymap, `keycap--preview-button-map' by default."
  (propertize text
              'keycap-command command
              'mouse-face 'header-line-highlight
              'help-echo help
              'local-map (or map keycap--preview-button-map)))

(defun keycap-preview-header-click (event)
  "Run the command of the header line button the mouse EVENT clicked.
It runs in the preview clicked, which stays unselected."
  (interactive "e")
  (pcase-let* ((position (event-start event))
               (`(,string . ,index) (posn-string position)))
    (with-selected-window (posn-window position)
      (call-interactively (get-text-property index 'keycap-command string)))))

(defun keycap--preview-number (number)
  "NUMBER, short."
  (if (= number (round number))
      (number-to-string (round number))
    (format "%.3g" number)))

(defun keycap--preview-extent ()
  "The size of the bounds in use, such as 20 × 20 × ∞."
  (when-let* ((region (keycap--preview-region)))
    (string-join (seq-mapn (lambda (lower upper)
                             (if (and lower upper) (keycap--preview-number (- upper lower)) "∞"))
                           (car region) (cadr region))
                 " × ")))

(defun keycap--preview-camera-name ()
  "The camera's name, such as iso, or else its azimuth and elevation."
  (let* ((azimuth (- (mod (+ keycap--preview-azimuth 180) 360) 180))
         (camera (seq-find (pcase-lambda (`(,_ ,camera-azimuth ,camera-elevation))
                             (and (= azimuth camera-azimuth)
                                  (= keycap--preview-elevation
                                     (keycap--preview-elevation camera-elevation))))
                           keycap--preview-cameras)))
    (if camera
        (symbol-name (car camera))
      (format "%d° %d°" (round azimuth) (round keycap--preview-elevation)))))

(defun keycap--preview-shown ()
  "What the preview shows, such as `shaded iso' or `sdf z = 4', for its header.
A tilted slice shows its angles: `sdf z ⊥ (12°, -30°) at 4'.  Each word
is a button."
  (concat (keycap--preview-button (symbol-name keycap--preview-view)
                                  #'keycap-preview-view-menu "mouse-1: switch the view")
          " "
          (if (keycap--preview-2d-p)
              (concat (keycap--preview-button (symbol-name keycap--preview-axis)
                                              #'keycap-preview-slice-menu "mouse-1: slice across another axis")
                      (if (keycap--preview-tilted-p)
                          (concat " ⊥ "
                                  (keycap--preview-button
                                   (format "(%d°, %d°)"
                                           (round (car keycap--preview-tilt))
                                           (round (cdr keycap--preview-tilt)))
                                   #'keycap-preview-level "mouse-1: level the slice")
                                  " at ")
                        " = ")
                      (keycap--preview-button (keycap--preview-number keycap--preview-offset)
                                              #'keycap-preview-slice-at
                                              "mouse-1: put the slice at an offset\nwheel: move it"
                                              keycap--preview-offset-map))
            (concat (keycap--preview-button (keycap--preview-camera-name)
                                            #'keycap-preview-camera-menu "mouse-1: point the camera")
                    (when (eq keycap--preview-projection 'perspective)
                      (concat " " (keycap--preview-button "perspective" #'keycap-preview-projection
                                                          "mouse-1: switch to orthographic")))))))

(defun keycap-preview-header ()
  "The preview's header line, as text."
  (let ((frame keycap--preview-frame))
    ;; Messages may hold `%', which the header line would take for its own.
    (string-replace
     "%" "%%"
     (string-join
      (delq nil
            (list
             ;; First, so that a narrow window does not cut it off.
             (when keycap--preview-failure
               (keycap--preview-button (propertize keycap--preview-failure 'face 'error)
                                       #'keycap-preview-goto-error "mouse-1: go to the error"))
             (keycap--preview-shown)
             (when (alist-get 'empty frame)
               (propertize (if (keycap--preview-2d-p) "nothing on this slice" "nothing in view")
                           'face 'warning))
             (when-let* (((buffer-live-p keycap--preview-source))
                         (status (with-current-buffer keycap--preview-source
                                   (keycap--export-status))))
               (keycap--preview-button
                (concat "Exporting " status
                        (substitute-command-keys " (\\[keycap-preview-keyboard-quit] cancels)"))
                #'keycap-preview-keyboard-quit "mouse-1: cancel the export"))
             keycap--preview-readout
             (when frame
               (keycap--preview-button
                (concat (alist-get 'bounds frame) " bounds "
                        (keycap--preview-extent)
                        (when-let* (((equal (alist-get 'bounds frame) "fitted"))
                                    (loose (alist-get 'loose (alist-get 'bounds keycap--preview-report))))
                          (propertize (format " (%s)" loose) 'face 'warning)))
                #'keycap-preview-toggle-bounds
                (if (eq keycap--preview-bounds 'fitted)
                    "mouse-1: show the script's bounds"
                  "mouse-1: show bounds fitted to the model")))
             (when frame
               (keycap--preview-button
                (format "%s %s%s" (upcase (alist-get 'backend frame))
                        (let ((ms (alist-get 'ms frame)))
                          (cond
                           ((>= ms 1000) (format "%.1f s" (/ ms 1000.0)))
                           ((>= ms 10) (format "%.0f ms" ms))
                           (t (format "%.1f ms" ms))))
                        (if (equal (alist-get 'backend frame) (symbol-name keycap--preview-backend))
                            ""
                          (format " (%s)" (or (alist-get 'fallback frame) "no GPU"))))
                #'keycap-preview-toggle-backend
                (if (eq keycap--preview-backend 'gpu)
                    "mouse-1: render on the CPU"
                  "mouse-1: render on the GPU")))
             (when (and keycap--preview-rendering
                        (> (- (float-time) keycap--preview-render-start) 0.25))
               "Rendering")
             keycap--preview-render-error))
      "  ·  "))))


;; --- Preview ---

(defun keycap--preview-make-directory (name)
  "A new directory for the frames of the script buffer NAME."
  (let ((base (expand-file-name "keycap" (or (getenv "XDG_RUNTIME_DIR")
                                                  temporary-file-directory)))
        (name (string-trim (replace-regexp-in-string "[^[:alnum:]_.]+" "-" (file-name-base name))
                           "-+" "-+")))
    (with-file-modes #o700
      (make-directory base t))
    (make-temp-file (expand-file-name (concat name "-") base) t)))

(defun keycap--preview-buffer (source)
  "A buffer for the preview of the script buffer SOURCE.
A renamed script's preview keeps its old name, so a buffer of SOURCE's
name may be another script's preview; then the new one gets a name of
its own."
  (let* ((name (format "*keycap: %s*" (buffer-name source)))
         (buffer (get-buffer name)))
    (if (and buffer
             (not (eq (buffer-local-value 'keycap--preview-source buffer) source))
             (with-current-buffer buffer (derived-mode-p 'keycap-preview-mode)))
        (generate-new-buffer name)
      (get-buffer-create name))))

(defun keycap--preview-for (source)
  "The preview buffer of the script buffer SOURCE, made and loaded if new."
  (with-current-buffer source
    (unless (buffer-live-p keycap--preview)
      (setq keycap--preview
            (with-current-buffer (keycap--preview-buffer source)
              (unless (derived-mode-p 'keycap-preview-mode)
                (keycap-preview-mode)
                (setq keycap--preview-source source
                      ;; Usually a tmpfs: every frame is written there.
                      keycap--preview-directory (keycap--preview-make-directory (buffer-name source))
                      keycap--preview-view keycap-preview-view
                      keycap--preview-bounds keycap-preview-bounds
                      keycap--preview-backend keycap-preview-backend
                      keycap--preview-axis 'z
                      keycap--preview-offset 0)
                (keycap--preview-reset-camera))
              (current-buffer)))
      (add-hook 'keycap--load-functions #'keycap--preview-loaded nil t)
      (add-hook 'kill-buffer-hook #'keycap--preview-kill-preview nil t)
      (keycap--reload))
    keycap--preview))

;;;###autoload
(defun keycap-preview ()
  "Show the model beside the script; it follows every edit."
  (interactive nil keycap-mode)
  (display-buffer (keycap--preview-for (current-buffer)) keycap--preview-display-action))

(put 'keycap--preview-kill-preview 'permanent-local-hook t)
(defun keycap--preview-kill-preview ()
  "Kill the script's preview along with the script."
  (when (buffer-live-p keycap--preview)
    (kill-buffer keycap--preview)))

(defun keycap--preview-cleanup ()
  "Forget the preview in its script, and delete its files."
  (when (buffer-live-p keycap--preview-source)
    (with-current-buffer keycap--preview-source
      (remove-hook 'keycap--load-functions #'keycap--preview-loaded t)))
  (when keycap--preview-leave-timer
    (cancel-timer keycap--preview-leave-timer))
  (keycap--preview-flush)
  (when keycap--preview-directory
    (delete-directory keycap--preview-directory t)))


;; --- Snapshots ---

;; A preview that no window shows and no edit changes, rendered by hand:
;; for frames made in a batch, such as the manual site's.

(defun keycap-preview-snapshot (script &rest settings)
  "A preview of the script buffer SCRIPT, set up by SETTINGS, that no window shows.
It does not follow the script: `keycap-preview-request' is its render
request, which the script's server answers, and `keycap-preview-set-frame'
takes the reply.  Killing it deletes its frames.  SETTINGS are:

- `:report', the `load' report whose model it shows, SCRIPT's last by default
- `:failure', why the script fails to load, by default the report's
- `:view', `shaded', `heightmap', `sdf' or `mono', by default the one the
  preview starts in for the model
- `:camera', (AZIMUTH ELEVATION) in degrees, iso by default
- `:slice', (AXIS OFFSET TILT), AXIS `x', `y' or `z', OFFSET nil for the
  middle of the bounds and TILT (RIGHT . UP) in degrees; level across Z
  through the middle by default
- `:bounds', `script' or `fitted', and `:backend', `gpu' or `cpu', by
  default `keycap-preview-bounds' and `keycap-preview-backend'."
  (let ((report (or (plist-get settings :report) (buffer-local-value 'keycap--report script)))
        (slice (plist-get settings :slice))
        (camera (plist-get settings :camera)))
    (with-current-buffer (generate-new-buffer (format "*keycap: %s*" (buffer-name script)))
      (keycap-preview-mode)
      (keycap--preview-reset-camera)
      (setq keycap--preview-source script
            keycap--preview-directory (keycap--preview-make-directory (buffer-name script))
            keycap--preview-report report
            keycap--preview-failure (if (plist-member settings :failure)
                                        (plist-get settings :failure)
                                      (keycap-report-failure report))
            keycap--preview-view (or (plist-get settings :view)
                                     (if (keycap-report-flat-p report) 'sdf keycap-preview-view))
            keycap--preview-bounds (or (plist-get settings :bounds) keycap-preview-bounds)
            keycap--preview-backend (or (plist-get settings :backend) keycap-preview-backend)
            keycap--preview-axis (or (car slice) 'z)
            keycap--preview-offset (or (nth 1 slice) (keycap--preview-middle keycap--preview-axis))
            keycap--preview-tilt (or (nth 2 slice) '(0 . 0)))
      (when camera
        (setq keycap--preview-azimuth (car camera)
              keycap--preview-elevation (keycap--preview-elevation (cadr camera))))
      (current-buffer))))

(defun keycap-preview-set-frame (frame)
  "Take FRAME, the server's reply to a render request, as the frame shown.
The header line and readings are of it; its image is the file the
request named.  An `error' reply signals it."
  (when-let* ((error (alist-get 'error frame)))
    (error "%s" error))
  (setq keycap--preview-frame frame
        keycap--preview-render-error nil
        keycap--preview-readout nil))

(defun keycap-preview-probe-sync (right up width height)
  "Read the model at RIGHT and UP on the level slice of a 2D view.
The reading shows in the header line as the mouse's would.  WIDTH and
HEIGHT are the frame's, in pixels.  Return the pixel read, (X . Y) from
the frame's top left corner."
  (unless (keycap--preview-2d-p)
    (user-error "Only the 2D views show a slice"))
  (pcase-let* ((`(,across ,upward) (pcase keycap--preview-axis
                                     ('x '(y z))
                                     ('y '(x z))
                                     (_ '(x y))))
               (scale (alist-get 'scale keycap--preview-frame))
               (x (+ (/ width 2.0)
                     (/ (- right (keycap--preview-middle across)) scale)
                     (* -0.5 height (car keycap--preview-pan))))
               (y (+ (/ height 2.0)
                     (/ (- (keycap--preview-middle upward) up) scale)
                     (* 0.5 height (cdr keycap--preview-pan)))))
    (keycap--preview-read
     (with-current-buffer keycap--preview-source
       (keycap-request-sync `((op . "probe") (x . ,(floor x)) (y . ,(floor y))))))
    (cons x y)))

(defun keycap-preview-idle-p (&optional script)
  "Non-nil when the preview of SCRIPT shows a frame, and nothing loads or renders.
SCRIPT is a script buffer, the current one by default."
  (let ((script (or script (current-buffer))))
    (when-let* ((preview (buffer-local-value 'keycap--preview script))
                ((buffer-live-p preview)))
      (with-current-buffer preview
        (and keycap--preview-frame
             (not keycap--preview-rendering)
             (not keycap--preview-pending)
             (not (buffer-local-value 'keycap--load-waiting script))
             (not (buffer-local-value 'keycap--load-timer script)))))))


;; --- Commands ---

(defun keycap--preview-reset-camera ()
  "Point the camera at the model from the front right, above; level the slice."
  (pcase-let ((`(,azimuth ,elevation) (alist-get 'iso keycap--preview-cameras)))
    (setq keycap--preview-azimuth azimuth
          keycap--preview-elevation elevation
          keycap--preview-zoom 1.0
          keycap--preview-pan '(0.0 . 0.0)
          keycap--preview-projection keycap-preview-projection
          keycap--preview-tilt '(0 . 0))))

(defun keycap--preview-revert (&rest _)
  "Evaluate the script again, starting its server if it stopped, and render it."
  (with-current-buffer keycap--preview-source
    (keycap--reload)))

(defun keycap--preview-elevation (elevation)
  "ELEVATION as the camera takes it, short of straight up or down."
  ;; There, the camera's up direction is undefined.
  (max -89.9 (min 89.9 elevation)))

(defun keycap--preview-look (azimuth elevation)
  "Look at the model from AZIMUTH and ELEVATION degrees."
  (setq keycap--preview-azimuth azimuth
        keycap--preview-elevation (keycap--preview-elevation elevation))
  (keycap--preview-render))

(defun keycap--preview-look-from (camera)
  "Look at the model from CAMERA, a name in `keycap--preview-cameras'."
  (apply #'keycap--preview-look (cdr (assq camera keycap--preview-cameras))))

(defun keycap--preview-move (right up)
  "Move the camera RIGHT and UP, in halves of the image's height."
  (setq keycap--preview-pan (cons (+ (car keycap--preview-pan) right)
                                  (+ (cdr keycap--preview-pan) up)))
  (keycap--preview-render))

(defun keycap-preview-orbit-left ()
  "Move the camera left around the model; in 2D views, move it left."
  (interactive nil keycap-preview-mode)
  (if (keycap--preview-2d-p)
      (keycap--preview-move -0.1 0)
    (keycap--preview-look (- keycap--preview-azimuth keycap--preview-step)
                          keycap--preview-elevation)))

(defun keycap-preview-orbit-right ()
  "Move the camera right around the model; in 2D views, move it right."
  (interactive nil keycap-preview-mode)
  (if (keycap--preview-2d-p)
      (keycap--preview-move 0.1 0)
    (keycap--preview-look (+ keycap--preview-azimuth keycap--preview-step)
                          keycap--preview-elevation)))

(defun keycap-preview-orbit-up ()
  "Move the camera up around the model; in 2D views, move it up."
  (interactive nil keycap-preview-mode)
  (if (keycap--preview-2d-p)
      (keycap--preview-move 0 0.1)
    (keycap--preview-look keycap--preview-azimuth
                          (+ keycap--preview-elevation keycap--preview-step))))

(defun keycap-preview-orbit-down ()
  "Move the camera down around the model; in 2D views, move it down."
  (interactive nil keycap-preview-mode)
  (if (keycap--preview-2d-p)
      (keycap--preview-move 0 -0.1)
    (keycap--preview-look keycap--preview-azimuth
                          (- keycap--preview-elevation keycap--preview-step))))

(defun keycap-preview-pan-left ()
  "Move the camera left."
  (interactive nil keycap-preview-mode)
  (keycap--preview-move -0.1 0))

(defun keycap-preview-pan-right ()
  "Move the camera right."
  (interactive nil keycap-preview-mode)
  (keycap--preview-move 0.1 0))

(defun keycap-preview-pan-up ()
  "Move the camera up."
  (interactive nil keycap-preview-mode)
  (keycap--preview-move 0 0.1))

(defun keycap-preview-pan-down ()
  "Move the camera down."
  (interactive nil keycap-preview-mode)
  (keycap--preview-move 0 -0.1))

(defun keycap--preview-clicked (event)
  "The preview the mouse EVENT happened in."
  (window-buffer (posn-window (event-start event))))

(defun keycap--preview-zoom (event factor)
  "Zoom the preview that EVENT happened in by FACTOR."
  (with-current-buffer (keycap--preview-clicked event)
    (setq keycap--preview-zoom (* keycap--preview-zoom factor))
    (keycap--preview-render)))

(defun keycap-preview-zoom-in (event)
  "Zoom in on the preview that EVENT, a key or the mouse wheel, happened in."
  (interactive (list last-nonmenu-event) keycap-preview-mode)
  (keycap--preview-zoom event 1.25))

(defun keycap-preview-zoom-out (event)
  "Zoom out of the preview that EVENT, a key or the mouse wheel, happened in."
  (interactive (list last-nonmenu-event) keycap-preview-mode)
  (keycap--preview-zoom event 0.8))

(defun keycap--preview-drag (event update)
  "Follow the drag that EVENT started, calling UPDATE with how far it went.
UPDATE gets the distance right and down, in pixels, and the image's height.
A click without a drag selects the preview, for its keys; a drag leaves
the keyboard in the window it was in, such as the script's."
  (let ((preview (current-buffer))
        (window (posn-window (event-start event)))
        (start (keycap--event-pixel event))
        (mouse-fine-grained-tracking t)
        moved
        movement)
    (let ((height (if keycap--preview-image
                      (cdr (image-size keycap--preview-image t (window-frame window)))
                    (window-body-height window t))))
      (unwind-protect
          (progn
            (setq keycap--preview-dragging t
                  keycap--preview-drag-share keycap-preview-drag-resolution
                  keycap--preview-drag-floor nil
                  keycap--preview-drag-last nil)
            (track-mouse
              (while (mouse-movement-p (setq movement (read-event)))
                (when-let* ((now (keycap--event-pixel movement)))
                  (setq moved t)
                  ;; `update' sets the preview's own variables.
                  (with-current-buffer preview
                    (funcall update (- (car now) (car start)) (- (cdr now) (cdr start)) height)
                    (keycap--preview-render))))))
        (with-current-buffer preview
          (setq keycap--preview-dragging nil)
          (if moved
              ;; The last frame, in full, without waiting for the one that runs
              (keycap--preview-render t)
            (select-window window)))))))

(defun keycap-preview-mouse-orbit (event)
  "Turn the camera around the model as the mouse drags, from EVENT.
In 2D views, move it."
  (interactive "e" keycap-preview-mode)
  (with-current-buffer (keycap--preview-clicked event)
    (if (keycap--preview-2d-p)
        (keycap-preview-mouse-pan event)
      (let ((azimuth keycap--preview-azimuth)
            (elevation keycap--preview-elevation))
        (keycap--preview-drag
         event
         (lambda (right down _height)
           (setq keycap--preview-azimuth (- azimuth (* 0.4 right))
                 keycap--preview-elevation (keycap--preview-elevation (+ elevation (* 0.4 down))))))))))

(defun keycap-preview-mouse-pan (event)
  "Move the camera with the mouse as it drags, from EVENT."
  (interactive "e" keycap-preview-mode)
  (with-current-buffer (keycap--preview-clicked event)
    (let ((pan keycap--preview-pan))
      (keycap--preview-drag
       event
       (lambda (right down height)
         (setq keycap--preview-pan (cons (- (car pan) (/ right (/ height 2.0)))
                                         (+ (cdr pan) (/ down (/ height 2.0))))))))))

(defun keycap-preview-projection ()
  "Switch the 3D views between orthographic and perspective projection."
  (interactive nil keycap-preview-mode)
  (setq keycap--preview-projection
        (if (eq keycap--preview-projection 'orthographic) 'perspective 'orthographic))
  (keycap--preview-render))

(defun keycap--preview-slice (axis &optional tilt)
  "Slice the model across AXIS through the middle of the bounds.
The slice is level, or at TILT."
  (setq keycap--preview-axis axis
        keycap--preview-offset (keycap--preview-middle axis)
        keycap--preview-offset-chosen nil
        keycap--preview-tilt (or tilt '(0 . 0)))
  (keycap--preview-render))

(defun keycap-preview-front ()
  "Look at the model from the front, along +Y; in 2D views, slice level across Y."
  (interactive nil keycap-preview-mode)
  (if (keycap--preview-2d-p)
      (keycap--preview-slice 'y)
    (keycap--preview-look-from 'front)))

(defun keycap-preview-right ()
  "Look at the model from the right, along -X; in 2D views, slice level across X."
  (interactive nil keycap-preview-mode)
  (if (keycap--preview-2d-p)
      (keycap--preview-slice 'x)
    (keycap--preview-look-from 'right)))

(defun keycap-preview-top ()
  "Look down at the model, along -Z; in 2D views, slice level across Z."
  (interactive nil keycap-preview-mode)
  (if (keycap--preview-2d-p)
      (keycap--preview-slice 'z)
    (keycap--preview-look-from 'top)))

(defun keycap--preview-facing (azimuth elevation)
  "The tilt of a slice across Z that faces a camera at AZIMUTH and ELEVATION."
  (let ((azimuth (degrees-to-radians azimuth))
        (elevation (degrees-to-radians elevation)))
    ;; The camera's direction is the normal (sin UP, -sin RIGHT cos UP,
    ;; cos RIGHT cos UP) that the tilt turns Z to.
    (cons (radians-to-degrees (atan (- (* (cos elevation) (sin azimuth))) (sin elevation)))
          (radians-to-degrees (asin (* (cos elevation) (cos azimuth)))))))

(defun keycap-preview-isometric ()
  "Look at the model from the front right, above.
In 2D views, slice through the middle of the bounds, facing that way."
  (interactive nil keycap-preview-mode)
  (if (keycap--preview-2d-p)
      (keycap--preview-slice 'z (apply #'keycap--preview-facing
                                       (cdr (assq 'iso keycap--preview-cameras))))
    (keycap--preview-look-from 'iso)))

;;;###autoload
(defun keycap-preview-cycle-view ()
  "Switch the preview to its next view.
The views are shaded, heightmap, sdf (the distance field) and mono (inside
and outside); the last two show a slice."
  (interactive nil keycap-mode keycap-preview-mode)
  (with-current-buffer (if (derived-mode-p 'keycap-preview-mode)
                           (current-buffer)
                         (let ((preview (keycap--preview-for (current-buffer))))
                           (display-buffer preview keycap--preview-display-action)
                           preview))
    (keycap--preview-choose-view (or (cadr (memq keycap--preview-view keycap--preview-views))
                                     (car keycap--preview-views)))))

(defun keycap--preview-choose-view (view)
  "Show VIEW, picked by hand, so that it stays as the script changes."
  (keycap--preview-set-view view)
  (setq keycap--preview-view-chosen t)
  (keycap--preview-render)
  (keycap--preview-hint))

(defun keycap-preview-shaded ()
  "Show the model in 3D, lit, each shape in its colour."
  (interactive nil keycap-preview-mode)
  (keycap--preview-choose-view 'shaded))

(defun keycap-preview-heightmap ()
  "Show the heightmap: the model in 3D, its depth as grey."
  (interactive nil keycap-preview-mode)
  (keycap--preview-choose-view 'heightmap))

(defun keycap-preview-sdf ()
  "Show the sdf: the distance field on a slice through the model."
  (interactive nil keycap-preview-mode)
  (keycap--preview-choose-view 'sdf))

(defun keycap-preview-mono ()
  "Show mono: the inside and outside of the model on a slice through it."
  (interactive nil keycap-preview-mode)
  (keycap--preview-choose-view 'mono))

(defun keycap--preview-slice-extent ()
  "The size of the bounds along the slice's axis, or the largest bounded one."
  (let* ((region (keycap--preview-region))
         (axis (seq-position '(x y z) keycap--preview-axis))
         (extents (seq-mapn (lambda (lower upper) (and lower upper (- upper lower)))
                            (car region) (cadr region)))
         (bounded (remq nil extents)))
    (or (nth axis extents) (if bounded (seq-max bounded) 2))))

(defun keycap--preview-slice-step ()
  "A round step through the slice, about a twentieth of the bounds along it."
  (let* ((step (/ (keycap--preview-slice-extent) 20.0))
         (power (expt 10.0 (floor (log step 10))))
         (mantissa (/ step power)))
    (* power (cond ((>= mantissa 5) 5) ((>= mantissa 2) 2) (t 1)))))

(defun keycap--preview-step-slice (direction offset)
  "Move the slice by one step in DIRECTION, 1 or -1, or to OFFSET if non-nil."
  (unless (keycap--preview-2d-p)
    (user-error "Only the 2D views show a slice"))
  (setq keycap--preview-offset-chosen t
        keycap--preview-offset
        (or offset
            (let ((step (keycap--preview-slice-step)))
              (* step (round (+ (/ keycap--preview-offset step) direction))))))
  (keycap--preview-render))

(defun keycap-preview-toggle-bounds ()
  "Switch between the script's bounds and the ones fitted to the model."
  (interactive nil keycap-preview-mode)
  (setq keycap--preview-bounds (if (eq keycap--preview-bounds 'script) 'fitted 'script))
  (when (and (eq keycap--preview-bounds 'script)
             (not (alist-get 'script (alist-get 'bounds keycap--preview-report))))
    (message "The script sets no bounds; fitted ones stand in"))
  (keycap--preview-render))

(defun keycap-preview-toggle-backend ()
  "Switch between rendering on the GPU and on the CPU."
  (interactive nil keycap-preview-mode)
  (setq keycap--preview-backend (if (eq keycap--preview-backend 'gpu) 'cpu 'gpu))
  (keycap--preview-render))

(defun keycap-preview-export-stl (file &optional resolution)
  "Export the model to FILE within the preview's bounds; see `keycap-export-stl'.
RESOLUTION as there."
  (interactive (with-current-buffer keycap--preview-source (keycap--export-arguments))
               keycap-preview-mode)
  (let ((bounds keycap--preview-bounds))
    (with-current-buffer keycap--preview-source
      (keycap-export-stl file resolution bounds))))

(defun keycap--preview-slice-shown ()
  "The slice the preview shows, as (AXIS OFFSET TILT), or nil in a 3D view."
  (when (keycap--preview-2d-p)
    (list keycap--preview-axis keycap--preview-offset keycap--preview-tilt)))

(defun keycap-preview-export-2d (file &optional kerf)
  "Export the outlines on the slice shown to FILE; see `keycap-export-2d'.
KERF as there.  In a 3D view, the slice is across Z through the middle
of the bounds."
  (interactive (with-current-buffer keycap--preview-source (keycap--export-2d-arguments))
               keycap-preview-mode)
  (let ((slice (keycap--preview-slice-shown))
        (bounds keycap--preview-bounds))
    (with-current-buffer keycap--preview-source
      (keycap-export-2d file kerf slice bounds))))

(defun keycap-preview-keyboard-quit ()
  "Cancel the script's export if one runs; otherwise, `keyboard-quit'."
  (interactive nil keycap-preview-mode)
  (if (buffer-local-value 'keycap--export keycap--preview-source)
      (with-current-buffer keycap--preview-source
        (keycap-export-cancel))
    (keyboard-quit)))

(defun keycap-preview-reset-camera ()
  "Point the camera at the model from the front right, above, unmoved and unzoomed.
In 2D views, level the slice, where it is."
  (interactive nil keycap-preview-mode)
  (keycap--preview-reset-camera)
  (keycap--preview-render))

(defun keycap-preview-slice-at (offset)
  "Put the slice of the 2D views at OFFSET along its axis."
  (interactive (list (read-number "Slice at: " keycap--preview-offset)) keycap-preview-mode)
  (keycap--preview-step-slice 0 offset))


;; --- Slice scrubbing ---

(defun keycap--preview-wheel-steps (event)
  "How many steps the mouse wheel EVENT moves the slice: 10 with Meta, - for down."
  (* (if (memq 'meta (event-modifiers event)) 10 1)
     (if (eq (event-basic-type event) 'wheel-up) 1 -1)))

(defun keycap--preview-scrubbed (offset down extent height)
  "OFFSET moved for the mouse going DOWN pixels, EXTENT to HEIGHT pixels.
Dragging up moves the slice forward."
  (- offset (* down (/ extent (float height)))))

(defun keycap-preview-mouse-slice-step (event)
  "Step the slice of the 2D views as the mouse wheel EVENT turns.
Meta steps ten times as far."
  (interactive "e" keycap-preview-mode)
  (with-current-buffer (keycap--preview-clicked event)
    (keycap--preview-step-slice (keycap--preview-wheel-steps event) nil)))

(defun keycap-preview-mouse-slice (event)
  "Move the slice of the 2D views with the mouse as it drags, from EVENT.
The window's height covers the bounds along the slice's axis."
  (interactive "e" keycap-preview-mode)
  (with-current-buffer (keycap--preview-clicked event)
    (unless (keycap--preview-2d-p)
      (user-error "Only the 2D views show a slice"))
    (let ((offset keycap--preview-offset)
          (extent (keycap--preview-slice-extent)))
      (setq keycap--preview-offset-chosen t)
      (keycap--preview-drag
       event
       (lambda (_right down height)
         (setq keycap--preview-offset (keycap--preview-scrubbed offset down extent height))
         (force-mode-line-update))))))

(defun keycap--preview-offset-argument ()
  "The slice offset the prefix argument asks for, or nil."
  (cond
   ((consp current-prefix-arg)
    (read-number "Slice at: " keycap--preview-offset))
   (current-prefix-arg
    (prefix-numeric-value current-prefix-arg))))

(defun keycap-preview-slice-forward (&optional offset)
  "Move the slice of the 2D views forward along its axis.
A numeric prefix argument puts it at that OFFSET; \\[universal-argument] asks where."
  (interactive (list (keycap--preview-offset-argument)) keycap-preview-mode)
  (keycap--preview-step-slice 1 offset))

(defun keycap-preview-slice-backward (&optional offset)
  "Move the slice of the 2D views back along its axis.
A numeric prefix argument puts it at that OFFSET; \\[universal-argument] asks where."
  (interactive (list (keycap--preview-offset-argument)) keycap-preview-mode)
  (keycap--preview-step-slice -1 offset))


;; --- Tilting the slice ---

(defun keycap--preview-angle (angle)
  "ANGLE, in degrees, within ±180°."
  (- (mod (+ angle 180) 360) 180))

(defun keycap--preview-step-tilt (about direction angle)
  "Tilt the slice to the next whole step in DIRECTION, 1 or -1, or to ANGLE.
ABOUT is the image's axis it turns about, `right' or `up'."
  (unless (keycap--preview-2d-p)
    (user-error "Only the 2D views show a slice"))
  (let* ((old (if (eq about 'right) (car keycap--preview-tilt) (cdr keycap--preview-tilt)))
         (steps (/ old (float keycap--preview-tilt-step)))
         (new (keycap--preview-angle
               (or angle
                   (* keycap--preview-tilt-step
                      (if (> direction 0) (1+ (floor steps)) (1- (ceiling steps))))))))
    (setq keycap--preview-tilt (if (eq about 'right)
                                   (cons new (cdr keycap--preview-tilt))
                                 (cons (car keycap--preview-tilt) new))))
  (keycap--preview-render))

(defun keycap--preview-angle-argument ()
  "The tilt the prefix argument asks for, or nil."
  (cond
   ((consp current-prefix-arg)
    (read-number "Tilt to: " 0))
   (current-prefix-arg
    (prefix-numeric-value current-prefix-arg))))

(defun keycap-preview-tilt-forward (&optional angle)
  "Tilt the slice of the 2D views about the image's right, its top toward you.
A numeric prefix argument tilts it to that ANGLE, in degrees;
\\[universal-argument] asks for one."
  (interactive (list (keycap--preview-angle-argument)) keycap-preview-mode)
  (keycap--preview-step-tilt 'right 1 angle))

(defun keycap-preview-tilt-backward (&optional angle)
  "Tilt the slice of the 2D views about the image's right, its top away.
A numeric prefix argument tilts it to that ANGLE, as
`keycap-preview-tilt-forward' does."
  (interactive (list (keycap--preview-angle-argument)) keycap-preview-mode)
  (keycap--preview-step-tilt 'right -1 angle))

(defun keycap-preview-tilt-right (&optional angle)
  "Tilt the slice of the 2D views about the image's up, its right edge away.
A numeric prefix argument tilts it to that ANGLE, in degrees;
\\[universal-argument] asks for one."
  (interactive (list (keycap--preview-angle-argument)) keycap-preview-mode)
  (keycap--preview-step-tilt 'up 1 angle))

(defun keycap-preview-tilt-left (&optional angle)
  "Tilt the slice of the 2D views about the image's up, its right edge toward you.
A numeric prefix argument tilts it to that ANGLE, as
`keycap-preview-tilt-right' does."
  (interactive (list (keycap--preview-angle-argument)) keycap-preview-mode)
  (keycap--preview-step-tilt 'up -1 angle))

(defun keycap-preview-level ()
  "Level the slice of the 2D views, normal to its axis again."
  (interactive nil keycap-preview-mode)
  (setq keycap--preview-tilt '(0 . 0))
  (keycap--preview-render))

(defun keycap--preview-tilted (tilt right down)
  "TILT moved for the mouse going RIGHT and DOWN pixels.
The slice turns as if held where the mouse is: down brings its top
toward you, right takes its right edge away."
  (cons (keycap--preview-angle (+ (car tilt) (* 0.4 down)))
        (keycap--preview-angle (+ (cdr tilt) (* 0.4 right)))))

(defun keycap-preview-mouse-tilt (event)
  "Tilt the slice of the 2D views with the mouse as it drags, from EVENT."
  (interactive "e" keycap-preview-mode)
  (with-current-buffer (keycap--preview-clicked event)
    (unless (keycap--preview-2d-p)
      (user-error "Only the 2D views show a slice"))
    (let ((tilt keycap--preview-tilt))
      (keycap--preview-drag
       event
       (lambda (right down _height)
         (setq keycap--preview-tilt (keycap--preview-tilted tilt right down)))))))


;; --- Menus ---

;; One set of menus serves the menu bar, the context menu (`mouse-3') and
;; the header line's buttons.

(defconst keycap--preview-view-items
  '(["Shaded" keycap-preview-shaded
     :style radio :selected (eq keycap--preview-view 'shaded)]
    ["Heightmap" keycap-preview-heightmap
     :style radio :selected (eq keycap--preview-view 'heightmap)
     :help "The model in 3D, its depth as grey"]
    ["SDF" keycap-preview-sdf
     :style radio :selected (eq keycap--preview-view 'sdf)
     :help "The distance field on a slice"]
    ["Mono" keycap-preview-mono
     :style radio :selected (eq keycap--preview-view 'mono)
     :help "Inside and outside on a slice"])
  "The views, as menu items.")

(defconst keycap--preview-camera-items
  '(["Front" keycap-preview-front]
    ["Right" keycap-preview-right]
    ["Top" keycap-preview-top]
    ["Isometric" keycap-preview-isometric]
    "---"
    ["Perspective" keycap-preview-projection
     :style toggle :selected (eq keycap--preview-projection 'perspective)]
    ["Reset Camera" keycap-preview-reset-camera])
  "The cameras of the 3D views, as menu items.")

(defconst keycap--preview-slice-items
  '(["Across X" keycap-preview-right
     :style radio :selected (eq keycap--preview-axis 'x)]
    ["Across Y" keycap-preview-front
     :style radio :selected (eq keycap--preview-axis 'y)]
    ["Across Z" keycap-preview-top
     :style radio :selected (eq keycap--preview-axis 'z)]
    ["Isometric" keycap-preview-isometric]
    "---"
    ["Forward" keycap-preview-slice-forward]
    ["Back" keycap-preview-slice-backward]
    ["At..." keycap-preview-slice-at]
    ["Level" keycap-preview-level :active (keycap--preview-tilted-p)]
    ["Reset Camera" keycap-preview-reset-camera])
  "The slices of the 2D views, as menu items.")

(defun keycap--preview-menu-items (&rest _)
  "The items of the preview's menu, for the view it shows."
  (append keycap--preview-view-items
          '("---")
          (if (keycap--preview-2d-p) keycap--preview-slice-items keycap--preview-camera-items)
          '("---"
            ["Fitted Bounds" keycap-preview-toggle-bounds
             :style toggle :selected (eq keycap--preview-bounds 'fitted)]
            ["Render on the GPU" keycap-preview-toggle-backend
             :style toggle :selected (eq keycap--preview-backend 'gpu)]
            "---"
            ["Export STL..." keycap-preview-export-stl]
            ["Export 2D..." keycap-preview-export-2d]
            ["Cancel Export" keycap-preview-keyboard-quit
             :active (buffer-local-value 'keycap--export keycap--preview-source)]
            "---"
            ["Keys" keycap-preview-keys]
            ["Manual" keycap-guide])))

(defun keycap-preview-view-menu ()
  "Pick the preview's view from a menu."
  (interactive nil keycap-preview-mode)
  (popup-menu (keycap-preview-menu 'view)))

(defun keycap-preview-camera-menu ()
  "Pick the preview's camera from a menu."
  (interactive nil keycap-preview-mode)
  (popup-menu (keycap-preview-menu 'camera)))

(defun keycap-preview-slice-menu ()
  "Pick the slice of the preview's 2D views from a menu."
  (interactive nil keycap-preview-mode)
  (popup-menu (keycap-preview-menu 'slice)))

(defun keycap-preview-menu (name)
  "The preview's menu NAME, as a keymap.
NAME is `context', the menu a right click on the model opens, or `view',
`camera' or `slice', the menu of that word of the header line."
  (pcase name
    ;; A click on the frame, which `posn-image' takes for one on an image
    ('context (keycap--preview-context-menu (make-sparse-keymap)
                                            '(mouse-3 (nil 1 (0 . 0) 0 nil 1 nil (image) nil nil))))
    ('view (easy-menu-create-menu "View" keycap--preview-view-items))
    ('camera (easy-menu-create-menu "Camera" keycap--preview-camera-items))
    ('slice (easy-menu-create-menu "Slice" keycap--preview-slice-items))
    (_ (error "No preview menu %s" name))))

(defun keycap--preview-context-menu (menu click)
  "Fill MENU with the preview's menu, for a mouse CLICK on the preview.
On the model, the menu starts with the way to its shape's `draw'."
  (when (posn-image (event-start click))
    (define-key-after menu [keycap-goto-shape]
      `(menu-item "Go to Shape" ,(lambda ()
                                   (interactive)
                                   (keycap-preview-mouse-goto-shape click))
                  :help "Show the `draw' of the shape under the mouse in the script"))
    (define-key-after menu [keycap-goto-separator] menu-bar-separator))
  ;; Past the menu's own title, the items of the preview's.
  (nconc menu (cddr (easy-menu-create-menu "Preview" (keycap--preview-menu-items)))))


;; --- Going to the script ---

(defun keycap--preview-image-pixel (event)
  "The frame's pixel the mouse EVENT is on, as (X . Y), or nil off the image."
  (let ((position (event-start event)))
    (when-let* (((posn-image position))
                (xy (posn-object-x-y position)))
      (cons (floor (* (car xy) keycap--preview-scale))
            (floor (* (cdr xy) keycap--preview-scale))))))

(defun keycap--preview-drawn (index)
  "Where the shape number INDEX of the last load is drawn, as (FILE LINE COLUMN).
FILE is nil for the script itself; nil for no such shape."
  (when-let* ((shape (and index (nth index (alist-get 'shapes keycap--preview-report)))))
    (list (alist-get 'file shape) (alist-get 'line shape) (alist-get 'column shape))))

(defun keycap--preview-show-in-script (file line column)
  "Select the script, or the FILE it imports, at LINE and COLUMN."
  (pop-to-buffer (if (and file (not (with-current-buffer keycap--preview-source
                                      (keycap--here-p file))))
                     (find-file-noselect file)
                   keycap--preview-source))
  (goto-char (keycap--position line column))
  (pulse-momentary-highlight-one-line))

(defun keycap-preview-mouse-goto-shape (event)
  "Show the `draw' of the shape the mouse EVENT is on, in the script.
In 2D views, of the shape the mouse is in, or else the nearest one."
  (interactive "e" keycap-preview-mode)
  (with-current-buffer (keycap--preview-clicked event)
    (let ((pixel (or (keycap--preview-image-pixel event)
                     (user-error "Not on the model")))
          (preview (current-buffer)))
      (with-current-buffer keycap--preview-source
        (keycap--request
         `((op . "probe") (x . ,(car pixel)) (y . ,(cdr pixel)))
         (lambda (reply)
           (when (buffer-live-p preview)
             (with-current-buffer preview
               (if-let* ((drawn (keycap--preview-drawn (alist-get 'shape reply))))
                   (apply #'keycap--preview-show-in-script drawn)
                 (message "No shape there"))))))))))

(defun keycap-preview-goto-error ()
  "Show the error that stops the script, in the script."
  (interactive nil keycap-preview-mode)
  (let ((failure (with-current-buffer keycap--preview-source
                 (seq-find (lambda (diagnostic) (eq (flymake-diagnostic-type diagnostic) :error))
                           (keycap-report-diagnostics keycap--report)))))
    (unless failure
      (user-error "The script has no error"))
    (pop-to-buffer keycap--preview-source)
    (goto-char (flymake-diagnostic-beg failure))))


;; --- Hints ---

;; Most keys say what they do in the header line or the menus; the ones
;; that do not, the slice's most of all, are named in one line of the
;; echo area: on `?', and once each for 3D and 2D views when the
;; preview first shows one.

(defconst keycap--preview-hints
  '((3d ("drag, arrows" . "turn")
        ("middle drag, M-arrows" . "move")
        ("wheel" . "zoom")
        ("1 3 7 0" . "front, right, top, iso")
        ("r" . "reset")
        ("s z d m" . "shaded, heightmap, sdf, mono"))
    (2d ("[ ]" . "move the slice")
        ("{ } M-{ M-}" . "tilt it")
        ("1 3 7 0" . "across Y, X, Z, facing iso")
        ("S-wheel, S-drag" . "move it")
        ("C-drag" . "tilt it")
        ("r" . "level it, reset the camera")
        ("s z d m" . "views")))
  "The keys the hint names, for 3D and 2D views, as (KEYS . WHAT) pairs.")

(defvar keycap--preview-hinted nil
  "The kinds of view, `3d' and `2d', whose hint was shown in this session.")

(defun keycap--preview-hint-text (kind)
  "The hint for KIND of view, `3d' or `2d'."
  (mapconcat (pcase-lambda (`(,keys . ,what))
               (concat (propertize keys 'face 'help-key-binding) " " what))
             (append (alist-get kind keycap--preview-hints)
                     '(("?" . "this hint") ("h" . "every key")))
             "  ·  "))

(defun keycap--preview-hint ()
  "Show the hint for the view shown, unless one for its kind was shown already."
  (let ((kind (if (keycap--preview-2d-p) '2d '3d)))
    (unless (memq kind keycap--preview-hinted)
      (push kind keycap--preview-hinted)
      (message "%s" (keycap--preview-hint-text kind)))))

(defun keycap-preview-keys ()
  "Name the preview's most used keys in the echo area, for the view shown."
  (interactive nil keycap-preview-mode)
  (message "%s" (keycap--preview-hint-text (if (keycap--preview-2d-p) '2d '3d))))


;; --- Mode ---

(defvar-keymap keycap-preview-mode-map
  :doc "Keymap for `keycap-preview-mode'."
  "<left>" #'keycap-preview-orbit-left
  "<right>" #'keycap-preview-orbit-right
  "<up>" #'keycap-preview-orbit-up
  "<down>" #'keycap-preview-orbit-down
  "M-<left>" #'keycap-preview-pan-left
  "M-<right>" #'keycap-preview-pan-right
  "M-<up>" #'keycap-preview-pan-up
  "M-<down>" #'keycap-preview-pan-down
  "<down-mouse-1>" #'keycap-preview-mouse-orbit
  "<down-mouse-2>" #'keycap-preview-mouse-pan
  ;; Unbound, it would be read as a second `down-mouse-1', whose drag
  ;; would take the `double-mouse-1' for its end.
  "<double-down-mouse-1>" #'ignore
  "<double-mouse-1>" #'keycap-preview-mouse-goto-shape
  "<down-mouse-3>" context-menu-entry
  "<wheel-up>" #'keycap-preview-zoom-in
  "<wheel-down>" #'keycap-preview-zoom-out
  "S-<down-mouse-1>" #'keycap-preview-mouse-slice
  "C-<down-mouse-1>" #'keycap-preview-mouse-tilt
  "S-<wheel-up>" #'keycap-preview-mouse-slice-step
  "S-<wheel-down>" #'keycap-preview-mouse-slice-step
  "M-<wheel-up>" #'keycap-preview-mouse-slice-step
  "M-<wheel-down>" #'keycap-preview-mouse-slice-step
  "+" #'keycap-preview-zoom-in
  "=" #'keycap-preview-zoom-in
  "-" #'keycap-preview-zoom-out
  "p" #'keycap-preview-projection
  "1" #'keycap-preview-front
  "3" #'keycap-preview-right
  "7" #'keycap-preview-top
  "0" #'keycap-preview-isometric
  "r" #'keycap-preview-reset-camera
  "v" #'keycap-preview-cycle-view
  "s" #'keycap-preview-shaded
  "z" #'keycap-preview-heightmap
  "d" #'keycap-preview-sdf
  "m" #'keycap-preview-mono
  "[" #'keycap-preview-slice-backward
  "]" #'keycap-preview-slice-forward
  "{" #'keycap-preview-tilt-backward
  "}" #'keycap-preview-tilt-forward
  "M-{" #'keycap-preview-tilt-left
  "M-}" #'keycap-preview-tilt-right
  "b" #'keycap-preview-toggle-bounds
  "G" #'keycap-preview-toggle-backend
  "e" #'keycap-preview-export-stl
  "l" #'keycap-preview-export-2d
  "?" #'keycap-preview-keys
  "C-g" #'keycap-preview-keyboard-quit)

(easy-menu-define keycap-preview-mode-menu keycap-preview-mode-map
  "Menu for `keycap-preview-mode'."
  '("Preview" :filter keycap--preview-menu-items))

(define-derived-mode keycap-preview-mode special-mode "keycap preview"
  "Major mode for the model of a `keycap-mode' script.

\\{keycap-preview-mode-map}"
  :interactive nil
  (setq-local cursor-type nil
              cursor-in-non-selected-windows nil
              truncate-lines nil
              show-trailing-whitespace nil
              display-line-numbers nil
              header-line-format '(:eval (keycap-preview-header))
              revert-buffer-function #'keycap--preview-revert
              context-menu-functions '(keycap--preview-context-menu))
  (add-hook 'kill-buffer-hook #'keycap--preview-cleanup nil t)
  (add-hook 'window-size-change-functions #'keycap--preview-resized nil t))

(provide 'keycap-preview)

;;; keycap-preview.el ends here
