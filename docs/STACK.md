# The stack

What to reach for, and when not to. **Versions verified against
`proxy.golang.org` on 2026-09-08.** Baseline Go 1.27.

Defaults, not laws. Deviating is fine; deviating *silently* is not — write the
reason down in the code review or an ADR. Companion: [GO.md](GO.md).

---

## Rule zero: the standard library

More of Go's stack is in the standard library than in any comparable ecosystem,
and the list grows every release. Check here before you add a module.

| Need | Standard library | Since |
|---|---|---|
| HTTP server + method/wildcard routing | `net/http.ServeMux` | 1.22 |
| Structured logging | `log/slog` | 1.21 |
| UUID v4 / v7 | `uuid` | **1.27** |
| JSON (strict, fast) | `encoding/json` — v2 engine by default | **1.27** |
| Concurrency-safe test clock | `testing/synctest` | 1.25 |
| Goroutine spawn + wait | `sync.WaitGroup.Go` | 1.25 |
| Path traversal containment | `os.Root` | 1.24 |
| Benchmark loop | `testing.B.Loop` | 1.24 |
| Test-scoped ctx / tempdir / chdir | `testing.T.Context/TempDir/Chdir` | 1.24 |
| Typed error extraction | `errors.AsType[T]` | 1.26 |
| Slices, maps, iterators | `slices`, `maps`, `iter` | 1.21–1.23 |
| Min/max, clear | builtins | 1.21 |
| Post-quantum KEM / signatures | `crypto/mlkem`, `crypto/mldsa` | 1.24 / 1.27 |
| HKDF, PBKDF2, SHA-3 | `crypto/hkdf`, `crypto/pbkdf2`, `crypto/sha3` | 1.24 |
| Weak pointers | `weak` | 1.24 |
| Goroutine leak profile | `runtime/pprof` `goroutineleak` | 1.27 |

`github.com/google/uuid` (v1.6.0, last released January 2024) is the one to
delete first: `uuid.NewV7()` is now stdlib.

---

## Default stacks

**Focused CLI tool**

```
github.com/spf13/cobra          v1.10.2   // or alecthomas/kong for tag-driven CLIs
github.com/knadh/koanf/v2       v2.3.6    // only with ≥3 config sources
```
Plus `log/slog` and `flag`/`cobra` from the list above, and in
`[dev-dependencies]` terms: `github.com/google/go-cmp` and
`github.com/rogpeppe/go-internal` (testscript). That is the whole list for most
tools. Add `github.com/charmbracelet/lipgloss` when there is real terminal
output to style, and nothing else without a reason.

**HTTP service**

```
github.com/go-chi/chi/v5              v5.3.2
github.com/jackc/pgx/v5               v5.11.0
github.com/pressly/goose/v3           v3.28.0
go.opentelemetry.io/otel              v1.46.0
github.com/prometheus/client_golang   v1.24.1
```
Everything else — routing primitives, JSON, logging, TLS, graceful shutdown — is
`net/http`, `encoding/json`, `log/slog`, `crypto/tls` and `context`. A Go HTTP
service with six direct dependencies is normal, not minimal.

---

## HTTP

| Need | Default | v | Notes |
|---|---|---|---|
| Router | `net/http.ServeMux` | std | Since 1.22 it does `GET /items/{id}` and precedence. For most services this is the whole router. |
| Router, more ergonomics | `chi` | 5.3.2 | Plain `http.Handler` middleware, sub-routers, no framework. The right first step up from `ServeMux`. |
| Full framework | `echo` / `gin` | 4.15.4 / 1.12.0 | Both fine, both mature, both invent their own `Context`. Pick one only if the team wants batteries. |
| OpenAPI-first | `huma` | 2.39.1 | Generates the spec from your handler types instead of the other way round. Runs on top of chi/echo/`ServeMux`. |
| Client | `net/http.Client` | std | With an explicit `Timeout` and a shared `Transport`. Never `http.DefaultClient` in a service. |
| Retries | `hashicorp/go-retryablehttp` | 0.7.8 | Or `cenkalti/backoff/v5` (5.0.3) for a general retry loop. |
| WebSocket | `coder/websocket` | 1.8.15 | The maintained continuation of `nhooyr/websocket`. Context-aware API. |
| gRPC | `google.golang.org/grpc` + `protobuf` | 1.83.2 / 1.36.12 | |
| gRPC, HTTP-friendly | `connectrpc.com/connect` | 1.21.0 | Speaks gRPC, gRPC-Web and its own HTTP/JSON protocol from one handler. Reach for it when browsers or curl are clients. |
| Protobuf toolchain | `bufbuild/buf` | 1.72.0 | Lint, breaking-change detection, codegen. Replaces a `protoc` invocation nobody understands. |
| HTTP/3 | `quic-go/quic-go` | 0.62.0 | |
| Rate limiting | `golang.org/x/time/rate` | 0.16.0 | Already a quasi-stdlib dependency. |
| Circuit breaker | `sony/gobreaker/v2` | 2.4.0 | |

