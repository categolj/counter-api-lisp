# counter-api (rontolisp)

counter-api's HTTP contract as a wasi:http 0.3 component compiled by
[rontolisp](https://github.com/making/rontolisp), its counters kept in `wasi:keyvalue@0.2.0-draft2`
through whatever store the host maps: on a [sluice](https://github.com/making/sluice) wasi wicket a
sqlite file, Redis or a Tanzu GemFire region.

## API

| Method | Path | Description |
| --- | --- | --- |
| POST | `/counter` | Increments the counter of `entryId` and answers it: `{"entryId": 100}` -> `{"counter": 1}` |
| POST | `/counter?readOnly=true` | Answers the counter without incrementing it (`0` when absent; `TRUE` and `1` read too) |
| GET | `/counter` | Every counter, by count descending (a tie by `entryId`): `[{"entryId": 100, "counter": 1}]` |
| POST | `/import` | Writes each `{"entryId", "counter"}` of an array, the others left as they are: `{"imported": 2}` |
| GET | `/actuator/health` | `{"status": "UP"}` |

An error answers `{"status": 400, "error": "..."}`: a body that is no JSON, an `entryId` that is no
int32, an import that is no array or holds an item without integer `entryId` and `counter` or with
a negative `counter` (nothing is written then). A store failing answers `500`. An increment and an
import each write an ECS line on stdout, a failure one on stderr.

## Storage

A counter is the key `"<entryId>"` holding the count's decimal digits, what wasi:keyvalue's
`increment` reads and writes, so an increment is atomic in the store (a compare-and-swap on GemFire).
The component opens the bucket `""`; the route maps it to a store and a namespace. The listing reads
the namespace a page of keys at a time, each page's values in one call (wasi:keyvalue's `get-many`).
An import writes its counters in one call (`set-many`), not atomically: a store failing on the way
may leave some written.

## Build and test

```bash
make                       # counter-api.wasm, with rontolisp on the PATH
make RONTOLISP='java -jar rontolisp-0.1.0-SNAPSHOT-exec.jar'
make test                  # the unit tests: rove on the interpreter, over an in-memory store
make e2e                   # test/e2e.sh: the component on a wicket
```

The component takes a rontolisp passing a `list<T>` argument to an imported function (`develop`
since [2db646c](https://github.com/making/rontolisp/commit/2db646c17367cde969e4cc5e2627c0f71c0f1295));
the unit tests run on an older one too.

`make test` needs no host: on the interpreter the keyvalue calls go to
[`test/memory-keyvalue.lisp`](test/memory-keyvalue.lisp). `make e2e` runs a
`sluice-wicket-runtime-wasi` (on the PATH, or `SLUICE_WICKET`) over its default store, a sqlite file
in a temporary directory, or over the store `counter` of the `keyvalue:` section a file names
(`STORE=store.yaml make e2e`, in a namespace of its own, purged at the end).

## Run on a wicket

```yaml
keyvalue:
  stores:
    grid:
      type: gemfire
      locators: [grpcs://192.0.2.20:50051, grpcs://192.0.2.30:50051, grpcs://192.0.2.40:50051]
      region: counter
      ca-cert: /etc/sluice/gemfire/ca.pem
      client-cert: /etc/sluice/gemfire/client.pem
      client-key: /etc/sluice/gemfire/client.key

routes:
  - host: counter.example
    component: /srv/counter-api.wasm
    sandbox:
      wasi: [keyvalue]
      keyvalue:
        "": grid/counter     # without it the namespace is the host
```

The region is created once (the store creates none):

```text
gfsh> create region --name=counter --type=PARTITION_PERSISTENT --redundant-copies=1
```

Without the `keyvalue:` section the wicket's store is a sqlite file beside the config. Name the
namespace: a route of another host then reaches the same counters.

## Moving the counters from another counter-api

`GET /counter` answers what `POST /import` takes, so the counters move by piping one into the other:

```bash
curl -s https://<the old one>/counter \
  | curl -s -X POST -H 'content-type: application/json' --data-binary @- https://<this one>/import
```

An import writes absolute counts: run it once, right before the traffic moves. An increment the old
one takes in between is lost, and an import after the move takes back what this one counted since.
