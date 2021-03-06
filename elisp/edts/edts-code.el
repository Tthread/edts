;;; edts-code.el --- Utilities for compiling and running tools on code.

;; Copyright 2012-2013 Thomas Järvstrand <tjarvstrand@gmail.com>

;; Author: Thomas Järvstrand <thomas.jarvstrand@gmail.com>
;; Keywords: erlang
;; This file is not part of GNU Emacs.

;;
;; This file is part of EDTS.
;;
;; EDTS is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Lesser General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; EDTS is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Lesser General Public License for more details.
;;
;; You should have received a copy of the GNU Lesser General Public License
;; along with EDTS. If not, see <http://www.gnu.org/licenses/>.
;;

;; All code for compilation and in-buffer highlighting is a rewrite of work
;; done by Sebastian Weddmark Olsson.

(require 'eproject-extras)
(require 'path-util)

(require 'edts-face)

(defvar edts-code-issue-types '(edts-code-compile
                                edts-code-dialyzer
                                edts-code-eunit-failed)
  "List of overlay categories that are considered edts-code-issues")

(defvar edts-code-before-compile-hook
  nil
  "Hooks to run before compilation. Hooks are called with the name of
the module to be compiled as the only argument.")

(defvar edts-code-after-compile-hook
  '(edts-code-eunit
    edts-code-dialyze-related-hook-fun)
  "Hooks to run after compilation finishes. Hooks are called with the
compilation result as a symbol as the only argument")
(defvaralias ;; Compatibility
  'edts-code-after-compilation-hook
  'edts-code-after-compile-hook
  "This variable is deprecated, use `edts-code-after-compile-hook'")

(defvar edts-code-buffer-issues nil
  "A plist describing the current issues (errors and warnings) in the
current buffer. It is a plist with one entry for each type (compilation,
xref, eunit, etc). Each entry in turn is an plist with an entry for each
issue severity (error, warning, etc).")
(make-variable-buffer-local 'edts-code-buffer-issues)

(defcustom edts-code-inhibit-dialyzer-on-save t
  "If non-nil, don't run dialyzer analysis on every save."
  :group 'edts
  :type 'boolean)

(defconst edts-code-issue-overlay-priorities
  '((passed-test . 900)
    (failed-test . 901)
    (warning     . 902)
    (error       . 903))
  "The overlay priorities for compilation errors and warnings")

(defconst edts-code-issue-fringe-bitmap
  (when (boundp 'fringe-bitmaps)
    (if (member 'small-blip fringe-bitmaps)
        'small-blip
      'filled-square))
  "The bitmap to display in the fringe to indicade an issue on that
line.")

(defun edts-code-overlay-priority (type)
  "Returns the overlay priority of TYPE. Type can be either a string or
a symbol."
  (let ((type (if (symbolp type) type (intern type))))
    (cdr (assoc type edts-code-issue-overlay-priorities))))

(defun edts-code--set-issues (type issues)
  "Set the buffer's issues of TYPE to ISSUES. Issues should be an plist
with severity as key and a lists of issues as values"
  (setq edts-code-buffer-issues
        (plist-put edts-code-buffer-issues type issues)))

(defun edts-code-buffer-status ()
  "Return 'error if there are any edts errors in current buffer,
'warning if there are warnings and 'ok otherwise."
  (block nil
    (let ((status 'ok)
          (issues edts-code-buffer-issues))
      (while issues
        (when (plist-get (cadr issues) 'error)
          (return 'error))
        (when (plist-get (cadr issues) 'warning)
          (setq status 'warning))
        (setq issues (cddr issues)))
      status)))

(defun edts-code-compile-and-display ()
  "Compiles current buffer on node related the that buffer's project."
  (interactive)
  (edts-face-remove-overlays '(edts-code-compile))
  (let ((module   (ferl-get-module))
        (file     (buffer-file-name)))
    (when module
      (run-hook-with-args 'edts-code-before-compile-hook (intern module))
      (edts-compile-and-load-async
       module file #'edts-code-handle-compilation-result))))

(defun edts-code-handle-compilation-result (comp-res)
  (when comp-res
    (let ((result   (cdr (assoc 'result comp-res)))
          (errors   (cdr (assoc 'errors comp-res)))
          (warnings (cdr (assoc 'warnings comp-res))))
      (edts-code--set-issues 'edts-code-compile (list 'error   errors
                                                      'warning warnings))
      (edts-code-display-error-overlays 'edts-code-compile errors)
      (edts-code-display-warning-overlays 'edts-code-compile warnings)
      (edts-face-update-buffer-mode-line (edts-code-buffer-status))
      (run-hook-with-args 'edts-code-after-compile-hook (intern result))
      result)))

(defun edts-code--issue-to-file-map (issues)
  "Creates an alist with mapping between filenames and related elements
of ISSUES."
  (let* ((issue-alist nil))
    (mapc
     #'(lambda (e)
         (let* ((file (file-truename (cdr (assoc 'file e))))
                (new-e (cons e (cdr (assoc file issue-alist)))))
           (push (cons file new-e) issue-alist)))
     issues)
    issue-alist))

(defun edts-code-eunit (result)
  "Runs eunit tests for current buffer on node related to that
buffer's project."
  (interactive '(ok))
  (let ((module (ferl-get-module)))
    (when module
      (edts-face-remove-overlays '(edts-code-eunit-passed))
      (edts-face-remove-overlays '(edts-code-eunit-failed))
      (when (not (eq result 'error))
	(edts-get-module-eunit-async
	 module #'edts-code-handle-eunit-result)))))

(defun edts-code-handle-eunit-result (eunit-res)
  (when eunit-res
    (let ((failed (cdr (assoc 'failed eunit-res)))
          (passed (cdr (assoc 'passed eunit-res))))
      (edts-code--set-issues 'edts-code-eunit (list 'error failed))
      (edts-code-display-passed-test-overlays
       'edts-code-eunit-passed passed)
      (edts-code-display-failed-test-overlays
       'edts-code-eunit-failed failed)
      (edts-face-update-buffer-mode-line (edts-code-buffer-status)))))

(defun edts-code-dialyze-related-hook-fun (result)
  "Runs dialyzer as a hook if `edts-code-inhibit-dialyzer-on-save' is nil"
  (unless (or edts-code-inhibit-dialyzer-on-save (eq result 'error))
    (edts-code-dialyze-related)))

(defun edts-code-dialyze-related ()
  "Runs dialyzer for all live buffers related to current
buffer either by belonging to the same project or, if current buffer
does not belongi to any project, being in the same directory as the
current buffer's file."
  (interactive)
  (edts-face-remove-overlays '(edts-code-dialyzer))
  (if eproject-mode
      (edts-code-dialyze-project)
    (edts-code-dialyze-no-project)))

(defun edts-code-dialyze-project ()
  "Runs dialyzer for all live buffers with its file in current
buffer's project, on the node related to that project."
  (let* ((bufs (edts-project-buffer-list (eproject-root) '(ferl-get-module)))
         (mods (mapcar #'ferl-get-module bufs))
         (otp-plt nil)
         (out-plt (path-util-join edts-data-directory
                                  (concat (eproject-name) ".plt"))))
    (edts-get-dialyzer-analysis-async
     mods otp-plt out-plt #'edts-code-handle-dialyze-result)))

(defun edts-code-dialyze-no-project ()
  "Runs dialyzer for all live buffers with its file in current
buffer's directory, on the node related to that buffer."
  (let* ((dir      default-directory)
         (otp-plt  nil)
         (plt-file (concat (file-name-nondirectory dir) ".plt"))
         (out-plt  (path-util-join edts-data-directory plt-file))
         (mods     (edts-code--modules-in-dir dir)))
    (edts-get-dialyzer-analysis-async
     mods otp-plt out-plt #'edts-code-handle-dialyze-result)))

(defun edts-code--modules-in-dir (dir)
  "Return a list of all edts buffers visiting a file in DIR,
non-recursive."
  (let ((dir (directory-file-name dir)))
    (reduce
     #'(lambda (acc buf)
         (with-current-buffer buf
           (if (and (buffer-live-p buf)
                    (string= dir (path-util-dir-name (buffer-file-name)))
                    (ferl-get-module buf))
               (cons module acc)
             acc)))
     (buffer-list)
     :initial-value nil)))

(defun edts-code-handle-dialyze-result (analysis-res)
  (when analysis-res
    (let* ((all-warnings (cdr (assoc 'warnings analysis-res)))
           (warn-alist  (edts-code--issue-to-file-map all-warnings)))
      ;; Set the warning list in each project-buffer
      (with-each-buffer-in-project (gen-sym) (eproject-root)
        (let ((warnings (cdr (assoc (buffer-file-name) warn-alist))))
          (edts-code--set-issues 'edts-code-dialyzer (list 'warning warnings))
          (edts-face-update-buffer-mode-line (edts-code-buffer-status))
          (when warnings
            (edts-code-display-warning-overlays 'edts-code-dialyzer
                                                warnings)))))))


(defun edts-code-display-error-overlays (type errors)
  "Displays overlays for ERRORS in current buffer."
  (mapcar
   #'(lambda (error)
       (edts-code-display-issue-overlay type
                                        'edts-face-error-line
                                        'edts-face-error-fringe-bitmap
                                        error))
   errors))

(defun edts-code-display-warning-overlays (type warnings)
  "Displays overlays for WARNINGS in current buffer."
  (mapcar
   #'(lambda (warning)
       (edts-code-display-issue-overlay type
                                        'edts-face-warning-line
                                        'edts-face-warning-fringe-bitmap
                                        warning))
   warnings))

(defun edts-code-display-failed-test-overlays (type failed-tests)
  "Displays overlays for FAILED TESTS in current buffer."
  (mapcar
   #'(lambda (failed-test)
       (edts-code-display-issue-overlay type
                                        'edts-face-failed-test-line
                                        'edts-face-error-fringe-bitmap
                                        failed-test))
   failed-tests))

(defun edts-code-display-passed-test-overlays (type passed-tests)
  "Displays overlays for PASSED TESTS in current buffer."
  (mapcar
   #'(lambda (passed-test)
       (edts-code-display-issue-overlay type
                                        'edts-face-passed-test-line
                                        nil
                                        passed-test))
   passed-tests))


(defun edts-code-display-issue-overlay (type face fringe-face issue)
  "Displays overlay with FACE for ISSUE in current buffer."
  (let* ((line         (edts-code-find-issue-overlay-line issue))
         (issue-type   (cdr (assoc 'type issue)))
         (desc         (cdr (assoc 'description issue)))
         (help         (format "line %s, %s: %s" line issue-type desc))
         (overlay-type type)
         (prio         (edts-code-overlay-priority
                        (cdr (assoc 'type issue))))
         (fringe       (list edts-code-issue-fringe-bitmap fringe-face)))
    (when (integerp line)
      (edts-face-display-overlay face
                                 line
                                 help
                                 overlay-type
                                 prio
                                 nil
                                 fringe))))

(defun edts-code-find-issue-overlay-line (issue)
  "Tries to find where in current buffer to display overlay for `ISSUE'."
  (let ((cur-file (file-name-nondirectory (buffer-file-name)))
        (err-file (file-name-nondirectory (cdr (assoc 'file issue)))))
    (if (string-equal cur-file err-file)
        (cdr (assoc 'line issue))
        (save-excursion
          (goto-char (point-min))
          (let ((re (format "^-include\\(_lib\\)?(\".*%s\")." err-file)))
          ; This is probably not 100% correct in all cases
            (if (re-search-forward re nil t)
                (line-number-at-pos)
                0); Will to look strange, but at least we show the issue.
            )))))

(defun edts-code-next-issue ()
  "Moves point to the next error in current buffer and prints the error."
  (interactive)
  (push-mark)
  (let* ((overlay (edts-face-next-overlay (point) edts-code-issue-types)))
    (if overlay
        (progn
          (goto-char (overlay-start overlay))
          (message (overlay-get overlay 'help-echo)))
        (error "EDTS: no more issues found"))))

(defun edts-code-previous-issue ()
  "Moves point to the next error in current buffer and prints the error."
  (interactive)
  (push-mark)
  (let* ((overlay (edts-face-previous-overlay (point) edts-code-issue-types)))
    (if overlay
        (progn
          (goto-char (overlay-start overlay))
          (message (overlay-get overlay 'help-echo)))
        (error "EDTS: no more issues found"))))
