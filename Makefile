# counter-api.wasm, a wasi:http 0.3 component, compiled by rontolisp:
#   make                                                  # rontolisp on the PATH
#   make RONTOLISP='java -jar rontolisp-0.1.0-SNAPSHOT-exec.jar'
#   make test                                             # the unit tests (rove, the interpreter)
#   make e2e                                              # test/e2e.sh: the component on a wicket
#   make wit                                              # wit/keyvalue/ downloaded again
RONTOLISP ?= rontolisp
# wit/keyvalue/: WebAssembly/wasi-keyvalue's wit/ as published at this commit
WASI_KEYVALUE = aa972c86e4294b97908b8d24d5950cc525ace7a6

counter-api.wasm: counter-api.lisp counter.lisp $(wildcard wit/keyvalue/*.wit)
	$(RONTOLISP) counter-api.lisp -o $@ --component --optimize

.PHONY: test e2e wit clean
test:
	$(RONTOLISP) test test/counter-test.lisp

e2e: counter-api.wasm
	test/e2e.sh

wit:
	rm -rf wit/keyvalue && mkdir -p wit/keyvalue
	curl -sSfL https://github.com/WebAssembly/wasi-keyvalue/archive/$(WASI_KEYVALUE).tar.gz \
	  | tar -xz -C wit/keyvalue --strip-components=2 wasi-keyvalue-$(WASI_KEYVALUE)/wit

clean:
	rm -f counter-api.wasm
