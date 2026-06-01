# go-quality

Shared Go quality-gate toolchain for the fleet — **one canonical source** for
the lint config, static-analysis scripts, and CI gates used across `mooncake`,
`dex`, `moongit`, and future Go repos. Consumed as a [mooncake](http://127.0.0.1:8080/alehatsman/mooncake)
module.

## What's here

```
index.yml            module manifest (name + export → component map)
.golangci.yml        shared baseline lint config (common linter core)
scripts/
  ai-lint.sh         AI-smell sweep (stub panics, agent TODOs, prompt artifacts)
  arch-snapshot.sh   package-graph / coupling / cyclomatic snapshot (markdown)
  budget-status.sh   gocyclo + god-file soft-cap status
  dupl-report.sh     production-code duplication report
  install-tools.sh   go install the static-analysis toolchain
  check-tools.sh     verify the toolchain is present
  ci/fast.sh         pre-commit gate  (vet + gofmt + ai-lint + budget)
  ci/full.sh         pre-push gate    (build + test + lint + vuln + arch + budget + dupl)
```

## `GO_TAGS` support

The CI gates and `arch-snapshot.sh` honor a `GO_TAGS` env var and thread it into
`go build`/`go test`/`go vet`, `golangci-lint --build-tags`, `govulncheck -tags`,
and `go list`. This is what lets **dex** run the shared gate with its mandatory
`sqlite_fts5` tag (mattn/go-sqlite3 ships FTS5 only with that tag) without
forking the scripts. Projects with no build tags leave `GO_TAGS` unset and the
flag is simply omitted.

Other knobs: `PKG` (default `./...`), `CAP_GOCYCLO` (35), `CAP_GOD_LOC` (500),
`T` (dupl threshold, 100).

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
  `cyclop` cap, staticcheck checks, base gosec excludes, and revive rules.
  Per-project `exclusions.rules` are path-bound and stay in each repo's own
  `.golangci.yml` (golangci-lint v2 has no native config merge).

## Consuming this module

The ergonomic wiring (mooncake ≥ the default-props/shorthand release): hoist the
invariant `go_tags`/`pkg` into the binding as **default props** and wire each
export with the one-line task-as-alias shorthand.

```yaml
vars: { GO_TAGS: "", PKG: ./... }
modules:
  goq:
    source: "127.0.0.1:8080/alehatsman/go-quality@v0.1.1"
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
  # budget-status/dupl/ai-lint/fmt/tools declare neither go_tags nor pkg —
  # the defaults are filtered out, so these wrappers work too:
  budget-status: goq/budget-status
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
