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

Component wiring (the `use:` exports + `go_tags`/`pkg`/`bin`/`cmd_path` props)
and the first tagged release land in #95 (G2). Until then this repo is the
asset skeleton: the canonical scripts + lint config + manifest.