`gorilla/websocket` (v1.5.3) still works and is still widely deployed; new code
goes to `coder/websocket` for the context-aware API. `fasthttp` and everything
built on it buys throughput at the cost of `net/http` compatibility — that trade
is almost never worth it.

## Serialization

| Need | Default | v | Notes |
|---|---|---|---|
| JSON | `encoding/json` | std | Go 1.27 ships the v2 engine by default: significantly faster unmarshal, and it now **rejects** invalid UTF-8 and duplicate object keys. Escape hatch while you fix your data: `GODEBUG=nojsonv2=1`. |
| JSON, low-level tokens | `encoding/json/jsontext` | std 1.27 | Streaming encoder/decoder when you need the tokens, not a struct. |
| JSON, extreme throughput | `bytedance/sonic` | 1.15.3 | JIT-based, amd64/arm64. Only after you have measured that stdlib JSON is the bottleneck — which is much less likely since 1.27. |
| YAML | `go.yaml.in/yaml/v3` | 3.0.5 | **`gopkg.in/yaml.v3` is archived.** This is the drop-in, maintained continuation — same API, same import shape. |
| YAML, richer | `goccy/go-yaml` | 1.19.2 | Better errors, anchors/aliases, comment preservation. Worth the migration if you generate YAML for humans. |
| TOML | `BurntSushi/toml` | — | Or `pelletier/go-toml/v2`. Both fine. |
| Protobuf | `google.golang.org/protobuf` | 1.36.12 | The `github.com/golang/protobuf` module is superseded; do not start there. |
| Struct → struct decoding | `go-viper/mapstructure/v2` | 2.5.0 | The maintained fork of `mitchellh/mapstructure`. |
| Validation | `go-playground/validator/v10` | 10.30.4 | Tag-driven. Fine at a boundary; do not let it become your domain model. |
| Compression | `klauspost/compress` | 1.20.0 | Faster gzip/zstd/flate than stdlib, drop-in. |

## Errors

| Context | Default | v | Notes |
|---|---|---|---|
| Everything | `errors` + `fmt.Errorf` | std | `errors.Is`, `errors.AsType[T]`, `errors.Join`. This is the answer. |
| Stack traces on errors | `cockroachdb/errors` | 1.14.0 | Only when you genuinely cannot reconstruct the path from wrapped context — usually that means the wrapping is too thin. |

`github.com/pkg/errors` is archived and has been redundant since Go 1.13. If you
find it in a repo, that repo has not been modernized.

## CLI and configuration

| Need | Default | v | Notes |
|---|---|---|---|
| Flags, one command | `flag` | std | Genuinely enough for a single-purpose tool. |
| Subcommands | `spf13/cobra` | 1.10.2 | The default. Pairs with `spf13/pflag` (1.0.10) for POSIX flags. |
| Subcommands, struct-tag style | `alecthomas/kong` | 1.16.1 | Declarative — the CLI *is* a struct. Less machinery than cobra when you do not need its generators. |
| Subcommands, minimal | `urfave/cli/v3` | 3.11.0 | |
| Config layering | `knadh/koanf/v2` | 2.3.6 | Defaults → file → env → flags, with pluggable providers and no global state. |
| Config layering, batteries | `spf13/viper` | 1.21.0 | Works, widely known, holds global state and pulls a large dependency tree. Prefer koanf for new code. |
| Env into a struct | `caarlos0/env/v11` | 11.4.1 | When env is the *only* source, this is all you need. |
| Platform paths | `adrg/xdg` | 0.5.3 | Do not hand-roll `~/.config`. |
| TUI | `charmbracelet/bubbletea` | 1.3.10 | With `lipgloss` (1.1.0) for layout. A real commitment — only for interactive tools. |
| Colour | `fatih/color` | 1.19.0 | Or `lipgloss` if you already have it. |
| Live reload (dev only) | `air-verse/air` | 1.67.4 | |

Below three configuration sources, `flag` + `os.Getenv` + a `Config` struct beats
any library.

## Observability

| Need | Default | v | Notes |
|---|---|---|---|
| Logging | `log/slog` | std | One handler, built in `main`, injected. Not a package global. |
| Pretty dev handler | `lmittmann/tint` | 1.2.0 | Human-readable slog output for local runs; JSON in production. |
| slog + context fields | `veqryn/slog-context` | 0.9.0 | Carries request-scoped attrs without threading them through every call. |
| Tracing / metrics | `go.opentelemetry.io/otel` | 1.46.0 | The interop contract. Bridge into slog, do not replace it. |
| Prometheus metrics | `prometheus/client_golang` | 1.24.1 | |

