# go-quality — design decisions

Status: v1, 2026-09-08. Why the gates are shaped the way they are.
The *what* lives in [README.md](README.md); this file is only the reasoning,
so that a future change has to argue with a recorded decision rather than
rediscover it.

## Deliberately out of scope


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

## Design decisions

### The baseline carries the guide's linters (blast radius: accepted)

`.golangci.yml` enables the linters that mechanically enforce `docs/GO.md`.
Consumers (`mooncake`, `dex`, `moongit`) will surface new findings on their next
gate run. That is the intended behaviour — the canonical config is canonical.

### …but only where they add coverage

Every candidate was run against a probe file with `govet` + `staticcheck` alone,
then alone, and kept only if it reported something they did not. Four linters and
ten `revive` rules failed that test — each reported the *same file:line:col* as a
check already enabled — and were dropped. The full list is recorded inline in
`.golangci.yml` next to the `disable:` block and the `revive` rules, so nobody
re-adds one on the reasonable-sounding theory that more linters is more safety.

Two linters overlap by design and are kept: `modernize` subsumes `copyloopvar`
and `intrange`, so those two are not enabled separately.

### Tests are linted

`run.tests` flips `false` → `true`, with an exclusion block relaxing `errcheck`,
`gosec`, `cyclop`, `bodyclose`, `noctx`, `containedctx`, `contextcheck` and
`musttag` inside `_test.go`. Without this, every test rule in `GO.md` would be
unenforceable and `usetesting` / `testifylint` / `tparallel` would be dead
weight.

### The finding schema is a file, not a convention

Four bash emitters carried byte-identical `json_str` bodies and an `emit` that
differed only in one string literal, which made the schema a four-file edit that
would eventually miss one. `scripts/lib/findings.sh` owns it now.

It stops at the bash boundary on purpose. `budget-status`, `dupl-report` and
`structure-ratchet` construct their JSONL inside an embedded `python3` block; a
bash helper cannot reach into that, and rewriting three working analysis scripts
in a different language to share thirty lines would cost more than it saves.
Those three are noted in the lib's header as the copies that stay manual.

### `config-check` exists because golangci-lint v2 has no config merge

`sync-config` copies the baseline into a consumer, and the consumer then appends
its own path-bound `exclusions.rules`. Nothing detects that the copy has since
drifted — a dropped linter is silent.

It enforces rather than mutates on purpose: a consumer that deliberately diverged
should record that decision, and a consumer that lost a linter by accident should
be told. Rewriting the file would erase the difference between the two.

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
  linter, asserting the intended diagnostic actually fires — and, for each
  candidate, that it fires somewhere `govet`/`staticcheck` do not.
- Every `[gate]` marker in `docs/GO.md` cross-checked against the resolved
  linter set, the configured `revive` rules, and the `index.yml` exports.
- Every script's `--format jsonl` output is valid JSON per line (`jq -e`).
- `config-check` self-test: passes against the canonical file, fails against a
  copy with a linter removed.
- Every version and API claim in `docs/GO.md` / `docs/STACK.md` verified against
  go.dev release notes, pkg.go.dev, or `proxy.golang.org/<mod>/@latest` on
  2026-09-08 — not from model memory.
- Local toolchain is go1.26.4; current release is go1.27. The guide is written
  against 1.27 semantics with the 1.26 baseline called out where it differs.
