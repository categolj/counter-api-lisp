# counter-api-lisp

counter-api (a count per blog entry id) as a wasi:http 0.3 component compiled by
[rontolisp](https://github.com/making/rontolisp), the counters in `wasi:keyvalue@0.2.0-draft2`. It
runs on a [sluice](https://github.com/making/sluice) wasi wicket (`sluice-wicket-runtime-wasi`),
deployed with `cf push` through sluice's cf-api, the store a Tanzu GemFire region (sluice's
`gemfire` keyvalue store). It replaces counter-api-cpp (C++ on GemFire's native client) and keeps
its HTTP contract and log lines; the blog frontend (blog-frontend-htmx) calls `POST /counter` and
`POST /counter?readOnly=true`, and shows "—" when counter-api cannot be reached. `GET /counter` and
`POST /import` are for moving the counters between deployments. README.md has the API, storage
and run details.

## Layout

- `counter.lisp`: the routes (`route`, `handle`), JSON, ECS logging, the keyvalue calls
- `counter-api.lisp`: loads `counter.lisp` and makes it the component's `http-handler`
- `test/counter-test.lisp`: rove unit tests on the interpreter; `test/memory-keyvalue.lisp`
  provides the keyvalue imports in memory there (pages of 100 keys, a "store gone" switch)
- `test/e2e.sh`: the built component on a local wicket (`make e2e`), over its sqlite store or a
  store a `keyvalue:` file names (`STORE=...`)
- `wit/keyvalue/`: WebAssembly/wasi-keyvalue's `wit/` as published at the commit the Makefile pins;
  regenerate with `make wit`, never edit by hand
- `.github/workflows/ci.yaml`: unit tests, build, E2E on sluice's latest wicket image; on `main`,
  pushes the component to `ghcr.io/categolj/counter-api-lisp` (`:<sha>`, `:latest`)

## Build and test

`make test`, `make`, `make e2e` (needs `sluice-wicket-runtime-wasi` on the PATH or
`SLUICE_WICKET`). The sources need rontolisp's `develop` (CI installs the `0.1.0-SNAPSHOT` native
release). Run `rontolisp format counter.lisp counter-api.lisp test/` before committing.

## Conventions

- Logging: one ECS JSON line per event (`log-event`), stdout below warn, stderr from warn. Only an
  increment, an import and a keyvalue failure log; reads and health checks do not (the cf-api's
  access log covers them). Keep the field names counter-api-cpp writes.
- A counter is the key `"<entryId>"` holding decimal digits, in the bucket `""`; the route maps
  the bucket to a store and namespace. Increments go through `wasi:keyvalue/atomics`.
- Commit and push to `main` directly. CI runs are heavy on rontolisp's side too: do not re-run
  cancelled ones, let the next push cover them.
- Where rontolisp falls short (a missing builtin, a compiler bug, a doc gap), file a todo in the
  rontolisp repository (`.todo/`, numbers from its `.todo/claim-number.sh`) rather than working
  around it silently; adopt the fix here once it lands on `develop`.

## Production details stay out of the repository

The repository is public. `.private/` (gitignored, written in Japanese) holds the production
GemFire cluster's addresses, the wicket's client certificate and keys, the cf-api deployment
procedure and the GemFire mock procedure; start from `.private/README.md`. Never copy anything
from it into tracked files: examples use `*.example` hosts and `192.0.2.x` addresses. Tests need
no GemFire (it is proprietary): sluice's GemFire mock stands in, and the default E2E store is
sqlite.
