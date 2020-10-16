;;; crdt.el --- collaborative editing using Conflict-free Replicated Data Types
;;
;; Copyright (C) 2020 Qiantan Hong
;;
;; Author: Qiantan Hong <qhong@mit.edu>
;; Maintainer: Qiantan Hong <qhong@mit.edu>
;; Keywords: collaboration crdt
;;
;; crdt.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; crdt.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with crdt.el.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; * Algorithm
;;   This packages implements the Logoot split algorithm
;;     André, Luc, et al.
;;     "Supporting adaptable granularity of changes for massive-scale collaborative editing."
;;     9th IEEE International Conference on Collaborative Computing: Networking, Applications and Worksharing.
;;     IEEE, 2013.
;; * Protocol
;;   Text-based version
;;   (it should be easy to migrate to a binary version.  Using text for better debugging for now)
;;   Every message takes the form (type . body)
;;   type can be: insert delete cursor hello challenge sync overlay
;;   - insert
;;     body takes the form (buffer-name crdt-id position-hint content)
;;     - position-hint is the buffer position where the operation happens at the site
;;       which generates the operation.  Then we can play the trick that start search
;;       near this position at other sites to speedup crdt-id search
;;     - content is the string to be inserted
;;   - delete
;;     body takes the form (buffer-name position-hint (crdt-id . length)*)
;;   - cursor
;;     body takes the form
;;          (site-id point-position-hint point-crdt-id mark-position-hint mark-crdt-id)
;;     *-crdt-id can be either a CRDT ID, or
;;       - nil, which means clear the point/mark
;;       - "", which means (point-max)
;;   - contact
;;     body takes the form
;;          (site-id name address port)
;;     when name is nil, clear the contact for this site-id
;;   - focus
;;     body takes the form (site-id buffer-name)
;;   - hello
;;     This message is sent from client to server, when a client connect to the server.
;;     body takes the form (client-name &optional response)
;;   - challenge
;;     body takes the form (salt)
;;   - login
;;     It's always sent after server receives a hello message.
;;     Assigns an ID to the client
;;     body takes the form (site-id).
;;   - sync
;;     This message is sent from server to client to get it sync to the state on the server.
;;     Might be used for error recovery or other optimization in the future.
;;     One optimization I have in mind is let server try to merge all CRDT item into a single
;;     one and try to synchronize this state to clients at best effort.
;;     body takes the form (buffer-name major-mode content . crdt-id-list)
;;     - major-mode is the major mode used at the server site
;;     - content is the string in the buffer
;;     - crdt-id-list is generated from CRDT--DUMP-IDS
;;   - desync
;;     Indicates that the server has stopped sharing a buffer.
;;     body takes the form (buffer-name)
;;   - overlay-add
;;     body takes the form (buffer-name site-id logical-clock species
;;                          front-advance rear-advance
;;                          start-position-hint start-crdt-id
;;                          end-position-hint end-crdt-id)
;;   - overlay-move
;;     body takes the form (buffer-name site-id logical-clock
;;                          start-position-hint start-crdt-id
;;                          end-position-hint end-crdt-id)
;;   - overlay-put
;;     body takes the form (buffer-name site-id logical-clock prop value)
;;   - overlay-remove
;;     body takes the form (buffer-name site-id logical-clock)


;;; Code:


