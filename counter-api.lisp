;;;; counter-api.lisp: the wasi:http component serving counter.lisp's routes (`make`).

(load "counter.lisp")

(rontolisp:http-handler 'counter-api:handle 8080)