`zap` (1.28.0) and `zerolog` (1.35.1) are still excellent and still faster in a
microbenchmark. They are no longer the default: `slog` is the interop point every
library now targets, and the performance gap does not show up in a service that
also talks to a database. Keep them where they already are; do not add them to
something new.

## Data and storage

| Need | Default | v | Notes |
|---|---|---|---|
| PostgreSQL | `jackc/pgx/v5` | 5.11.0 | Native protocol, real types, `COPY`, `LISTEN/NOTIFY`. Use `pgxpool` and skip `database/sql` unless you need driver portability. |
| SQL → typed Go | `sqlc` | 1.31.1 | You write SQL, it generates the structs and methods. Compile-time-checked queries with no runtime reflection and no DSL to learn. The best answer in the Go ecosystem right now. |
| Light `database/sql` sugar | `jmoiron/sqlx` | 1.4.0 | Stable to the point of stillness (last release 2024-04). Fine, and not where new energy is going. |
| Schema-first ORM | `ent` | 0.14.6 | Codegen, graph traversal, strong typing. Real learning curve. |
| ActiveRecord ORM | `gorm` | 1.31.2 | Ergonomic, reflective, and the source of most "why is this query slow" tickets in Go. Choose deliberately. |
| Migrations | `pressly/goose/v3` | 3.28.0 | Plain SQL files, embeddable in the binary. Or `golang-migrate/migrate/v4` (4.19.1). |
| SQLite, no cgo | `modernc.org/sqlite` | 1.58.0 | Pure Go. Cross-compiles, no build tags, slower than cgo. |
| SQLite, cgo | `mattn/go-sqlite3` | 1.14.52 | Faster, needs cgo, and extensions like FTS5 need a build tag. |
| Redis | `redis/go-redis/v9` | 9.22.0 | |
| In-process cache | `maypok86/otter/v2` | 2.3.0 | S3-FIFO eviction, generics. `hashicorp/golang-lru/v2` (2.0.7) if plain LRU is all you need. |
| Object storage | `aws/aws-sdk-go-v2` | 1.46.0 | S3-compatible endpoints included. |

## Messaging and jobs

| Need | Default | v | Notes |
|---|---|---|---|
| Kafka | `twmb/franz-go` | 1.21.6 | Pure Go, complete protocol support, no librdkafka. |
| NATS | `nats-io/nats.go` | 1.53.1 | |
| Postgres-backed job queue | `riverqueue/river` | 0.47.0 | Transactional enqueue in the same database. If you already have Postgres, you probably do not need a broker. |

## Concurrency and collections

| Need | Default | v | Notes |
|---|---|---|---|
| Bounded parallel work + first error | `golang.org/x/sync/errgroup` | 0.23.0 | `SetLimit` is the worker pool you were about to write. |
| Single-flight, semaphore | `golang.org/x/sync` | 0.23.0 | |
| Rate limiting | `golang.org/x/time/rate` | 0.16.0 | |
| Concurrent map / counter | `puzpuzpuz/xsync/v4` | 4.5.0 | After you have rejected "one owner goroutine with a channel". |
| Goroutine leak detection in tests | `go.uber.org/goleak` | 1.3.0 | One `defer goleak.VerifyNone(t)` finds a class of bug nothing else does. |

`samber/lo` (1.53.0) is popular and mostly redundant now that `slices` and `maps`
are stdlib; every helper it adds is one more idiom a reader has to learn.
`sourcegraph/conc` has not shipped since 2023 — `errgroup` covers the same ground.

## Crypto and TLS

| Need | Default | Notes |
|---|---|---|
| TLS | `crypto/tls` | Post-quantum `X25519MLKEM768` on by default since 1.24. |
| Hashing | `crypto/sha256`, `crypto/sha3` | `blake3` only where speed matters and interop does not. |
| Password hashing | `golang.org/x/crypto/argon2` | Never a plain hash, never bcrypt for new code. |
| KDF | `crypto/hkdf`, `crypto/pbkdf2` | Stdlib since 1.24. |
| Post-quantum | `crypto/mlkem`, `crypto/mldsa` | Stdlib. |

Do not write your own crypto, and do not vendor an unaudited fork of someone
else's.

## Testing

