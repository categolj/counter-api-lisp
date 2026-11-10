;;;; memory-keyvalue.lisp: wasi:keyvalue@0.2.0-draft2 (store, atomics, batch) in memory, the
;;;; provider of counter.lisp's imports on the interpreter. As a wicket's store: the identifier ""
;;;; opens one namespace (another is no-such-store), list-keys answers pages of 100 keys in key
;;;; order, the cursor the last key of a page, and increment adds to the decimal digits a value
;;;; holds. While *keyvalue-down* is true, every call but open and drop answers the error arm, as
;;;; a store gone does.

(defvar *keyvalue*
  (make-hash-table :test #'equal)
  "The namespace's pairs, the values strings.")

(defvar *keyvalue-down* nil "True: the store is gone.")

(defvar *keyvalue-handles* 0 "The last bucket handle handed out.")

(defun keyvalue-reset ()
  "An empty store, up."
  (clrhash *keyvalue*)
  (setf *keyvalue-down* nil))

(defun keyvalue-fail (message)
  (error 'rontolisp:wit-error :payload (cons :other message) :message message))

(defun keyvalue-page (cursor)
  "The keys after CURSOR, 100 at most, and the next page's cursor (nil: none)."
  (let ((keys '()))
    (maphash (lambda (key value)
               (declare (ignore value))
               (when (or (null cursor) (string> key cursor)) (push key keys)))
             *keyvalue*)
    (setf keys (sort keys #'string<))
    (if (> (length keys) 100)
        (let ((page (subseq keys 0 100)))
          (list :keys page :cursor (car (last page))))
        (list :keys keys :cursor nil))))

(defun keyvalue-increment (key delta)
  (let* ((value (gethash key *keyvalue*))
         (sum
          (+ delta
             (if value
                 (handler-case (parse-integer value)
                   (error ()
                     (keyvalue-fail
                      (format nil "the value of '~a' is not a decimal i64"
                              key))))
                 0))))
    (setf (gethash key *keyvalue*) (princ-to-string sum))
    sum))

(defun memory-keyvalue (member &rest args)
  "The provider: MEMBER names the bound function, ARGS are its arguments (the bucket first)."
  (cond
   ((string= member "open")
    (if (string= (first args) "")
        (incf *keyvalue-handles*)
        (error 'rontolisp:wit-error
               :payload :no-such-store
               :message (first args))))
   ((string= member "bucket-drop") nil)
   (*keyvalue-down* (keyvalue-fail "the store is down"))
   ((string= member "bucket-get") (values (gethash (second args) *keyvalue*)))
   ((string= member "bucket-set")
    (setf (gethash (second args) *keyvalue*) (third args))
    nil)
   ((string= member "bucket-delete")
    (remhash (second args) *keyvalue*)
    nil)
   ((string= member "bucket-exists")
    (nth-value 1 (gethash (second args) *keyvalue*)))
   ((string= member "bucket-list-keys") (keyvalue-page (second args)))
   ((string= member "increment")
    (keyvalue-increment (second args) (third args)))
   ((string= member "get-many")
    (mapcar (lambda (key) (list key (values (gethash key *keyvalue*))))
            (second args)))
   ((string= member "set-many")
    (dolist (pair (second args))
      (setf (gethash (first pair) *keyvalue*) (second pair)))
    nil)
   ((string= member "delete-many")
    (dolist (key (second args)) (remhash key *keyvalue*))
    nil)
   (t (keyvalue-fail (format nil "memory-keyvalue: no member ~a" member)))))

(dolist (interface
         '("wasi:keyvalue/store@0.2.0-draft2"
           "wasi:keyvalue/atomics@0.2.0-draft2"
           "wasi:keyvalue/batch@0.2.0-draft2"))
  (rontolisp:wit-provide interface #'memory-keyvalue))
