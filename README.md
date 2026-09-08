# go-quality

Shared Go quality toolchain for the fleet — **one canonical source** for how we
write Go and for the lint config, static-analysis scripts, and CI gates that
enforce it across `mooncake`, `dex`, `moongit`, and future Go repos. Consumed as
a [mooncake](https://github.com/alehatsman/mooncake) module.

Two deliverables, one repo:

| | |
|---|---|
| **[docs/GO.md](docs/GO.md)** | How to write Go here. 118 rules, Go 1.27 baseline. Read this first. |
| **[docs/STACK.md](docs/STACK.md)** | What to reach for. Versions verified against the module proxy, not from memory. |
| **the gate** | `.golangci.yml` + `scripts/` + the mooncake presets. What machines check. |

The two halves are wired together on purpose. Every rule in `docs/GO.md` marked
`[gate]` is enforced by a linter in `.golangci.yml` or a script in `scripts/`.
Change one without the other and the guide starts lying — `goq/config-check`
exists to catch the copy that drifted.

**Agents:** read `docs/GO.md` before writing Go, `docs/STACK.md` before adding a
dependency, and consume `.gate/findings.jsonl` (`goq/findings`) for the machine
view of what the gate found.

Rust sibling: **[rust-quality](https://github.com/alehatsman/rust-quality)** —
same shape, same JSONL finding schema, same gate composition, adapted where Rust
differs (a canonical `[workspace.lints]` block instead of `.golangci.yml`,
cargo-deny instead of govulncheck, no clone detection). Changes to the shared
conventions — the finding schema, the `--format jsonl` contract, the ai-lint
rule set, the fast/full gate split — should land in both.

## What's here

```
index.yml            module manifest (name + export → component map)
SPEC.md              what this module is, its interfaces, and why the gates are shaped this way
.golangci.yml        canonical lint config — the enforceable half of docs/GO.md
docs/
  GO.md              the Go guide: rules, traps, review checklist
  STACK.md           library defaults with verified versions
scripts/
  ai-lint.sh         AI-smell sweep (stub panics, agent TODOs, prompt artifacts)
  arch-snapshot.sh   package-graph / coupling / cyclomatic snapshot (markdown)
  budget-status.sh   gocyclo + god-file soft-cap status
  dupl-report.sh     production-code duplication report
  deps-status.sh     go mod verify + direct-dep cap + opt-in new-dependency ratchet
  lint-config-check.sh  .golangci.yml drift vs this module's canonical baseline
  cov.sh             coverage report + opt-in monotonic floor
  structure-ratchet.sh  monotonic ratchet: fails when structural counts grow (opt-in)
                        (+ --format jsonl structured findings)
  findings-to-sarif.sh  project .gate/findings.jsonl -> SARIF 2.1.0 (code scanning)
  install-tools.sh   go install the static-analysis toolchain
  check-tools.sh     verify the toolchain is present
  ci/fast.sh         pre-commit gate  (vet + mod-tidy + gofmt + ai-lint + budget + config-check)
  ci/full.sh         pre-push gate    (build + test + mod-tidy + lint + vuln + arch + budget + dupl + deps + structure-ratchet)
```

## The lint baseline

`.golangci.yml` enables ~41 linters, grouped in the file by what they defend:
errors (`errorlint`, `nilerr`, `nilnil`, `forcetypeassert`), context
(`contextcheck`, `containedctx`, `fatcontext`, `noctx`), concurrency and
resource lifetime (`sqlclosecheck`, `rowserrcheck`, `recvcheck`, `tparallel`),
modernization (`modernize`, `exptostd`), logging (`sloglint`) and tests
(`usetesting`, `testifylint`). The `disable:` list is as load-bearing as the
`enable:` list — each entry records a linter that was considered and rejected,
with the reason.

Two things to know before you consume it:

- **Tests are linted** (`run.tests: true`). Without that, every test rule in
  `docs/GO.md` is unenforceable. A baseline exclusion block relaxes the linters
  that legitimately do not apply inside `_test.go`.
- **Formatting is checked by `golangci-lint run`** via the `formatters:` block
  (`gofmt` + `goimports`), which closes the gap left by `ci/fast.sh` only
  checking *staged* files. Set `goimports.local-prefixes` to your module path in
  your local config.

`contextcheck` is the one linter here with a meaningful false-positive history.
If it fights your codebase, exclude it by path locally rather than dropping it
from the baseline — `goq/config-check` reports a dropped linter as an error and
a locally added exclusion as nothing at all.

## Structural ratchet (opt-in enforcement)

`budget-status`, `dupl` and `deadcode` are **informational** — they print drift
but never fail, so god files, over-cap complexity, clone pairs and dead code can
grow unbounded. `structure-ratchet.sh` turns those signals into a **one-way
door**: it freezes four counts (`god_files`, `gocyclo_over`, `dupl_pairs`,
`deadcode_symbols`) in a committed baseline and **fails the gate when any count
grows**. Counts may shrink freely; `--refresh` re-tightens the baseline.

It is **opt-in per project**: with no baseline file present it skips cleanly
(exit 0), so it is safe in the shared `ci/full.sh` for every consumer. Opt in
once:

```
scripts/structure-ratchet.sh --refresh      # writes benchmark/structure/baseline.json
git add benchmark/structure/baseline.json   # commit to enable enforcement
```

Knobs: `STRUCTURE_BASELINE` (path), `DEADCODE_PKG` (deadcode entry pkgs,
default `./...`), plus the shared `GO_TAGS`/`CAP_GOCYCLO`/`CAP_GOD_LOC`/`DUPL_T`.
Standalone preset: `structure-ratchet.yml`.

## Config drift (`goq/config-check`)

golangci-lint v2 has **no config merge**. `goq/sync-config` copies this module's
baseline into a consumer, the consumer appends its own path-bound
`exclusions.rules` — and from that moment nothing notices when the copy loses a
linter. A deleted line in `enable:` silently turns a gate off and `docs/GO.md`
starts describing checks that no longer run.

`lint-config-check.sh` closes that hole. It resolves both configs with
golangci-lint itself (`golangci-lint linters --config …`, not by grepping YAML)
and diffs the enabled sets:

- `linter_missing` **[error]** — canonical enables it, the consumer does not.
- `linter_extra` **[note]** — the consumer enables more; fine, just visible.
- `setting_drift` **[error]** — `cyclop.max-complexity` or `run.tests` differs.
  Both are load-bearing outside golangci-lint: the first is shared with
  `budget-status.sh` and the structural ratchet, the second decides whether test
  rules are enforced at all.
- `config_absent` **[error]** — a Go repo consuming this module without the
  config is misconfigured, not exempt.

It never rewrites the file; the fix is `goq/sync-config` or a deliberate local
decision. Runs in `ci/fast.sh` (config-only, no compilation).

## Dependency surface (`goq/deps`)

Go has no dependency-policy tool; this is the nearest offline equivalent.

- `go mod verify` — the module cache still matches `go.sum`. **[error]**
- direct-dependency count vs `CAP_DIRECT_DEPS` (40). **[warning]**
- new direct dependencies absent from a committed baseline. **[error]**
- dropped dependencies — an improvement worth locking in. **[note]**
- available updates — `--updates` only, needs the network, off in the gate.

New-dependency enforcement is opt-in the same way the structural ratchet is:

```
scripts/deps-status.sh --refresh        # writes benchmark/deps/baseline.txt
git add benchmark/deps/baseline.txt     # commit to enable enforcement
```

After that, adding a direct dependency fails the gate until the baseline is
refreshed in the same commit — which is exactly the review moment a new
dependency deserves. Runs in `ci/full.sh`.

## Out-of-band gates (`goq/cov`, `goq/race`)

Both roughly double wall-clock, so neither is in `goq/ci`. Run them nightly,
pre-release, or after touching anything concurrent.

`goq/cov` measures per-package coverage (**not** `-coverpkg=./...`, which counts
a handler reached by an end-to-end test as coverage of everything it touches).
Packages with no test files are reported as their own finding and excluded from
the total, so a new untested package cannot silently dilute the number. It
reports and exits 0 until a floor is committed:

```
scripts/cov.sh --refresh                     # writes benchmark/coverage/baseline.txt
git add benchmark/coverage/baseline.txt      # coverage may rise, not fall
```

`goq/race` runs `go test -race` with `CGO_ENABLED=1` (the detector needs cgo)
and a `count` prop for shaking out a suspected flake.

## Machine-readable findings (`--format jsonl` + `goq/findings`)

Every gate step also speaks **agent**. The scripts that surface findings accept
`--format jsonl`, emitting one finding object per line on stdout (human status
routed to stderr) in a shared schema:

```json
{"tool":"structure-ratchet","rule":"gocyclo_over","level":"error","path":"cmd/dex/main_index.go","line":178,"col":1,"message":"gocyclo_over grew above baseline: …","fingerprint":"gocyclo_over:cmd/dex/main_index.go:178"}
```

Fields: `tool, rule, level (error|warning|note), path, line, col?, message,
fingerprint`. `level:error` = gate-failing — the same signal the human gate
enforces. Emitters: `ai-lint` (every smell = error), `structure-ratchet` (NEW
offenders = error, improvements = note), `deps` (new dependency = error, count
over cap = warning, dropped dep = note), `lint-config-check` (missing linter or
setting drift = error, extra linter = note), `dupl` (clone pairs = warning),
`budget` (god files + over-cap complexity = warning), `cov` (below floor =
error; not aggregated — see below). Text output is byte-identical without the
flag.

The **`goq/findings`** preset (`findings.yml`) aggregates every emitter into one
`.gate/findings.jsonl` artifact (gitignored, truncated per run). It is a **pure
producer** — emitters never abort the sweep and it does not re-gate; enforcement
stays with `goq/ci`. It also stays **offline and cheap**: `deps` runs without
`--updates`, and `cov` is deliberately not an emitter because it would re-run
the whole test suite. This is the boundary agents read; dedup across runs via
each finding's `fingerprint`. Consume it with a task:

```yaml
findings: goq/findings   # -> .gate/findings.jsonl
```

**SARIF** — `goq/sarif` (`findings-to-sarif.sh`) projects the JSONL stream into
SARIF 2.1.0 (`.gate/findings.sarif`), a pure leaf format change so the same
findings upload to GitHub code scanning and render in IDEs. Levels
(error/warning/note) map straight across; each finding's `fingerprint` becomes a
SARIF `partialFingerprint` for stable cross-run dedup. Run on demand / in CI
after `goq/findings`, never in the local fast path:

```yaml
sarif: goq/sarif   # .gate/findings.jsonl -> .gate/findings.sarif
```

## `GO_TAGS` support

The CI gates and `arch-snapshot.sh` honor a `GO_TAGS` env var and thread it into
`go build`/`go test`/`go vet`, `golangci-lint --build-tags`, `govulncheck -tags`,
and `go list`. This is what lets **dex** run the shared gate with its mandatory
`sqlite_fts5` tag (mattn/go-sqlite3 ships FTS5 only with that tag) without
forking the scripts. Projects with no build tags leave `GO_TAGS` unset and the
flag is simply omitted.

Other knobs: `PKG` (default `./...`), `CAP_GOCYCLO` (35), `CAP_GOD_LOC` (500),
`T` (dupl threshold, 100), `CAP_DIRECT_DEPS` (40), `DEPS_BASELINE`
(`benchmark/deps/baseline.txt`), `COV_MIN` (0), `COV_BASELINE`
(`benchmark/coverage/baseline.txt`), `GATE_DIR` (`.gate`).

## Reconciliation notes (canonical vs. project-local)

These scripts were reconciled from the divergent mooncake + dex copies into one
canonical version each. What stayed **out** of the shared baseline, by design:

- **Project-specific budgets.** mooncake's per-handler-LOC cap and
  `config.Step` universal-field cap are mooncake-internal; `budget-status.sh`
  ships only the generic gocyclo + god-file caps. Projects layer extra caps in
  their own script.
- **Project-specific CI stages.** mooncake's docs/schema regen + verify-clean,
  `mkdocs --strict`, and `escalation-lint` are not in `ci/full.sh`; they stay in
  mooncake's own task, run after this gate.
- **Lint exclusions.** `.golangci.yml` carries the shared linter selection,
  `cyclop` cap, staticcheck checks, base gosec excludes, revive rules, and the
  one exclusion block every repo needs (the `_test.go` relaxations that
  `run.tests: true` requires). Per-project `exclusions.rules` are path-bound and
  stay in each repo's own `.golangci.yml` (golangci-lint v2 has no native config
  merge) — `goq/config-check` makes that divergence visible instead of silent.
- **Project-specific stack choices.** `docs/STACK.md` records fleet defaults, not
  mandates. A repo that needs `gorm` or `zap` is not violating anything; it just
  writes the reason down.

## Consuming this module

The ergonomic wiring (mooncake ≥ the default-props/shorthand release): hoist the
invariant `go_tags`/`pkg` into the binding as **default props** and wire each
export with the one-line task-as-alias shorthand.

```yaml
vars: { GO_TAGS: "", PKG: ./... }
modules:
  goq:
    source: "github.com/alehatsman/go-quality@v0.3.3"
    props:
      go_tags: "{{ GO_TAGS }}"   # only the exports that declare it receive it
      pkg: "{{ PKG }}"

tasks:
  test: goq/test
  vet:  goq/vet
  lint: goq/lint
  vuln: goq/vuln
  ci:   goq/ci
  ci-fast: goq/ci-fast
  # budget-status/dupl/ai-lint/fmt/tools/deps/config-check declare neither
  # go_tags nor pkg — the defaults are filtered out, so these wrappers work too:
  budget-status: goq/budget-status
  deps: goq/deps
  config-check: goq/config-check
  # out of band — not in goq/ci, run them deliberately:
  cov:  goq/cov
  race: goq/race
  # build takes its own props, so keep the full form:
  build:
    steps:
      - use: goq/build
        props: { cmd_path: ./cmd, bin: "{{ BIN }}" }
```

A module-level default prop is applied **only to the exports that declare it**
(so a `go_tags` default reaches `lint`/`test`/… but is skipped for
`budget-status`); a per-call `props:` overrides. `mooncake task` lists each
component's own `description:`, so the shorthand tasks need no `desc:`.

The full export catalog + the first tagged release are tracked in #95 (G2).
