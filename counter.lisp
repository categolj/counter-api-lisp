;;;; counter.lisp: counter-api, a count per entry id kept in wasi:keyvalue. counter-api.lisp
;;;; serves it as a wasi:http component, test/counter-test.lisp tests it.
;;;;
;;;;   POST /counter                {"entryId": 100}  -> {"counter": 1}   increments
;;;;   POST /counter?readOnly=true  {"entryId": 100}  -> {"counter": 1}   reads (0 when absent)
;;;;   GET  /counter                -> [{"entryId": 100, "counter": 1}, ...] by count, descending
;;;;   POST /import                 [{"entryId": 100, "counter": 2}, ...] -> {"imported": 1}
;;;;   GET  /actuator/health        -> {"status": "UP"}
;;;;
;;;; A counter is the key "<entryId>" holding the count's decimal digits (what the store's
;;;; increment reads and writes), in the bucket "": the route maps it to a store and a namespace.

(defpackage #:counter-api
  (:use #:cl)
  (:export #:route #:handle))
(in-package #:counter-api)

(rontolisp:wit-import "wit/keyvalue.wit"
                      :interface "wasi:keyvalue/store@0.2.0-draft2" :package kv)
(rontolisp:wit-import "wit/keyvalue.wit"
                      :interface "wasi:keyvalue/atomics@0.2.0-draft2" :package kva)
(rontolisp:wit-import "wit/keyvalue.wit"
                      :interface "wasi:keyvalue/batch@0.2.0-draft2" :package kvb)

;;; --- JSON and logging ---------------------------------------------------------------------

(defun respond (status value)
  (list status '(:content-type "application/json")
        (list (rontolisp:json-stringify value))))

(defun fail (status message)
  (respond status (rontolisp:plist-hash-table (list :status status :error message))))

(defun parse-json (text)
  "TEXT's JSON value, or :invalid."
  (handler-case (rontolisp:json-parse text)
    (error () :invalid)))

(defun timestamp ()
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ" year month day hour minute second)))

(defun log-event (level action outcome message &rest fields)
  "One ECS line, FIELDS (name value ...) after the event's own: on stderr from a warning up, else
on stdout."
  (let ((stream (if (member level '("warn" "error") :test #'string=)
                    *error-output*
                    *standard-output*)))
    (write-line (rontolisp:json-stringify
                 (rontolisp:plist-hash-table
                  (list* :@timestamp (timestamp) :log.level level :ecs.version "8.11.0"
                         :service.name "counter-api" :event.kind "event"
                         :event.action action :event.outcome outcome :message message
                         fields)))
                stream)
    (finish-output stream)))

;;; --- counters -----------------------------------------------------------------------------

(defun int32-p (x)
  (and (integerp x) (<= -2147483648 x 2147483647)))

(defun int64-p (x)
  (and (integerp x) (<= -9223372036854775808 x 9223372036854775807)))

(defun key-of (entry-id)
  (princ-to-string entry-id))

(defun entry-id-of (key)
  "The entry id KEY names, or nil: a key of another's is no counter."
  (let ((entry-id (handler-case (parse-integer key) (error () nil))))
    (and (int32-p entry-id) entry-id)))

(defun count-of (value)
  "The count VALUE holds, or nil."
  (and value (handler-case (parse-integer value) (error () nil))))

(defmacro with-bucket ((bucket) &body body)
  `(let ((,bucket (kv:open "")))
     (unwind-protect (progn ,@body)
       (kv:bucket-drop ,bucket))))

(defun fetch (bucket keys)
  "KEYS with their values in one call, (key value) each, the value nil for a key gone meanwhile."
  (and keys (kvb:get-many bucket keys)))

(defun store-all (bucket pairs)
  "Writes PAIRS, (key value) each, in one call: not atomic, a failure may leave some written."
  (when pairs
    (kvb:set-many bucket pairs)))

(defun counters (bucket)
  "Every counter, (entry-id . count), by count descending, then by entry id."
  (let ((all '())
        (cursor nil))
    (loop
      (let ((page (kv:bucket-list-keys bucket cursor)))
        (dolist (pair (fetch bucket (getf page :keys)))
          (let ((entry-id (entry-id-of (first pair)))
                (count (count-of (second pair))))
            (when (and entry-id count)
              (push (cons entry-id count) all))))
        (setf cursor (getf page :cursor))
        (unless cursor
          (return))))
    (sort all (lambda (a b)
                (or (> (cdr a) (cdr b))
                    (and (= (cdr a) (cdr b)) (< (car a) (car b))))))))

;;; --- the routes ---------------------------------------------------------------------------

(defun read-only-p (query)
  (let ((value (and query (rontolisp:query-param query "readOnly"))))
    (and value (member value '("true" "TRUE" "1") :test #'string=) t)))

(defun post-counter (bucket query body)
  (let ((payload (parse-json body)))
    (cond ((eq payload :invalid)
           (fail 400 "invalid JSON body"))
          ((not (and (hash-table-p payload) (int32-p (gethash "entryId" payload))))
           (fail 400 "entryId is required and must be an integer"))
          ((read-only-p query)
           (let ((count (count-of (kv:bucket-get bucket (key-of (gethash "entryId" payload))))))
             (respond 200 (rontolisp:plist-hash-table (list :counter (or count 0))))))
          (t
           (let* ((entry-id (gethash "entryId" payload))
                  (count (kva:increment bucket (key-of entry-id) 1)))
             (log-event "info" "counter-incremented" "success" "incremented counter for entryId"
                        :counter.entry_id entry-id :counter.value count)
             (respond 200 (rontolisp:plist-hash-table (list :counter count))))))))

(defun get-counters (bucket)
  (respond 200 (map 'vector
                    (lambda (counter)
                      (rontolisp:plist-hash-table
                       (list "entryId" (car counter) "counter" (cdr counter))))
                    (counters bucket))))

(defun import-problem (items)
  "Why ITEMS do not import, or nil: the first faulty item's fault."
  (loop for item across items
        do (unless (and (hash-table-p item)
                        (int32-p (gethash "entryId" item))
                        (int64-p (gethash "counter" item)))
             (return "each item requires integer entryId and counter"))
           (when (minusp (gethash "counter" item))
             (return "counter must be non-negative"))))

(defun post-import (bucket body)
  (let* ((payload (parse-json body))
         (problem (cond ((eq payload :invalid) "invalid JSON body")
                        ((not (simple-vector-p payload)) "request body must be a JSON array")
                        (t (import-problem payload)))))
    (if problem
        (fail 400 problem)
        (progn
          (store-all bucket (map 'list
                                 (lambda (item)
                                   (list (key-of (gethash "entryId" item))
                                         (princ-to-string (gethash "counter" item))))
                                 payload))
          (log-event "info" "counters-imported" "success" "imported counters via /import"
                     :counter.imported (length payload))
          (respond 200 (rontolisp:plist-hash-table (list :imported (length payload))))))))

(defun route (env body)
  "The response to the request ENV (a Clack environment) with BODY, the request's body."
  (let ((method (getf env :request-method))
        (path (getf env :path-info)))
    (handler-case
        (cond ((and (eq method :get) (string= path "/actuator/health"))
               (respond 200 (rontolisp:plist-hash-table (list :status "UP"))))
              ((and (eq method :post) (string= path "/counter"))
               (with-bucket (bucket) (post-counter bucket (getf env :query-string) body)))
              ((and (eq method :get) (string= path "/counter"))
               (with-bucket (bucket) (get-counters bucket)))
              ((and (eq method :post) (string= path "/import"))
               (with-bucket (bucket) (post-import bucket body)))
              (t (list 404 nil)))
      (rontolisp:wit-error (e)
        (log-event "error" "keyvalue-failed" "failure" (princ-to-string e)
                   :http.request.method (symbol-name method) :url.path path)
        (fail 500 "Internal Server Error")))))

(rontolisp:async-defun handle (env)
  (let* ((raw (getf env :raw-body))
         (body (if raw (rontolisp:await (rontolisp:read-all raw)) "")))
    (route env body)))
