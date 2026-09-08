# go-quality — SPEC

Status: v1, 2026-09-08.

## Goal

One canonical source for Go lint config, quality gates, and the agent-facing Go
guide, consumed as a mooncake module by every Go repo in the fleet.

Two deliverables, one repo:

1. **Gate module** — configs + scripts + mooncake presets. Machine-enforced.
2. **Guide** — `docs/GO.md` (how to write it) and `docs/STACK.md` (what to reach
   for). Human/agent-read, not enforced.

The guide is not decoration. Every rule in `docs/GO.md` that a tool can check is
marked `[gate]` and is actually wired into `.golangci.yml` or a script in this
repo. Rules without the marker are review surface. That mapping is the contract:
an agent reads `GO.md`, writes code, and `goq/ci` agrees with the document.

## Scope

### In

- Shared config: `.golangci.yml` (canonical baseline linter selection + settings).
- Gates: build, test, fmt, vet, lint, vuln, scan, ai-lint, arch-snapshot,
  budget-status, dupl, structure-ratchet, cov, race, deps, config-check.
- Aggregate gates: `ci-fast` (pre-commit), `ci` (pre-push).
- JSONL findings stream (`.gate/findings.jsonl`) + SARIF projection.
- Toolchain install/verify.
- Two guide docs.

### Out (deferred, with reasons)

- **Semver / API-diff gate.** `gorelease` is still `x/exp` and unmaintained in
  practice; `go-apidiff` is third-party and noisy on internal packages. The
  fleet publishes no v1+ libraries yet. Revisit when one ships.
- **License scanning.** `go-licenses` needs a full module download graph and is
  slow enough to belong in a nightly, not a push gate. `deps-status.sh` leaves a
  hook for it.
- **Mutation testing.** `go-mutesting` is unmaintained; `gremlins` is alpha.
  Nothing credible to wire.
- **`nilaway`.** High signal, high false-positive rate, and no stable release.
  On the watch list in `docs/STACK.md`, not in the gate.

## Interfaces

### Env knobs (shared by all scripts)

| Var                  | Default                            | Meaning                                          |
|----------------------|------------------------------------|--------------------------------------------------|
| `PKG`                | `./...`                            | Package pattern passed to go commands            |
| `GO_TAGS`            | *(unset)*                          | Build tags threaded into build/test/vet/lint/vuln |
| `CAP_GOCYCLO`        | `35`                               | Cyclomatic soft cap                              |
| `CAP_GOD_LOC`        | `500`                              | God-file soft cap, non-test `.go`                |
| `DUPL_T`             | `100`                              | dupl clone threshold                             |
| `STRUCTURE_BASELINE` | `benchmark/structure/baseline.json`| Structural ratchet baseline                      |
| `DEADCODE_PKG`       | `./...`                            | deadcode entry packages                          |
| `CAP_DIRECT_DEPS`    | `40`                               | Direct-dependency count soft cap                 |
| `DEPS_BASELINE`      | `benchmark/deps/baseline.txt`      | Committed direct-dependency allowlist (opt-in)   |
| `COV_MIN`            | `0`                                | Total coverage floor, percent (0 = report only)  |
| `COV_BASELINE`       | `benchmark/coverage/baseline.txt`  | Committed coverage floor (opt-in, overrides `COV_MIN`) |
| `GATE_DIR`           | `.gate`                            | Findings artifact dir                            |

### Findings schema (unchanged)

```json
{"tool":"…","rule":"…","level":"error|warning|note","path":"…","line":1,"col":1,
 "message":"…","fingerprint":"rule:path:line"}
```

`level:error` = gate-failing. stdout is pure JSONL under `--format jsonl`; human
status goes to stderr. New emitters in this revision: `deps` (warning), `cov`
(warning/error), `config-check` (error).

### mooncake exports (`goq/*`)

Existing: `default`/`ci`, `ci-fast`, `tools`, `sync-config`, `build`, `test`,
`fmt`, `vet`, `lint`, `vuln`, `scan`, `ai-lint`, `arch-snapshot`,
`budget-status`, `dupl`, `structure-ratchet`, `findings`, `sarif`.

New: `cov`, `race`, `deps`, `config-check`.

### Gate composition

`ci-fast` (pre-commit, cheap) — unchanged shape, one step added:
1. `go vet`
2. `go mod tidy` drift
3. `gofmt` on staged `.go`
4. ai-lint on staged `.go`
5. budget soft caps
6. **config-check** — `.golangci.yml` drift vs the canonical baseline

`ci` (pre-push, first failure stops) — unchanged shape, one step added:
1. build
2. test
3. `go mod tidy` drift
4. golangci-lint
5. govulncheck
6. arch-snapshot summary
7. budget soft caps
8. dupl (informational)
9. **deps** (informational + hard cap)
10. structure-ratchet (opt-in)

