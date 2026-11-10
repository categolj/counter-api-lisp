;;;; counter-test.lisp: counter.lisp's routes on the interpreter, over memory-keyvalue.lisp's
;;;; store. From the repository's root: `make test` (rontolisp test test/counter-test.lisp).

(ql:quickload "rove")
(use-package :rove)

(load "../counter.lisp")
(load "memory-keyvalue.lisp")

(defun json (text)
  "TEXT with its single quotes double: JSON written without escapes."
  (substitute #\" #\' text))

(defvar *out*
  (make-broadcast-stream)
  "Where the routes' stdout goes: nowhere, but in a test of it.")

(defvar *err* (make-broadcast-stream) "Where their stderr goes.")

(defun call (method path &key (body "") query)
  "The answer to METHOD PATH: (status body), the body a string."
  (destructuring-bind (status headers &optional parts) (let ((*standard-output*
                                                              *out*)
                                                             (*error-output*
                                                              *err*))
                                                         (counter-api:route
                                                          (list
                                                           :request-method
                                                           method
                                                           :path-info path
                                                           :query-string query)
                                                          body))
    (declare (ignore headers))
    (list status (apply #'concatenate 'string parts))))

(defun increment (entry-id)
  (call :post "/counter" :body (format nil "{\"entryId\":~d}" entry-id)))

(deftest counting (keyvalue-reset)
  (testing "read-only answers 0 for an entry never counted, and writes nothing"
    (ok
     (equal (call :post "/counter"
                  :body (json "{'entryId': 100}")
                  :query "readOnly=true") (list 200 (json "{'counter':0}"))))
    (ok (zerop (hash-table-count *keyvalue*))))
  (testing "an increment counts from 1, per entry"
    (ok (equal (increment 100) (list 200 (json "{'counter':1}"))))
    (ok (equal (increment 100) (list 200 (json "{'counter':2}"))))
    (ok (equal (increment 101) (list 200 (json "{'counter':1}")))))
  (testing "readOnly true, TRUE and 1 read; another value counts"
    (dolist (flag '("true" "TRUE" "1"))
      (ok
       (equal (call :post "/counter"
                    :body (json "{'entryId': 100}")
                    :query (format nil "readOnly=~a" flag))
              (list 200 (json "{'counter':2}")))))
    (ok
     (equal (call :post "/counter"
                  :body (json "{'entryId': 100}")
                  :query "readOnly=false") (list 200 (json "{'counter':3}")))))
  (testing "a count is its key's decimal digits"
    (ok (equal (gethash "100" *keyvalue*) "3"))))

(deftest rejecting (keyvalue-reset)
  (testing "a body of no JSON"
    (ok
     (equal (call :post "/counter" :body "not json")
            (list 400 (json "{'status':400,'error':'invalid JSON body'}")))))
  (testing "no entryId, or one not an int32"
    (dolist (body
             '("{}" "[]" "{'entryId':'100'}" "{'entryId':1.5}"
               "{'entryId':2147483648}"))
      (ok
       (equal (call :post "/counter" :body (json body))
              (list 400
                    (json
                     "{'status':400,'error':'entryId is required and must be an integer'}"))))))
  (testing "the routes there are"
    (ok
     (equal (call :get "/actuator/health") (list 200 (json "{'status':'UP'}"))))
    (ok (equal (call :get "/nothing") '(404 "")))
    (ok (equal (call :get "/import") '(404 "")))))

(deftest listing (keyvalue-reset)
  (testing "none" (ok (equal (call :get "/counter") '(200 "[]"))))
  (testing "by count descending, a tie by entry id; a key no counter's left out"
    (setf (gethash "7" *keyvalue*) "5" (gethash "3" *keyvalue*) "5"
          (gethash "12" *keyvalue*) "9" (gethash "greeting" *keyvalue*) "hello"
          (gethash "8" *keyvalue*) "many")
    (ok
     (equal (call :get "/counter")
            (list 200
                  (json
                   "[{'entryId':12,'counter':9},{'entryId':3,'counter':5},{'entryId':7,'counter':5}]")))))
  (testing "over pages of keys"
    (keyvalue-reset)
    (dotimes (i 250)
      (setf (gethash (princ-to-string (+ 1000 i)) *keyvalue*)
            (princ-to-string (1+ i))))
    (let ((counters (rontolisp:json-parse (second (call :get "/counter")))))
      (ok (= (length counters) 250))
      (ok (= (gethash "entryId" (aref counters 0)) 1249))
      (ok (= (gethash "entryId" (aref counters 249)) 1000)))))

(deftest importing (keyvalue-reset)
  (testing "what the listing answers imports back as it was"
    (increment 100)
    (increment 100)
    (increment 101)
    (let ((exported (second (call :get "/counter"))))
      (ok
       (equal (call :post "/import"
               :body (json
                      "[{'entryId':100,'counter':0},{'entryId':101,'counter':0}]"))
              (list 200 (json "{'imported':2}"))))
      (ok
       (equal (call :post "/import" :body exported)
              (list 200 (json "{'imported':2}"))))
      (ok (equal (second (call :get "/counter")) exported))))
  (testing "an increment counts on from an imported count"
    (ok (equal (increment 100) (list 200 (json "{'counter':3}")))))
  (testing "a refused import writes nothing"
    (dolist (refused
             '(("not json" "invalid JSON body")
               ("{}" "request body must be a JSON array")
               ("[{'entryId':1,'counter':5},{'entryId':2}]"
                "each item requires integer entryId and counter")
               ("[{'entryId':1,'counter':'5'}]"
                "each item requires integer entryId and counter")
               ("[{'entryId':1,'counter':5},{'entryId':2,'counter':-1}]"
                "counter must be non-negative")))
      (ok
       (equal (call :post "/import" :body (json (first refused)))
              (list 400
               (format nil "{\"status\":400,\"error\":~s}" (second refused))))))
    (ok (null (gethash "1" *keyvalue*)))))

(deftest logging (keyvalue-reset)
  (testing "an increment and an import each write an ECS line on stdout"
    (let ((out
           (with-output-to-string (*out*)
             (increment 100)
             (call :post "/import"
                   :body (json "[{'entryId':1,'counter':2}]")))))
      (ok
       (cl-ppcre:scan "^\\{\"@timestamp\":\"\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\d\\.\\d{3}Z\",\"log.level\":\"info\""
                      out))
      (ok
       (search (json
                "'event.action':'counter-incremented','event.outcome':'success','message':'incremented counter for entryId','counter.entry_id':100,'counter.value':1}")
               out))
      (ok
       (search (json
                "'event.action':'counters-imported','event.outcome':'success','message':'imported counters via /import','counter.imported':1}")
               out))))
  (testing "a store gone fails the call 500, with an ECS error on stderr"
    (setf *keyvalue-down* t)
    (let* ((answer nil)
           (err (with-output-to-string (*err*) (setf answer (increment 100)))))
      (ok
       (equal answer
        (list 500 (json "{'status':500,'error':'Internal Server Error'}"))))
      (ok (search (json "'log.level':'error'") err))
      (ok
       (search
        (json "'event.action':'keyvalue-failed','event.outcome':'failure'")
        err)))))