| Need | Default | v | Notes |
|---|---|---|---|
| Runner and framework | `testing` | std | Table tests, subtests, `t.Cleanup`, fuzzing. |
| Deep comparison | `google/go-cmp` | 0.7.0 | `cmp.Diff` prints what differed. `reflect.DeepEqual` prints `false`. |
| Concurrency and time | `testing/synctest` | std 1.25 | Fake clock, deterministic scheduling. Replaces every `time.Sleep` in a test. |
| Assertions | `stretchr/testify` | 1.12.1 | Universally known. Its `assert`/`require` split is a real footgun — `assert` continues after failure. Prefer plain `if got != want` where it reads fine. |
| CLI / script tests | `rogpeppe/go-internal/testscript` | 1.16.0 | Testdata-driven transcript tests. What the Go team uses for `cmd/go`. |
| Snapshots | `gkampitakis/go-snaps` | 0.5.23 | |
| Real dependencies | `testcontainers/testcontainers-go` | 0.44.0 | Integration tests against the actual database. `ory/dockertest/v3` (3.12.0) is the lighter alternative. |
| Generated mocks | `go.uber.org/mock` | 0.6.0 | The maintained continuation of `golang/mock`. Or `matryer/moq` (0.7.1) for smaller, readable output. Write a fake first. |
| Clock injection | `jonboulle/clockwork` | 0.5.0 | Only outside a `synctest` bubble. |
| Test output | `mfridman/tparse` | 0.18.0 | Turns `go test -json` into something readable. |

## Benchmark and profile

| Need | Default | Notes |
|---|---|---|
| Microbenchmarks | `testing.B` + `b.Loop()` | Stdlib. Nothing else needed. |
| Comparing benchmark runs | `golang.org/x/perf/cmd/benchstat` | "Is it faster" needs statistics, not one number. |
| CPU / heap / block profiles | `runtime/pprof`, `net/http/pprof` | |
| Wall-clock including off-CPU | `felixge/fgprof` | 0.9.5. `pprof` shows CPU; `fgprof` shows waiting. |
| Scheduler / latency analysis | `go tool trace` | The only thing that explains goroutine stalls. |
| Goroutine leaks | `runtime/pprof` `goroutineleak` | Go 1.27, promoted from experiment. |

## Build, release, ship

| Need | Default | v | Notes |
|---|---|---|---|
| Release automation | `goreleaser/goreleaser/v2` | 2.18.1 | Cross-compile, archives, checksums, changelog, GitHub release, Homebrew tap. |
| Linux packages | `goreleaser/nfpm/v2` | 2.47.0 | deb/rpm/apk without a packaging toolchain. |
| Container images | `ko` / distroless | — | `ko` builds an image from Go source with no Dockerfile and no daemon. |
| Lint | `golangci-lint` | 2.13.2 | Configured by `../.golangci.yml` in this module. |
| Vulnerabilities | `golang.org/x/vuln/cmd/govulncheck` | 1.7.0 | Reachability-based. |
| Static analysis, standalone | `honnef.co/go/tools` (staticcheck) | 0.8.1 | Already inside golangci-lint; standalone for editor integration. |

## Deliberately not picked

| Module | Why not |
|---|---|
| `github.com/google/uuid` | `uuid` is stdlib as of Go 1.27. |
| `gopkg.in/yaml.v3` | Archived. `go.yaml.in/yaml/v3` is the drop-in successor. |
| `github.com/pkg/errors` | Archived; stdlib `errors` has done this since Go 1.13. |
| `github.com/golang/mock` | Unmaintained; `go.uber.org/mock` is the continuation. |
| `github.com/mitchellh/mapstructure` | Unmaintained; `go-viper/mapstructure/v2` is the fork. |
| `github.com/valyala/fasthttp`, `gofiber/fiber` | Abandons `net/http` compatibility for throughput you almost certainly do not need. |
| `github.com/sirupsen/logrus` | Maintenance mode; `log/slog` is stdlib. |
| `io/ioutil` | Deprecated since Go 1.16. |
| `github.com/benbjohnson/clock` | Unmaintained; `testing/synctest` covers the test case. |
| `tools.go` with blank imports | Replaced by `go.mod` `tool` directives in Go 1.24. |
| `golang.org/x/exp/slices`, `.../maps` | Absorbed into stdlib. [gate: `exptostd`] |

## Watch list

Not defaults yet. Re-check next quarter.

- **`go.yaml.in/yaml/v4`** — at `v4.0.0-rc.6`. Wait for the release.
- **`uber-go/nilaway`** — nil-panic static analysis. Still no tagged release and
  a false-positive rate that would poison the gate. Genuinely promising.
- **`encoding/json/v2` explicit API** — the engine is already the default in
  1.27; the explicit `json/v2` import with its `Options` arguments is worth
  adopting once the ecosystem's struct tags settle.
- **`simd` / `simd/archsimd`** — experimental (`GOEXPERIMENT=simd`), arm64 and
  wasm added in 1.27. Watch, do not ship.
- **Generic methods (Go 1.27)** — new enough that the idioms are not settled.
  Let somebody else find the traps.
- **`tetratelabs/wazero`** — 1.12.0, the mature answer to "run untrusted logic
  in-process". On the list because plugin architectures keep asking for it.
