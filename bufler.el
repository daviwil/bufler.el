;;; bufler.el --- Bufler, the buffer and workspace manager  -*- lexical-binding: t; -*-

;; Copyright (C) 2020  Adam Porter

;; Author: Adam Porter <adam@alphapapa.net>
;; URL: https://github.com/alphapapa/bufler.el
;; Package-Version: 0.2-pre
;; Package-Requires: ((emacs "26.3") (dash "2.17") (dash-functional "2.17") (f "0.17") (magit-section "0.1"))
;; Keywords: convenience

;;; License:

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

;; This is a work-in-progress.  It is not published as a package yet.
;; Please feel free to use it and offer feedback.

;; Bufler is like Ibuffer, but using
;; [[https://github.com/magit/magit][magit-section]] to group buffers
;; in a very flexible way.

;;; Code:

;;;; Requirements

(require 'cl-lib)
(require 'eieio)
(require 'map)
(require 'project)
(require 'subr-x)
(require 'vc)

;; For faces.
(require 'outline)

(require 'dash)
(require 'dash-functional)
(require 'f)
(require 'magit-section)

(require 'group-tree)

;;;; Variables

(defvar bufler-mode-map
  (let ((map (copy-keymap magit-section-mode-map)))
    (define-key map (kbd "g") #'bufler)
    (define-key map (kbd "k") #'bufler-kill)
    (define-key map (kbd "s") #'bufler-save)
    (define-key map (kbd "RET") #'bufler-pop)
    map))

(defvar bufler-emacs-source-directory
  (cl-reduce (lambda (val fn)
               (funcall fn val))
             ;; I feel like Emacs needs a function like `f-parent'.
             '(file-name-directory directory-file-name file-name-directory
                                   directory-file-name file-name-directory)
             :initial-value (locate-library "cl-lib"))
  "The directory containing the installed source code for this Emacs.
Usually this will be something like \"/usr/share/emacs/VERSION\".")

;;;; Customization

(defgroup bufler nil
  "Like Ibuffer, but using Magit-Section sections."
  :link '(url-link "https://github.com/alphapapa/bufler.el")
  :group 'convenience)

(defcustom bufler-reverse nil
  "Reverse group order after grouping buffers."
  :type 'boolean)

(defcustom bufler-face-prefix "outline-"
  "Prefix used to look up faces.
The depth number is appended to the prefix."
  :type '(choice (const :tag "Outline faces" "outline-")
                 (const :tag "Prism faces (requires `prism')" "prism-level-")))

(defcustom bufler-initial-face-depth 1
  ;; Setting it to 1, because in the default Emacs config, it presents
  ;; better contrast between the first two levels (blue/orange rather than
  ;; black/blue), and the bold blue is a bit less harsh than the bold black.
  "First depth level used for outline faces.
May be used to skip the first N level faces.  See
`bufler-face-prefix'."
  :type 'integer)

(defcustom bufler-vc-state nil
  "Show buffers' VC state.
With a lot of file-backed buffers open, this might be slow,
because `vc-registered' and `vc-refresh-state' must be called to
get correct results."
  :type 'boolean)

(defcustom bufler-filter-fns (list #'bufler-hidden-buffer-p)
  "Buffers that match these functions are not shown."
  :type '(repeat function))

(defcustom bufler-group-path-separator " ► "
  "Separator shown between path elements."
  :type 'string)

(defcustom bufler-buffer-mode-annotate-preds
  (list (lambda (buffer)
          "Return non-nil if BUFFER's major-mode is `dired-mode'."
          (member (buffer-local-value 'major-mode buffer)
                  '(dired-mode))))
  "Predicates that determine whether to annotate a buffer with its major mode."
  :type '(repeat function))

(defface bufler-group
  '((t (:underline nil :weight bold)))
  "Face for Bufler groups.")

(defface bufler-buffer
  '((t (:inherit default)))
  "Face for normal (i.e. file-backed) buffers.")

(defface bufler-buffer-special
  '((t (:inherit default :slant italic)))
  "Face for special buffers.")

(defface bufler-mode
  '((t (:inherit font-lock-type-face)))
  "Face for the mode of buffers and groups.
Only used in the mode annotation in each buffer's formatted
string, not in group headers.")

(defface bufler-size
  '((t (:inherit font-lock-comment-face)))
  "Face for the size of buffers and groups.")

(defface bufler-vc
  '((t (:inherit font-lock-warning-face)))
  "Face for the VC status of buffers.")

;; Silence byte-compiler.  This is defined later in the file.
(defvar bufler-groups)

;;;; Commands

(define-derived-mode bufler-mode magit-section-mode "Bufler")

;;;###autoload
(defun bufler ()
  "Show Bufler."
  (interactive)
  (cl-labels
      ;; This gets a little hairy because we have to wrap `-group-by'
      ;; to implement "chains" of grouping functions.
      (
       (insert-thing (thing &optional (level 0))
                     (pcase thing
                       ((pred bufferp) (insert-buffer thing level))
                       (_ (insert-group thing level))))
       (insert-buffer
        (buffer level) (magit-insert-section nil (bufler-buffer buffer)
                         (insert (make-string (* 2 level) ? ) (bufler-format-buffer buffer level) "\n")))
       (insert-group
        (group level) (pcase (car group)
                        ('nil (pcase-let* ((`(,_type . ,things) group))
                                (--each things
                                  (insert-thing it level))))
                        (_ (pcase-let* ((`(,type . ,things) group)
                                        (num-buffers 0))
                             ;; This almost seems lazy, using `-tree-map-nodes'
                             ;; with `bufferp', but it works, and it's correct,
                             ;; and since `bufferp' is in C, maybe it's even fast.
                             (-tree-map-nodes #'bufferp (lambda (&rest _)
                                                          (cl-incf num-buffers))
                                              group)
                             (magit-insert-section (bufler-group (cdr things))
                               (magit-insert-heading (make-string (* 2 level) ? )
                                 (format-group type level)
                                 (propertize (format " (%s)" num-buffers)
                                             'face 'bufler-size))
                               (--each things
                                 (insert-thing it (1+ level))))))) )
       (format-group
        (group level) (propertize (cl-typecase group
                                    (string group)
                                    (otherwise (prin1-to-string group)))
                                  'face (list :inherit (list 'bufler-group (bufler-level-face level)))))
       (hidden-p (buffer)
                 (string-prefix-p " " (buffer-name buffer)))
       (as-string
        (arg) (cl-typecase arg
                (string arg)
                (otherwise (format "%s" arg))))
       (format< (test-dir buffer-dir)
                (string< (as-string test-dir) (as-string buffer-dir)))
       (boring-p (buffer)
                 (hidden-p buffer)))
    (let* ((inhibit-read-only t)
           (groups (bufler-buffers))
           pos)
      (when bufler-reverse
        (setf groups (nreverse (-sort #'format< groups))))
      (with-current-buffer (get-buffer-create "*Bufler*")
        (setf pos (point))
        (bufler-mode)
        (erase-buffer)
        (magit-insert-section (bufler-root)
          (--each groups
            (insert-thing it 0)))
        (setf buffer-read-only t)
        (pop-to-buffer (current-buffer))
        (goto-char pos)))))

;;;;; Buffer commands

(defun bufler-visit ()
  "Visit buffer at point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (buffer-p (eq 'bufler-buffer (oref section type))))
    (pop-to-buffer (oref section value))))

(defmacro bufler-define-buffer-command (name docstring command)
  "Define an Bufler command to call COMMAND on selected buffers.
It is named `bufler-NAME' and uses DOCSTRING.

NAME, okay, `checkdoc'?"
  (declare (indent defun))
  `(defun ,(intern (concat "bufler-" (symbol-name name))) (&rest _args)
     ,docstring
     (interactive)
     (when-let* ((sections (or (magit-region-sections) (list (magit-current-section)))))
       (bufler--map-sections ,command sections)
       (bufler))))

(bufler-define-buffer-command kill "Kill buffer."
  #'kill-buffer)

(bufler-define-buffer-command pop "Pop to buffer."
  #'pop-to-buffer)

(bufler-define-buffer-command save "Save buffer."
  (lambda (buffer)
    (when (buffer-file-name buffer)
      (with-current-buffer buffer
        (save-buffer)))))

;;;; Functions

(cl-defun bufler-buffers (&optional (groups bufler-groups))
  "Return buffers grouped by GROUPS."
  (group-tree groups (cl-loop with buffers = (buffer-list)
                              for fn in bufler-filter-fns
                              do (setf buffers (cl-remove-if fn buffers))
                              finally return buffers)))

(defun bufler-level-face (level)
  "Return face for LEVEL."
  (intern (format "%s%s" bufler-face-prefix (+ level bufler-initial-face-depth))))

(defun bufler-format-buffer (buffer depth)
  "Return string for BUFFER to be displayed at DEPTH."
  (let* ((modified-s (propertize (if (and (buffer-file-name buffer)
                                          (buffer-modified-p buffer))
                                     "*" "")
                                 'face 'font-lock-warning-face))
         (buffer-face (if (bufler-special-buffer-p buffer)
                          'bufler-buffer-special 'bufler-buffer))
         (level-face (bufler-level-face depth))
         (face (list :inherit (list buffer-face level-face)))
         (name (propertize (buffer-name buffer) 'face face))
         (size (propertize (concat "(" (file-size-human-readable (buffer-size buffer)) ")")
                           'face 'bufler-size))
         ;; Getting correct, up-to-date results from vc is harder than it should be.
         (vc-state (when bufler-vc-state
                     (or (when (and (buffer-file-name buffer)
                                    (vc-registered (buffer-file-name buffer)))
                           (with-current-buffer buffer
                             ;; Unfortunately, this seems to be necessary to get the correct state.
                             (vc-refresh-state))
                           (pcase (vc-state (buffer-file-name buffer))
                             ((and 'edited it)
                              (propertize (format " %s" it)
                                          'face 'bufler-vc))))
                         "")))
         (mode-annotation (when (cl-loop for fn in bufler-buffer-mode-annotate-preds
                                         thereis (funcall fn buffer))

                            (propertize (replace-regexp-in-string
                                         (rx "-mode" eos) ""
                                         (format " %s" (buffer-local-value 'major-mode buffer))
                                         t t)
                                        'face 'bufler-mode))))
    (concat name modified-s " " size vc-state mode-annotation)))

(defun bufler--map-sections (fn sections)
  "Map FN across SECTIONS."
  (cl-labels ((do-section
               (section) (if (oref section children)
                             (mapc #'do-section (oref section children))
                           (cl-typecase (oref section value)
                             (list (mapc #'do-thing (oref section value)))
                             (buffer (funcall fn (oref section value))))))
              (do-thing
               (thing) (cl-typecase thing
                         (buffer (funcall fn thing))
                         (magit-section (do-section thing))
                         (list (mapc #'do-thing thing)))))
    (mapc #'do-section sections)))

;;;;; Buffer predicates

;; These functions take a buffer as their sole argument.  They may be
;; used in the grouping predicates defined later.

(defun bufler-special-buffer-p (buffer)
  "Return non-nil if BUFFER is special.
That is, if its name starts with \"*\"."
  (string-match-p (rx bos (optional (1+ blank)) "*")
                  (buffer-name buffer)))

(defun bufler-hidden-buffer-p (buffer)
  "Return non-nil if BUFFER is hidden.
That is, if its name starts with \" \"."
  (string-match-p (rx bos (1+ blank)) (buffer-name buffer)))

;;;;; Grouping

;;;;;; Applicators

;; These functions are used to partially apply arguments to the
;; predicates defined below, and they're intended to be used to define
;; groups in `bufler-groups'.

(defun bufler-group (type &rest args)
  "Return a grouping function applying ARGS to `bufler-group-TYPE'.
TYPE, okay, `checkdoc'?"
  (let ((fn (intern (concat "bufler-group-" (symbol-name type)))))
    (apply #'apply-partially fn args)))

;; NOTE: We use `byte-compile' explicitly because uncompiled closures
;; don't work in `-select', or something like that.

(defun bufler-and (name &rest preds)
  ;; Copied from dash-functional.el.
  "Return a grouping function that groups buffers matching all of PREDS.
The resulting group is named NAME.  This can also be used with a
single predicate to apply a name to a group."
  (byte-compile (lambda (x)
                  (when (-all? (-cut funcall <> x) preds)
                    name))))

(defun bufler-or (name &rest preds)
  ;; Copied from dash-functional.el.
  "Return a grouping function that groups buffers matching any of PREDS.
The resulting group is named NAME."
  (byte-compile (lambda (x)
                  (when (-any? (-cut funcall <> x) preds)
                    name))))

(defun bufler-not (name pred)
  ;; Copied from dash-functional.el.
  "Return a grouping function that groups buffers which do not match PRED.
The resulting group is named NAME."
  (byte-compile (lambda (x)
                  (unless (funcall pred x)
                    name))))

;;;;;; Grouping predicates

;; These functions are intended to be partially applied using the
;; applicator functions above.  Each one, in its partially applied
;; form, should take a buffer as its sole argument and return a key by
;; which to group its buffer, or nil if it should not be grouped.

(defun bufler-group-dir (dirs depth buffer)
  "Group buffers in DIRS.
DIRS may be one or a list of strings which are directory paths.
If the BUFFER's `default-directory' is or is a descendant of
DIRS, a string based on the first of DIRS is returned; otherwise,
nil.

DEPTH may be an integer specifying a maximum depth of
subdirectories of DIR, up to which a group is created for the
subdirectory.  For example, if DIR were \"~/src/emacs\", and
DEPTH were 1, and a buffer's directory were
\"~/src/emacs/bufler.el\", a group for
\"~/src/emacs/bufler.el\" would be created rather than putting
the buffer in a group for \"~/src/emacs\".  (NOTE THAT THIS
FEATURE MAY BE BUGGY AT THE MOMENT.)

Note that directory paths are canonicalized before comparing, so,
e.g. symlinks are resolved."
  (let* ((buffer-dir (buffer-local-value 'default-directory buffer))
         (dirs (if (listp dirs) dirs (list dirs)))
         (group-name (concat "Dir: " (car dirs))))
    ;; MAYBE: Memoize `f-canonical' here.
    (cl-labels ((dir-related-p (test-dir buffer-dir)
                               (let ((test-dir (f-canonical test-dir))
                                     (buffer-dir (f-canonical buffer-dir)))
                                 (or (f-equal? test-dir buffer-dir)
                                     (f-ancestor-of? test-dir buffer-dir)))))
      (unless (listp dirs)
        (setf dirs (list dirs)))
      (cl-loop for dir in dirs
               when (dir-related-p dir buffer-dir)
               return (if depth
                          (concat "Dir: "
                                  (apply #'f-join dir
                                         (-take depth (f-split (f-relative buffer-dir dir)))))
                        group-name)))))

;; These docstrings contain contorted English to satisfy the whims of
;; `checkdoc'.

(defun bufler-group-name-match (name regexp buffer)
  "Group BUFFERs whose names match REGEXP.
If it matches, NAME is returned, otherwise nil."
  (cl-check-type name string)
  (when (string-match-p regexp (buffer-name buffer))
    (propertize name 'face 'magit-head)))

(defun bufler-group-mode-match (name regexp buffer)
  "Group buffers whose major modes match REGEXP.
If BUFFER's mode matches REGEXP, NAME is returned, otherwise
nil."
  (cl-check-type name string)
  (let ((mode-name (symbol-name (buffer-local-value 'major-mode buffer))))
    (when (string-match-p regexp mode-name)
      (propertize name 'face 'magit-head))))

;;;;;; Auto-groups

;; These functions automatically create groups for buffers they match,
;; keyed by their return value.  However, when one of these functions
;; returns nil, the buffer is not grouped into a "nil" group, but is
;; raised to the next level.  (This is implemented in the `bufler'
;; function.)

(defmacro bufler-defauto-group (name &rest body)
  "Define a grouping function named `bufler-group-by-NAME'.
It takes one argument, a buffer, which is bound to `buffer' in
BODY.  It should return a key by which to group its buffer, or
nil if it should not be grouped.

NAME, okay, `checkdoc'?"
  (declare (indent defun))
  (let* ((fn-name (intern (concat "bufler-group-auto-" (symbol-name name))))
         (docstring (format "Group buffers by %s." name)))
    `(defun ,fn-name (buffer)
       ,docstring
       ,@body)))

(bufler-defauto-group file
  (when-let* ((filename (or (buffer-file-name buffer)
                            (when (buffer-base-buffer buffer)
                              (buffer-file-name (buffer-base-buffer buffer))))))
    (propertize (concat "File: " (file-name-nondirectory filename))
                'face 'magit-section-heading)))

(bufler-defauto-group directory
  (propertize (concat "Dir: " (file-truename (buffer-local-value 'default-directory buffer)))
              'face 'magit-section-heading))

(bufler-defauto-group mode
  (propertize (symbol-name (buffer-local-value 'major-mode buffer))
              'face 'magit-head))

(bufler-defauto-group indirect
  (when (buffer-base-buffer buffer)
    "*indirect*"))

(bufler-defauto-group hidden
  (if (string-prefix-p " " (buffer-name buffer))
      "*hidden*"
    "Normal"))

(bufler-defauto-group special
  (if (bufler-special-buffer-p buffer)
      "*special*"
    "non-special buffers"))

(bufler-defauto-group project
  (when-let* ((project (with-current-buffer buffer
                         (project-current)))
              (project-root (car (project-roots project))))
    (concat "Project: " project-root)))

(bufler-defauto-group tramp
  (when-let* ((host (file-remote-p (buffer-local-value 'default-directory buffer)
                                   'host)))
    (concat "Tramp: " host)))

;;;;;; Group-defining macro

;; This seems to work better than I expected.

;;;###autoload
(defmacro bufler-defgroups (&rest groups)
  "Expand GROUPS into a group definition suitable for `bufler-groups'.
See documentation for details."
  (declare (indent defun))
  `(cl-macrolet ((group (&rest groups) `(list ,@groups))
                 (group-and (name &rest groups)
                            `(bufler-and ,name ,@groups))
                 (group-or (name &rest groups)
                           `(bufler-or ,name ,@groups))
                 (group-not (name group)
                            `(bufler-not ,name ,group))
                 (mode-match (name regexp)
                             `(bufler-group 'mode-match ,name ,regexp))
                 (name-match (name regexp)
                             `(bufler-group 'name-match ,name ,regexp))
                 (dir (dirs &optional depth)
                      `(bufler-group 'dir ,dirs ,depth))
                 (auto-directory () `(bufler-group 'auto-directory))
                 (auto-file () `(bufler-group 'auto-file))
                 (auto-indirect () `(bufler-group 'auto-indirect))
                 (auto-mode () `(bufler-group 'auto-mode))
                 (auto-project () `(bufler-group 'auto-project))
                 (auto-tramp () `(bufler-group 'auto-tramp)))
     (list ,@groups)))

;;;; Additional customization

;; These options must be defined after functions they call in their
;; values, and after the `bufler-defgroups' macro.

(defcustom bufler-groups
  (bufler-defgroups
   (group
    ;; Subgroup collecting all `help-mode' and `info-mode' buffers.
    (group-or "*Help/Info*"
              (mode-match "*Help*" (rx bos "help-"))
              (mode-match "*Info*" (rx bos "info-"))))
   (group
    ;; Subgroup collecting all special buffers (i.e. ones that are not
    ;; file-backed), except `magit-status-mode' buffers (which are allowed to fall
    ;; through to other groups, so they end up grouped with their project buffers).
    (group-and "*Special*"
               (lambda (buffer)
                 (unless (or (funcall (mode-match "Magit" (rx bos "magit-status"))
                                      buffer)
                             (funcall (mode-match "Dired" (rx bos "dired"))
                                      buffer)
                             (funcall (auto-file) buffer))
                   "*Special*")))
    (group
     ;; Subgroup collecting these "special special" buffers
     ;; separately for convenience.
     (name-match "**Special**"
                 (rx bos "*" (or "Messages" "Warnings" "scratch" "Backtrace") "*")))
    (group
     ;; Subgroup collecting all other Magit buffers, grouped by directory.
     (mode-match "*Magit* (non-status)" (rx bos (or "magit" "forge") "-"))
     (auto-directory))
    ;; Subgroup for Helm buffers.
    (mode-match "*Helm*" (rx bos "helm-"))
    ;; Remaining special buffers are grouped automatically by mode.
    (auto-mode))
   ;; All buffers under "~/.emacs.d" (or wherever it is).
   (dir user-emacs-directory)
   (group
    ;; Subgroup collecting buffers in `org-directory' (or "~/org" if
    ;; `org-directory' is not yet defined).
    (dir (if (bound-and-true-p org-directory)
             org-directory
           "~/org"))
    (group
     ;; Subgroup collecting indirect Org buffers, grouping them by file.
     ;; This is very useful when used with `org-tree-to-indirect-buffer'.
     (auto-indirect)
     (auto-file))
    ;; Group remaining buffers by whether they're file backed, then by mode.
    (group-not "*special*" (auto-file))
    (auto-mode))
   (group
    ;; Subgroup collecting buffers in a version-control project,
    ;; grouping them by directory.
    (auto-project))
   ;; Group remaining buffers by directory, then major mode.
   (auto-directory)
   (auto-mode))
  "List of grouping functions recursively applied to buffers.
Note that this is likely to look very ugly in the customization
UI due to lambdas being byte-compiled.  Please see the source
code for this option's definition to see the human-readable group
definitions.

Each item may be an Bufler grouping function or a list of
grouping functions (each element of which may also be a list, and
so forth, spiraling into infinity...oh, hello, Alice).

When a buffer matches the first grouping function in a list of
them, it is recursively grouped according to the rest of the
functions in that group; otherwise it is matched by the rest of
the functions after that group.  Therefore, a list may contain a
single grouping function to prevent further sub-grouping of
buffers matching a function.

This may seem confusing at first, but once you get the hang of
it, it's powerful and flexible.  Study the default groups and the
resulting output, and you should figure it out quickly enough."
  :type '(repeat (or function list)))

;;;; Footer

(provide 'bufler)

;;; bufler.el ends here