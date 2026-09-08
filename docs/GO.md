# Go, done properly

Baseline: **Go 1.27, 2026-09.** Rules, not essays. `[gate]` marks what `goq/ci`
enforces — everything else is review surface.

Companion: [STACK.md](STACK.md) — what to reach for.

The `[gate]` markers are a contract, not decoration. Each one is wired to a
linter in `../.golangci.yml` or a script in `../scripts/`. If you change one
without the other, this document has started lying.

---

## 1. Before the first line

1. **Spec first for anything non-trivial.** Goal, scope, interfaces, edge cases,
   validation. Go makes bad designs easy to write and hard to notice — nothing
   in the type system will stop you from shipping a package that does four jobs.
2. **Boring tech, few deps, small interfaces.** Every dependency is code you
   ship, an `init()` you execute, and a module proxy you trust. [gate: `goq/deps`]
3. **One package until one package hurts.** Splitting later costs a rename;
   splitting up front costs an import cycle you will spend an afternoon on.

## 2. Toolchain, version, modernization

4. **Pin the toolchain in `go.mod`.** The `go` line is your language and API
   floor; the `toolchain` line is what actually builds. "Works on my machine" is
   a version skew.
   ```
   go 1.27.0
   toolchain go1.27.1
   ```
5. **Stay inside the support window.** Go patches the two most recent major
   releases. On 1.25 today you are one release from unpatched, and the patches
   are not cosmetic — see §13.
6. **Set the `go` line to what you actually require**, not to the newest number
   you saw. It gates language features, `go mod tidy` behaviour, and which
   modernizer rewrites are legal.
7. **Tools live in `go.mod`.** `go get -tool <pkg>` writes a `tool` directive;
   `go tool <pkg>` runs it at the pinned version. The `tools.go`-with-blank-imports
   trick has been obsolete since Go 1.24 — delete it.
8. **Run `go fix` and mean it.** Since Go 1.26 it is the modernizer suite:
   `min`/`max`, `for range n`, `slices.Contains`, `strings.Cut`, `wg.Go`,
   `t.Context()`, `errors.AsType`, `b.Loop()`, `any`. Nearly all of it is
   auto-fixable — `golangci-lint run --fix`. [gate: `modernize`]
9. **`gofmt` output or it does not merge.** Import grouping via `goimports`,
   with `local-prefixes` set to your module path. [gate]
10. **`go vet` is not optional and is not lint.** It catches printf mismatches,
    lost struct tags, copied locks, and misplaced `WaitGroup.Add`. [gate]

## 3. Project shape

11. **One module at the repo root.** Multi-module repos are for genuinely
    independent release cadences, not for tidiness.
12. **`cmd/<name>/main.go` parses flags, builds config, calls into a package,
    maps the error to an exit code.** Nothing else. Logic in `main` is logic you
    cannot test.
13. **`internal/` is the default.** Exporting is a decision with a support
    obligation attached; make it deliberately, not by leaving a directory at the
    top level.
14. **Package names describe what they provide** — singular, lowercase, no
    underscores, no plurals. `store`, `httpapi`, `tokenizer`. Never `util`,
    `helpers`, `common`, `base`, `misc`, `types`: those are names for "things I
    did not want to think about". [gate: `revive var-naming`]
15. **Do not stutter.** `store.New`, not `store.NewStore`. `http.Server`, not
    `http.HTTPServer`.
16. **Skip `pkg/`.** It carries zero information and adds a path segment to
    every import in the repo.
17. **Group files by responsibility.** "One type per file" is a convention from
    other languages; Go renders a package as one page.
18. **No `init()` with side effects.** Registration into a global registry,
    opening a file, reading an env var — all of it happens at an unpredictable
    time, before flags are parsed, and cannot be tested. Use an explicit
    constructor.