;;; Customs
(defgroup crdt nil
  "Collaborative editing using Conflict-free Replicated Data Types."
  :prefix "crdt-"
  :group 'applications)
(defcustom crdt-ask-for-name t
  "Ask for display name everytime a CRDT session is to be started."
  :type 'boolean)
(defcustom crdt-default-name "anonymous"
  "Default display name."
  :type 'string)
(defcustom crdt-ask-for-password t
  "Ask for server password everytime a CRDT server is to be started."
  :type 'boolean)

(require 'cl-lib)

;;; Pseudo cursor/region utils
(require 'color)
(defvar crdt-cursor-region-colors
  (let ((n 10))
    (cl-loop for i below n
          for hue by (/ 1.0 n)
          collect (cons
                   (apply #'color-rgb-to-hex
                          (color-hsl-to-rgb hue 0.5 0.5))
                   (apply #'color-rgb-to-hex
                          (color-hsl-to-rgb hue 0.2 0.5))))))

(defun crdt--get-cursor-color (site-id)
  "Get cursor color for SITE-ID."
  (car (nth (mod site-id (length crdt-cursor-region-colors)) crdt-cursor-region-colors)))
(defun crdt--get-region-color (site-id)
  "Get region color for SITE-ID."
  (cdr (nth (mod site-id (length crdt-cursor-region-colors)) crdt-cursor-region-colors)))
(defun crdt--move-cursor (ov pos)
  "Move pseudo cursor overlay OV to POS."
  ;; Hax!
  (let* ((eof (eq pos (point-max)))
         (eol (unless eof (eq (char-after pos) ?\n)))
         (end (if eof pos (1+ pos)))
         (display-string
          (when eof
            (unless (or (eq (point) (point-max))
                        (cl-some (lambda (ov)
                                   (and (eq (overlay-get ov 'category) 'crdt-pseudo-cursor)
                                        (overlay-get ov 'before-string)))
                                 (overlays-in (point-max) (point-max))))
              (propertize " " 'face (overlay-get ov 'face))))))
    (move-overlay ov pos end)
    (overlay-put ov 'before-string display-string)))
(defun crdt--move-region (ov pos mark)
  "Move pseudo marked region overlay OV to mark between POS and MARK."
  (move-overlay ov (min pos mark) (max pos mark)))

;;; CRDT ID utils
;; CRDT IDs are represented by unibyte strings (for efficient comparison)
;; Every two bytes represent a big endian encoded integer
;; For base IDs, last two bytes are always representing site ID
;; Stored strings are BASE-ID:OFFSETs. So the last two bytes represent offset,
;; and second last two bytes represent site ID
(defconst crdt--max-value (lsh 1 16))
;; (defconst crdt--max-value 16)
;; for debug
(defconst crdt--low-byte-mask 255)
(defsubst crdt--get-two-bytes (string index)
  "Get the big-endian encoded integer from STRING starting from INDEX.
INDEX is counted by bytes."
  (logior (lsh (elt string index) 8)
          (elt string (1+ index))))
(defsubst crdt--get-two-bytes-with-offset (string offset index default)
  "Helper function for CRDT--GENERATE-ID.
Get the big-endian encoded integer from STRING starting from INDEX,
but with last two-bytes of STRING (the offset portion) replaced by OFFSET,
and padded infintely by DEFAULT to the right."
  (cond ((= index (- (string-bytes string) 2))
         offset)
        ((< (1+ index) (string-bytes string))
         (logior (lsh (elt string index) 8)
                 (elt string (1+ index))))
        (t default)))

(defsubst crdt--id-offset (id)
  "Get the literal offset integer from ID.
Note that it might deviate from real offset for a character
in the middle of a block."
  (crdt--get-two-bytes id (- (string-bytes id) 2)))
(defsubst crdt--set-id-offset (id offset)
  "Set the OFFSET portion of ID destructively."
  (let ((length (string-bytes id)))
    (aset id (- length 2) (lsh offset -8))
    (aset id (- length 1) (logand offset crdt--low-byte-mask))))
(defsubst crdt--id-replace-offset (id offset)
  "Create and return a new id string by replacing the OFFSET portion from ID."
  (let ((new-id (substring id)))
    (crdt--set-id-offset new-id offset)
    new-id))
(defsubst crdt--id-site (id)
  "Get the site id from ID."
  (crdt--get-two-bytes id (- (string-bytes id) 4)))
(defsubst crdt--generate-id (low-id low-offset high-id high-offset site-id)
  "Generate a new ID between LOW-ID and HIGH-ID.
The generating site is marked as SITE-ID.
Offset parts of LOW-ID and HIGH-ID are overriden by LOW-OFFSET
and HIGH-OFFSET.  (to save two copying from using CRDT--ID-REPLACE-OFFSET)"
  (let* ((l (crdt--get-two-bytes-with-offset low-id low-offset 0 0))
         (h (crdt--get-two-bytes-with-offset high-id high-offset 0 crdt--max-value))
         (bytes (cl-loop for pos from 2 by 2
                      while (< (- h l) 2)
                      append (list (lsh l -8)
                                   (logand l crdt--low-byte-mask))
                      do (setq l (crdt--get-two-bytes-with-offset low-id low-offset pos 0))
                      do (setq h (crdt--get-two-bytes-with-offset high-id high-offset pos crdt--max-value))))
         (m (+ l 1 (random (- h l 1)))))
    (apply #'unibyte-string
           (append bytes (list (lsh m -8)
                               (logand m crdt--low-byte-mask)
                               (lsh site-id -8)
                               (logand site-id crdt--low-byte-mask)
                               0
                               0)))))

;; CRDT-ID text property actually stores a cons of (ID-STRING . END-OF-BLOCK-P)
(defsubst crdt--get-crdt-id-pair (pos &optional obj)
  "Get the (CRDT-ID . END-OF-BLOCK-P) pair at POS in OBJ."
  (get-text-property pos 'crdt-id obj))
(defsubst crdt--get-starting-id (pos &optional obj)
  "Get the CRDT-ID at POS in OBJ."
  (car (crdt--get-crdt-id-pair pos obj)))
(defsubst crdt--end-of-block-p (pos &optional obj)
  "Get the END-OF-BLOCK-P at POS in OBJ."
  (cdr (crdt--get-crdt-id-pair pos obj)))
(defsubst crdt--get-starting-id-maybe (pos &optional obj limit)
  "Get the CRDT-ID at POS in OBJ if POS is no smaller than LIMIT.
Return NIL otherwise."
  (unless (< pos (or limit (point-min)))
    (car (get-text-property pos 'crdt-id obj))))
(defsubst crdt--get-id-offset (starting-id pos &optional obj limit)
  "Get the real offset integer for a character at POS.
Assume the stored literal ID is STARTING-ID."
  (let* ((start-pos (previous-single-property-change (1+ pos) 'crdt-id obj (or limit (point-min)))))
    (+ (- pos start-pos) (crdt--id-offset starting-id))))

;;; CRDT ID and text property utils
(defsubst crdt--get-id (pos &optional obj left-limit right-limit)
  "Get the real CRDT ID at POS."
  (let ((right-limit (or right-limit (point-max)))
        (left-limit (or left-limit (point-min))))
    (cond ((>= pos right-limit) "")
          ((< pos left-limit) nil)
          (t
           (let* ((starting-id (crdt--get-starting-id pos obj))
                  (left-offset (crdt--get-id-offset starting-id pos obj left-limit)))
             (crdt--id-replace-offset starting-id left-offset))))))

(defsubst crdt--set-id (pos id &optional end-of-block-p obj limit)
  "Set the crdt ID and END-OF-BLOCK-P at POS in OBJ.
Any characters after POS but before LIMIT that used to
have the same (CRDT-ID . END-OF-BLOCK-P) pair are also updated
with ID and END-OF-BLOCK-P."
  (put-text-property pos (next-single-property-change pos 'crdt-id obj (or limit (point-max))) 'crdt-id (cons id end-of-block-p) obj))

(cl-defmacro crdt--with-insertion-information
    ((beg end &optional beg-obj end-obj beg-limit end-limit) &body body)
  "Helper macro to setup some useful variables."
  `(let* ((not-begin (> ,beg ,(or beg-limit '(point-min)))) ; if it's nil, we're at the beginning of buffer
          (left-pos (1- ,beg))
          (starting-id-pair (when not-begin (crdt--get-crdt-id-pair left-pos ,beg-obj)))
          (starting-id (if not-begin (car starting-id-pair) ""))
          (left-offset (if not-begin (crdt--get-id-offset starting-id left-pos ,beg-obj ,beg-limit) 0))
          (not-end (< ,end ,(or end-limit '(point-max))))
          (ending-id (if not-end (crdt--get-starting-id ,end ,end-obj) ""))
          (right-offset (if not-end (crdt--id-offset ending-id) 0))
          (beg ,beg)
          (end ,end)
          (beg-obj ,beg-obj)
          (end-obj ,end-obj)
          (beg-limit ,beg-limit)
          (end-limit ,end-limit))
     ,@body))
(defmacro crdt--split-maybe ()
  '(when (and not-end (eq starting-id (crdt--get-starting-id end end-obj)))
    ;; need to split id block
    (crdt--set-id end (crdt--id-replace-offset starting-id (1+ left-offset))
     (crdt--end-of-block-p left-pos beg-obj) end-obj end-limit)
    (rplacd (get-text-property left-pos 'crdt-id beg-obj) nil) ;; clear end-of-block flag
    t))

(defsubst crdt--same-base-p (a b)
  (let* ((a-length (string-bytes a))
         (b-length (string-bytes b)))
    (and (eq a-length b-length)
         (let ((base-length (- a-length 2)))
           (eq t (compare-strings a 0 base-length b 0 base-length))))))

;;; Buffer local variables
(defmacro crdt--defvar-permanent-local (name &optional val docstring)
  `(progn
     (defvar-local ,name ,val ,docstring)
     (put ',name 'permanent-local t)))
(crdt--defvar-permanent-local crdt--status-buffer)
(defsubst crdt--assimilate-status-buffer (buffer)
  (let ((status-buffer crdt--status-buffer))
    (with-current-buffer buffer
      (setq crdt--status-buffer status-buffer))))
(defmacro crdt--defvar-session (name &optional val docstring)
  (let ((setter-name (intern (format "%s-setter" name))))
    `(progn
       (defvar-local ,name ,val ,docstring)
       (defun ,name ()
         (when crdt--status-buffer
           (with-current-buffer crdt--status-buffer ,name)))
       (defun ,setter-name (val)
         (when crdt--status-buffer
           (with-current-buffer crdt--status-buffer (setq ,name val))))
       (gv-define-simple-setter ,name ,setter-name))))

(crdt--defvar-session crdt--local-id nil "Local site-id.")
(crdt--defvar-session crdt--local-clock 0 "Local logical clock.")
(defvar crdt--inhibit-update nil "When set, don't call CRDT--LOCAL-* on change.
This is useful for functions that apply remote change to local buffer,
to avoid recusive calling of CRDT synchronization functions.")
(crdt--defvar-permanent-local crdt--changed-string nil)
(crdt--defvar-permanent-local crdt--last-point nil)
(crdt--defvar-permanent-local crdt--last-mark nil)
(crdt--defvar-permanent-local crdt--pseudo-cursor-table nil
                              "A hash table that maps SITE-ID to CONSes of the form (CURSOR-OVERLAY . REGION-OVERLAY).")
(cl-defstruct (crdt--contact-metadata
                (:constructor crdt--make-contact-metadata (display-name focused-buffer-name host service)))
  display-name host service focused-buffer-name)
(crdt--defvar-session crdt--contact-table nil
                      "A hash table that maps SITE-ID to CRDT--CONTACT-METADATAs.")
(cl-defstruct (crdt--overlay-metadata
                (:constructor crdt--make-overlay-metadata
                              (lamport-timestamp species front-advance rear-advance plist))
                (:copier crdt--copy-overlay-metadata))
  ""
  lamport-timestamp species front-advance rear-advance plist)
(crdt--defvar-permanent-local crdt--overlay-table nil
                              "A hash table that maps CONSes of the form (SITE-ID . LOGICAL-CLOCK) to overlays.")
(defvar crdt--track-overlay-species nil)
(crdt--defvar-permanent-local crdt--enabled-overlay-species nil)
(crdt--defvar-permanent-local crdt--buffer-network-name)

(crdt--defvar-session crdt--local-name nil)
(crdt--defvar-session crdt--focused-buffer-name nil)
(crdt--defvar-session crdt--user-menu-buffer nil)
(crdt--defvar-session crdt--buffer-menu-buffer nil)
(defvar crdt--session-alist nil)
(defvar crdt--session-menu-buffer nil)

;;; Session menu
(defun crdt--session-menu-goto ()
  (interactive)
  (with-current-buffer
      (process-get (tabulated-list-get-id) 'status-buffer)
    (crdt-list-buffer)))
(defun crdt--session-menu-kill ()
  (interactive)
  (with-current-buffer
      (process-get (tabulated-list-get-id) 'status-buffer)
    (crdt-stop-session)))
(defvar crdt-session-menu-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'crdt--session-menu-goto)
    (define-key map (kbd "k") #'crdt--session-menu-kill)
    map))
(define-derived-mode crdt-session-menu-mode tabulated-list-mode
  "CRDT User List"
  (setq tabulated-list-format [("Session Name" 15 t)
                               ("Role" 7 t)
                               ("My Display Name" 15 t)
                               ("Buffers" 15 t)
                               ("Users" 15 t)]))
(defun crdt-list-sessions (&optional crdt-buffer display-buffer)
  "Display a list of active CRDT sessions.
If DISPLAY-BUFFER is provided, display the output there. Otherwise use a dedicated
buffer for displaying active users on CRDT-BUFFER."
  (interactive)
  (unless display-buffer
    (unless (and crdt--session-menu-buffer (buffer-live-p crdt--session-menu-buffer))
      (setf crdt--session-menu-buffer
            (generate-new-buffer "*CRDT Sessions*")))
    (setq display-buffer crdt--session-menu-buffer))
  (crdt-refresh-sessions display-buffer)
  (switch-to-buffer-other-window display-buffer))
(defun crdt-refresh-sessions (display-buffer)
  (with-current-buffer display-buffer
    (crdt-session-menu-mode)
    (setq tabulated-list-entries nil)
    (mapc (lambda (pair)
            (cl-destructuring-bind (name . s) pair
              (push
               (list s (with-current-buffer (process-get s 'status-buffer)
                         (vector name (if (process-contact s :server) "Server" "Client")
                                 crdt--local-name
                                 (mapconcat (lambda (v) (format "%s" v))
                                            (hash-table-keys crdt--buffer-table)
                                            ", ")
                                 (mapconcat (lambda (v) (format "%s" v))
                                            (let (users)
                                              (maphash (lambda (k v)
                                                         (push (crdt--contact-metadata-display-name v) users))
                                                       crdt--contact-table)
                                              (cons crdt--local-name users))
                                            ", "))))
               tabulated-list-entries)))
          crdt--session-alist)
    (tabulated-list-init-header)
    (tabulated-list-print)))
(defsubst crdt--refresh-sessions-maybe ()
  (when (and crdt--session-menu-buffer (buffer-live-p crdt--session-menu-buffer))
    (crdt-refresh-sessions crdt--session-menu-buffer)))

;;; Buffer menu
(defun crdt--buffer-menu-goto ()
  (interactive)
  (switch-to-buffer-other-window (tabulated-list-get-id)))
(defun crdt--buffer-menu-kill ()
  (interactive)
  (with-current-buffer (tabulated-list-get-id)
    (crdt-stop-share-buffer)))
(defvar crdt-buffer-menu-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'crdt--buffer-menu-goto)
    (define-key map (kbd "k") #'crdt--buffer-menu-kill)
    map))
(define-derived-mode crdt-buffer-menu-mode tabulated-list-mode
  "CRDT User List"
  (setq tabulated-list-format [("Buffer" 15 t)
                               ("Network Name" 15 t)]))
(defun crdt-list-buffer (&optional crdt-buffer display-buffer)
  "Display a list of buffers shared in the current CRDT session.
If DISPLAY-BUFFER is provided, display the output there. Otherwise use a dedicated
buffer for displaying active users on CRDT-BUFFER."
  (interactive)
  (with-current-buffer (or crdt-buffer (current-buffer))
    (unless (or crdt-mode crdt--network-process)
      (error "Not a CRDT shared buffer."))
    (unless display-buffer
      (unless (and (crdt--buffer-menu-buffer) (buffer-live-p (crdt--buffer-menu-buffer)))
        (setf (crdt--buffer-menu-buffer)
              (generate-new-buffer (concat (buffer-name (current-buffer))
                                           " buffers")))
        (crdt--assimilate-status-buffer (crdt--buffer-menu-buffer)))
      (setq display-buffer (crdt--buffer-menu-buffer)))
    (with-current-buffer crdt--status-buffer
      (crdt-refresh-buffers display-buffer))
    (switch-to-buffer-other-window display-buffer)))
(defun crdt-refresh-buffers (display-buffer)
  (with-current-buffer display-buffer
    (crdt-buffer-menu-mode)
    (setq tabulated-list-entries nil)
    (maphash (lambda (k v)
               (push (list v (vector (buffer-name v) k))
                     tabulated-list-entries))
             (crdt--buffer-table))
    (tabulated-list-init-header)
    (tabulated-list-print)))
(defsubst crdt--refresh-buffers-maybe ()
  (when (and (crdt--buffer-menu-buffer) (buffer-live-p (crdt--buffer-menu-buffer)))
    (crdt-refresh-buffers (crdt--buffer-menu-buffer)))
  (crdt--refresh-sessions-maybe))

;;; User menu
(defun crdt--user-menu-goto ()
  (interactive)
  (let* ((site-id (tabulated-list-get-id))
         (focused-buffer
          (with-current-buffer crdt--status-buffer
            (gethash
             (crdt--contact-metadata-focused-buffer-name
              (gethash site-id crdt--contact-table))
             crdt--buffer-table))))
    (switch-to-buffer-other-window focused-buffer)
    (when site-id
      (goto-char (overlay-start (car (gethash site-id crdt--pseudo-cursor-table)))))))
(defvar crdt-user-menu-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'crdt--user-menu-goto)
    map))
(define-derived-mode crdt-user-menu-mode tabulated-list-mode
  "CRDT User List"
  (setq tabulated-list-format [("Display Name" 15 t)
                               ("Focused Buffer" 15 t)
                               ("Address" 15 t)
                               ("Port" 7 t)]))
(defun crdt-list-users (&optional crdt-buffer display-buffer)
  "Display a list of active users working on a CRDT-shared buffer CRDT-BUFFER.
If DISPLAY-BUFFER is provided, display the output there. Otherwise use a dedicated
buffer for displaying active users on CRDT-BUFFER."
  (interactive)
  (with-current-buffer (or crdt-buffer (current-buffer))
    (unless crdt-mode
      (error "Not a CRDT shared buffer."))
    (unless display-buffer
      (unless (and (crdt--user-menu-buffer) (buffer-live-p (crdt--user-menu-buffer)))
        (setf (crdt--user-menu-buffer)
              (generate-new-buffer (concat (buffer-name (current-buffer))
                                           " users")))
        (crdt--assimilate-status-buffer (crdt--user-menu-buffer)))
      (setq display-buffer (crdt--user-menu-buffer)))
    (with-current-buffer crdt--status-buffer
      (crdt-refresh-users display-buffer))
    (switch-to-buffer-other-window display-buffer)))
(defun crdt-refresh-users (display-buffer)
  "Must be called with CURRENT-BUFFER set to a CRDT status buffer."
  (let (table local-name local-id)
    (setq table crdt--contact-table)
    (setq local-name crdt--local-name)
    (setq local-id crdt--local-id)
    (with-current-buffer display-buffer
      (crdt-user-menu-mode)
      (setq tabulated-list-entries nil)
      (push (list local-id (vector local-name (or (crdt--focused-buffer-name) "--") "*myself*" "--")) tabulated-list-entries)
      (maphash (lambda (k v)
                 (push (list k (let ((name (crdt--contact-metadata-display-name v))
                                     (host (crdt--contact-metadata-host v))
                                     (service (crdt--contact-metadata-service v))
                                     (focused-buffer-name (or (crdt--contact-metadata-focused-buffer-name v) "--")))
                                 (let ((colored-name (concat name " ")))
                                   (put-text-property 0 (1- (length colored-name))
                                                      'face `(:background ,(crdt--get-region-color k))
                                                      colored-name)
                                   (put-text-property (1- (length colored-name)) (length colored-name)
                                                      'face `(:background ,(crdt--get-cursor-color k))
                                                      colored-name)
                                   (vector colored-name focused-buffer-name host (format "%s" service)))))
                       tabulated-list-entries))
               table)
      (tabulated-list-init-header)
      (tabulated-list-print))))
(defsubst crdt--refresh-users-maybe ()
  (when (and (crdt--user-menu-buffer) (buffer-live-p (crdt--user-menu-buffer)))
    (crdt-refresh-users (crdt--user-menu-buffer)))
  (crdt--refresh-sessions-maybe))

;;; CRDT insert/delete
(defsubst crdt--base64-encode-maybe (str)
  (when str (base64-encode-string str)))
(defun crdt--local-insert (beg end)
  "To be called after a local insert happened in current buffer from BEG to END.
Returns a list of (insert type) messages to be sent."
  (let (resulting-commands)
    (crdt--with-insertion-information
     (beg end)
     (unless (crdt--split-maybe)
       (when (and not-begin
                  (eq (crdt--id-site starting-id) (crdt--local-id))
                  (crdt--end-of-block-p left-pos))
         ;; merge crdt id block
         (let* ((max-offset crdt--max-value)
                (merge-end (min end (+ (- max-offset left-offset 1) beg))))
           (unless (= merge-end beg)
             (put-text-property beg merge-end 'crdt-id starting-id-pair)
             (let ((virtual-id (substring starting-id)))
               (crdt--set-id-offset virtual-id (1+ left-offset))
               (push `(insert ,crdt--buffer-network-name
                              ,(base64-encode-string virtual-id) ,beg
                              ,(buffer-substring-no-properties beg merge-end))
                     resulting-commands))
             (cl-incf left-offset (- merge-end beg))
             (setq beg merge-end)))))
     (while (< beg end)
       (let ((block-end (min end (+ crdt--max-value beg))))
         (let ((new-id (crdt--generate-id starting-id left-offset ending-id right-offset (crdt--local-id))))
           (put-text-property beg block-end 'crdt-id (cons new-id t))
           (push `(insert ,crdt--buffer-network-name
                          ,(base64-encode-string new-id) ,beg
                          ,(buffer-substring-no-properties beg block-end))
                 resulting-commands)
           (setq beg block-end)
           (setq left-offset (1- crdt--max-value)) ; this is always true when we need to continue
           (setq starting-id new-id)))))
    ;; (crdt--verify-buffer)
    (nreverse resulting-commands)))

(defun crdt--find-id (id pos &optional before)
  "Find the first position *after* ID if BEFORE is NIL, or *before* ID otherwise.
Start the search from POS."
  (let* ((left-pos (previous-single-property-change (if (< pos (point-max)) (1+ pos) pos)
                                                    'crdt-id nil (point-min)))
         (left-id (crdt--get-starting-id left-pos))
         (right-pos (next-single-property-change pos 'crdt-id nil (point-max)))
         (right-id (crdt--get-starting-id right-pos)))
    (cl-block nil
      (while t
        (cond ((<= right-pos (point-min))
               (cl-return (point-min)))
              ((>= left-pos (point-max))
               (cl-return (point-max)))
              ((and right-id (not (string< id right-id)))
               (setq left-pos right-pos)
               (setq left-id right-id)
               (setq right-pos (next-single-property-change right-pos 'crdt-id nil (point-max)))
               (setq right-id (crdt--get-starting-id right-pos)))
              ((string< id left-id)
               (setq right-pos left-pos)
               (setq right-id left-id)
               (setq left-pos (previous-single-property-change left-pos 'crdt-id nil (point-min)))
               (setq left-id (crdt--get-starting-id left-pos)))
              (t
               ;; will unibyte to multibyte conversion cause any problem?
               (cl-return
                 (if (eq t (compare-strings left-id 0 (- (string-bytes left-id) 2)
                                            id 0 (- (string-bytes left-id) 2)))
                     (min right-pos (+ left-pos (if before 0 1)
                                       (- (crdt--get-two-bytes id (- (string-bytes left-id) 2))
                                          (crdt--id-offset left-id))))
                   right-pos))))))))
(defun crdt--remote-insert (id position-hint content)
  (let ((crdt--inhibit-update t))
    (let* ((beg (crdt--find-id id position-hint)) end)
      (goto-char beg)
      (insert content)
      (setq end (point))
      (with-silent-modifications
        (crdt--with-insertion-information
         (beg end)
         (let ((base-length (- (string-bytes starting-id) 2)))
           (if (and (eq (string-bytes id) (string-bytes starting-id))
                    (eq t (compare-strings starting-id 0 base-length
                                           id 0 base-length))
                    (eq (1+ left-offset) (crdt--id-offset id)))
               (put-text-property beg end 'crdt-id starting-id-pair)
             (put-text-property beg end 'crdt-id (cons id t))))
         (crdt--split-maybe)))))
  ;; (crdt--verify-buffer)
  )

(defun crdt--local-delete (beg end)
  (let ((outer-end end))
    (crdt--with-insertion-information
     (beg 0 nil crdt--changed-string nil (length crdt--changed-string))
     (when (crdt--split-maybe)
       (let* ((not-end (< outer-end (point-max)))
              (ending-id (when not-end (crdt--get-starting-id outer-end))))
         (when (and not-end (eq starting-id (crdt--get-starting-id outer-end)))
           (crdt--set-id outer-end
                         (crdt--id-replace-offset starting-id (+ 1 left-offset (length crdt--changed-string))))))))
    (crdt--with-insertion-information
     ((length crdt--changed-string) outer-end crdt--changed-string nil 0 nil)
     (crdt--split-maybe)))
  ;; (crdt--verify-buffer)
  `(delete ,crdt--buffer-network-name
           ,beg ,@ (crdt--dump-ids 0 (length crdt--changed-string) crdt--changed-string t)))
(defun crdt--remote-delete (position-hint id-pairs)
  (dolist (id-pair id-pairs)
    (cl-destructuring-bind (length . id) id-pair
      (while (> length 0)
        (goto-char (crdt--find-id id position-hint t))
        (let* ((end-of-block (next-single-property-change (point) 'crdt-id nil (point-max)))
               (block-length (- end-of-block (point))))
          (cl-case (cl-signum (- length block-length))
            ((1) (delete-char block-length)
             (cl-decf length block-length)
             (crdt--set-id-offset id (+ (crdt--id-offset id) block-length)))
            ((0) (delete-char length)
             (setq length 0))
            ((-1)
             (let* ((starting-id (crdt--get-starting-id (point)))
                    (eob (crdt--end-of-block-p (point)))
                    (left-offset (crdt--get-id-offset starting-id (point))))
               (delete-char length)
               (crdt--set-id (point) (crdt--id-replace-offset starting-id (+ left-offset length)) eob))
             (setq length 0)))))
      ;; (crdt--verify-buffer)
      )))

(defun crdt--before-change (beg end)
  (unless crdt--inhibit-update
    (setq crdt--changed-string (buffer-substring beg end))))

(defun crdt--after-change (beg end length)
  (mapc (lambda (ov)
          (when (eq (overlay-get ov 'category) 'crdt-pseudo-cursor)
            (crdt--move-cursor ov beg)))
        (overlays-in beg (min (point-max) (1+ beg))))
  (when (crdt--local-id) ; CRDT--LOCAL-ID is NIL when a client haven't received the first sync message
    (unless crdt--inhibit-update
      (let ((crdt--inhibit-update t))
        ;; we're only interested in text change
        ;; ignore property only changes
        (save-excursion
          (goto-char beg)
          (unless (and (= length (- end beg))
                       (string-equal crdt--changed-string
                                     (buffer-substring-no-properties beg end)))
            (widen)
            (with-silent-modifications
              (unless (= length 0)
                (crdt--broadcast-maybe
                 (crdt--format-message (crdt--local-delete beg end))))
              (unless (= beg end)
                (dolist (message (crdt--local-insert beg end))
                  (crdt--broadcast-maybe
                   (crdt--format-message message)))))))))))

;;; CRDT point/mark synchronization
(defsubst crdt--id-to-pos (id hint)
  (if (> (string-bytes id) 0)
      (crdt--find-id id hint t)
    (point-max)))
(defun crdt--remote-cursor (site-id point-position-hint point-crdt-id mark-position-hint mark-crdt-id)
  (when site-id
    (let ((ov-pair (gethash site-id crdt--pseudo-cursor-table)))
      (if point-crdt-id
          (let* ((point (crdt--id-to-pos point-crdt-id point-position-hint))
                 (mark (if mark-crdt-id
                           (crdt--id-to-pos mark-crdt-id mark-position-hint)
                         point)))
            (unless ov-pair
              (let ((new-cursor (make-overlay 1 1))
                    (new-region (make-overlay 1 1)))
                (overlay-put new-cursor 'face `(:background ,(crdt--get-cursor-color site-id)))
                (overlay-put new-cursor 'category 'crdt-pseudo-cursor)
                (overlay-put new-region 'face `(:background ,(crdt--get-region-color site-id) :extend t))
                (setq ov-pair (puthash site-id (cons new-cursor new-region)
                                       crdt--pseudo-cursor-table))))
            (crdt--move-cursor (car ov-pair) point)
            (crdt--move-region (cdr ov-pair) point mark))
        (when ov-pair
          (remhash site-id crdt--pseudo-cursor-table)
          (delete-overlay (car ov-pair))
          (delete-overlay (cdr ov-pair)))))))

(cl-defun crdt--local-cursor (&optional (lazy t))
  (let ((point (point))
        (mark (when (use-region-p) (mark))))
    (unless (and lazy
                 (eq point crdt--last-point)
                 (eq mark crdt--last-mark))
      (when (or (eq point (point-max)) (eq crdt--last-point (point-max)))
        (mapc (lambda (ov)
                (when (eq (overlay-get ov 'category) 'crdt-pseudo-cursor)
                  (crdt--move-cursor ov (point-max))))
              (overlays-in (point-max) (point-max))))
      (setq crdt--last-point point)
      (setq crdt--last-mark mark)
      (let ((point-id-base64 (base64-encode-string (crdt--get-id point)))
            (mark-id-base64 (when mark (base64-encode-string (crdt--get-id mark)))))
        `(cursor ,crdt--buffer-network-name ,(crdt--local-id)
                 ,point ,point-id-base64 ,mark ,mark-id-base64)))))
(defun crdt--post-command ()
  (unless (eq crdt--buffer-network-name (crdt--focused-buffer-name))
    (crdt--broadcast-maybe
     (crdt--format-message `(focus ,(crdt--local-id) ,crdt--buffer-network-name)))
    (setf (crdt--focused-buffer-name) crdt--buffer-network-name))
  (let ((cursor-message (crdt--local-cursor)))
    (when cursor-message
      (crdt--broadcast-maybe (crdt--format-message cursor-message)))))

;;; CRDT ID (de)serialization
(defun crdt--dump-ids (beg end object &optional omit-end-of-block-p)
  "Serialize all CRDT ids in OBJECT from BEG to END into a list.
The list contains CONSes of the form (LENGTH CRDT-ID-BASE64 . END-OF-BLOCK-P),
or (LENGTH . CRDT-ID-BASE64) if OMIT-END-OF-BLOCK-P is non-NIL.
in the order that they appears in the document"
  (let (ids (pos end))
    (while (> pos beg)
      (let ((prev-pos (previous-single-property-change pos 'crdt-id object beg)))
        (push (cons (- pos prev-pos)
                    (cl-destructuring-bind (id . eob) (crdt--get-crdt-id-pair prev-pos object)
                      (let ((id-base64 (base64-encode-string id)))
                        (if omit-end-of-block-p id-base64 (cons id-base64 eob)))))
              ids)
        (setq pos prev-pos)))
    ids))
(defun crdt--load-ids (ids)
  "Load the CRDT ids in IDS (generated by CRDT--DUMP-IDS)
into current buffer."
  (let ((pos (point-min)))
    (dolist (id-pair ids)
      (let ((next-pos (+ pos (car id-pair))))
        (put-text-property pos next-pos 'crdt-id
                           (cons (base64-decode-string (cadr id-pair)) (cddr id-pair)))
        (setq pos next-pos)))))
(defun crdt--verify-buffer ()
  "Debug helper function.
Verify that CRDT IDs in a document follows ascending order."
  (let* ((pos (point-min))
         (id (crdt--get-starting-id pos)))
    (cl-block
        (while t
          (let* ((next-pos (next-single-property-change pos 'crdt-id))
                 (next-id (if (< next-pos (point-max))
                              (crdt--get-starting-id next-pos)
                            (cl-return)))
                 (prev-id (substring id)))
            (crdt--set-id-offset id (+ (- next-pos pos) (crdt--id-offset id)))
            (unless (string< prev-id next-id)
              (error "Not monotonic!"))
            (setq pos next-pos)
            (setq id next-id))))))

;;; Network protocol
(crdt--defvar-session crdt--network-process nil)
(crdt--defvar-session crdt--network-clients nil)
(crdt--defvar-session crdt--next-client-id)
(crdt--defvar-session crdt--buffer-table)
(defun crdt--format-message (args)
  (format "%S" args))
(cl-defun crdt--broadcast-maybe (message-string &optional (without t))
  "Broadcast or send MESSAGE-STRING.
If CRDT--NETWORK-PROCESS is a server process, broadcast MESSAGE-STRING
to clients except the one of which CLIENT-ID property is EQ to WITHOUT.
If CRDT--NETWORK-PROCESS is a client process, send MESSAGE-STRING
to server when WITHOUT is T."
  ;; (message "Send %s" message-string)
  (if (process-contact (crdt--network-process) :server)
      (dolist (client (crdt--network-clients))
        (when (and (eq (process-status client) 'open)
                   (not (eq (process-get client 'client-id) without)))
          (process-send-string client message-string)
          ;; (run-at-time 1 nil #'process-send-string client message-string)
          ;; ^ quick dirty way to simulate network latency, for debugging
          ))
    (when without
      (process-send-string (crdt--network-process) message-string)
      ;; (run-at-time 1 nil #'process-send-string crdt--network-process message-string)
      )))
(defsubst crdt--overlay-add-message (id clock species front-advance rear-advance beg end)
  `(overlay-add ,crdt--buffer-network-name ,id ,clock
                ,species ,front-advance ,rear-advance
                ,beg ,(if front-advance
                          (base64-encode-string (crdt--get-id beg))
                        (crdt--base64-encode-maybe (crdt--get-id (1- beg))))
                ,end ,(if rear-advance
                          (base64-encode-string (crdt--get-id end))
                        (crdt--base64-encode-maybe (crdt--get-id (1- end))))))
(defun crdt--generate-challenge ()
  (apply #'unibyte-string (cl-loop for i below 32 collect (random 256))))
(defun crdt--greet-client (process)
  (with-current-buffer (process-get process 'status-buffer)
    (cl-pushnew process crdt--network-clients)
    (let ((client-id (process-get process 'client-id)))
      (unless client-id
        (unless (< crdt--next-client-id crdt--max-value)
          (error "Used up client IDs. Need to implement allocation algorithm."))
        (process-put process 'client-id crdt--next-client-id)
        (setq client-id crdt--next-client-id)
        (process-send-string process (crdt--format-message `(login ,client-id)))
        (cl-incf crdt--next-client-id))
      (maphash (lambda (k buffer)
                 (with-current-buffer buffer
                   (process-send-string process (crdt--format-message `(sync
                                                                        ,crdt--buffer-network-name
                                                                        ,major-mode
                                                                        ,(buffer-substring-no-properties (point-min) (point-max))
                                                                        ,@ (crdt--dump-ids (point-min) (point-max) nil))))
                   ;; synchronize cursor
                   (maphash (lambda (site-id ov-pair)
                              (cl-destructuring-bind (cursor-ov . region-ov) ov-pair
                                (let* ((point (overlay-start cursor-ov))
                                       (region-beg (overlay-start region-ov))
                                       (region-end (overlay-end region-ov))
                                       (mark (if (eq point region-beg)
                                                 (unless (eq point region-end) region-end)
                                               region-beg))
                                       (point-id-base64 (base64-encode-string (crdt--get-id point)))
                                       (mark-id-base64 (when mark (base64-encode-string (crdt--get-id mark)))))
                                  (process-send-string process
                                                       (crdt--format-message
                                                        `(cursor ,crdt--buffer-network-name ,site-id
                                                                 ,point ,point-id-base64 ,mark ,mark-id-base64))))))
                            crdt--pseudo-cursor-table)
                   (process-send-string process (crdt--format-message (crdt--local-cursor nil)))))
               crdt--buffer-table)
      ;; synchronize contact
      (maphash (lambda (k v)
                 (process-send-string
                  process (crdt--format-message `(contact ,k ,(crdt--contact-metadata-display-name v)
                                                          ,(crdt--contact-metadata-host v)
                                                          ,(crdt--contact-metadata-service v))))
                 (process-send-string
                  process (crdt--format-message `(focus ,k ,(crdt--contact-metadata-focused-buffer-name v)))))
               crdt--contact-table)
      (process-send-string process
                           (crdt--format-message `(contact ,(crdt--local-id)
                                                           ,(crdt--local-name))))
      (process-send-string process
                           (crdt--format-message `(focus ,(crdt--local-id)
                                                         ,(crdt--focused-buffer-name))))
      (let ((contact-message `(contact ,client-id ,(process-get process 'client-name)
                                       ,(process-contact process :host)
                                       ,(process-contact process :service))))
        (crdt-process-message contact-message process))
      ;; synchronize tracked overlay
      (maphash (lambda (k buffer)
                 (with-current-buffer buffer
                   (maphash (lambda (k ov)
                              (let ((meta (overlay-get ov 'crdt-meta)))
                                (process-send-string
                                 process
                                 (crdt--format-message (crdt--overlay-add-message
                                                        (car k) (cdr k)
                                                        (crdt--overlay-metadata-species meta)
                                                        (crdt--overlay-metadata-front-advance meta)
                                                        (crdt--overlay-metadata-rear-advance meta)
                                                        (overlay-start ov)
                                                        (overlay-end ov))))
                                (cl-loop for (prop value) on (crdt--overlay-metadata-plist meta) by #'cddr
                                      do (process-send-string
                                          process
                                          (crdt--format-message `(overlay-put ,(car k) ,(cdr k) ,prop ,value))))))
                            crdt--overlay-table)))
               crdt--buffer-table))))

(defmacro crdt--with-buffer-name (name &rest body)
  "Find CRDT shared buffer associated with NAME and evaluate BODY in it.
Must be called when CURRENT-BUFFER is a CRDT status buffer."
  `(let (crdt-buffer)
     (setq crdt-buffer (gethash ,name crdt--buffer-table))
     (if crdt-buffer
         (with-current-buffer crdt-buffer
           (save-excursion
             (widen)
             ,@body))
       (unless (process-contact crdt--network-process :server)
         (setq crdt-buffer (generate-new-buffer (format "crdt - %s" ,name)))
         (puthash ,name crdt-buffer crdt--buffer-table)
         (with-current-buffer crdt-buffer
           (setq crdt--buffer-network-name ,name)
           (setq crdt--status-buffer (process-get process 'status-buffer))
           (crdt-mode)
           (save-excursion
             (widen)
             ,@body))))))

(cl-defgeneric crdt-process-message (message process))
(cl-defmethod crdt-process-message (message process)
  (message "Unrecognized message %S from %s:%s."
           message (process-contact process :host) (process-contact process :service)))
(cl-defmethod crdt-process-message ((message (head insert)) process)
  (cl-destructuring-bind (buffer-name crdt-id position-hint content) (cdr message)
    (crdt--with-buffer-name
     buffer-name
     (crdt--remote-insert (base64-decode-string crdt-id) position-hint content)))
  (crdt--broadcast-maybe (crdt--format-message message) (process-get process 'client-id)))
(cl-defmethod crdt-process-message ((message (head delete)) process)
  (crdt--broadcast-maybe (crdt--format-message message) (process-get process 'client-id))
  (cl-destructuring-bind (buffer-name position-hint . id-base64-pairs) (cdr message)
    (mapc (lambda (p) (rplacd p (base64-decode-string (cdr p)))) id-base64-pairs)
    (crdt--with-buffer-name
     buffer-name
     (crdt--remote-delete position-hint id-base64-pairs))))
(cl-defmethod crdt-process-message ((message (head cursor)) process)
  (cl-destructuring-bind (buffer-name site-id point-position-hint point-crdt-id
                                      mark-position-hint mark-crdt-id)
      (cdr message)
    (crdt--with-buffer-name
     buffer-name
     (crdt--remote-cursor site-id point-position-hint
                          (and point-crdt-id (base64-decode-string point-crdt-id))
                          mark-position-hint
                          (and mark-crdt-id (base64-decode-string mark-crdt-id)))))
  (crdt--broadcast-maybe (crdt--format-message message) (process-get process 'client-id)))
(cl-defmethod crdt-process-message ((message (head sync)) process)
  (unless (crdt--server-p)             ; server shouldn't receive this
    (cl-destructuring-bind (buffer-name mode content . ids) (cdr message)
      (crdt--with-buffer-name
       buffer-name
       (erase-buffer)
       (if (fboundp mode)
           (unless (eq major-mode mode)
             (funcall mode)             ; trust your server...
             (crdt-mode))
         (message "Server uses %s, but not available locally." mode))
       (insert content)
       (crdt--load-ids ids)))
    (crdt--refresh-buffers-maybe)))
(cl-defmethod crdt-process-message ((message (head desync)) process)
  (cl-destructuring-bind (buffer-name) (cdr message)
    (let ((buffer (gethash buffer-name crdt--buffer-table)))
      (when buffer
        (with-current-buffer buffer
          (crdt-mode 0)
          (setq crdt--status-buffer nil))
        (remhash buffer-name crdt--buffer-table)
        (message "Server stopped sharing %s." buffer-name))))
  (crdt--broadcast-maybe (crdt--format-message message)
                         (when process (process-get process 'client-id)))
  (crdt--refresh-buffers-maybe))
(cl-defmethod crdt-process-message ((message (head login)) process)
  (cl-destructuring-bind (id) (cdr message)
    (puthash 0 (crdt--make-contact-metadata nil nil
                                            (process-contact process :host)
                                            (process-contact process :service))
             crdt--contact-table)
    (setq crdt--local-id id)
    (crdt--refresh-sessions-maybe)))
(cl-defmethod crdt-process-message ((message (head challenge)) process)
  (unless (crdt--server-p)             ; server shouldn't receive this
    (message nil)
    (let ((password (read-passwd
                     (format "Password for %s:%s: "
                             (process-contact (crdt--network-process) :host)
                             (process-contact (crdt--network-process) :service)))))
      (crdt--broadcast-maybe (crdt--format-message
                              `(hello ,(crdt--local-name) ,(gnutls-hash-mac 'SHA1 password (cadr message))))))))
(cl-defmethod crdt-process-message ((message (head contact)) process)
  (cl-destructuring-bind
        (site-id display-name &optional host service) (cdr message)
    (if display-name
        (if host
            (puthash site-id (crdt--make-contact-metadata
                              display-name nil host service)
                     crdt--contact-table)
          (let ((existing-item (gethash site-id crdt--contact-table)))
            (setf (crdt--contact-metadata-display-name existing-item) display-name)))
      (remhash site-id crdt--contact-table))
    (crdt--refresh-users-maybe))
  (crdt--broadcast-maybe (crdt--format-message message) (process-get process 'client-id)))
(cl-defmethod crdt-process-message ((message (head focus)) process)
  (cl-destructuring-bind
        (site-id buffer-name) (cdr message)
    (let ((existing-item (gethash site-id crdt--contact-table)))
      (setf (crdt--contact-metadata-focused-buffer-name existing-item) buffer-name))
    (when (and (= site-id 0) (not crdt--focused-buffer-name))
      (setq crdt--focused-buffer-name buffer-name)
      (switch-to-buffer (gethash buffer-name crdt--buffer-table)))
    (crdt--refresh-users-maybe))
  (crdt--broadcast-maybe (crdt--format-message message) (process-get process 'client-id)))

(defsubst crdt--server-p ()
  (process-contact (crdt--network-process) :server))

(defun crdt--network-filter (process string)
  (unless (and (process-buffer process)
               (buffer-live-p (process-buffer process)))
    (set-process-buffer process (generate-new-buffer "*crdt-server*"))
    (set-marker (process-mark process) 1))
  (with-current-buffer (process-buffer process)
    (unless crdt--status-buffer
      (setq crdt--status-buffer (process-get process 'status-buffer)))
    (save-excursion
      (goto-char (process-mark process))
      (insert string)
      (set-marker (process-mark process) (point))
      (goto-char (point-min))
      (let (message)
        (while (setq message (ignore-errors (read (current-buffer))))
          ;; (print message)
          (cl-macrolet ((body ()
                          '(if (or (not (crdt--server-p)) (process-get process 'authenticated))
                            (let ((crdt--inhibit-update t))
                              (with-current-buffer crdt--status-buffer
                                (crdt-process-message message process)))
                            (cl-block nil
                              (when (eq (car message) 'hello)
                                (cl-destructuring-bind (name &optional response) (cdr message)
                                  (when (or (not (process-get process 'password)) ; server password is empty
                                            (and response (string-equal response (process-get process 'challenge))))
                                    (process-put process 'authenticated t)
                                    (process-put process 'client-name name)
                                    (crdt--greet-client process)
                                    (cl-return))))
                              (let ((challenge (crdt--generate-challenge)))
                                (process-put process 'challenge
                                             (gnutls-hash-mac 'SHA1 (substring (process-get process 'password)) challenge))
                                (process-send-string process (crdt--format-message `(challenge ,challenge))))))))
            (if debug-on-error (body)
              (condition-case err (body)
                (error (message "%s error when processing message from %s:%s, disconnecting." err
                                (process-contact process :host) (process-contact process :service))
                       (if (crdt--server-p)
                           (delete-process process)
                         (crdt-stop-session))))))
          (delete-region (point-min) (point))
          (goto-char (point-min)))))))
(defun crdt--server-process-sentinel (client message)
  (with-current-buffer (process-get client 'status-buffer)
    (unless (or (process-contact client :server) ; it's actually server itself
                (eq (process-status client) 'open))
      ;; client disconnected
      (setq crdt--network-clients (delq client crdt--network-clients))
      (when (process-buffer client) (kill-buffer (process-buffer client)))
      ;; generate a clear cursor message and a clear contact message
      (let* ((client-id (process-get client 'client-id))
             (clear-contact-message `(contact ,client-id nil)))
        (crdt-process-message clear-contact-message client)
        (maphash
         (lambda (k v)
           (crdt-process-message
            `(cursor ,k ,client-id 1 nil 1 nil)
            client))
         crdt--buffer-table)
        (crdt--refresh-users-maybe)))))
(defun crdt--client-process-sentinel (process message)
  (with-current-buffer (process-get process 'status-buffer)
    (unless (eq (process-status process) 'open)
      (crdt-stop-session))))

;;; UI commands
(defun crdt--read-name ()
  (if crdt-ask-for-name
      (let ((input (read-from-minibuffer (format "Display name (default %S): " crdt-default-name))))
        (if (> (length input) 0) input crdt-default-name))
    crdt-default-name))
(defun crdt--share-buffer (buffer session)
  (if (process-contact session :server)
      (with-current-buffer buffer
        (setq crdt--status-buffer (process-get session 'status-buffer))
        (puthash (buffer-name buffer) buffer (crdt--buffer-table))
        (setq crdt--buffer-network-name (buffer-name buffer))
        (crdt-mode)
        (save-excursion
          (widen)
          (let ((crdt--inhibit-update t))
            (with-silent-modifications
              (crdt--local-insert (point-min) (point-max))))
          (crdt--broadcast-maybe
           (crdt--format-message `(sync
                                   ,crdt--buffer-network-name
                                   ,major-mode
                                   ,(buffer-substring-no-properties (point-min) (point-max))
                                   ,@ (crdt--dump-ids (point-min) (point-max) nil)))))
        (crdt--refresh-buffers-maybe)
        (crdt--refresh-sessions-maybe))
    (message "Only server can add new buffer.")))
(defun crdt-share-buffer (session-name)
  "Share the current buffer in the CRDT session with name SESSION-NAME.
Create a new one if such a CRDT session doesn't exist.
If SESSION-NAME is empty, use the buffer name of the current buffer."
  (interactive
   (list (let ((session-name (completing-read "Enter a session name (create if not exist): "
                                              crdt--session-alist)))
           (unless (and session-name (> (length session-name) 0))
             (setq session-name (buffer-name (current-buffer))))
           session-name)))
  (if (and crdt-mode crdt--status-buffer)
      (message "Current buffer is already shared in a CRDT session.")
    (let ((session (assoc session-name crdt--session-alist)))
      (if session
          (crdt--share-buffer (current-buffer) (cdr session))
        (let ((port (read-from-minibuffer "Create new session on Port (default 1333): " nil nil t nil "1333")))
          (crdt--share-buffer (current-buffer) (crdt-new-session port session-name)))))))
(defun crdt-stop-share-buffer ()
  "Stop sharing the current buffer."
  (interactive)
  (if crdt-mode
      (if (crdt--server-p)
          (let ((buffer-name crdt--buffer-network-name))
            (with-current-buffer crdt--status-buffer
              (let ((desync-message `(desync ,buffer-name)))
                (crdt-process-message desync-message nil))))
        (message "Only server can stop sharing a buffer."))
    (message "Not a CRDT shared buffer.")))
(defun crdt-new-session (port session-name &optional password display-name)
  "Start a new CRDT session on PORT."
  (let ((new-session
         (with-current-buffer (generate-new-buffer " *crdt-status*")
           (condition-case err
               (setq crdt--network-process
                     (make-network-process
                      :name "CRDT Server"
                      :server t
                      :family 'ipv4
                      :host "0.0.0.0"
                      :buffer (current-buffer)
                      :service port
                      :filter #'crdt--network-filter
                      :sentinel #'crdt--server-process-sentinel
                      :plist `(status-buffer ,(current-buffer))))
             (t (kill-buffer (current-buffer))
                (signal (car err) (cdr err))))
           (setq crdt--local-id 0)
           (setq crdt--network-clients nil)
           (setq crdt--local-clock 0)
           (setq crdt--next-client-id 1)
           (unless password
             (setq password
                   (when crdt-ask-for-password
                     (read-from-minibuffer "Set password (empty for no authentication): "))))
           (when (and password (> (length password) 0))
             (process-put crdt--network-process 'password password))
           (unless display-name
             (setq display-name (crdt--read-name)))
           (setq crdt--local-name display-name)
           (setq crdt--contact-table (make-hash-table :test 'equal))
           (setq crdt--buffer-table (make-hash-table :test 'equal))
           (setq crdt--status-buffer (current-buffer))
           crdt--network-process)))
    (push (cons session-name new-session) crdt--session-alist)
    new-session))
(defsubst crdt--clear-pseudo-cursor-table ()
  (when crdt--pseudo-cursor-table
    (maphash (lambda (key pair)
               (delete-overlay (car pair))
               (delete-overlay (cdr pair)))
             crdt--pseudo-cursor-table)
    (setq crdt--pseudo-cursor-table nil)))
(defun crdt-stop-session ()
  "Stop sharing the current session."
  (interactive)
  (if (not crdt--status-buffer)
      (message "No CRDT session running on current buffer.")
    (let ((status-buffer crdt--status-buffer))
      (with-current-buffer status-buffer
        (dolist (client crdt--network-clients)
          (when (process-live-p client)
            (delete-process client))
          (when (process-buffer client)
            (kill-buffer (process-buffer client))))
        (when crdt--user-menu-buffer
          (kill-buffer crdt--user-menu-buffer))
        (maphash
         (lambda (k v)
           (with-current-buffer v
             (setq crdt--status-buffer nil)
             (crdt-mode 0)))
         crdt--buffer-table)
        (setq crdt--session-alist
              (delq (cl-find-if (lambda (p) (eq (cdr p) crdt--network-process))
                                crdt--session-alist)
                    crdt--session-alist))
        (crdt--refresh-sessions-maybe)
        (delete-process crdt--network-process)
        (message "Disconnected."))
      (kill-buffer status-buffer))))

(defun crdt-connect (address port &optional name)
  "Connect to a CRDT server running at ADDRESS:PORT.
Open a new buffer to display the shared content."
  (interactive "MAddress: \nnPort: ")
  (unless name
    (setq name (crdt--read-name)))
  (setq crdt--status-buffer
        (with-current-buffer (generate-new-buffer "*crdt-client*")
          (setq crdt--local-name name)
          (condition-case err
              (setq crdt--network-process
                    (make-network-process
                     :name "CRDT Client"
                     :buffer (current-buffer)
                     :host address
                     :family 'ipv4
                     :service port
                     :filter #'crdt--network-filter
                     :sentinel #'crdt--client-process-sentinel
                     :plist `(status-buffer ,(current-buffer))))
            (t (kill-buffer (current-buffer))
               (signal (car err) (cdr err))))
          (push (cons address crdt--network-process) crdt--session-alist)
          (setq crdt--local-clock 0)
          (process-send-string crdt--network-process
                               (crdt--format-message `(hello ,name)))
          (setq crdt--contact-table (make-hash-table :test 'equal))
          (setq crdt--buffer-table (make-hash-table :test 'equal))
          (setq crdt--status-buffer (current-buffer)))))
(defun crdt-test-client ()
  (interactive)
  (crdt-connect "127.0.0.1" 1333))
(defun crdt-test-server ()
  (interactive)
  (crdt--share-buffer (current-buffer) (crdt-new-session 1333 "test")))

;;; overlay tracking
(defun crdt--enable-overlay-species (species)
  (push species crdt--enabled-overlay-species)
  (when crdt-mode
    (let ((crdt--inhibit-overlay-advices t))
      (maphash (lambda (k ov)
                 (let ((meta (overlay-get ov 'crdt-meta)))
                   (when (eq species (crdt--overlay-metadata-species meta))
                     (cl-loop for (prop value) on (crdt--overlay-metadata-plist meta) by #'cddr
                           do (overlay-put ov prop value)))))
               crdt--overlay-table))))
(defun crdt--disable-overlay-species (species)
  (setq crdt--enabled-overlay-species (delq species crdt--enabled-overlay-species))
  (when crdt-mode
    (let ((crdt--inhibit-overlay-advices t))
      (maphash (lambda (k ov)
                 (let ((meta (overlay-get ov 'crdt-meta)))
                   (when (eq species (crdt--overlay-metadata-species meta))
                     (cl-loop for (prop value) on (crdt--overlay-metadata-plist meta) by #'cddr
                           do (overlay-put ov prop nil)))))
               crdt--overlay-table))))
(defun crdt--make-overlay-advice (orig-fun beg end &optional buffer front-advance rear-advance)
                                        ; should we check if we are in the current buffer?
  (let ((new-overlay (funcall orig-fun beg end buffer front-advance rear-advance)))
    (when crdt-mode
      (when crdt--track-overlay-species
        (crdt--broadcast-maybe
         (crdt--format-message
          (crdt--overlay-add-message (crdt--local-id) (crdt--local-clock)
                                     crdt--track-overlay-species front-advance rear-advance
                                     beg end)))
        (let* ((key (cons (crdt--local-id) (crdt--local-clock)))
               (meta (crdt--make-overlay-metadata key crdt--track-overlay-species
                                                  front-advance rear-advance nil)))
          (puthash key new-overlay crdt--overlay-table)
          (let ((crdt--inhibit-overlay-advices t)
                (crdt--modifying-overlay-metadata t))
            (overlay-put new-overlay 'crdt-meta meta)))
        (cl-incf (crdt--local-clock))))
    new-overlay))
(cl-defmethod crdt-process-message ((message (head overlay-add)) process)
  (cl-destructuring-bind
        (buffer-name site-id logical-clock species
                     front-advance rear-advance start-hint start-id-base64 end-hint end-id-base64)
      (cdr message)
    (crdt--with-buffer-name
     buffer-name
     (let* ((crdt--track-overlay-species nil)
            (start (crdt--find-id (base64-decode-string start-id-base64) start-hint front-advance))
            (end (crdt--find-id (base64-decode-string end-id-base64) end-hint rear-advance))
            (new-overlay
             (make-overlay start end nil front-advance rear-advance))
            (key (cons site-id logical-clock))
            (meta (crdt--make-overlay-metadata key species
                                               front-advance rear-advance nil)))
       (puthash key new-overlay crdt--overlay-table)
       (let ((crdt--inhibit-overlay-advices t)
             (crdt--modifying-overlay-metadata t))
         (overlay-put new-overlay 'crdt-meta meta)))))
  (crdt--broadcast-maybe (crdt--format-message message) (process-get process 'client-id)))
(defun crdt--move-overlay-advice (orig-fun ov beg end &rest args)
  (when crdt-mode
    (unless crdt--inhibit-overlay-advices
      (let ((meta (overlay-get ov 'crdt-meta)))
        (when meta ;; to be fixed
          (let ((key (crdt--overlay-metadata-lamport-timestamp meta))
                (front-advance (crdt--overlay-metadata-front-advance meta))
                (rear-advance (crdt--overlay-metadata-rear-advance meta)))
            (crdt--broadcast-maybe
             (crdt--format-message
              `(overlay-move ,crdt--buffer-network-name ,(car key) ,(cdr key)
                             ,beg ,(if front-advance
                                       (base64-encode-string (crdt--get-id beg))
                                     (crdt--base64-encode-maybe (crdt--get-id (1- beg))))
                             ,end ,(if rear-advance
                                       (base64-encode-string (crdt--get-id end))
                                     (crdt--base64-encode-maybe (crdt--get-id (1- end))))))))))))
  (apply orig-fun ov beg end args))
(cl-defmethod crdt-process-message ((message (head overlay-move)) process)
  (cl-destructuring-bind (buffer-name site-id logical-clock
                                      start-hint start-id-base64 end-hint end-id-base64)
      (cdr message)
    (crdt--with-buffer-name
     buffer-name
     (let* ((key (cons site-id logical-clock))
            (ov (gethash key crdt--overlay-table)))
       (when ov
         (let* ((meta (overlay-get ov 'crdt-meta))
                (front-advance (crdt--overlay-metadata-front-advance meta))
                (rear-advance (crdt--overlay-metadata-rear-advance meta))
                (start (crdt--find-id (base64-decode-string start-id-base64) start-hint front-advance))
                (end (crdt--find-id (base64-decode-string end-id-base64) end-hint rear-advance)))
           (let ((crdt--inhibit-overlay-advices t))
             (move-overlay ov start end)))))))
  (crdt--broadcast-maybe (crdt--format-message message) (process-get process 'client-id)))
(defvar crdt--inhibit-overlay-advices nil)
(defvar crdt--modifying-overlay-metadata nil)
(defun crdt--delete-overlay-advice (orig-fun ov)
  (unless crdt--inhibit-overlay-advices
    (when crdt-mode
      (let ((meta (overlay-get ov 'crdt-meta)))
        (when meta
          (let ((key (crdt--overlay-metadata-lamport-timestamp meta)))
            (remhash key crdt--overlay-table)
            (crdt--broadcast-maybe (crdt--format-message
                                    `(overlay-remove ,crdt--buffer-network-name ,(car key) ,(cdr key)))))))))
  (funcall orig-fun ov))
(cl-defmethod crdt-process-message ((message (head overlay-remove)) process)
  (cl-destructuring-bind (buffer-name site-id logical-clock) (cdr message)
    (crdt--with-buffer-name
     buffer-name
     (let* ((key (cons site-id logical-clock))
            (ov (gethash key crdt--overlay-table)))
       (when ov
         (remhash key crdt--overlay-table)
         (let ((crdt--inhibit-overlay-advices t))
           (delete-overlay ov))))))
  (crdt--broadcast-maybe (crdt--format-message message) (process-get process 'client-id)))
(defun crdt--overlay-put-advice (orig-fun ov prop value)
  (unless (and (eq prop 'crdt-meta)
               (not crdt--modifying-overlay-metadata))
    (when crdt-mode
      (unless crdt--inhibit-overlay-advices
        (let ((meta (overlay-get ov 'crdt-meta)))
          (when meta
            (setf (crdt--overlay-metadata-plist meta) (plist-put (crdt--overlay-metadata-plist meta) prop value))
            (let* ((key (crdt--overlay-metadata-lamport-timestamp meta))
                   (message (crdt--format-message `(overlay-put ,crdt--buffer-network-name
                                                                ,(car key) ,(cdr key) ,prop ,value))))
              (condition-case nil
                  (progn ; filter non-readable object
                    (read-from-string message)
                    (crdt--broadcast-maybe message))
                (invalid-read-syntax)))))))
    (funcall orig-fun ov prop value)))
(cl-defmethod crdt-process-message ((message (head overlay-put)) process)
  (cl-destructuring-bind (buffer-name site-id logical-clock prop value) (cdr message)
    (crdt--with-buffer-name
     buffer-name
     (let ((ov (gethash (cons site-id logical-clock) crdt--overlay-table)))
       (when ov
         (let ((meta (overlay-get ov 'crdt-meta)))
           (setf (crdt--overlay-metadata-plist meta)
                 (plist-put (crdt--overlay-metadata-plist meta) prop value))
           (when (memq (crdt--overlay-metadata-species meta) crdt--enabled-overlay-species)
             (let ((crdt--inhibit-overlay-advices t))
               (overlay-put ov prop value))))))))
  (crdt--broadcast-maybe (crdt--format-message message) (process-get process 'client-id)))
(advice-add 'make-overlay :around #'crdt--make-overlay-advice)
(advice-add 'move-overlay :around #'crdt--move-overlay-advice)
(advice-add 'delete-overlay :around #'crdt--delete-overlay-advice)
(advice-add 'overlay-put :around #'crdt--overlay-put-advice)
(defun crdt--install-hooks ()
  (add-hook 'after-change-functions #'crdt--after-change nil t)
  (add-hook 'before-change-functions #'crdt--before-change nil t)
  (add-hook 'post-command-hook #'crdt--post-command nil t))
(defun crdt--uninstall-hooks ()
  (remove-hook 'after-change-functions #'crdt--after-change t)
  (remove-hook 'before-change-functions #'crdt--before-change t)
  (remove-hook 'post-command-hook #'crdt--post-command t))
(define-minor-mode crdt-mode
    "CRDT mode" nil " CRDT" nil
    (if crdt-mode
        (progn
          (setq crdt--pseudo-cursor-table (make-hash-table))
          (setq crdt--overlay-table (make-hash-table :test 'equal))
          (crdt--install-hooks))
      (crdt--uninstall-hooks)
      (crdt--clear-pseudo-cursor-table)
      (setq crdt--overlay-table nil)))

;;; Org integration
(defun crdt--org-overlay-advice (orig-fun &rest args)
  (if crdt-org-sync-overlay-mode
      (let ((crdt--track-overlay-species 'org))
        (apply orig-fun args))
    (apply orig-fun args)))
(cl-loop for command in '(org-cycle org-shifttab)
      do (advice-add command :around #'crdt--org-overlay-advice))
(define-minor-mode crdt-org-sync-overlay-mode ""
  nil " Sync Org Overlay" nil
  (if crdt-org-sync-overlay-mode
      (progn
        (save-excursion
          (widen)
          ;; heuristic to remove existing org overlays
          (cl-loop for ov in (overlays-in (point-min) (point-max))
                do (when (memq (overlay-get ov 'invisible)
                               '(outline org-hide-block))
                     (delete-overlay ov))))
        (crdt--enable-overlay-species 'org))
    (crdt--disable-overlay-species 'org)))

(provide 'crdt)