Opt-in / out of band: `cov`, `race`. Both roughly double wall-clock; neither
belongs on the push path by default.

## Design decisions

### Lint baseline gets the guide's linters (blast radius: accepted)

`.golangci.yml` gains the linters that mechanically enforce `docs/GO.md`:
`errorlint`, `modernize`, `usetesting`, `sloglint`, `nilnesserr`, `nilnil`,
`sqlclosecheck`, `rowserrcheck`, `durationcheck`, `errchkjson`, `fatcontext`,
`containedctx`, `contextcheck`, `copyloopvar`, `intrange`, `exptostd`,
`forcetypeassert`, `makezero`, `wastedassign`, `asasalint`, `bidichk`,
`predeclared`, `reassign`, `recvcheck`, `gocheckcompilerdirectives`,
`testifylint`, `spancheck`, `musttag`, `perfsprint`, `iotamixing`.

Consumers (`mooncake`, `dex`, `moongit`) will surface new findings on their next
gate run. That is the intended behaviour — the canonical config is canonical.

### Tests are linted

`run.tests` flips `false` → `true`, with an exclusion block relaxing
`errcheck`, `gosec`, `cyclop`, `dupl`, `noctx`, `forcetypeassert` and the
complexity caps inside `_test.go`. Without this, every test rule in `GO.md`
would be unenforceable and `usetesting` / `testifylint` / `paralleltest` would
be dead weight.

### `config-check` exists because golangci-lint v2 has no config merge

`sync-config` copies the baseline into a consumer, and the consumer then appends
its own path-bound `exclusions.rules`. Nothing detects that the consumer's copy
has since drifted — a dropped linter is silent. `lint-config-check.sh` asserts
the consumer's `.golangci.yml` still enables every linter in the canonical
`enable:` list and still carries the canonical `cyclop.max-complexity` and
`staticcheck.checks`. Enforcement, not mutation — it never rewrites the file.

It is enforcement, not mutation, on purpose: a consumer that has deliberately
diverged should record that decision, and a consumer that lost a linter by
accident should be told. Rewriting the file would erase the difference between
the two.

## Edge cases

- **No git repo / no staged files.** Scripts degrade to a clean skip, exit 0.
- **No `.golangci.yml` in the consumer.** `config-check` reports it as a single
  finding and exits non-zero — a Go repo consuming this module without the
  config is misconfigured, not exempt.
- **`GO_TAGS` and the config check.** Build tags do not affect config parsing;
  `config-check` ignores `GO_TAGS` entirely.
- **Coverage without a baseline.** `cov` reports and exits 0. It gates only once
  `benchmark/coverage/baseline.txt` is committed, matching `structure-ratchet`'s
  opt-in shape.
- **Coverage of a package with no test files.** `go test -cover` reports
  `[no test files]`, not 0%. Those packages are listed separately and excluded
  from the total so a new untested package cannot silently dilute the floor.
- **`deps` without a baseline.** Reports the direct-dependency count against
  `CAP_DIRECT_DEPS` and lists available updates; new-dependency detection is
  skipped. With `benchmark/deps/baseline.txt` committed, any direct module not
  in the baseline is a gate-failing finding.
- **`go list -m -u all` needs the network.** `deps-status.sh` runs it with
  `GOFLAGS=-mod=mod` and a timeout; on failure the update report degrades to a
  note and the dependency-count check still runs offline.
- **`-race` and `GO_TAGS`.** `race` threads tags like every other gate; a repo
  with a cgo-linked tag (dex's `sqlite_fts5`) needs cgo enabled for `-race`
  anyway, so no special-casing.
- **Missing tools.** `ci` treats them as fatal; individual presets say what to
  install.
- **`modernize` and older `go` directives.** The linter proposes rewrites using
  language/stdlib features newer than the module's `go` line only when the line
  allows it; a repo pinned to `go 1.22` sees fewer suggestions, not wrong ones.

## Validation

- `bash -n` + `shellcheck` clean on every script.
- `golangci-lint config verify` accepts `.golangci.yml`.
- `golangci-lint run` over a scratch module exercising each newly enabled
  linter, asserting the intended diagnostic actually fires.
- Every script's `--format jsonl` output is valid JSON per line (`jq -e`).
- `config-check` self-test: passes against the canonical file, fails against a
  copy with a linter removed.
- Every version and API claim in `docs/GO.md` / `docs/STACK.md` verified against
  go.dev release notes, pkg.go.dev, or `proxy.golang.org/<mod>/@latest` on
  2026-09-08 — not from model memory.
- Local toolchain is go1.26.4; current release is go1.27. The guide is written
  against 1.27 semantics with the 1.26 baseline called out where it differs.