19. **Package-level mutable state is global state.** `Err*` sentinels and
    immutable lookup tables are fine. A configurable logger, a default client, a
    cache — those belong to a struct someone constructs. [gate: `reassign` for
    the worst case: writing another package's exported var]
20. **Dependencies point inward.** `main` → application → domain. The domain
    package imports none of yours. `goq/arch-snapshot` prints the graph when you
    want to check.

## 4. Types and API surface

21. **Name your domain values.** `type UserID string` cannot be passed where a
    `TenantID` belongs; `string` can be passed anywhere. Validate in the
    constructor, keep the field unexported, and the invariant holds by
    construction.
22. **Make the zero value useful, or make it unreachable.** `bytes.Buffer` and
    `sync.Mutex` are usable at zero. If yours is not, unexport the fields and
    make `New…` the only way in — a half-initialized struct is a nil-pointer
    panic waiting for production.
23. **Accept interfaces, return concrete types.** And define the interface in
    the package that *consumes* it, sized to what that package actually calls.
    An interface declared next to its single implementation is a type alias with
    extra ceremony.
24. **Interfaces are one to three methods.** `io.Reader` is the shape to aim
    for. A ten-method interface is a class hierarchy that got lost.
25. **Struct literals always use field names.** Positional literals break
    silently when a field is added.
26. **A config struct beats functional options** until callers genuinely need to
    compose defaults across packages. Options are a real pattern with a real
    cost: every knob becomes a function, and the zero value stops meaning
    anything.
27. **`any`, not `interface{}`.** [gate: `modernize`]
28. **Generics when you would otherwise write the same function three times.**
    Not to build a type-level framework, and never where an interface reads
    better. Go 1.27 added generic methods; that is not an invitation.
29. **`iota` blocks contain only `iota`.** Mixing a literal into the block makes
    every subsequent value a guess. [gate: `iotamixing`]
30. **Pick pointer or value receivers per type and stay there.** Mixing them
    means a method set that varies by how the value was obtained. [gate:
    `recvcheck`]
31. **Never return `(nil, nil)`.** It forces a third branch on every caller and
    they will forget it. Return a real value, a sentinel error, or a named
    "not found" type. [gate: `nilnil`]
32. **Tag every struct that crosses a boundary** — JSON, DB, YAML. An untagged
    field silently marshals under its Go name and renames itself the day someone
    refactors. [gate: `musttag`]
33. **`omitzero`, not `omitempty`,** for anything where an explicit zero differs
    from absent (Go 1.24+). `omitempty` drops `0`, `false` and `""`, which is
    almost never what an API means. [gate: `modernize omitzero`]

## 5. Errors

34. **Errors are values you return.** Not exceptions, not logs, not `os.Exit`
    from a library.
35. **`%w` when the caller may need to match, `%v` when you are deliberately
    hiding the cause at a boundary.** Choosing `%v` by accident is the most
    common error bug in Go. [gate: `errorlint`]
36. **`errors.Is` for sentinels, `errors.AsType[T]` for types** (`errors.As`
    below Go 1.26). Never `err == ErrX`, never `err.(*MyErr)` — both fail the
    moment anything wraps. [gate: `errorlint`, `modernize errorsastype`]
37. **Sentinels are `Err`-prefixed package vars; error types are `Error`-suffixed.**
    [gate: `revive error-naming`]
38. **Carry data, not a formatted string.** `&NotFoundError{ID: id}` beats
    `fmt.Errorf("user %s not found", id)` the first time a caller needs the ID.
39. **Add only context the caller lacks.** `fmt.Errorf("open config: %w", err)`
    — not `"error while trying to open the config file: %w"`, which repeats what
    `err` already says and reads like an apology.
40. **Error strings are lowercase and unpunctuated.** They get concatenated.
    [gate: `revive error-strings`]
41. **Do not log and return the same error.** Pick the layer that owns the
    decision. Anything else prints the same failure five times and you still do
    not know who handled it.
42. **`return nil` when `err != nil` is data loss**, not a shortcut. [gate:
    `nilerr`, `nilnesserr`]
43. **`_ = f()` needs a comment saying why the error cannot matter.** No comment
    means you forgot. [gate: `errcheck`]
44. **`errors.Join` for genuinely parallel failures** (a batch, a shutdown
    sequence). Not as a substitute for wrapping a chain.
45. **Named results only for `defer`-based decoration or documentation.**
    Otherwise they invite a naked `return` and a reader who cannot tell what
    came back.

## 6. Panics and concurrency

46. **A panic means a programmer made a mistake.** It is never control flow and
    never a response to bad input.
47. **`recover` only at a process boundary** — an HTTP handler, a worker loop —
    and only to turn the panic into a logged error and a 500. A `recover` in the
    middle of a library is a `try/catch` in disguise.
48. **Unchecked type assertions are panics with extra steps.** `v, ok := x.(T)`.
    [gate: `forcetypeassert`, `errcheck`]
49. **Never start a goroutine without knowing how it stops.** A goroutine with
    no owner and no cancellation is a leak you will find with `pprof` at 3am —
    or with the `goroutineleak` profile (Go 1.27), which exists precisely
    because this is so common.
50. **`wg.Go(func(){...})`** (Go 1.25), not `Add(1)`/`go`/`defer Done()`. [gate:
    `modernize waitgroupgo`]
51. **`errgroup` when the goroutines return errors**, `errgroup.WithContext`
    when the first failure should cancel the rest.
52. **Channels transfer ownership; mutexes protect state.** Reaching for a
    channel because it feels idiomatic gives you a state machine you did not
    design.
53. **A mutex sits next to the fields it guards, is unexported, and is never
    copied.** A copied `sync.Mutex` or `WaitGroup` protects nothing. [gate:
    `govet copylocks`, `revive waitgroup-by-value`]
54. **Never hold a lock across a blocking call** — I/O, a channel send, another
    lock. That is a deadlock with a longer fuse.
55. **A buffered channel's size needs a reason.** `make(chan T, 1)` for a
    signal, `make(chan T, N)` because N is the batch. `100` because it felt safe
    is a hidden queue.
56. **Every blocking loop selects on `ctx.Done()`.**
57. **The sender closes, once.** A receiver closing a channel is a panic in
    another goroutine.
58. **Atomic types, not the atomic functions.** `atomic.Int64` cannot be used
    non-atomically by accident; `atomic.AddInt64(&x, 1)` sitting next to a plain
    `x++` can. [gate: `modernize atomictypes`, `revive atomic`]
59. **Loop variables have been per-iteration since Go 1.22.** Delete every
    `x := x`. [gate: `modernize forvar`]
60. **Run the suite under `-race` before you trust concurrent code.** [gate:
    `goq/race`, out of band]

## 7. Context

61. **First parameter, named `ctx`, type `context.Context`.** [gate: `revive
    context-as-argument`]
62. **Never store a context in a struct.** It freezes one request's deadline
    into an object that outlives it. [gate: `containedctx`]
63. **Propagate the context you were given.** Manufacturing a fresh
    `context.Background()` halfway down a call chain silently disconnects
    cancellation from everything below it. [gate: `contextcheck`]
64. **`context.TODO()` is a note to yourself.** It is not a solution and it must
    not survive review.
65. **Context values are request-scoped metadata** — trace ID, auth subject,
    request ID. Never dependencies, never optional arguments. Keys are
    unexported types, never strings. [gate: `revive context-keys-type`]
66. **Every outbound call takes the context and a timeout.** No timeout is a
    hang waiting for production. [gate: `noctx`]
67. **Do not re-wrap the context inside a loop.** Each iteration adds a layer
    and the chain grows without bound. [gate: `fatcontext`]
68. **Cancellation is advisory — you have to check it.** A tight loop with no
    `ctx.Err()` check ignores every deadline above it.
69. **`context.WithoutCancel` for work that must outlive the request**, and
    `context.AfterFunc` for cleanup that must run on cancellation. Detaching by
    passing `Background()` loses the values too.

## 8. Resource lifetime

70. **`defer` on the line after acquisition.** Anything between them is a leak
    path.
71. **`defer` in a loop runs at function exit, not iteration exit.** Extract the
    body into a function. [gate: `revive defer`]
72. **Check the error on any `Close` that can lose data** — a buffered writer, a
    file you wrote, a transaction. Ignoring `Close` on a reader is fine and
    should say so.
73. **HTTP response bodies get closed, always, on every path including the error
    path.** [gate: `bodyclose`]
74. **`rows.Close()` and `rows.Err()` after every `sql.Rows` loop.** Without
    `rows.Err()` a truncated result set looks exactly like a complete one.
    [gate: `sqlclosecheck`, `rowserrcheck`]
75. **`os.Root` (Go 1.24) for any path derived from untrusted input.** It makes
    `../../etc/passwd` a returned error instead of a breach.
76. **`make([]T, n)` gives you n zero values.** Then `append` adds an n+1st.
    Use `make([]T, 0, n)`. [gate: `makezero`]

## 9. Logging and observability

77. **`log/slog`.** One handler, built in `main`, injected. Not a package-level
    logger that every package reconfigures.
78. **The message is a constant; the variable data are attributes.**
    `slog.Info("user login failed", "user", id, "reason", r)` — not
    `slog.Info(fmt.Sprintf(...))`. A formatted message cannot be grouped,
    counted, or alerted on. [gate: `sloglint static-msg`]
79. **Use the `Context` variants where a context is in scope**
    (`InfoContext`, `ErrorContext`) so trace correlation actually works. [gate:
    `sloglint context`]
80. **Levels mean something.** `Error` = a human should do something. If nobody
    acts on it, it is `Warn` or it is noise.
81. **Never log a secret, a token, or a full request body.** Redact in the
    type's `LogValue()`, not at every call site, and unit-test the redaction.
82. **Spans get ended and errors get recorded on them.** An unended span is a
    trace that never arrives. [gate: `spancheck`]

## 10. Testing

83. **Table-driven, named cases, `t.Run` subtests.** The case name is what you
    read when CI fails at 2am.
84. **Test the exported API from `package foo_test`** where practical. A test
    that reaches into unexported state is a test that fails on every refactor
    and passes on every bug.
85. **`t.Helper()` in every helper**, so the failure points at the caller.
86. **`t.Cleanup` over `defer`** — it runs after parallel subtests, `defer` does
    not.
87. **`t.Context()`, `t.TempDir()`, `t.Setenv()`, `t.Chdir()`.** They clean up,
    they fail loudly, and they respect the test lifecycle. [gate: `usetesting`]
88. **`t.Setenv` and `t.Parallel` are mutually exclusive** — the env is process
    global. The test binary will tell you, at runtime, once. [gate: `tparallel`
    for the adjacent mistakes]
89. **`cmp.Diff` for structs, not `reflect.DeepEqual`.** One prints what
    differed; the other prints `false`.
90. **Fakes over mock frameworks.** An in-memory implementation of your own
    interface is faster to write, faster to run, and does not encode call order
    as a requirement. Reach for a generated mock only when the interaction *is*
    the thing under test.
91. **Inject the clock and the randomness.** Code that calls `time.Now()` or
    `rand.Int()` inside the logic cannot be tested deterministically.
92. **`testing/synctest` for concurrent code** (stable since Go 1.25). Its
    bubble gives you a fake clock and a `Wait()` that knows when every goroutine
    is durably blocked. A `time.Sleep` in a test is a flake with a countdown.
93. **`for b.Loop()` in benchmarks** (Go 1.24), plus `b.ReportAllocs()`. It
    replaces `for i := 0; i < b.N; i++` and stops the compiler optimizing your
    benchmark away. [gate: `modernize bloop`]
94. **Golden files are reviewed like code.** An auto-regenerated golden that
    nobody read is a test that asserts the bug.
95. **Fuzz anything that parses bytes.** `go test -fuzz` costs one function.
96. **Do not assert on log output.** You are testing a formatter.
97. **Coverage is a smoke alarm, not a target.** [gate: `goq/cov`, opt-in floor]

## 11. Documentation

98. **Every exported identifier has a doc comment starting with its own name.**
    `// Parse converts s into a UUID.` That is the sentence that shows in the
    index and the sentence an agent reads first.
99. **One package comment per package**, on the file named after the package or
    a `doc.go`. [gate: `revive package-comments`]
100. **Runnable `Example` functions** — the only documentation the compiler
     checks. `ExampleParse`, with an `// Output:` comment.
101. **Comments explain why, not what.** The code already says what.
102. **No design narratives, no changelogs, no "previously this used X" in
     source comments.** That is what the commit history is for. [gate:
     `goq/ai-lint`]

## 12. Performance

103. **Measure first.** `go test -bench` + `benchstat` for how much, `pprof` for
     where, `go tool trace` for why it is waiting. A guess about a Go hot path is
     usually wrong, and usually about allocation rather than CPU.
104. **Allocate less before you allocate faster.** `make([]T, 0, n)` when n is
     known, `strings.Builder` instead of `+=` in a loop, reuse buffers across
     iterations. [gate: `modernize stringsbuilder`]
105. **Pass slices and strings, not pointers to them.** A `*[]byte` parameter is
     almost always a misunderstanding of how slice headers work.
106. **Interface boxing allocates.** A hot path that stores concrete values in
     `any` is allocating once per value.
107. **`sync.Pool` only with a measured allocation problem**, and never for
     anything with a finalizer or an owner.
108. **Stop setting `GOMAXPROCS` by hand.** Since Go 1.25 the runtime reads
     cgroup CPU limits and updates as they change. `GOMEMLIMIT` is the knob that
     still earns its keep in a container.
109. **`-gcflags=-m` tells you what escaped.** Escape analysis explains more
     allocation surprises than any blog post.
110. **Do not micro-optimize what the compiler already does.** Bounds-check
     elimination, inlining and devirtualization are real; your hand-unrolled
     loop is usually slower and always harder to read.

## 13. Supply chain

111. **Every direct dependency is code you ship and an `init()` you run.** The
     count is a budget, not an accident. [gate: `goq/deps`]
112. **Commit `go.sum`. Never widen `GOFLAGS` in CI.** `-mod=readonly` is the
     default for a reason; `-mod=mod` lets a build silently rewrite go.mod.
113. **`go mod verify` and `go mod tidy` in the gate.** [gate]
114. **`govulncheck`, not a generic CVE scanner.** It is reachability-based: it
     reports the vulnerabilities your code can actually reach, which is why its
     output is short enough to act on. [gate]
115. **Keep the toolchain patched.** In May 2026, CVE-2026-42501
     (GO-2026-4984) let a malicious module proxy bypass checksum-database
     validation entirely while serving a Go toolchain — the empty-checksum
     response was treated as a successful verification. Fixed in Go 1.25.10 and
     1.26.3. The supply chain includes the compiler.
116. **Pin `GOPROXY` and `GOSUMDB` to something you trust**, and keep
     `GOPRIVATE`/`GONOSUMDB` as narrow as the private modules require. Every
     path excluded from the checksum database is a path with no integrity check.
117. **Read what a new dependency does at init time** before you add it. A
     module you merely import has already run code by the time `main` starts.
118. **Vendor only for a reason** — an air-gapped build, a reproducibility
     requirement. Otherwise it is a second copy of the truth to keep in sync.

## 14. Traps — 2026 edition

Each of these has cost somebody a day.

| Trap | Reality |
|---|---|
| `err == ErrNotFound` | Fails the moment anything wraps. `errors.Is`. |
| `fmt.Errorf("...: %v", err)` | Silently un-wraps the chain. `%w`. |
| A `nil` pointer in a non-nil interface | `var p *T = nil; var i any = p; i != nil` is **true**. The classic returning-a-typed-nil-error bug. |
| `defer` inside a loop | Runs at function exit. Ten thousand open files. |
| `make([]T, n)` then `append` | n zero values, then your data. |
| Slice aliasing after `append` | `append` may or may not share the backing array. `slices.Clone` when the caller keeps the original. |
| `for ... range` over a map | Order is deliberately randomized. A test that passes locally will fail in CI. |
| `time.Time` compared with `==` | Compares the monotonic reading and the location too. `t1.Equal(t2)`. |
| `t.Parallel()` + `t.Setenv` | Runtime panic. The environment is process-global. |
| A green `golangci-lint` step | On a warm cache it can emit nothing because it did not re-analyze. `goq/lint` cleans the cache first for exactly this reason. |
| `go test` without `-race` | The race is still there. It just did not lose this time. |
| `context.Background()` mid-chain | Disconnects cancellation and drops every value above it. |
| Unbuffered channel in a `select` with no `default` | Blocks forever when nobody is receiving. |
| `GOMAXPROCS` set manually in a container | Since Go 1.25 the runtime already reads the cgroup limit; your value overrides a better one. |
| `omitempty` on a numeric or bool field | Drops `0` and `false`. Use `omitzero` (Go 1.24+). |
| `encoding/json` behaviour change | Go 1.27 makes `encoding/json/v2` the default implementation: invalid UTF-8 and duplicate object keys are now rejected. `GODEBUG=nojsonv2=1` is the escape hatch while you fix the data. |
| `time.After` in a loop | No longer leaks since Go 1.23 (unreferenced timers are collected) — but every guide written before then still says it does. |
| Timer channels | Unbuffered since Go 1.23, and the `asynctimerchan` GODEBUG that restored the old behaviour was removed in 1.27. Code that relied on a stale buffered value is now broken for good. |
| `sync.WaitGroup` passed by value | Never completes. Pass the pointer. |
| Blank-import side effects | A driver registered in `init()` is a global mutation from an import line. |

## 15. Review checklist

- [ ] Does a wrong value have a type that makes it unrepresentable?
- [ ] Can the caller match on the error, or did we hand them a string?
- [ ] Is every error either handled, wrapped with `%w`, or explicitly ignored
      with a reason?
- [ ] Does every goroutine have an owner and a way to stop?
- [ ] Is the context propagated, or did somebody manufacture a `Background()`?
- [ ] Is there a timeout on every external call?
- [ ] Is every acquired resource released on the error path too?
- [ ] Does the zero value work, or is the constructor the only way in?
- [ ] Is each new dependency justified, and did someone read its `init()`?
- [ ] Do the tests assert behavior, or do they mirror the implementation?
- [ ] Would the first doc sentence tell a stranger what this is?
- [ ] Is the exported surface as small as it can be?

## Upstream

- [Effective Go](https://go.dev/doc/effective_go) — still the base layer.
- [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments) — the short list every Go reviewer has memorized.
- [Google Go Style Guide](https://google.github.io/styleguide/go/) — read `best-practices.md` in full; it is the most useful document on this list.
- [Go Proverbs](https://go-proverbs.github.io/) — for the ones that fit on a slide.
- [The Go Memory Model](https://go.dev/ref/mem) — before you write a lock-free anything.
- [Go vulnerability database](https://pkg.go.dev/vuln/) — what `govulncheck` reads.
