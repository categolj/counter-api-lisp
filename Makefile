# counter-api.wasm, a wasi:http 0.3 component, compiled by rontolisp:
#   make                                                  # rontolisp on the PATH
#   make RONTOLISP='java -jar rontolisp-0.1.0-SNAPSHOT-exec.jar'
#   make test                                             # the unit tests (rove, the interpreter)
#   make e2e                                              # test/e2e.sh: the component on a wicket
RONTOLISP ?= rontolisp

counter-api.wasm: counter-api.lisp counter.lisp wit/keyvalue.wit
	$(RONTOLISP) counter-api.lisp -o $@ --component --optimize

.PHONY: test e2e clean
test:
	$(RONTOLISP) test test/counter-test.lisp

e2e: counter-api.wasm
	test/e2e.sh

clean:
	rm -f counter-api.wasm
