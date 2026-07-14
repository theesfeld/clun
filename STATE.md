# STATE

Living checklist and the only session-to-session memory besides PLAN.md/DECISIONS.md.
Update before every commit. Seeded from PLAN.md §5.

---

## Current phase: **25 — Performance pass**  (IN PROGRESS — m1–m5 done: measure / fast paths / shapes+read-ICs / index-key / args-skip; ~3× geomean, gate is ≥5×; Phase 24 committed)

**Phase 25 IN PROGRESS** (Performance pass; deps: all engine phases ✓; ~3k LOC, milestoned). The gate (after
the 2026-07-14 operator-approved split) is **(G1)** conformance pass-list unchanged/grown + **(G2)** ≥5× on
the benchmark suite vs the Phase-24 baseline. The former **(G3)** curated test262 ≥ 90% is now its own
**Phase 25b** (deps: 25) — see PLAN §5 + the resolved note below.

**Milestone 1 DONE — "measure first":** the benchmark suite + the frozen Phase-24 baseline + the design doc
(no engine change). `bench/{richards,deltablue,splay}.js` — the Octane trio ported to clun (self-contained,
deterministic, `Clun.nanoseconds()` timing since `Date.now()` is only 1-second-granular here; each
self-verifies its result and THROWS on mismatch) + `bench/run.sh` + `make bench`. DeltaBlue was hand-written
(its workflow author agent was content-filtered); richards/splay came from the author fan-out. **Frozen
Phase-24 baseline** (commit `b9a8a862`, SBCL 2.6.5, Intel Ultra 9 275HX, best of 5, in `docs/benchmarks.md`):
startup 17 ms; richards 3600.4 ms / 80 iters; deltablue 2942.0 ms / 40 iters; splay 1520.3 ms / 40 iters — so
the ≥5× gate is richards ≤720, deltablue ≤588, splay ≤304 ms. Measurement is SELF-RELATIVE (clun-vs-clun on a
fixed workload — node/bun are NOT on this host, so no cross-runtime numbers are claimed). Design
(`docs/design/phase-25.md`, synthesized from a parallel map of the object model + emitter): shapes
(transition tree keyed by property-add + dict fallback) behind the `obj-own-desc`/`obj-set-desc` seam
(objects.lisp:91/94); inline caches keyed by shape at the `js-getv`/`js-set` emitter seams; direct call paths
for known arity; a `+=` string-builder; COMPILE-tiering only if measured-necessary. No engine code changed
this milestone, so `make purity` (**687 files**) and `make test-lisp` (**2627**/0/0) are unchanged and exec
conformance is provably **22,643** (the ASDF load plan is untouched — bench fixtures + docs + a `make bench`
target only).

**Milestone 2 DONE — profile-guided fast paths:** a `sb-sprof` profile of the baseline
(`scripts/profile.lisp`) redirected the plan — several cheap, low-risk hot spots were worth taking BEFORE
the risky shapes rewrite. Four behavior-preserving changes (no kernel-architecture rewrite): (1)
`with-js-floats` masks the FP traps once per JS call chain instead of per arithmetic op (a per-thread
`*fp-masked*` guard + coarse masks at `jm-call`/`jm-construct`) — killed `arch_set_fp_modes` (~4%); (2) a
property-write fast path mutating an existing own writable DATA descriptor in place (guarded `(eq o receiver)`
+ non-array, so `Reflect.set` to an exotic receiver / arrays keep the full path) — killed the
validate-and-apply write cost (~24%); (3) a tight `ptable-pos` linear scan (direct `string=`/`eq`, no generic
`position`/`equal`); (4) inlined descriptor predicates (`pd-set-p` etc.). **Measured (best of 5):** richards
3600.4→2262.0 ms (**1.59×**), deltablue 2942.0→2182.0 (**1.35×**), splay 1520.3→901.2 (**1.69×**), geomean
≈**1.53×**. `make test-lisp` **2627**/0/0; conformance G1 pending re-verify (expect **22,643**, 0 regressions).
Adversarial review panel (3 agents) found **1 HIGH — FIXED**: the write fast-path's original
`(not (js-array-p receiver))` guard dropped a `Reflect.set(plainObj, idx, v, typedArray)` write (a typed
array synthesizes a throwaway descriptor); the `(eq o receiver)` guard closes it (verified: `ta[0]` now
written). Re-profile confirms the property-key scan (`STRING=*`+`ptable-pos` ~33%) + adjustable-vector `aref`
(~15%) now top the profile — exactly the shapes/IC targets.

**Milestone 3 DONE — shapes + read inline caches:** a `pshape` transition tree (interned per
property-ADD order; `objects.lisp`) on the ptable gives objects with the same key layout a shared shape
identity; the ptable gained a `shape` slot (defaults to a shared `*root-pshape*`; NIL = dropped out after a
delete; arrays demoted to NIL). A per-site monomorphic READ inline cache (`%ic-read`, struct
`ic{shape,slot,holder,hshape}`) keys on that shape: an OWN-data hit reads `descs[slot]` directly (no key
scan, no `[[Get]]` generic dispatch); a **depth-1 PROTO hit** (for method dispatch `obj.m()`) additionally
revalidates the direct-proto link + holder shape. Both re-read the LIVE descriptor + require
`data-descriptor-p`, so value/attribute/data↔accessor/freeze changes stay correct — only a LAYOUT change
flips/clears the shape → miss → full `jm-get`. Wired at the emitter's static member read + assignment-target
read + method-call read sites. **Measured (best of 5, cumulative vs baseline):** richards 3600.4→1705.0 ms
(**2.11×**), deltablue 2942.0→1968.7 (**1.49×**), splay 1520.3→884.7 (**1.72×**). `make test-lisp` **2666**/0/0 (added shape-cap + IC hit-path/invalidation regression tests).
**Adversarial IC-soundness panel (3 agents, each built the engine + ran live JS probes — 18+22+46 scenarios):
ZERO findings** — shape maintenance (no cross-hit; every layout mutation funnels through the seams),
own-data IC, and the three-part proto-IC guard all verified sound (setPrototypeOf, shadowing, holder
add/delete, data↔accessor churn, freeze, depth≥2 never cached, `this` preserved). Fixed a stale `props`-slot
comment in values.lisp the panel flagged. **Memory leak found by the G1 GATE (not the panel):** the first
conformance run OOM'd — the pshape tree is process-global + monotonic, so dynamic-key objects mint unbounded
pshapes across the 40k-programs-in-one-image runner (also a real `Clun.serve` leak). Fixed with a hard global
cap (`*pshape-cap*`=200k → object drops to dict-mode when reached; verified 2M unique keys stays flat at
180 MB; benchmarks unchanged). **G1 conformance (after the cap fix): 22,643 / 0 crashes / 0 regressions;**
`make purity` clean (687 files).

**Milestone 4 DONE — array-index-key-p fast path (profile-guided; the planned write IC was reverted):** a
per-site WRITE inline cache was tried first but REGRESSED deltablue/splay — their writes mostly CREATE
properties (constructor init), where the pre-write shape never matches the cached post-write shape, so every
write missed AND paid an extra refill scan (and the sound fix, a shape-TRANSITION IC, is subtle re: proto
setter shadowing). Reverted. Profiling the laggards instead: splay's #1 cost was `array-index-key-p`
(**26%**) — the canonical-array-index test ran a full float-parse + `princ-to-string` round-trip on EVERY
enumerated key. Rewritten to fail fast (cheap digit scan + direct integer parse; a non-numeric key returns
nil after one char), and the double index-parse in `ordinary-own-property-keys` removed. Semantically EXACT
(verified against the canonical index definition via observable array-length + enumeration behavior — 11
edge-case probes + a 2-agent panel, ZERO divergences). **Measured clean (best of 7, cumulative vs baseline):**
richards 1533.6 ms (**2.35×**), deltablue 1790.4 (**1.64×**), splay 565.0 (**2.69×**). `make test-lisp`
**2666**/0/0; `make purity` 687 clean; **G1 conformance 22,643 / 0 crashes / 0 regressions.**

**Milestone 5 DONE — skip the unused `arguments` object:** deltablue's ~44%-total `setup-frame` cost was
mostly an UNCONDITIONAL `arguments`-object allocation on every non-arrow call. Now a non-arrow function
builds `arguments` only when its body (or a nested arrow at any depth, or a default-param expr) textually
references the identifier — detected precisely by `comp-resolve` flagging the FUNCTION scope
(`cs-uses-arguments`) whenever `arguments` resolves to it (compilation is a full traversal, so every read
[`compile-identifier`] and write [`compile-reference`] is seen); `compile-function-common` reads the flag
AFTER the body is compiled and `setup-frame` gates `make-arguments-object`. Sound: the object is
unobservable in clun by any other channel — `f.arguments`, `arguments.callee`, the arguments iterator,
mapped/aliased args, `with`, and caller-visible direct `eval` are all UNIMPLEMENTED (pre-existing gaps,
confirmed by the panel). **Adversarial soundness panel + coverage probes: ZERO divergences** (reads/writes/
typeof/member/computed/for-in/delete/template/default-param/nested-arrows-1-3-deep/generators/async all
build correctly; `[...arguments]` throws "not iterable" — a PRE-EXISTING gap, unchanged). **Measured clean
(best of 7, cumulative vs baseline):** richards 1064.2 ms (**3.38×**), deltablue 1110.9 (**2.65×**), splay
487.4 (**3.12×**) — the biggest single lift so far (deltablue 1.64→2.65×). `make test-lisp` **2666**/0/0;
`make purity` 687 clean; **G1 conformance 22,643 / 0 crashes / 0 regressions.**

**Next action:** Phase 25 **milestone 6 — close on the ≥5× G2 gate** (now at ~3× geomean; richards 3.38× /
deltablue 2.65× / splay 3.12×). Remaining profile levers: (a) property CREATION — `make-prop-desc`/`data-pd`/
`%make-ptable`/`validate-and-apply` ~15–20% on deltablue/splay (a fast create-data-property path that skips
the validate machinery for a brand-new default data property on an extensible ordinary object); (b) the rest
of the call frame — positional param binding (the current `bind-parameters` walks the args LIST with `nth`,
O(n²)) + cheaper frame alloc; (c) a shaped-`descs` simple-vector to kill the read-IC-hit hairy-`aref`. Take
them one at a time, **profile-guided, verify G1 before measuring each**, and re-evaluate the trio against the
≥5× targets (richards ≤720, deltablue ≤588, splay ≤304 ms). A `+=` string builder is orthogonal (helps
string-concat loops, not this trio) — lower priority.

**G3 scope concern — RESOLVED (2026-07-14, operator-approved split):** the ≥90% curated-test262 target is
split out of Phase 25 into a new **Phase 25b — Conformance push to ≥90%** (PLAN §5). Phase 25's gate is now
just G1+G2 (perf); Phase 25b (deps: 25) owns the ~2,700-test correctness lift, to start with a failure-bucket
analysis of the ~5,520 `fail(gap)` tests. DoD §1.4 point 2's "≥90% at Phase 25's close" now reads "at Phase
25b's close". So Phase 25 closes when shapes/ICs/etc. reach ≥5×; the conformance work proceeds separately
after (on the faster engine).

---

## Recent phase outcomes (most recent first)

**Phase 24 outcome:** Spawn + package scripts — the daily-driver workflow, milestoned; gate MET.
**Milestone 1 DONE (committed):** `Clun.spawnSync` (`src/runtime/spawn.lisp`, `clun.runtime`) — the
blocking subprocess primitive over `sb-ext:run-program :wait t`: `cmd` = `[program, ...args]`
(PATH-resolved via `:search t`), `opts.cwd`/`opts.env` (via `Object.keys`, replaces the env)/`opts.stdin`
(string/typed-array/ArrayBuffer), `stdout`/`stderr` = `pipe`(→ Uint8Array)|`inherit`|`ignore`. Piped
stdout/stderr go to TEMP FILES (a full pipe would deadlock a synchronous read of any size — the file
absorbs it), read back after exit; exit mapping `:exited`→`exitCode`/`:signaled`→`signalCode` (name);
`{pid,exitCode,signalCode,success,stdout,stderr}`; a missing program → a catchable JS `Error`, a non-array
cmd → `TypeError`. Installed onto the `Clun` global. Tests (`spawn-tests.lisp`): echo/exit-code/signal/
stdin/env/stdio-modes/**5 MB-no-deadlock**/cwd/not-found+type-error. `make test-lisp` **2602**/0/0, purity
clean **686 files**, exec 22,643.

**Milestone 2 DONE (committed):** the ASYNC `Clun.spawn` (`spawn.lisp`) — `run-program :wait nil` with
non-blocking stdout/stderr/stdin pipes on the reactor (`sb-unix:unix-read`/`unix-write`, EAGAIN-safe; stdin a
`{write,end}` writer with an :output-drain queue), stdout/stderr as `Promise<Uint8Array>` resolved at pipe
EOF, an `.exited` promise + `exitCode`/`signalCode`/`kill(sig)`/`onExit`. The `:status-hook` (interrupt
context) `lp:loop-post`s a PRE-ALLOCATED thunk ONLY (§6); `%sp-finalize` (loop thread) settles + a loop
handle stays active until child-exited AND all read pipes drained. Verified: exit-code, signal, stdout pipe,
**10 MB dual-pipe (no deadlock, 0.5 s)**, kill, onExit, **1,000 spawns no leak** (sequential — a 1,000-fork
burst hits the 1024 fd ulimit, a system limit not a clun bug). Adversarial panel (6 agents, 5 findings, 4
confirmed): fixed a **§6 recycled-fd use-after-close** (raw `sb-posix:close` left run-program's `:auto-close`
finalizer armed → a later GC closed a recycled fd; now close via the STREAM, which closes once + cancels the
finalizer), a `:stopped`-status premature-`.exited` (finalize now commits only on `:exited`/`:signaled`), a
mid-setup-failure orphaned-handle/fd-leak (setup wrapped in a cleanup handler-case), and a stdin leak when the
child exits before `end()` (finalize closes stdin). `make test-lisp` **2609**/0/0, purity clean **686 files**,
exec 22,643.

**Milestone 3 DONE — `clun run <script>`** (`src/main.lisp`) per §3.6: `/bin/sh -c` (always — a documented
divergence), PATH = the script pkg dir's `node_modules/.bin` for cwd + every ancestor (nearest first) + the
real PATH, `pre<name>` (a failing pre aborts) → `<name>` → `post<name>`, env (`npm_lifecycle_event`/
`npm_package_name`/`_version`/`npm_config_user_agent`/`npm_execpath`/`npm_package_json`), `--if-present`
(missing script → 0), shell-quoted arg passthrough, exit code propagates (signal → 128+sig); the dispatcher
runs a package.json script if present, ELSE falls back to running the name as a FILE (script-first,
file-fallback). A latent bug was FIXED en route: `clun test` had silently ignored `--cwd` (discovery
re-derived cwd from `(truename ".")`) — now honours the caller-resolved cwd (test files also see the right
`process.cwd()`). **PHASE-24 GATE MET:** the spawn matrix (echo/exit/signal/stdin/env/stdio-modes), a
**5 MB (sync) + 10 MB dual-pipe (async, no deadlock, 0.5 s)** drain, **1,000 spawns no leak** (sequential — a
1,000-fork burst hits the 1024 fd ulimit, a system limit), the scripts fixture (`scripts-tests.lisp`:
pre-fail aborts, npm_* env asserted, exit propagation, the `.bin` PATH walk), AND `examples/e2e.sh` — the v1
workflow demo, hermetic: `clun install` a graph from the local fixture → `clun run build` (prebuild → a
`.bin` tool invoked by bare name → a dist artifact) → `clun test` (verifies the artifact) → `--if-present` +
file-fallback dispatch. `make test-lisp` **2627**/0/0; `make purity` clean over **687 files**; exec
**22,643** (0 crashes, 0 regressions — the spawn/scripts layers are engine-inert). Adversarial reviews across
the phase (spawn: 6 agents / 4 confirmed §6 fd/finalize/leak fixes; scripts: found + fixed a MEDIUM
file-fallback argv drop when a flag precedes the name, a §6 missing-`/bin/sh` clean-exit, and a doc-claim
correction — the e2e now actually covers the dispatch its comment documents). **Deliberate divergences:**
always `/bin/sh` (never a login shell); `spawnSync` piped stdio goes through temp files; lifecycle scripts
still never run during install (Phase 23), only via `clun run`.

**Phase 23 outcome:** `clun install` / `add` / `remove` — the package manager, hermetic, milestoned.
**Resolver** (`src/install/resolver.lisp`, `clun.installer`): breadth-first, highest-satisfying, cycle-safe
resolution over the async registry client; `plan-layout` places the graph DETERMINISTICALLY (independent of
async fetch order) — hoist first-seen, nest conflicts (the `shared@1`/`shared@2` diamond). **Linker**
(`linker.lisp`): cache-fetch by integrity else download (http / the Phase-20 https worker) → cache-store →
the hardened Phase-22 `extract-package`; scope-correct `bin` symlinks into `node_modules/.bin`; lifecycle
scripts NEVER run. **Lockfile** (`lockfile.lisp`): `clun.lock` deterministic JSON (`write-json :sort-keys`),
offline-reinstallable, dist-tag pinning, `--frozen-lockfile` drift. **install / install-async**
(`installer.lisp`) + a JSON **writer** (`clun.sys:write-json`) + package.json editing (add/remove). **CLI**
(`main.lisp`): `install` / `add <pkg>` / `remove <pkg>` dispatch + flags (`-d/-D`, `-E`, `--frozen-lockfile`,
`--production`, `--dry-run`, `--registry`). **Gate MET:** the binary e2e (`examples/e2e-install.sh`) —
`clun install` against the local fixture → `clun run` an app that `require`s the installed packages → exact
stdout; then delete node_modules + `clun install` OFFLINE from the lock via the cache → same output +
BYTE-IDENTICAL lock. `make test-lisp` **2581**/0/0; `make purity` clean over **684 files**; exec **22,643**
(0 crashes, 0 regressions — the install layer is engine-inert). Three adversarial panels across the phase
(resolver / install-engine / CLI) confirmed + fixed ~14 findings (placement determinism, §6 raw-error escapes
on a malformed package.json / clun.lock / lock-shape, dist-tag lock pinning, scoped `.bin`, `--registry`
arg parsing). **Deliberate gap:** the live `clun add <pkg>` smoke against real npm stays blocked by the
pure-tls `registry.npmjs.org` `protocol_version` interop gap — the hermetic fixture e2e is the gate.

**Phase 22 outcome:** safe tarball extraction. **Integrity** (`src/install/integrity.lisp`,
`clun.integrity`): SRI (`sha512-<base64>`) over the `.tgz` bytes — `parse-sri` (strongest of 512/384/256/1),
`verify-integrity` or `integrity-error`. **Reader** (`src/install/tarball.lisp`, `clun.tarball`): bounded
chipz inflate (512 MB cap; a decode error or the cap → `tarball-error`, never a raw condition); a ustar/pax/
gnu header reader (octal + GNU base-256 sizes, checksum, pax `path`/`linkpath`/`size` + gnu `L`/`K` + ustar
`prefix` overrides; every size bounds-checked before slicing). **Hardened extractor** `extract-package`:
verify-then-commit — the SRI is checked before any write; entries land in a mkdtemp staging sibling and are
atomically renamed in on success (removed on failure). Invariant: `%safe-descend` re-lstats every parent
component per entry and refuses a symlink component (never write THROUGH a symlink), refuses `..`/absolute/
NUL/empty names (covering the pax/longname/prefix routes); symlink + hardlink escaping targets refused;
device/FIFO refused; mode masked to `#o777` (setuid stripped, exec bit kept); duplicate last-wins;
`%write-regular` re-lstats + refuses a surviving symlink leaf. **Cache**: content-addressed `~/.clun/cache`;
store verifies + temp-renames; fetch re-verifies (a poisoned entry ignored). **Gate MET:** `make test-lisp`
**2506**/0/0 (a lodash-scale + bin + pax-longname corpus; the full mandated traversal suite; integrity +
cache); `make purity` clean over **677 files**; exec **22,643** (0 crashes, 0 regressions — the install layer
is engine-inert). Adversarial security panel (10 agents): the traversal dimension crafted **28 malicious
archives** and found **NO escape** (the invariant holds — a symlink can only ever be a LEAF, never a
traversed parent); fixed 2 §6 reader gaps (a malformed pax LEN raised a raw BOUNDING-INDICES error →
`%parse-pax` now slices only a well-formed record; `inflate-gzip` wraps chipz errors) + adopted a
defense-in-depth symlink-leaf recheck.

**Phase 21 outcome:** semver + the registry front half, hermetic. **Semver** (`src/install/semver.lisp`,
`clun.install`): node-semver ported to pure CL (bignum components, prerelease precedence §11, `^ ~ - x * ||`
ranges, includePrerelease) — 100% on node-semver's OWN fixtures (converted to JSON *by Clun's own engine* — a
`.cjs` that `require`s each fixture + `JSON.stringify`s — then replayed vector-by-vector); 2 enumerated
deviations (3 JS-object `{}` inputs; `validRange` `'*'` vs `Range.toString` `''`) verified faithful by the
panel. **Registry client** (`src/install/registry.lisp`, `clun.registry`): abbreviated metadata
(`Accept: …vnd.npm.install-v1+json`) → a `pkg-metadata` struct via the engine-free clun.sys JSON reader;
scoped `%2F`; `.npmrc`-lite (`registry=`/`@scope:registry=`/`_authToken`) + `--registry`; transient retries
(408/429/5xx/conn) with a tracked+cleared backoff timer; transport dispatches http → the Phase-18 reactor
client, https → the Phase-20 pure-tls worker path (`net:https-request`, fail-closed). **Local fixture**
(`tests/lisp/install/registry-fixture.lisp`): a manifest-driven (`tests/fixtures/registry/packages.json`)
in-process server (`net:tcp-listen` + the Phase-17 parser) serving 7 packages / 10 hand-built tarballs
(plain/scoped/bin/diamond-conflict/**pax-longname**); `dist.integrity` = sha512 from the real bytes
(ironclad + cl-base64); ETag → 304; gzip via a **stored-block gzip encoder** (no deflate encoder is vendored —
chipz decompresses only — so it emits valid RFC-1952 STORED blocks + an ironclad CRC32; chipz round-trips it);
reusable via `make registry-fixture`. **Gate MET:** `make test-lisp` **2462**/0/0; `make purity` clean over
**674 files**; exec **22,643** (0 crashes, 0 regressions — the install layer is engine-inert). Adversarial
panel (22 agents, 18 findings): fixed a **§6** fixture crash (a malformed `%`-escape threw a raw parse-error
that unwound `run-loop` — `%url-decode` now tolerant + on-data wrapped → 400; regression test added),
`parse-registry-base` userinfo-strip + bracketed-IPv6, `auth-token-for` path-scoping, 408 retry + backoff
timer clear; a blocking `fetch-metadata` was dropped (untestable in-process). HTTPS proven **FAIL-CLOSED**
only (an untrusted in-process pure-tls server is rejected); a green in-process round-trip is not asserted
(pure-tls self-interop peer-cert race) and live npmjs stays gated on the `protocol_version` interop fix.
**Prose-honesty:** an apologetic/unverified source comment the user flagged was removed — no unverified
claims in source/docs.

**Next action:** Begin Phase 22 (Tarball + integrity; deps 13 ✓ + 21 fixtures ✓): streaming chipz-inflate →
a hand-rolled ustar/pax reader (pax `path`/`linkpath`/`size` overrides, gnu `L` longname, `package/` prefix
strip, mode-bit capture); SRI sha512 **verify-then-commit** (temp dir + atomic rename); a content-addressed
cache. **Gate:** a real-package corpus (lodash-scale fixture, a bin package, the Phase-21 **pax-longname**
tarball) extracts correctly, PLUS the **mandated traversal suite** — absolute names, `..` plain/embedded/
via-pax-path, longname `..`, symlink-escape then write-through, hardlink escape, pax linkpath escape, NUL/
empty/`.` names, device/FIFO rejected, setuid stripped, size-field overflow + base-256, duplicate last-wins,
header-before-pax ordering — every case rejected/handled per spec.

**Phase 20 outcome:** HTTPS. `fetch("https://…")` over the Phase-19 pure-CL TLS stack. **pure-tls is now in
the `clun` binary** (`:depends-on`; ironclad + the closure come with it). Because pure-tls does a BLOCKING
handshake + gray-stream I/O (unfit for the non-blocking reactor), HTTPS runs on the **worker pool** (§3.2):
`src/net/tls-client.lisp`'s `https-request` (blocking connect → `make-tls-client-stream` `+verify-required+`
+ trust context → `%serialize-request` → read-to-EOF → the Phase-17 response parser → gunzip) runs on a
worker; `web-fetch` `%do-fetch` dispatches by scheme (http → the Phase-18 reactor client; https →
`%https-request-async` via `lp:worker-submit`), reusing redirects / AbortSignal / timeout / Response; abort/
timeout close the worker's socket to unblock the read (verified: `AbortSignal.timeout` unblocks a stuck
handshake at ~the deadline). The realm loop is `:workers 0`, so `workers.lisp` gained lazy, mutex-guarded
worker spawning. Trust: `$SSL_CERT_FILE` / `$SSL_CERT_DIR` → a probed system CA bundle; no anchor → reject.
**THE SECURITY FIX (critical):** pure-tls's client verify step SKIPS verification when no peer certificate is
recorded — and on the pure-tls↔pure-tls path the peer cert is recorded only RACILY, so a handshake could
complete and be ACCEPTED with an unverified certificate (a certificate-authentication BYPASS; reproduced: a
leaf not anchored in the trust store was accepted). **Patched `vendor/pure-tls/src/streams.lisp` so
`+verify-required+` with a null peer cert FAILS CLOSED** (`tls-verification-error :no-peer-certificate`);
peer-cert ⟺ chain (leaf-first, set together) so this closes the only fail-open. Verified: the bypass now
rejects; real HTTPS still works; pure-tls's own 10 suites still pass. (A README posture line claiming HTTPS
"always fails closed" had been written while the bypass was known — corrected; the posture is now honest AND
the claim is now true.) **Gate MET:** hermetic — a deterministic net-level TLS transport round-trip, a
verify-FUNCTION matrix (expired / wrong-host / self-signed / bad-chain each → its distinct condition), and a
deterministic end-to-end fetch FAIL-CLOSED test (fetch a fixture WITHOUT trusting its CA → must reject); live
smoke (logged): example.com accepts under the system store + rejects under the test CA (verification both
ways against a real server); the badssl.com expired/wrong-host/self-signed/untrusted-root subdomains all
reject. `make build`/`test`(**1286 parachute + 42 TS + 74 JS**)/`test-tls`(10 suites / 342)/`test-crypto`(24)/
`purity`(**669 files**) green; exec **22,643** (0 crashes, 0 regressions — the TLS stack is not in a bare
test262 realm's path). Adversarial review: the ultracode panel hung on a live fetch, so fail-closed + §6
crash-safety (empty-host / dead-port / plaintext-server → clean JS errors, never a backtrace) + abort/timeout
were verified BY HAND. Test CA via `scripts/gen-test-certs.sh` (checked-in PEMs; openssl is a build-time
fixture tool, not a runtime dep). **Deliberate gaps:** registry.npmjs.org handshake fails (pure-tls
`protocol_version` — flagged for Phase 21); blocking DNS; one worker per in-flight request; the 120 s default
fetch timeout is long (but protective — Node/Bun have none); reactor-native TLS is post-v1.

**Next action:** Begin Phase 21 (Semver + registry client + local registry fixture; deps 00 for semver ✓, 18
for the client ✓ — ◇ semver is independent): port node-semver (versions, prerelease precedence, ranges
`^ ~ - || * x`, includePrerelease) + its fixture corpus at 100%; a registry client (abbreviated-metadata
Accept, scoped `%2F`, retries, `--registry`, `.npmrc`-lite); a local registry fixture (in-process server +
hand-built `.tgz` for ~8 packages with a version conflict / scoped / bin / pax-longname, `dist.integrity`
from real bytes, gzip + ETag/304). Gate: semver corpus 100%; metadata round-trips incl. scoped/gzip/304;
the fixture server reusable as a make target. NOTE: the pure-tls `registry.npmjs.org` `protocol_version`
interop failure MUST be resolved before the LIVE npm smoke (Phase 23) — the local fixture keeps Phase 21
hermetic meanwhile.

**Phase 19 outcome:** the pure-CL crypto/TLS foundation is in-tree + proven. Vendored (pinned, `.git`-
stripped, auto-registered via the vendor/*/ scan) **ironclad** (all primitives — SBCL VOPs, zero foreign) +
**pure-tls** (TLS 1.3 + X.509 + trust store) + a ~18-lib dep closure (alexandria, bordeaux-threads +
trivial-garbage, global-vars, trivial-features, babel, flexi-streams + trivial-gray-streams, cl-base64,
split-sequence, idna, usocket, atomics, precise-time, cl-cancel; + fiveam/asdf-flv/trivial-backtrace to run
pure-tls's own suites). SHAs in DECISIONS 2026-07-13. **The purity scanner does a full DIRECTORY scan of
vendor/, so every foreign-code file had to go — 4 patches + strips** (each `;; clun purity patch (Phase 19):`):
precise-time's C `clock_gettime` → `sb-unix:clock-gettime` (drop the foreign dep + darwin/windows/nx files);
trivial-features's byte-order probe → SBCL's `:little-endian` feature; usocket's `wait-for-input` alien
select → `sb-sys:wait-until-fd-usable` (+ deleted the dead `#+win32` WSA block + the ecl/clasp/lispworks/
cmucl backends); pure-tls's win/mac native-cert `:feature` foreign deps + files stripped. `crypto.
getRandomValues`/`randomUUID` keep their existing pure `/dev/urandom` path (ironclad os-prng routing is a
deferred follow-up); the main `clun` binary is UNCHANGED (crypto is test-only until Phase 20 pulls pure-tls in
for HTTPS). **KATs** (`tests/lisp/crypto/kat-tests.lisp`, own image via `make test-crypto` — kept out of
clun/tests so ironclad's fds don't pressure the socket suites' reactor image): 6 groups asserting ironclad
against PUBLISHED vectors — SHA-2 (FIPS 180-4), HMAC-SHA256 (RFC 4231), HKDF-SHA256 (RFC 5869), AES-256-GCM
(NIST), X25519 (RFC 7748), ChaCha20-Poly1305 (RFC 8439, composed from ChaCha20 + Poly1305 since this
ironclad's AEAD set is eax/etm/gcm) incl. tamper-rejection — **24 assertions green**. **pure-tls's own suites**
(`make test-tls`): crypto / record / handshake / certificate / trust-store / boringssl / x509test / ml-dsa /
cancel / security-regression — **10 suites, 342 checks, all green** (RFC-8448 traces + BoringSSL/OpenSSL cert
fixtures); the genuinely-interop suites (network / openssl-binary / resumption / cancel-integration) are
excluded — they need drakma (Appendix-B study-only) / external binaries / a live network. **Gate MET:** all
KATs pass; pure-tls suites pass; `make purity` clean over **667 files** (was 199); `make build`/`test`
(**1271 parachute + 42 TS + 74 JS**) green; exec **22,643** (0 crashes, 0 regressions — the crypto stack is
not in the `clun` binary's load plan, fully inert). Adversarial review panel (4 dims × find→verify-by-
running/reading, 11 agents, 7 findings / **3 confirmed, all LOW**): (1) added `trust-store-tests` +
`boringssl-tests` to the gate — self-contained + passing (their drakma/"boringssl" refs are a COMMENT /
fixture paths), strengthening it 8→10 suites; (2) deleted the cleanly-removable dead non-SBCL foreign
backends (usocket clasp/lispworks, ironclad ecl-opt); (3) documented the irreducible baseline — reader-
conditional non-SBCL FFI (ffi:c-inline / fli: / ff:def-foreign-call) in ironclad's core (common/prng) +
usocket's ecl/mkcl block is provably never read/compiled on SBCL (features absent; not in the load plan) and
the §1.1 token list (per spec) reports clean; extending the scanner to other-impl FFI tokens is a noted
hygiene follow-up. **Net-socket-suite flakiness FIXED (follow-up commit, 2026-07-13):** the suites had
occasionally thrown `bad file descriptor` under heavy load — SBCL's serve-event signals a bad-fd error when a
handler is left on an fd closed out from under it (a re-entrant close during dispatch / a GC finalizer on an
orphaned socket). `reactor-poll` now catches that, prunes the stale handler(s) (via our own el-fd-handlers +
`sb-posix:fstat`), and continues — never letting the loop die (§6); a `loop/reactor-recovers-from-closed-fd`
regression test locks it. The two borderline perf-threshold tests (server ≥30k req/s, loopback ≥100 MB/s) are
now best-of-3 (a genuinely-slow path fails all three; transient contention is filtered). `make test-lisp` now
deterministically green (8/8 runs, incl. under CPU-hog load); a 30-iteration / 19,500-connection stress under
hog load + forced GC showed 0 escaped errors.

**Next action:** Phase 20 (HTTPS, deps 18 ✓ + 19 ✓) — IN PROGRESS. **Done so far:** the design
(docs/design/phase-20.md — worker-pool blocking-TLS architecture, pure-tls client/server API mapped);
the hermetic **test PKI** (scripts/gen-test-certs.sh → tests/fixtures/certs/: test-ca + localhost-leaf +
expired/wrong-host/self-signed/bad-chain negatives, all verified); and a **proven end-to-end TLS 1.3
round-trip in-tree** — a pure-tls server (our leaf) ↔ client (`+verify-required+`, trust = test-ca,
hostname `localhost`) exchanged data with full chain + hostname verification (blocking, over a loopback
sb-bsd-sockets stream). **Remaining:** `src/net/tls-client.lisp` (blocking TLS HTTP request on the worker
pool, reusing net's request serializer + http-response parser); trust-store resolution
(`SSL_CERT_FILE`/`SSL_CERT_DIR` → system PEM bundle probe → injected test CA); wire `web-fetch` `%do-fetch`
to dispatch `https` → the worker-pool TLS path (redirects/abort/timeout/gzip reused); the negative matrix
as checked-in tests (expired/wrong-host/self-signed/bad-chain each → a distinct catchable error, fail
closed); posture labeling (§3.4) in README + errors; the AbortSignal→close-worker-socket wiring. Gate:
hermetic HTTPS round-trip vs an in-process pure-tls server with the test CA; negatives fail closed with
distinct errors; one live smoke (`fetch("https://registry.npmjs.org/left-pad")` → parseable JSON) logged.
(The Phase-16 net-socket flakiness that surfaced during Phase 19 is FIXED — reactor-poll bad-fd recovery,
above — so the socket gate is deterministic.)

**Phase 18 outcome:** fetch + URL + a reactor HTTP client. Three layers. **`src/runtime/web-url.lisp`** — a
WHATWG URL + URLSearchParams parser in CL: special schemes (http/https/ws/wss/ftp/file) with `//`authority +
default-port elision, userinfo, IPv4 + `[IPv6]` hosts (validated in-process, hex lower-cased), relative
resolution (dot-segments incl. `%2e`; query-only/fragment-only keep the base path; `\`→`/` for special
schemes), percent-encoding per the WHATWG encode sets, non-ASCII host → a loud "IDNA not supported"
TypeError; a URL object (href/protocol/host/hostname/port/pathname/search/searchParams/hash/origin + re-
serializing setters for href/hostname/port/pathname/search/hash) with a **linked** URLSearchParams (get/
getAll/set/append/has/delete/sort/forEach/entries/keys/values/@@iterator/size/toString, `+`↔space, form-
urlencoded) that reflects back into `url.search`. **`src/net/http-client.lisp`** (pure CL) — a reactor
HTTP/1.1 client over `tcp-connect`: serialize the request (origin-form Host, CRLF-stripped headers, Accept-
Encoding: gzip, Content-Length, Connection: close), parse the reply via a **response parser added to
http-parser.lisp** (status line + content-length / chunked / read-until-close framing, `response-finish` on
EOF, ALL bounded by *max-body-bytes* → §6), gunzip (chipz) a `Content-Encoding: gzip|deflate` body, a ref'd-
timer timeout, a cancel thunk. **`src/runtime/web-fetch.lisp`** — `fetch(input, init)` → `Promise<Response>`:
normalize a string/URL/Request + init; http-only (https → loud TypeError, Phase 20); follow 301/302/303/307/
308 redirects (≤20 → TypeError; 301/302-POST + 303 → GET dropping body + content-* headers; 307/308 preserve);
AbortSignal (already/mid-flight → AbortError, timeout → TimeoutError); network/DNS errors → TypeError; a
readable Response (text/json/arrayBuffer/bytes, lenient U+FFFD UTF-8). Vendored **chipz** @ 75dfbc6 (pure-CL
gunzip; DECISIONS 2026-07-13). **Riskiest engine change — reactor-thread affinity:** serve-event dispatches
an fd handler only for a registration made by the thread running it; an `async` body runs on a COROUTINE
thread, so a naive `await fetch(...)` registered the client socket off the loop thread → the connection hung.
Fix `lp:run-on-loop` — reactor mutations (tcp-connect/write/close/shutdown/listen, listener-close) run
synchronously on the loop thread and marshal via `loop-post` otherwise; the loop tracks `el-thread`, and a
coroutine thread binds `lp:*on-foreign-thread*` so pre-run setup on the driver thread stays synchronous
(socket tests unaffected) while a coroutine's setup defers. **Gate MET:** fetch vs the Phase-17 server on ONE
loop — JSON round-trip, text, 4xx/5xx, redirect chains, gzip auto-decode, abort→AbortError, timeout; a WPT-
subset URL corpus; 25 concurrent `Promise.all` fetches all correct — tests/lisp/runtime/url-tests +
tests/lisp/net/fetch-tests; `make build`/`test`(**1271 parachute + 42 TS + 74 JS**)/`purity`(**199 files**)
green; parse 17,512 / exec **22,643** (0 crashes, 0 regressions — the client/URL are engine-inert; the
coroutine `*on-foreign-thread*` binding + loop `el-thread` are behavior-neutral). Adversarial review panel
(6 dims × find→**verify-by-running-the-binary**, 21 agents, **15 findings / 15 confirmed**, 14 fixed + 1
documented): **2 §6 crashes** — fetch to a port >65535 crashed raw (SB-BSD-SOCKETS) → the URL parser now
rejects port >2^16-1 as a TypeError; a non-UTF-8 body crashed `text()/json()` raw → a lenient U+FFFD decoder.
**3 HIGH correctness** — special-scheme `\` not normalized to `/`; empty-user+password dropped on
serialization (silent password loss); the redirect cap resolved with the 3xx instead of rejecting. Plus
MEDIUM (301/302-POST→GET, Host header used the resolved IP + dropped the port, until-close body bypassed
*max-body-bytes*, port setter leading-digits) and LOW (IPv6 lower-case, `%2e` dot-segments, GET/HEAD-with-body
→ TypeError). **Deliberate gaps** (tests/conformance/url-fetch-gaps.txt): IDNA/punycode, the `file:` `C|`→`C:`
quirk, getter-only protocol/username/password/host, IPv6 canonical compression, no connection pool, blocking
DNS, cross-origin redirect header stripping, streaming bodies; `node:url` deprioritized (fileURLToPath/
pathToFileURL already exist).

**Next action:** Begin Phase 19 (Crypto foundation, deps 00; ironclad landed in Phase 12 — ◇ independent of
the HTTP track): KAT suites (SHA-2/HMAC FIPS, HKDF RFC 5869, AES-GCM NIST, x25519 RFC 7748, ChaCha20-Poly1305
RFC 8439); vendor + pin pure-tls with the Linux dep closure (Appendix B); the cl-cancel purity patch (precise-
time → sb-unix:clock-gettime); strip windows/macos verify files; run pure-tls crypto/record/handshake/cert
suites in CI; extend make purity over the closure. Gate: all KATs pass; pure-tls suites pass; make purity
green over the full closure. (Phase 20 HTTPS then unblocks: deps 18 ✓ + 19.)

**Phase 17 outcome:** HTTP/1.1 serving, three layers. `src/net/http-parser.lisp` — a pure-CL incremental
request parser ("accumulate-then-parse"), bounded by max-header/max-body so every malformed shape is a
classified `:error <code>` (400/431/413), never a crash or unbounded growth (§6); handles content-length +
chunked in, pipelining, keep-alive detection. `src/runtime/web-http.lisp` — the **Headers** (case-
insensitive multimap: get/set/append/has/delete/forEach/entries/keys/values/@@iterator), **Request**
(method/url/lazy-headers + text/json/arrayBuffer/bytes over a shared prototype — cheap per request), and
**Response** (new Response/Response.json/status/ok/headers) web classes, on the engine object API, shared
with Phase-18 fetch; a shared `%body->octets` (string/typed-array/ArrayBuffer/Clun.file). `src/runtime/
clun-serve.lisp` — **Clun.serve({port,hostname,fetch,error}) → server{port,url,stop()}**: accepts on the
Phase-16 socket layer, feeds the parser, builds a Request, calls the JS `fetch` handler — a synchronous
Response writes immediately, a `Promise<Response>` from its `.then` continuation. Keep-alive (HTTP/1.1
default; pipelined), Content-Length out, 431/413, HEAD (headers only), Date/Connection, graceful `stop()`
(drains in-flight → resolves), 503 shedding, flush-then-close (`net:tcp-shutdown`). Response header
names/values are **CRLF-stripped** (no response splitting, §6). **Two engine changes:** `run-loop` now
drains microtasks right after the reactor (a socket handler's async `.then` must run → "after the reactor"
is a dispatch point); and `coroutine-resume` **prunes a completed coroutine** from `realm-coroutines`
(they were retained until realm teardown — an unbounded leak for a long-running server with `async`
handlers; RSS now plateaus). **Gate MET:** curl interop (GET/JSON/POST-async/404/HEAD/keep-alive),
malformed-request suite (12 parser tests), **≥30k req/s** (measured ~33k, real parsing + a JS handler),
graceful shutdown, **1k-request RSS plateau** (149 MB flat over 5k reqs after the leak fix), examples/
serve.ts smoke — tests/lisp/net/{http-parser,http-server}-tests + a curl smoke; `make build`/`test`
(**1172 parachute + 42 TS + 74 JS**)/`purity`(**177 files**) green; parse 17,512 / exec **22,643** (0
crashes, 0 regressions). Adversarial review panel (5 dims × find→**verify-by-running**, 16 agents, 11
findings / **2 confirmed + fixed**): `new Request({body})` only handled string bodies (typed-array/
ArrayBuffer/number → empty) → the shared `%body->octets`. Proactively fixed a header-injection (CRLF →
response splitting) + the coroutine leak (surfaced by the RSS curve). Deliberate: buffered bodies; no
routes/static/WebSocket/TLS-server; IP-literal hosts (DNS → Phase 18); URL objects → Phase 18.

**Next action (done in Phase 18):** HTTP client, fetch, URL — WHATWG URL/URLSearchParams minus IDNA; a
reactor HTTP client (redirects ≤20, chunked decode, gzip via chipz); the fetch API (Request/Response/Headers
reused, AbortSignal, network errors → TypeError). Gate: fetch vs the Phase-17 server + a URL corpus.

**Phase 16 outcome:** a non-blocking TCP handle layer on the Phase-05 serve-event reactor —
`clun.net`/`src/net/sockets.lisp`, callback-based (Phase 17+ marshals to JS). Verified sb-bsd-sockets
facts drive it: non-blocking connect signals operation-in-progress; accept/recv return NIL on EAGAIN;
send returns a PARTIAL count when the kernel buffer fills; accepted sockets need explicit non-blocking;
a failed async connect surfaces via peername-signals-then-recv; `:nosignal` turns write-to-closed into a
catchable socket-error (no SIGPIPE); socket-send accepts a zero-copy displaced view. A `tcp` handle holds
a ref'd loop handle (keeps the loop alive while open), a reusable 256 KB read buffer, and a FIFO write
queue of `(octets . offset)` chunks; `%flush` sends the head with `:nosignal`, advancing the offset via a
DISPLACED VIEW on a partial send (copying the remainder would be O(n²) to drain a big write), registers
`:output` + marks backpressured, and fires `on-drain` ONCE on the backpressure→empty edge. `tcp-connect`
(EINPROGRESS→:output→peername-promote/ECONNREFUSED), `tcp-listen` (SO_REUSEADDR, port-0 real-port,
`%on-acceptable` drains the accept queue), `tcp-close` (idempotent: remove both reactor handlers,
socket-close, deactivate handle, on-close once — EOF→code NIL, error→code string). `socket-error-code`
maps sb-bsd-sockets subclasses → JS errno strings (ECONNREFUSED/EADDRINUSE/…). 4 MB SO_{SND,RCV}BUF cut
reactor round-trips. **Gate MET:** tests/lisp/net/sockets-tests.lisp — port-0 real-port, echo roundtrip,
**2,000 sequential + 500 concurrent** echoes, **fd-count stable** (zero leaks over 400 cycles),
connect-refused→ECONNREFUSED, **throughput ~131–137 MB/s** (64 MB loopback ≥100) — all green;
`make build`/`test`(**1122 parachute + 42 TS + 74 JS**)/`purity`(**172 files**) green; parse 17,512 / exec
**22,643** (0 crashes, 0 regressions — the socket layer is engine-inert). Adversarial review panel (5 dims
× find→**verify-by-running-CL**, 11 agents, 6 findings / **4 confirmed + fixed**): a zero-byte `tcp-write`
CASE-FAILURE crash (skip empty + broaden the send catch → §6) and `on-drain` firing spuriously/repeatedly
(now edge-triggered on a genuine backpressure→empty transition, per Node's `drain`). Verified no data
corruption / 0 connection errors across 12,000 connects under 4-CPU-hog contention. Deliberate: hostnames
must be IP literals (DNS→18); IPv6 lightly tested; no UDP; unclassified socket errors → a generic code.

**Next action:** Begin Phase 17 (HTTP server + `Clun.serve`, deps 14 ✓, 16 ✓): own incremental HTTP/1.1
parser (adversarial lengths, §6); Request/Response/Headers classes (shared with fetch); `Clun.serve({port,
hostname,fetch,error})` → Server{stop(graceful),url,port}; keep-alive, chunked both ways, 16 KB header /
configurable body limits (431/413), HEAD, date header; `Clun.file` responses via chunked worker-pool reads;
503 shedding. Gate: curl interop; malformed-request suite; ≥30k req/s loopback with real parsing + a JS
handler; graceful shutdown completes in-flight under load; 1k-request RSS plateau; examples/serve.ts smoke.

**Phase 15 outcome:** `clun test` — a Bun-compatible runner whose framework is implemented in CL against
the engine object API (no JS in the implementation, §1.1). `src/test-runner/` (7 files): **registry**
(the describe/test tree + the JS globals describe/test/it + .skip/.todo/.only/.skipIf/.todoIf/.if/.each,
before*/after* hooks, setDefaultTimeout — describe(fn) runs at load to build the tree, test bodies stash
for later), **expect** (~22 matchers on the shared `eng:js-deep-equal` + inspector, `.not`,
`.resolves`/`.rejects` returning REAL Promises so they run as microtasks under the scheduler's drive,
expect.assertions/hasAssertions), **diff** (LCS line diff → `- Expected`/`+ Received`), **scheduler**
(Bun-exact hook order + timeouts + only/todo/skip/bail/-t), **reporter** (result lines + summary block,
timing omitted for determinism), **discovery** (`*.{test,spec}.*`/`*_{test,spec}.*` walk skipping
node_modules; positional path/substring filters), **runner** (per-file realm → load → schedule →
aggregate → exit code). Engine seams: `run-module-file :teardown nil` (load + drive but keep the loop
ALIVE across tests), `teardown-realm`, and `run-callback-to-settlement` (drive the loop until a test's
promise settles or a ref'd timeout timer fires; catches js-condition AND any raw CL error → a clean test
failure, §6). `main.lisp` routes `subcommand=test`. Bun-faithful hook order (file→outer→inner beforeAll
lazily; beforeEach outer→inner; afterEach inner→outer; afterAll inner→outer), .only per-file isolation,
.todo pass→fail under --todo, -t regex over the full path, --bail, exit 1 on fail/zero-tests/0-match.
**Gate MET:** meta-test matrix + hook-order byte-exact via the fixture harness
(tests/js/testrunner/{hookorder,matchers,failing,skiptodo,only,bail,filter,filterzero,zerotests,async})
green; `make build`/`test`(**1110 parachute + 42 TS + 74 JS**)/`purity`(**170 files**) green; parse 17,512
/ exec **22,643** (0 crashes, 0 regressions — the runner's engine seams are test-runner-only, inert for
conformance). Adversarial review panel (5 dims × find→**verify-by-running-the-binary**, 15 agents, 10
findings / **8 confirmed + fixed**), all §6 crash-safety or wrong-behavior: `.resolves`/`.rejects` on a
PRIMITIVE crashed via jm-get (→ a clean "received is not a Promise" failure + a systemic CL-error→failure
net in run-callback-to-settlement), `toBeCloseTo(Infinity)` FP-invalid trap (guarded; equal infinities
pass), afterAll errors silently swallowed (now reported + counted, symmetric with beforeAll/afterEach),
`.only` buried in a `describe.skip` wrongly activating only-mode (has-only now computed ignoring skip
subtrees). Deliberate: per-test timing omitted (deterministic); no snapshots/mocks; `.each` name
interpolation a subset; runaway SYNCHRONOUS tests non-preemptible (async timeouts enforced).

**Next action:** Begin Phase 16 (Sockets, deps 05 ✓, ◇ independent): non-blocking connect (EINPROGRESS)/
accept/read/write with EAGAIN→NIL; write queues + backpressure; IPv6; port-0 real-port reporting; error
mapping to JS codes (ECONNREFUSED…); BROKEN-PIPE handling — on the Phase-05 serve-event reactor (respect
the thread-registration rule). Gate: echo server 2,000 sequential + 500 concurrent connections;
/proc/self/fd count stable (zero leaks); ≥100 MB/s single-connection loopback.

**Phase 14 outcome:** the async product floor. Most substrate pre-existed (loop queues + heap timers +
handle refcount from 05; Promise/microtask/nextTick + setTimeout/Interval from 06; Clun.sleep from 08/12),
so this was wiring + two new primitives. **Timers**: setTimeout/setInterval/**setImmediate** now return an
enriched Timeout/Immediate object with `ref()`/`unref()`/`hasRef()`/`refresh()`/`close()` +
`[Symbol.toPrimitive]` (a number); ref/unref delegate to the loop handle (`lp:timer-ref/unref/refd-p`), so
an unref'd timer genuinely stops keeping the loop alive. setImmediate maps to the `tasks` (check) queue
with a cancellation box (`clearImmediate`); its ref/unref is liveness-inert (documented). **node:timers**
re-exports the realm globals + legacy no-ops; **node:timers/promises** `setTimeout`/`setImmediate` return
Promises and `setInterval` returns an async iterator, all honouring `{signal, ref}`. **AbortController/
AbortSignal** (new `src/runtime/abort.lisp`, installed by install-globals): a minimal EventTarget for the
`abort` event — aborted/reason/onabort/addEventListener/removeEventListener/throwIfAborted + statics
abort/timeout(unref'd)/any; default reason = Error name "AbortError" (no DOMException in v1). **events.once**
now rejects on `error`, honours `{signal}`, and detaches listeners on settle; **captureRejections** routes a
rejecting listener's promise to an `error` emit. **assert.rejects/doesNotReject** return Promises (matchers,
string-message overload, sync-throw → rejected). Engine fix: **for-await now runs IteratorClose (return())
on break/return/throw** (was leaking lazy sources — the interval iterator hung the loop). **Gate MET:**
ordering corpus (nextTick→microtask→timer→immediate) exact-output, unref'd-timer process-exit test, abort +
timers/promises + events.once fixtures — tests/js/async/{ordering,timers,tpromises,unref,abort,evonce} green;
`make build`/`test`(**1110 parachute + 42 TS + 64 JS**)/`purity`(**163 files**) green; parse 17,512 / exec
**22,643** (+5: the for-await IteratorClose fix; pass-list regenerated monotonic; 0 crashes, 0 regressions).
Adversarial review panel (find→**verify-by-running-the-binary**, 13
agents, 7 findings / 2 confirmed): fixed a §6 HIGH — `process.exit()` inside an async coroutine leaked a raw
`PROCESS-EXIT` Lisp backtrace (the coroutine thread now marshals any non-JS serious-condition back to the
driver, which re-raises it on the JS thread → clean exit with the code); + a LOW (`new AbortSignal()` now
throws "Illegal constructor" on the construct path). Deliberate divergences: top-level setTimeout(0)
before setImmediate (Node unspecified; Clun deterministic); setImmediate unref liveness-inert; AbortSignal is
a partial EventTarget (abort only) with an AbortError Error (no DOMException); AbortSignal.any tolerates a
non-iterable (returns a never-aborting signal); errorMonitor still deferred (no fresh-Symbol mint).

**Next action:** Begin Phase 15 (Test runner `clun test`, deps 14 ✓; 10 for `-t` ✓): discovery
(*.test.*/*_test.*/*.spec.*/*_spec.*, positional substring filters); collection + hook scheduler (exact
Bun ordering + failure semantics, only-bubbling, CI-guard); ~22 matchers on the shared deepEquals/inspector;
`.resolves`/`.rejects` (Jest-async); timeout machinery; reporter + LCS diffs + summary + exit codes; `--bail`,
`--todo`; self-hosting migration of tests/js expect-style suites; meta-tests via the built binary. Gate:
meta-test matrix (pass/fail/skip/todo/only/bail/zero-tests→1); hook-order fixture byte-exact; self-hosted green.

**Phase 13 outcome:** files. Three engine-free layers below the runtime boundary (Phase-07 discipline).
`src/sys/fs.lisp` gains a code-carrying `clun.sys:fs-error` (code/errno/syscall/path) + a `with-fs
(syscall path)` macro mapping BOTH `sb-posix:syscall-error` (errno straight off) and CL `file-error`
(probes the path → ENOENT/EISDIR/EACCES, fills errno from the code) → the condition; the macro + condition
sit ABOVE the first use so the macro compiles. Added: mutating ops (mkdir/rmdir/rm-rf/rename/symlink/
readlink/chmod/truncate/mkdtemp/access), octet + string whole-file I/O (directory-guarded → EISDIR),
stat→fstat (second-granular ns). **`node:buffer` = a Uint8Array subclass** (`src/runtime/node/buffer.lisp`):
a Phase-11 `:uint8` typed-array whose proto chain is Buffer.prototype→Uint8Array.prototype (indexing/
.length/TA-methods inherit) over new engine helpers (`u8-from-octets`/`ta-octets`/`ta-subview`/
`u8-over-arraybuffer`); alloc/from(str|array|ArrayBuffer|Buffer)/concat(zero-pad|truncate)/compare/
copy(memmove backward-overlap)/fill/indexOf/slice+subarray(SHARED memory)/toString+write(utf8/hex/base64/
base64url/latin1/ascii/ucs2, incl. the 2-arg `write(str,enc)` form); numeric read/write funnel through
`%read-uint`/`%write-uint` so ONE `%num-bounds` guard → catchable RangeError on OOB for every int/float/
BigInt/variable-width accessor (floats via sb-kernel float bits, trap-masked). `node:fs`
(`src/runtime/node/fs.lisp`): 23 sync fns as `%op-*` wrapped by `%with-fs`, the SAME ops feeding
`%callbackify` + `%promisify` (14 `fs/promises`) for free; Stats/Dirent/constants; mkdirSync({recursive})
returns the topmost created dir; `.errno` NEGATIVE (libuv/Linux); message `CODE: description, syscall
'path'` via a shared `clun.sys:fs-code-message`. `Clun.file`/`Clun.write` (lazy text/json/arrayBuffer/
bytes/exists; string|TypedArray|ArrayBuffer sinks) return real Promises (fs-error → rejected). **Gate MET:**
tests/js/node fixtures (buffer KAT + bufedge OOB/overlap/pad/encoding + fsops bracket-paths/symlink-chains/
ENOENT/EISDIR + fsedge errno/message/mkdir-return/access + clunfile lazy) green; `make build`/`test`
(**1110 parachute + 42 TS + 58 JS**)/`purity`(**161 files**) green; parse 17,512 / exec **22,638** (0 crashes,
0 regressions — the builtin-module hook is NIL/inert in bare test262 realms). Adversarial review panel
(find→**verify-by-running-the-binary**): crash-safety dominated (raw Lisp backtraces reaching JS) —
Buffer.from(ArrayBuffer) view+OOB crash, OOB numeric read/write across ALL accessors (verified by an
adversarial probe: neg/NaN/Inf offsets, 8-byte read on a 4-byte buf, byteLength overrun), copy
backward-overlap corruption, Clun.file.text() missing-file crash (read-file-string now signals fs-error),
Clun.write(ArrayBuffer); + correctness (concat zero-pad, write 2-arg encoding, mkdir-recursive return,
accessSync mode, error message shape + negative errno). Deliberate divergences
(tests/conformance/fs-buffer-gaps.txt): integer-write value masking, negative/NaN-offset clamping,
view-vs-backing OOB bound; no fds/streams/watchers/Dir/chown/utimes; second-granular stat times.

**Next action:** Begin Phase 14 (Async product wave, deps 06 ✓, 12 ✓, 13 ✓): timers globals + Timer
ref/unref real loop accounting + node:timers + timers/promises; process.nextTick dedicated queue wiring;
events.once + captureRejections; assert.rejects/doesNotReject; Clun.sleep/sleepSync; queueMicrotask;
AbortController/AbortSignal. Gate: extended ordering corpus (nextTick vs microtask vs timer vs immediate)
exact-output; unref'd-timer exit test; abort fixtures.

**Phase 12 outcome:** the engine-light node stdlib floor. Node builtins resolve via an engine hook
`*builtin-module-builder*` (NIL in bare test262 realms → inert there) that the runtime installs; a
`node:`/bare builtin name is intercepted in `require`/`import` before the resolver and returns a per-realm
cached `:cjs` record with a freshly-built exports object. Modules (`src/runtime/node/`, one self-registering
file each): **path** (posix; win32 throws), **os** (over new `clun.sys` /proc + CL primitives), **querystring**
(legacy; null-proto parse), **util** (format/inspect→shared/isDeepStrictEqual/promisify/callbackify/inherits/
deprecate/stripVTControlCharacters/types), **events** (full sync EventEmitter), **assert** (strict family +
loose equal + throws-with-class + AssertionError). Globals: **structuredClone** (deep clone incl Date + cycles;
DataCloneError), **crypto.randomUUID/getRandomValues** (pure `/dev/urandom`; full ironclad → Phase 19),
**Clun.which/nanoseconds/fileURLToPath/pathToFileURL/sleep**; one shared `eng:js-deep-equal` behind
util/assert/Clun deepEquals. **Gate MET:** per-module conformance fixtures (tests/js/node/*) green;
`make build`/`test`(**parachute + 42 TS + 53 JS**)/`purity`(**159 files**) green; conformance parse 17,512 /
exec **22,638** (0 crashes, 0 regressions — engine behaviorally untouched). Adversarial review panel (5 dims ×
find→verify-by-running-the-binary, 31 agents): **25/26 confirmed + fixed** — querystring null-proto +
prototype-collision, util BigInt/Symbol/NaN format + inspect depth:Infinity/null crash + %j circular, events
once-removal-by-identity + emit('error') no-arg + prependListener newListener, assert loose-equal +
throws-class-validation + AssertionError, structuredClone Date/DataCloneError, path extname/format, and a
class of outside-the-float-mask NaN checks (`js-nan-p`, never `=`). The 5 non-reference modules were authored
by a parallel write-only subagent fan-out and integrated in one build.

**Phase 11 outcome:** BigInt + binary data. **BigInt is a plain CL integer** (`js-bigint-p` =
`integerp` — no engine value is ever a raw integer otherwise, so it's an unambiguous value-domain
slot; faithful + cheaper than a wrapper). The front-end was already done (lexer/parser/emitter flow
`123n` through as a CL integer), so the work threaded BigInt through values/typeof/dispatch,
coercions (ToNumeric/ToBigInt; ToNumber→TypeError = the honesty linchpin), all operators (==/=== ,
`1n==1`→true mathematical eq; relational exact bigint↔double; a `numeric-binary` doing full
ToNumeric(l) then ToNumeric(r); bitwise incl. `>>>`→TypeError; `+bigint`→TypeError), inspector
(`123n`), and `BigInt()`/toString(radix)/asIntN/asUintN (`builtins-bigint.lisp`). **Binary data**
(`builtins-binary.lisp`): `js-array-buffer` (ub8 vector, detach = bytes→NIL), ONE `js-typed-array`
struct with a `kind` slot (11 kinds incl. Uint8Clamped + Big{Int,Uint}64) as an integer-indexed
exotic (overrides the `jm-*` generics; CanonicalNumericIndexString element get/set; OOB read→
undefined/write→no-op; ascending OwnPropertyKeys), `js-data-view`; byte assembly is pure SBCL
(`ldb`/`dpb` + `sb-kernel` float-bit primitives), LE for TypedArrays, DataView chooses endianness;
alloc capped at half the runtime heap → catchable RangeError. TextEncoder/Decoder reuse the WTF-8
codec with a USV-string step (lone surrogates→U+FFFD) + BOM strip. **Gate MET:** BigInt **96.1%**
(73/76), TypedArray **67.8%** (835/1231), DataView **70.5%** (346/491) each ≥65%; overall curated
**80.4%** (22,638/28,163) ≥80%; 0 crashes. `make build`/`test`(**1110 parachute + 42 TS + 49 JS**)/
`purity`(**151 files**) green; conformance parse 17,512 / exec **22,638** (0 crashes, 0 regressions).
Adversarial review panel (5 dims × find→verify-by-running-the-binary, 19 agents): **14/14 confirmed
+ fixed** — mostly crash-safety (raw Lisp backtraces reaching the user: signaling-NaN Float32 read,
ArrayBuffer/TypedArray huge-alloc heap-exhaustion, DataView/fill/set detaching-`valueOf`, BigInt
`**`/`<<` DoS) + silent wrong-answers (JSON.stringify BigInt, descending TypedArray keys, unstable/
NaN-misplacing sort, overlapping `.set`, lone-surrogate/BOM codecs); also fixed 7 order-of-eval
regressions from the `numeric-binary` refactor + a `js-unary-plus` double-`valueOf`. Gaps in
tests/conformance/bigint-binary-gaps.txt: resizable/growable buffers, SAB/Atomics, @@species subclass
returns, ES2023 change-by-copy TA methods, TextDecoder streaming/fatal/non-UTF-8 labels, encodeInto,
the 2^27-bit BigInt DoS cap, Number(bigint)=deliberate TypeError.

**Next action:** Begin Phase 12 (Node-compat wave 1, deps 08 ✓; 10 for assert.match ✓): the flagship
fan-out phase — one subagent per module (node:path/os/querystring/util/events/assert), each ships
module + conformance tests; + Clun.inspect/deepEquals/which/nanoseconds/fileURLToPath/pathToFileURL,
structuredClone, crypto.randomUUID/getRandomValues (vendor ironclad with KATs). Gate: per-module
conformance; kitchen-sink fixture runs identically under node where shared.

**Phase 10 outcome:** RegExp is a from-scratch JS-regex parser → own AST → CL-PPCRE **parse trees**
→ `create-scanner` (`src/engine/regex/` ast/parser/translate/regexp-object, ~1.1k LOC). Translating
to trees (not pattern strings) lets us undo JS-vs-PCRE semantics EXPLICITLY: `.` excludes LF/CR/LS/PS
(all four, `:everything` under /s); `\s`/`\S` = the ~25-codepoint JS WhiteSpace set; `\w`/`\W` = ASCII
only (negated forms INSIDE a class emitted as explicit complement ranges); `^`/`$` under /m built over
the full LineTerminator set (PPCRE multi-line-mode breaks on LF only); `\b`/`\B` = ASCII-word lookarounds;
Annex-B legacy octal (`\40`/`\101`/`\8`/`\9`, in & out of classes); empty `[]`/`[^]`. Exec uses
`pp:scan … :start li :real-start-pos 0` so g/y iteration anchors ^/\b absolutely. RegExp object:
lastIndex, exec/test, flag validation (dgimsuy, no dups, /v → SyntaxError), `.source` EscapeRegExpPattern,
IdentifierName group names + duplicate rejection, the RegExp() ctor (copy/override/IsRegExp short-circuit).
String match/matchAll/replace/replaceAll/search/split delegate to the @@ method ONLY when the arg is an
Object (primitive → string fallback), with `$$`/`$&`/$n/`$<name>` templates + fn replacer (named-groups
arg); Symbol.{match,matchAll,replace,search,split,species} statics exposed. **Gate MET:**
built-ins/RegExp/** **76.1%** (696/915) ≥60%; String regex methods **96.9%** (283/292) ≥75%; zero crashes.
`make build`/`test`(**1054 parachute + 42 TS + 49 JS**)/`purity`(**148 files**) green; conformance parse
17,512 / exec **20,631** (0 crashes, 0 regressions). Adversarial review panel (5 dims × find→verify-by-
running-the-binary, 28 agents): **21/23 confirmed + fixed** — all silent-mismatch classes (legacy octal,
empty class, /m terminators, ASCII \b, non-ASCII \S/\W in class, flag validation, scan-start anchors, fn
replacer groups arg, .source escaping, group-name validation, \c, missing Symbol statics + hyphenated
descriptions, RegExp(re) identity), which also unmasked + fixed a latent primitive-@@-getter bug (+102
RegExp tests, 64.9%→76.1%). Deliberate gaps (tests/conformance/regexp-gaps.txt): \p{} (loud; UCD gen
scaffolded), /v, inline modifiers, /d indices, the fully-generic @@ protocol (fast-path exec, not
user-overridable RegExpExec + @@species — 3 former false-passes removed from the pass-list, DECISIONS
2026-07-12), RegExp.escape, variable-length lookbehind (loud), Annex-B-under-/u, astral /u (BMP-only),
2 CL-PPCRE-vs-ECMAScript NFA edges.

**Next action:** Begin Phase 11 (Binary data + BigInt, deps 04 ✓): ArrayBuffer (ub8) + DataView + all
TypedArray kinds (ldb/dpb, make-double-float fast path, detach); TextEncoder/TextDecoder (UTF-8); BigInt
(literals, ops, ToBigInt, mixing TypeErrors, toString radix, BigInt64Array). Gate: TypedArray/DataView/
BigInt curated slices ≥65%; overall curated ≥80%. RegExp deferrals to revisit later: the generic @@
RegExpExec protocol + @@species, RegExp.escape, /d indices, \p{} (needs the UCD generator), /v flag.

**Phase 09 outcome:** `.ts/.mts/.cts` run by type-stripping. A **recursive-descent strip scanner**
(`clun.transpiler`, `src/transpiler/`) over the shared engine token stream erases type syntax to
EXACT-LENGTH whitespace (newlines kept → line+col preserved, no sourcemaps) and hard-errors on
non-erasable constructs (`unsupported-ts-syntax` → JS SyntaxError w/ line:col). It drives the lexer's
regex-vs-divide + template `${}` context exactly (via `reread-regexp`/`reread-template`), uses a
balanced `skip-type` (counts `()[]{}<>`, `>>` split, `=>`-after-`)` function types), and errors loudly
rather than mis-strip. Erases: annotations (var/param/return/field/for/catch), generics (decl/call/
arrow), `as`/`satisfies`, non-null `!`, interface/type/declare/type-only-namespace, import type/export
type + inline `{type X}`, implements, modifiers, overload signatures. Errors: enum/decorator/param-
property/`import=`/`export=`/runtime-namespace/`.tsx`/angle-cast. **The `<` ambiguity**: type-args only
when the matched `>` is followed by `(`/tag with type-list content (so `a < b` never stripped; arrow
generics handled); `a<b>(c)` comparison-call is the documented accepted corner. Loader: engine
`*ts-strip-hook*` (transpiler installs it), `read-source-for` strips before parse; resolver
`.mts`→ESM/`.cts`→CJS. **Gate MET:** 78-pair corpus green (33 byte-exact strip + same-length, 9 catalog
errors w/ line:col, 36 strip→run incl line-preservation); `make build`/`test`(**1004 parachute + 42 TS
+ 49 JS**)/`purity`(**143 files**) green; conformance parse 17,512 / exec 19,540, 0 crashes, 0
regressions. Review panel (6 dims × find→verify-by-running-the-stripper, 24 agents): **18/18 confirmed +
fixed** — contextual keywords as value idents (declare()/interface()/namespace()/abstract/static()),
arrow return types ending in `)`, arrow generics w/ default, tag templates + `as`-in-`${}`, `x!!`/`x! as`,
superclass type args, angle-cast→error, declare-namespace-ambient.
**Documented limits (not strip bugs):** class FIELD syntax unsupported by the ES2017 parser (annotation
strips fine); `class extends` method resolution a pre-existing engine gap; `??`/`?.` post-ES2017.

**Next action:** Begin Phase 10 (RegExp, deps 04 ✓): JS regex parser → own AST → CL-PPCRE parse trees
(group numbering, named-group map, i/m/s flags, `u` down-translation over code-unit strings); RegExp
object (lastIndex/exec/test/indices); String match/matchAll/replace/replaceAll/split/search with
`$1`/`$<name>`; loud SyntaxError for documented gaps; UCD generator for later `\p{…}`. Gate:
`built-ins/RegExp/**` ≥60% (gaps enumerated), String regex methods ≥75%, zero regressions.



**Phase 08 outcome:** `clun` is a real CLI. A `clun.runtime:install-runtime` hook augments a fresh
(runtime-free) realm with `console`, a full `process`, and a `Clun` stub; the CLI (`clun.cli` +
`main.lisp`) parses flags, autoloads `.env`, runs the entry, and renders uncaught errors. **The ONE
shared inspector** lives in `clun.engine` (`inspect-value`), Bun-flavored (verified vs Bun's
`console-log.expected.txt`): double-quoted strings, multiline objects + trailing comma, inline arrays,
`[Object ...]` past depth 2, `[Circular]`, `[Function: name]`, `Name {}` instances, `[Number: 5]`
wrappers, `Promise { … }`, `Map(n){ k: v }`. **console** log/info/debug→stdout, warn/error/trace→stderr,
`util.format` specifiers (`%s %d %i %f %j %o %O %c %%`). **process** argv/env(snapshot)/exit/exitCode/
platform/arch/pid/cwd/chdir/versions(node 22.11.0)/stdout.write/isTTY/hrtime(µs)/memoryUsage/on('exit').
**CLI** positional-stop flags (`-e`/`-p` as script, `-p` awaits a settled promise; `--cwd`/`--silent`/
`--revision`/`--backtrace`); extension routing → `run-module-file`; uncaught JS → `Name: message` +
stack on stderr, exit 1; stack overflow → `RangeError`; no Lisp backtrace without `--backtrace`; exit
0/1/2. **JS-fixture harness** `scripts/run-js-fixtures.lisp` + `tests/js/` wired into `make test`.
**Gate MET:** run/eval fixture matrix (13 JS fixtures: console/format/streams/process/exit/onexit/eval/
errors/env) green; console subset matches Bun; `make build`/`test`(**976 parachute + 13 JS**)/`purity`
(**138 files**) green; **conformance parse 17,512 / exec 19,540, 0 crashes, 0 regressions.** Review panel
(6 dims × find→verify-by-running, 23 agents): **17/17 confirmed + fixed** — several raw Lisp backtraces
(float-trap crashes in `%d`/`process.exit`/`hrtime` on NaN/Inf) that violated the no-backtrace contract,
plus getter/setter labels, class-instance names, `-p` string raw, `on('exit')` on throw, chdir errors,
`.env` `#`/`$VAR`. **Deferred 🟡:** `[class X]` display, SetIterator/MapIterator, exact 80-col array
wrapping, `hrtime.bigint` real BigInt (Phase 11), `.ts` execution (Phase 09).

**Next action:** Begin Phase 09 (TypeScript stripping, deps 08 ✓): erasable-syntax strip pass sharing
the engine lexer (§3.3); error catalog (enum/namespace/param-props/decorators/`import =`); `.tsx`
rejection; ≥60-pair corpus incl. adversarial (`<` ambiguity, generics-in-arrows, multiline annotations);
loader wiring for `.ts/.mts/.cts` (route through the Phase-08 CLI's TS branch). Gate: corpus green +
strip→run stack-trace line:col identical to source + each catalog error fires.

**Phase 07 outcome:** real multi-file projects run from `node_modules`. Three engine-free layers:
`src/sys/` (`clun.sys`: path discipline via `parse-native-namestring`, sb-posix+`truename` fs
primitives, a hand-rolled JSON reader) → `src/resolver/` (`clun.resolver`: the full Node CJS+ESM
algorithm — relative/absolute/bare, extension probing, dir index, `main`/`type`/`exports`/`imports`
with conditions + subpath patterns + `null` blocks, self-refs, scoped `@scope/pkg`, node_modules
walk, symlink realpath; **no engine dep**) → `src/engine/modules/` (records + a frame-based ESM
compile + CJS `require` + loader). **Module env = a frame** (Option A): compiled like a function
body, imports are getter-thunk slots MARKED on the cscope (shadow-safe deref via `compile-
identifier`); `import.meta` a reserved slot. **Load→evaluate = one post-order pass**: ESM→ESM imports
are live thunks into the exporter's frame slot (true live bindings, acyclic); ESM→CJS reads
`module.exports`. **CJS** runs sloppy in the Node `(function(exports,require,module,__filename,
__dirname){…})` wrapper (`this`===`module.exports`); realm-registry cache; cycle→partial; throw→evict.
**Interop:** import-of-CJS default=`module.exports`/named=enumerable keys 🟡; `require()` of ESM
throws; JSON module default=parsed value. **Gate MET:** resolution corpus green (101 assertions,
40+ scenarios); the fixture app (ESM entry → CJS dep + scoped ESM pkg via exports maps + JSON +
import.meta) runs; `make build`/`test`(887)/`purity`(128) green; **conformance parse 17,512
(+9), exec 19,540 held, 0 crashes, 0 regressions.** Review panel (6 dims × find→verify-by-running,
24 agents): 17/18 findings confirmed + fixed (exports pattern precedence, bare-in-exports reject,
`..`-escape block, JSON overflow→Infinity/strict-grammar/dup-key-last, CJS this+throw-evict, JSON
`{default as X}`, ESM early errors, named/anon default-export). **Deferred 🟡 (not gate-blocking):**
ESM cyclic live-binding-through-reassignment; TLA; namespace-object is a snapshot; test262
`module`-flagged exec tests stay skipped (follow-up: route via `run-module-file`).

**Next action:** Begin Phase 08 (CLI shell, console, process, deps 07 ✓): dispatcher + exact flags
(`-e`/`-p` as `[eval]` module — `run-module-source` exists, positional-stop, `--cwd`/`--silent`/
`--revision`/`--backtrace`); `.env` autoload; the shared inspector + full console; process core
(argv/env/exit/cwd/platform/versions/stdout.write/hrtime/…); uncaught-error rendering.

**Phase 06 outcome:** the async engine is live via **thread-per-coroutine** (the §3.1 fallback, taken
deliberately over state-machine lowering — see DECISIONS 2026-07-11 + docs/design/phase-06.md).
`src/engine/async/` (coroutine/generator/promise/async-function, ~900 LOC): generators (next/return/
throw, yield*, try/finally×yield×return via the real CL stack — for free), Promises (capability +
Symbol.species subclass model, thenable adoption, then/catch/finally, all/allSettled/race/any,
IfAbruptRejectPromise, unhandled-rejection→exit), async/await, for-await-of (sync + async iterables),
async generators. `run-source`/`eval-source` host a per-realm event loop (`:workers 0`), run top-level,
drive to idle, report unhandled rejections; runaway/abandoned coroutines are force-finished/terminated
at teardown (0 thread leak verified). **Gate MET (each dir ≥75%):** Promise 76.1%, async-fn 78.1%,
for-await 78.7%, generators ~78.5%; ordering corpus (nextTick<microtask<timer) passes; **0 crashes, 0
regressions** across the 34,779-file exec phase (pass 19,449, +3,118). 719 CL unit tests; purity clean
(115 files). Key conformance fixes: runner auto-includes doneprintHandle.js for `async` tests;
combinators reject-on-abrupt + AlreadyCalled guard. **DEFERRED to Phase 07:** ESM linking + TLA (Phase
07 owns module resolution); the gate does not require them. Phase 03 deferral `class extends` super
caps the Promise-subclass tests (revisit later).

**Next action:** Begin Phase 07 (Module resolution & CJS): `src/resolver/` pure-CL Node resolution +
~40-tree fixture corpus, loader hooks, CJS `require`, ESM↔CJS interop, JSON modules, import.meta. This
subsumes the deferred Phase 06 ESM linking. Deps 06 ✓.

**Phase 05 outcome:** the pure-SBCL reactor is live (`src/loop/` + `src/sys/sbcl-compat.lisp`, ~600
LOC). serve-event poll reactor + self-pipe wakeup (verified: signals don't wake serve-event, a byte
does — and the fd handler MUST be registered on the thread that runs serve-event, else it silently
never fires; `run-loop` registers it on the loop thread); own binary-heap timers (FIFO ties,
repeating, lazy cancel); handle refcounting (ref/unref real, loop exits at refs=0 ∧ queues empty);
enqueue-only signal delivery (atomic counter + self-pipe, §6 iron rule); sb-thread worker pool
(mailbox + loop-post completions); nextTick/microtask/task stub queues with Node-faithful drain
(nextTick priority, microtasks after each macrotask). Callbacks are CL thunks — Phase 06 wires JS
jobs into the same queues. **Gate MET:** timer ordering ✓, cross-thread wake <5 ms ✓, alive-iff-refs
✓, SIGINT→loop event ✓, microtask-drain ordering ✓. 674 unit tests; purity clean (110 files); 0
test262 regressions (parse 17,503 / exec 14,813, 0 crashes).

**Phase 04 outcome:** the stdlib core is broad and correct. Added 12 `builtins-*.lisp` modules
(~2,600 LOC): **Ryū** Number→String (interval method, exact-rational backend; cross-checked 0
mismatches vs the retained oracle over 40k+ random doubles + known-answer vectors), **JSON**
(own recursive-descent parser + SerializeJSONProperty printer), **Math** (full, trap-masked),
**Number** formatting (toFixed/toExponential/toPrecision/toString(radix)), **String** (~40 methods,
code-unit exact), **Array** (ES2017 prototype + statics, stable merge sort), **Object** extras +
**Reflect**, **Symbol** registry, **Map/Set/WeakMap/WeakSet** (SameValueZero + insertion order; SBCL
weak tables), **iterator protocol** (%IteratorPrototype% + concrete iterators), **Date** (UTC core,
pure gregorian math, ISO parse/format), **URI** functions, and a real **Function** constructor.
Measured **built-ins slice 83.5%** (8,912/10,673, gate ≥65% MET), **overall curated 81.0%**
(14,806/18,288 non-skip, gate ≥55% MET), **Ryū vectors pass**, **0 crashes** across the full
34,779-file exec phase. 583 CL unit tests pass; purity clean (101 files). exec-passlist regenerated
(+9,334 entries, monotonic). Key fix theme: NaN/Infinity float-trap discipline in builtins (new `%int`
helper; NaN-safe `js-zero-p`/`js-same-value(-zero)`; see DECISIONS 2026-07-10).

**Next action:** Begin Phase 05 (Event loop / async substrate, deps 01 ✓ — independent of the engine
track). NOTE Phase 04 deferred: RegExp-taking String overloads (match/replace/split with regexp) →
Phase 10; full UCD casing/normalize → later; TZif local time → Phase 26; Proxy → later; typed arrays
→ later. Phase 03 deferrals still open (`with`, tagged templates, full class super, mapped sloppy
`arguments`, global-scope TDZ); generators/async are Phase 06.

**Independent phases available if the main track blocks (◇):** 19 (crypto foundation, deps 00),
21-semver (deps 00), 16 (sockets, deps 05 ✓ — but respect the serve-event thread-registration rule).

---

## Blocked
_(nothing blocked)_

---

## Phase gate evidence log

- **Phase 00 — PASSED + committed (2026-07-10).**
  - `make build` → `build/clun` (save-lisp-and-die); `./build/clun --version` → `clun 0.0.1-dev`, exit 0. ✔
  - `make test` → parachute: 5 passed / 0 failed, exit 0. ✔
  - `make purity` → clean, 62 files scanned (load-plan ∪ src/tests/vendor), 0 violations; verified
    fails on a token planted in src/ AND in tests/. ✔
  - Fresh-clone build verified (ASDF cache cleared) + documented in README + docs/design/phase-00.md. ✔
  - Review panel (12 agents, 5 dimensions): 7 raw findings, 3 confirmed, all fixed — purity scanner
    now unions the ASDF load plan (closed a tests/ scan gap); STATE/DECISIONS/design wording corrected.

- **Phase 01 — PASSED + committed (2026-07-10).**
  - `make build` clean (zero warnings; fixed a constant-fold NaN trap); `make test` 261 passed / 0
    failed; `make purity` clean (73 files). Value-rep decided by micro-bench (native typecase 4.3x
    faster than tagged struct — DECISIONS.md).
  - Substrate: values/singletons, condition bridge, WTF-8 UTF-8⇄code-unit (WHATWG maximal-subpart),
    NaN/Inf/−0 + ToInt32/Uint32, Number↔String (shortest-round-trip), ToPrimitive/Boolean/Number/String.
  - Review panel (15 agents, 5 dims, verified by running code): 5 confirmed / 5 refuted. Fixed: major
    ASCII-digit-only StringToNumber (Unicode Nd digits were wrongly accepted); huge-exponent clamp
    (`"1e1000000"` 470ms→0ms); +completeness tests (huge strings, ToInt32 modulo, WTF-8 multibyte);
    trimmed an over-long comment.

- **Phase 02 — PASSED (#1/#3) + #2 operationalized + committed (2026-07-10).**
  - `make build` warning-free; `make test` 482 assertions; `make purity` clean; `make conformance`
    0 crashes / 23,713, 17,503-entry pass-list, no regressions.
  - Tokenizer + full ES2017 parser (0 crashes) + scope analyzer + AST printer + test262 runner.
  - Two review panels' findings all fixed (Phase-02 panel: 19 agents-confirmed, 0 refuted — for-in/of
    destructuring false-positive fix unblocked ~1,200 tests). Negative-parse 74.4% rejected, gate #2
    regression-proof via the growing pass-list; regexp-pattern negatives deferred to Phase 10.

- **Phase 03 — EXECUTION GATE MET + committed (2026-07-10).**
  - The engine executes real JavaScript. `make build` clean; `make test` 570 assertions; `make purity`
    clean (90 files); `make conformance-exec` **72.8% pass (5,460/7,500 curated, both modes)**, 0 crashes.
  - Object kernel + environments + operators + callables + realm/~60 builtins + closure emitter + eval.
  - Runner extended to an execution phase with a checked-in monotonic exec-passlist.

- **Phase 04 — STDLIB GATE MET + committed (2026-07-11).**
  - `make build` clean; `make test` **583 assertions** (incl. Ryū known-answer + 40k oracle
    cross-check); `make purity` clean (101 files); `make conformance-exec` over **34,779 files**:
    14,806 pass, **0 crashes**, exec-passlist +9,334 (monotonic).
  - **Gate:** built-ins slice **83.5%** (8,912/10,673 executed) ≥65% ✔; overall curated **81.0%**
    (14,806/18,288 non-skip) ≥55% ✔; **Ryū vectors pass** (0 mismatches vs oracle) ✔.
  - 12 `builtins-*.lisp` modules: Ryū, JSON, Math, Number-fmt, String, Array, Object+Reflect, Symbol,
    Map/Set/Weak*, iterator protocol, Date (UTC), URI; Function constructor. Runner extended to include
    the built-ins slice + periodic GC (21k execs/image).
  - Crash sweep: 278 → 0 (NaN/Infinity float-trap discipline — `%int`, NaN-safe zero/SameValue).
  - Adversarial review panel (6 dims × find→verify-by-running-code): **20 confirmed / 0 refuted**, all
    fixed then re-verified: JSON.parse EOF crashes (bounds-checked `jr-next`), pad/repeat heap-exhaustion
    → RangeError, toExponential/toPrecision ties-away rounding, JSON empty-replacer-array, Set −0
    canonicalization, Date.parse calendar/hour-24 validation, String.lastIndexOf position arg, Math.clz32
    (integer-length), Math.log10 exact powers of ten. Post-fix: +7 passes, 0 regressions, 0 crashes.

- **Phase 05 — EVENT-LOOP GATE MET + committed (2026-07-11).**
  - `make build` clean; `make test` **674 assertions** (17 loop tests); `make purity` clean (110
    files); `make conformance` 17,503 / 0 crashes; `make conformance-exec` 14,813 / 0 crashes — no
    regressions (engine untouched).
  - `src/loop/` (loop-core/timers/reactor/signals/workers/event-loop) + `src/sys/sbcl-compat.lisp`
    (self-pipe + poll probe). serve-event poll reactor, self-pipe wakeup, binary-heap timers, handle
    refcounting, enqueue-only signals, sb-thread worker pool, nextTick/microtask/task drain.
  - **Gate:** timer ordering ✓; cross-thread wake <5 ms ✓; alive-iff-refs ✓; SIGINT→event ✓;
    microtask-drain ordering ✓.
  - Verified gotcha (design doc + DECISIONS): SBCL dispatches an fd handler only on the thread that
    registered it → `run-loop` registers the self-pipe handler on the loop thread (Phase 16 must too).
  - Adversarial review panel (4 dims × verify-by-running-Lisp): **6 confirmed / 0 refuted**, all fixed
    + locked as regressions: (1) `loop-alive-p` ignored the mailbox → external/worker/callback
    loop-posts dropped at shutdown; (2) liveness ignored pending signal deltas → signal at shutdown
    dropped; (3) `destroy-event-loop` left OS signal handlers installed → stale handler wrote to the
    closed/recycled self-pipe fd (§6 use-after-close); (4) per-loop install flag guarded a
    process-global `enable-interrupt` → second live loop clobbered the first (now a loud error +
    ownership released on destroy). 680 unit tests after fixes; 0 regressions.

- **Phase 06 — ASYNC GATE MET + committed (2026-07-11).**
  - `make build` clean; `make test` **739 assertions** (generators/promises/async/for-await + ordering
    + subclass-builtins + panel regressions); `make purity` clean (115 files); `make conformance-exec`
    over 34,779 files: **pass 19,540** (+4,209 over Phase 05), **0 crashes**, exec-passlist regenerated
    (19,540, monotonic), **0 regressions**.
  - **Gate (each dir ≥75%):** Promise **76.1%** (542/712), async-function **78.1%**, for-await
    **78.7%**, generators **~78.5%**; ordering corpus (nextTick<microtask<timer) ✔.
  - Thread-per-coroutine engine (`src/engine/async/`): generators, Promises (capability/species),
    async/await, for-await, async generators. `run-source`/`eval-source` host + drive a per-realm loop;
    teardown terminates runaway/abandoned coroutines (0 thread leak). Vendored built-ins/Promise +
    Generator/Async prototypes (1,024 files) from the pinned d1d583d clone.
  - Fixes that unblocked the gate: runner auto-includes doneprintHandle.js for `async` tests; Promise
    combinators reject-on-abrupt (IfAbruptRejectPromise) + per-element AlreadyCalled guard.
  - DEFERRED: ESM linking + TLA → Phase 07 (owns module resolution); `class extends` super (Phase 03
    deferral) caps Promise-subclass tests.
  - Adversarial review panel (4 dims × verify-by-running-JS): **11 confirmed / 0 refuted**; 7 fixed +
    locked as regressions (Object.prototype.toString reads @@toStringTag; Promise.finally awaits
    onFinally's result + propagates its rejection; AggregateError global; for-await Awaits sync values
    (async-from-sync); `class extends Promise` derived default ctor binds `this` to super()'s result —
    real subclass Promises; setTimeout returns an opaque coercible id + clamps huge/∞ delays). 4
    DEFERRED (async-iteration edge cases, not a gate dir): async-generator request queue for concurrent
    next(); AsyncGenerator.return awaiting its arg; async `yield*`; + the `class extends` EXPLICIT-super
    ceiling (Phase 03 deferral). The `class extends Promise` fix generalized to **new-target-honoring in
    all builtin constructors** (Array/Boolean/Number/String/Error/Object/Function/bound-fn — subclassing
    a builtin now preserves both identities), and finally was made spec-faithful (single-arg internal
    `.then`, length-1 wrappers). Post-fix: 739 unit tests, **0 regressions, 0 crashes**.

- **Phase 07 — MODULE GATE MET + committed (2026-07-11).**
  - `make build` clean; `make test` **887 assertions** (sys/paths/fs/json + resolver corpus + module
    system + review regressions); `make purity` clean (**128 files**); `make conformance` parse
    **17,512** (+9: import.meta + anon-default-fn, pass-list regenerated, monotonic);
    `make conformance-exec` **pass 19,540 held, 0 crashes, 0 regressions**.
  - **Gate:** resolution corpus green (101 assertions / 40+ scenarios, engine-free); the fixture app
    (ESM entry → CJS dep + scoped ESM pkg via `exports` conditions + JSON module + `import.meta.main`)
    runs and produces `hi world|9|42|true`.
  - Three engine-free layers: `src/sys/` (`clun.sys`, ~430 LOC: path discipline, sb-posix/truename fs,
    hand-rolled JSON) → `src/resolver/` (`clun.resolver`, ~430 LOC: full Node CJS+ESM algorithm) →
    `src/engine/modules/` (~620 LOC: records, frame-based ESM compile, CJS require, loader). Emitter/
    parser/analyzer/eval extended for module scopes, import deref+const, `import.meta`, four
    import/export `compile-node` clauses, ESM early errors.
  - Adversarial review panel (6 dims × find→**verify-by-running-code**, 24 agents): **17 confirmed /
    1 self-refuted**, all 17 fixed + locked as regressions — resolver exports pattern precedence
    (Node PATTERN_KEY_COMPARE), bare-in-exports rejection, `..`-escape block; JSON overflow→Infinity,
    strict grammar, dup-key-last; CJS `this`=`module.exports` + throw→evict; JSON `{default as X}` +
    named-import error; ESM early errors (dup export/default, undeclared export, dup import) throw
    clean SyntaxErrors; named + anonymous `export default` function/class.
  - DEFERRED 🟡 (not gate-blocking): ESM cyclic live-binding-through-reassignment (acyclic is live);
    top-level await; namespace-object snapshot; test262 `module`-flagged exec tests stay skipped
    (follow-up: route through `run-module-file`).

- **Phase 08 — CLI GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **976 parachute + 13 tests/js** (0 failed); `make purity` clean
    (**138 files**); `make conformance` parse **17,512** (0 crashes, held); `make conformance-exec`
    **19,540** (0 crashes, 0 regressions).
  - **Gate:** run/eval fixture matrix (console/format/streams/process/exit/onexit/eval/pstring/errors/
    onexit-throw/env, 13 cases) green; console subset matches Bun's `console-log.expected.txt`; `-p`
    awaits a settled promise; uncaught JS → stack on stderr + exit 1; exit codes 0/1/2.
  - Runtime layer `src/runtime/` (install/console/process/clun-global) + shared inspector
    `src/engine/inspect.lisp` (in clun.engine) + CLI `src/cli/` (args/dotenv) + `src/main.lisp` rewrite
    + `src/sys/platform.lisp` (tty/env/hrtime/mem via sb-unix/sb-ext/sb-kernel). `make-realm` stays
    runtime-free; `clun.runtime:install-runtime` augments it (conformance uses the bare realm).
  - Adversarial review panel (6 dims × find→**verify-by-running-the-binary**, 23 agents): **17/17
    confirmed + fixed** — HIGH: float-trap crashes leaking raw Lisp backtraces (`%d`/`process.exit`/
    `hrtime` on NaN/Inf → trap-safe `safe-integer`), stack overflow → `RangeError` (storage-condition),
    getter/setter labels, `on('exit')` on uncaught throw, `.env` bare-`#`; MED/LOW: class-instance
    names, `-p` string raw, chdir errors→catchable, execPath absolutised, `$VAR` expansion.
  - Verified SBCL facts: no `sb-posix:isatty` (use `sb-unix:unix-isatty`); hrtime via
    `sb-ext:get-time-of-day` (µs); Node version pinned **22.11.0**.
  - DEFERRED 🟡: `[class X]` display, SetIterator/MapIterator, exact 80-col array wrapping,
    `hrtime.bigint` real BigInt (Phase 11), `.ts` execution (Phase 09).

- **Phase 09 — TS-STRIP GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **1004 parachute + 42 tests/ts (strip+errors) + 49 tests/js**
    (0 failed); `make purity` clean (**143 files**); `make conformance` parse **17,512**;
    `make conformance-exec` **19,540** (0 crashes, 0 regressions).
  - **Gate:** 78-pair corpus (tests/ts/strip byte-exact + same-length; tests/ts/errors message +
    line:col; tests/ts/runtime strip→run→known-output incl a line-preservation case) all green; each
    catalog error fires with its documented message; strip→run line:col identical to source (whitespace
    render preserves newlines + length).
  - `clun.transpiler` (`src/transpiler/` conditions/ts-type/ts-scan/strip): a recursive-descent strip
    scanner over the shared engine token stream — drives regex/template context via reread-*, balanced
    `skip-type` (`>>` split, arrow-return mode), records erase-spans, space-fills (newlines kept).
    Engine `*ts-strip-hook*` + `read-source-for`; resolver `.mts`→ESM/`.cts`→CJS; CLI rejects `.tsx`.
  - Adversarial review panel (6 dims × find→**verify-by-running-the-stripper**, 24 agents): **18/18
    confirmed + fixed** — contextual keywords as value idents, arrow return types ending in `)`, arrow
    generics w/ default, tag templates + `as`-in-`${}`, `x!!`/`x! as`, superclass type args,
    angle-cast→error, declare-namespace-ambient.
  - DEFERRED 🟡 (documented corners): `a<b>(c)` comparison-call & bare function-type arrow return
    `(): () => X =>` (rare; recommend parens); enum errors (Bun transpiles); class FIELD syntax + `class
    extends` method resolution + `??`/`?.` are pre-existing ENGINE limits (not strip bugs).

- **Phase 10 — REGEXP GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **1054 parachute + 42 tests/ts + 49 tests/js** (0 failed);
    `make purity` clean (**148 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 37,611 files: **pass 20,631**, **0 crashes**, exec-passlist regenerated (monotonic; 3 documented
    false-passes removed), **0 regressions**.
  - **Gate:** built-ins/RegExp/** **76.1%** (696/915 run) ≥60% ✔; String regex methods
    (match/matchAll/replace/replaceAll/search/split) **96.9%** (283/292) ≥75% ✔; deliberate gaps
    enumerated in tests/conformance/regexp-gaps.txt.
  - `src/engine/regex/` (ast/parser/translate/regexp-object, ~1.1k LOC): own JS-regex recursive-descent
    parser → AST → CL-PPCRE **parse trees** → create-scanner. JS-vs-PPCRE semantics undone in the tree
    (`.`/\s/\w/\b/^/$/octal/empty-class); exec via `:start li :real-start-pos 0`; String delegation +
    Symbol statics; loud SyntaxError for gaps. + `scripts/gen-unicode-tables.lisp` (UCD generator scaffold)
    + `tests/lisp/engine/regexp-tests.lisp` (50 assertions). Vendored built-ins/RegExp/** (1,879 files).
  - Adversarial review panel (5 dims × find→**verify-by-running-the-binary**, 28 agents): **21 confirmed /
    23 candidates**, ALL fixed + re-verified — every finding a SILENT wrong-answer (the design's worst
    class, which the vendored slice passed while mismatching): legacy octal escapes, empty `[]`/`[^]`, /m
    at all JS LineTerminators, ASCII \b/\B, non-ASCII \S/\W/\D in a class, RegExp() flag validation (incl.
    /v), scan-start-relative ^/\b under g/y, fn-replacer named-groups arg, .source EscapeRegExpPattern,
    group-name IdentifierName + duplicate rejection, \c fallback, the Symbol.{match,…,species} statics +
    camelCase descriptions, RegExp(re) IsRegExp short-circuit; exposing the statics unmasked + fixed a
    latent primitive-search-value @@-getter bug. Net: RegExp 64.9%→**76.1%** (+102), String methods
    91.1%→**96.9%**; 0 regressions/crashes.
  - DEFERRED 🟡 (regexp-gaps.txt): fully-generic @@ RegExpExec protocol (user-overridable exec) + @@species
    (B1 — 3 former false-passes removed from the exec pass-list, DECISIONS 2026-07-12), RegExp.escape,
    variable-length lookbehind (loud), Annex-B-under-/u early errors, astral /u (BMP-only), \p{}
    property escapes (loud; UCD gen scaffolded), /v flag, inline modifiers, /d match-indices, 2
    CL-PPCRE-vs-ECMAScript NFA-backtracking edge cases.

- **Phase 11 — BINARY+BIGINT GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **1110 parachute + 42 tests/ts + 49 tests/js** (0 failed);
    `make purity` clean (**151 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 40,654 files: **pass 22,638**, **0 crashes**, exec-passlist regenerated (monotonic), **0
    regressions**.
  - **Gate:** BigInt **96.1%** (73/76), TypedArray **67.8%** (835/1231), DataView **70.5%** (346/491)
    each ≥65% ✔; overall curated **80.4%** (22,638/28,163) ≥80% ✔; gaps in
    tests/conformance/bigint-binary-gaps.txt.
  - BigInt = plain CL integer (`js-bigint-p`=`integerp`), threaded through values/operators/coercions;
    `builtins-bigint.lisp` (ctor/statics/prototype) + `builtins-binary.lisp` (ArrayBuffer, 11 TypedArray
    exotics over the `jm-*` generics, DataView, TextEncoder/Decoder). Byte assembly pure SBCL (ldb/dpb +
    sb-kernel float bits). + `tests/lisp/engine/binary-tests.lisp` (56 assertions). Vendored built-ins/
    {BigInt,TypedArray,TypedArrayConstructors,ArrayBuffer,DataView} (3,043 files).
  - Adversarial review panel (5 dims × find→**verify-by-running-the-binary**, 19 agents): **14/14
    confirmed + fixed** — crash-safety (signaling-NaN Float32 read, ArrayBuffer/TypedArray huge-alloc
    heap-exhaustion, DataView/fill/set detaching-valueOf, BigInt `**`/`<<` DoS — all now catchable
    RangeError/TypeError, no raw Lisp backtrace) + silent wrong-answers (JSON.stringify BigInt→TypeError,
    descending→ascending TypedArray keys, unstable+NaN-misplacing sort, overlapping `.set` snapshot,
    lone-surrogate→U+FFFD + BOM strip). Also fixed 7 order-of-eval regressions from the `numeric-binary`
    refactor (full ToNumeric per-operand for `-`/`*`/`/`/`%`/`**`) + a `js-unary-plus` double-`valueOf`.
  - DEFERRED 🟡 (bigint-binary-gaps.txt): resizable/growable buffers, SAB/Atomics, @@species subclass
    returns, ES2023 change-by-copy TA methods, TextDecoder streaming/fatal/non-UTF-8 labels, encodeInto,
    the 2^27-bit BigInt DoS cap, Number(bigint)=deliberate TypeError.

- **Phase 12 — NODE-COMPAT WAVE 1 GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **parachute + 42 tests/ts + 53 tests/js** (0 failed); `make purity`
    clean (**159 files**); `make conformance` parse **17,512**; `make conformance-exec` **22,638** (0 crashes,
    0 regressions — the builtin-module hook is NIL/inert in bare test262 realms; engine behaviorally untouched).
  - **Gate:** per-module conformance fixtures tests/js/node/{modules,events,assertions,globals} green (exact
    stdout); node builtins reachable via require + import (CJS + ESM).
  - Substrate: engine `*builtin-module-builder*` hook + `try-builtin-module` (require.lisp/module-loader.lisp)
    + runtime `src/runtime/node/registry.lisp` (install-node-builtins). Modules `src/runtime/node/`
    (path/os/querystring/util/events/assert, self-registering); `src/runtime/globals.lisp` (structuredClone,
    crypto); `clun-global.lisp` extras; new `clun.sys` /proc + os-random-bytes primitives; one shared
    `eng:js-deep-equal` (inspect.lisp). 5 modules authored by a parallel write-only subagent fan-out.
  - Adversarial review panel (5 dims × find→**verify-by-running-the-binary**, 31 agents): **25/26 confirmed +
    fixed** — querystring null-proto + prototype-collision; util BigInt/Symbol/NaN format specifiers + inspect
    depth:Infinity/null host-crash + %j circular + isDate + deprecate-wrapper; events once-removal-by-identity
    + emit('error') no-arg + prependListener newListener + listenerCount(name,fn); assert loose-equal +
    throws-class-validation + AssertionError export; structuredClone Date + DataCloneError; path extname
    leading-dots + format dir===root; os.userInfo $USER; and a class of outside-the-float-mask NaN checks
    (`eng:js-nan-p`, never `=`/`/=`, which trap) across util/querystring/Clun.sleep.
  - DEFERRED 🟡 (matrix): path.win32 throws; util.format %d truncates (Bun-faithful console, not Node's full
    Number); pathToFileURL → string (URL object is Phase 18); util.promisify.custom, once-fire/removeAll
    `removeListener` emissions, full `instanceof assert.AssertionError`; full ironclad + KATs → Phase 19.

- **Phase 13 — FILES GATE MET + committed (2026-07-13).**
  - `make build` clean; `make test` = **1110 parachute + 42 tests/ts + 58 tests/js** (0 failed);
    `make purity` clean (**161 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 40,654 files: **pass 22,638**, **0 crashes**, **0 regressions** (node builtins inert in bare realms).
  - **Gate:** tests/js/node fixtures green — buffer (KAT: alloc/from/encodings/concat/compare/indexOf/
    numeric round-trips/slice-shares-memory/fill/toJSON), bufedge (OOB→RangeError, copy memmove overlap,
    concat zero-pad + truncate, write 2-arg + 3-arg encoding), fsops (bracket paths, deep recursive mkdir,
    symlink chain, ENOENT/EISDIR codes, stat, readdir, append, rename, rm -rf), fsedge (message shape +
    negative errno, mkdir-recursive topmost-return + already-exists/non-recursive undefined, accessSync
    mode), clunfile (lazy text/bytes/exists + size getter + write).
  - Three engine-free layers (Phase-07 discipline): `src/sys/fs.lisp` (+`fs-error` condition, errno table,
    `with-fs` mapping syscall-error + file-error, mutating ops, octet/string I/O, stat→fstat) →
    `src/runtime/node/buffer.lisp` (Buffer = Uint8Array subclass over Phase-11 typed-arrays; encodings;
    numeric read/write with one `%num-bounds` guard) → `src/runtime/node/fs.lisp` (`%op-*` × `%with-fs`/
    `%callbackify`/`%promisify`; Stats/Dirent/constants) + `Clun.file`/`Clun.write` (real Promises).
  - Adversarial review panel (find→**verify-by-running-the-binary**): crash-safety dominated (raw Lisp
    backtraces violating §6) — Buffer.from(ArrayBuffer) view + OOB crash; OOB numeric read/write across ALL
    accessors (int/float/BigInt/variable-width) → catchable RangeError (adversarial probe: neg/NaN/Inf
    offsets, over-read past backing, byteLength overrun — 0 raw backtraces); copy backward-overlap
    corruption (memmove); Clun.file.text() missing-file crash (read-file-string → fs-error); Clun.write(
    ArrayBuffer). Correctness: concat zero-pad, write(str,enc) 2-arg form, mkdirSync-recursive topmost
    return, accessSync mode arg, "CODE: description, syscall 'path'" message + negative libuv errno.
  - DEFERRED 🟡 (tests/conformance/fs-buffer-gaps.txt): Buffer integer-write value masking (not
    ERR_OUT_OF_RANGE), negative/NaN-offset clamps to 0, OOB numeric bound is backing-vs-view; no file
    descriptors / streams / watchers / Dir handles / recursive cp / chown / utimes / link; stat times
    second-granular; async is Promise-over-sync (real worker-pool offload deferred).

- **Phase 14 — ASYNC GATE MET + committed (2026-07-13).**
  - `make build` clean; `make test` = **1110 parachute + 42 tests/ts + 64 tests/js** (0 failed);
    `make purity` clean (**163 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 40,654 files: **pass 22,643** (+5 vs Phase 13; the for-await IteratorClose fix — pass-list
    regenerated monotonic), **0 crashes**, **0 regressions** (the coroutine serious-condition-marshalling
    change leaves the Promise/async/generator dirs unaffected).
  - **Gate:** tests/js/async fixtures green — `ordering` (sync→nextTick→microtask(Promise then queueMicrotask)
    →timer→immediate, deterministic), `timers` (arg forwarding, interval+clear, ref/unref/hasRef, clearImmediate,
    node:timers identity), `tpromises` (timers/promises setTimeout/setImmediate + setInterval async iterator via
    for-await+break), `unref` (unref'd timer → process exits promptly), `abort` (controller/signal/timeout/any +
    timers/promises signal reject), `evonce` (events.once resolve/reject-on-error/{signal} + captureRejections).
  - New: enriched Timeout/Immediate objects (`ref/unref/hasRef/refresh/close/@@toPrimitive`; `lp:timer-ref/unref/
    refd-p`), setImmediate/clearImmediate, `src/runtime/abort.lisp` (AbortController/AbortSignal),
    `src/runtime/node/timers.lisp` (node:timers + node:timers/promises), events.once reject-on-error+{signal}+
    captureRejections, assert.rejects/doesNotReject. Engine: for-await IteratorClose on abrupt completion.
  - Adversarial review panel (6 dims × find→**verify-by-running-the-binary**, 13 agents): **7 findings / 2
    confirmed + fixed** — HIGH (§6): `process.exit()` inside an async coroutine leaked a raw `PROCESS-EXIT`
    backtrace → the coroutine thread now marshals any non-JS serious-condition back to the driver, which
    re-raises it on the JS thread (clean exit with the code; works before and after an `await`); LOW:
    `new AbortSignal()` now throws "Illegal constructor" on the construct path. The 5 refuted findings were
    verified against Node semantics on the binary (documented deliberate divergences / correct behavior).
  - DEFERRED 🟡: top-level `setTimeout(0)` deterministically before `setImmediate` (Node unspecified);
    setImmediate ref/unref liveness-inert; AbortSignal is a partial EventTarget (abort event only) with an
    AbortError-named Error (DOMException post-v1); `AbortSignal.any` tolerates a non-iterable (never-aborting
    signal); `EventEmitter` errorMonitor + `events.on` async-iterator not implemented (no fresh-Symbol mint).

- **Phase 15 — TEST-RUNNER GATE MET + committed (2026-07-13).**
  - `make build` clean; `make test` = **1110 parachute + 42 tests/ts + 74 tests/js** (0 failed);
    `make purity` clean (**170 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 40,654 files: **pass 22,643**, **0 crashes**, **0 regressions** (the runner's engine seams —
    run-callback-to-settlement + run-module-file :teardown — are test-runner-only, inert for conformance).
  - **Gate:** the meta-test matrix + hook-order byte-exact run via the tests/js fixture harness (deterministic
    because the reporter omits timing): tests/js/testrunner/{hookorder (byte-exact Bun hook trace), matchers
    (all ~22 green), failing (→exit 1), skiptodo (skip/todo counts + describe.skip subtree), only (per-file
    isolation), bail (--bail stops + exit 1), filter (-t subset), filterzero (-t 0-match → exit 1), zerotests
    (→ exit 1), async (resolves/rejects + timeout)} — all green.
  - `src/test-runner/` (diff/registry/expect/scheduler/reporter/discovery/runner) — framework in CL against
    the engine object API (no JS in the impl). Engine seams added: `eng:run-module-file :teardown nil`,
    `eng:teardown-realm`, `eng:run-callback-to-settlement` (async test driving over the loop with a ref'd
    timeout timer; catches js-condition + any raw CL error → clean test failure). `main.lisp` routes `test`.
  - Adversarial review panel (5 dims × find→**verify-by-running-the-binary**, 15 agents): **10 findings /
    8 confirmed + fixed** — HIGH §6 crash-safety + wrong-behavior: `.resolves`/`.rejects` on a primitive
    (jm-get crash → clean "not a Promise" failure + a systemic CL-error→failure net in the settlement
    driver); `toBeCloseTo(Infinity)` FP-invalid trap (guarded; equal infinities pass); afterAll errors
    silently swallowed (now reported + counted, symmetric with beforeAll/afterEach); `.only` buried in a
    `describe.skip` wrongly activating only-mode (has-only recomputed ignoring skip subtrees).
  - DEFERRED 🟡: per-test `[N.NNms]` timing omitted (deterministic output — the one reporter divergence);
    no snapshots / mocks / spies (v1 non-goals); `.each` name interpolation a documented subset; concurrent
    tests run sequentially; runaway SYNCHRONOUS (non-awaiting) tests are not preemptible.

- **Phase 16 — SOCKETS GATE MET + committed (2026-07-13).**
  - `make build` clean; `make test` = **1122 parachute + 42 tests/ts + 74 tests/js** (0 failed);
    `make purity` clean (**172 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 40,654 files: **pass 22,643**, **0 crashes**, **0 regressions** (the socket layer is engine-inert;
    `sb-bsd-sockets` added to :depends-on).
  - **Gate:** tests/lisp/net/sockets-tests.lisp (both echo server + clients on ONE reactor loop) —
    port-0 real-port, echo roundtrip, **2,000 sequential**, **500 concurrent** (backlog 1024), **fd-no-leak**
    (fd count returns to baseline over 400 open/close cycles), **connect-refused → ECONNREFUSED**, and
    **throughput 64 MB loopback ≥100 MB/s** (measured ~131–137) — all green.
  - `clun.net` / `src/net/sockets.lisp`: a callback `tcp` handle on the reactor (`lp:reactor-add`),
    non-blocking connect/accept/read/write, a `(octets . offset)` write queue with zero-copy displaced-view
    partial sends + edge-triggered on-drain, ref'd loop handle for liveness, idempotent close with full
    handler removal, `socket-error-code` mapping. 256 KB read buffer + 4 MB SO_{SND,RCV}BUF.
  - Adversarial review panel (5 dims × find→**verify-by-running-CL**, 11 agents): **6 findings / 4 confirmed
    + fixed** — a zero-byte `tcp-write` `CASE-FAILURE` crash (skip empty + broaden the send handler → §6),
    and `on-drain` firing spuriously/repeatedly (now fires once on a genuine backpressure→empty edge, per
    Node `drain`). Stress-verified: 0 corruption / 0 connection errors across 12,000 connects under 4-CPU-hog
    contention. (A single earlier echo failure was induced by running the suite alongside a 6 GB conformance
    process — a testing artifact, not a defect; isolated runs are stable.)
  - DEFERRED 🟡: hostnames must be IP literals (DNS → Phase 18); IPv6 structurally present but lightly
    tested; no UDP; unclassified socket errors report a generic code; the single-threaded-both-ends
    throughput figure is a test artifact (a real server drives one direction per thread).

- **Phase 20 — HTTPS GATE MET + committed (2026-07-13).**
  - **Gate:** hermetic HTTPS round-trip vs an in-process pure-tls server (net-level TLS transport,
    deterministic); a verify-function matrix — expired / wrong-host / self-signed / bad-chain each fail
    closed with a distinct error; a deterministic end-to-end fetch FAIL-CLOSED test; live smoke (logged):
    `fetch("https://example.com/")` accepts under the system store, rejects under the test CA — verification
    both ways against a real server (registry.npmjs.org substituted: pure-tls `protocol_version` interop
    gap). `make build`/`test`(**1286 parachute + 42 TS + 74 JS**)/`test-tls`(10 suites / 342)/`test-crypto`
    (24)/`purity`(**669 files**) green; `make conformance-exec` **22,643, 0 crashes, 0 regressions**.
  - `pure-tls` added to the `clun` binary. HTTPS runs BLOCKING on the worker pool: `src/net/tls-client.lisp`
    `https-request` (connect → pure-tls handshake + verify → serialize → read-EOF → response parse → gunzip);
    `web-fetch` `%do-fetch` dispatches by scheme; abort/timeout close the worker socket. `workers.lisp` lazy
    worker spawn (realm loop is :workers 0). Trust: `$SSL_CERT_FILE`/`$SSL_CERT_DIR` → system bundle.
  - **SECURITY FIX (critical):** pure-tls's client verify SKIPS when no peer certificate is recorded (raced
    to nil on the pure-tls↔pure-tls path) → a cert-auth BYPASS (a leaf not anchored in the trust store was
    accepted). Patched `vendor/pure-tls/src/streams.lisp`: `+verify-required+` + null peer cert now FAILS
    CLOSED. Verified the bypass rejects; real HTTPS unaffected; pure-tls's 10 suites still pass. A README
    posture line claiming "always fails closed" (written while the bypass was known) was corrected — it is
    now honest AND true.
  - Adversarial review: the ultracode panel hung on a live fetch, so fail-closed (badssl.com expired/wrong-
    host/self-signed/untrusted-root all reject; example.com+test-ca rejects) + §6 crash-safety (empty-host /
    dead-port / plaintext-server → clean JS errors, no backtrace) + abort/timeout (AbortSignal.timeout
    unblocks a stuck handshake) were verified BY HAND.
  - Test CA: `scripts/gen-test-certs.sh` → checked-in PEMs (openssl is a build-time fixture tool, not a
    runtime dep). DEFERRED: registry.npmjs.org handshake (pure-tls protocol_version — Phase 21 blocker for
    the live npm smoke); blocking DNS; one worker per in-flight request; reactor-native TLS post-v1.

- **Phase 19 — CRYPTO FOUNDATION GATE MET + committed (2026-07-13).**
  - **Gate:** all KATs pass (`make test-crypto` — 24 assertions, 6 groups, exit 0); pure-tls suites pass
    (`make test-tls` — 10 suites / 342 checks, exit 0); `make purity` clean over **667 files** (was 199).
    Plus: `make build` clean (binary unchanged — crypto is test-only this phase); `make test` = **1271
    parachute + 42 tests/ts + 74 tests/js** (0 failed); `make conformance-exec` over 40,654 files: **pass
    22,643, 0 crashes, 0 regressions** (the crypto/TLS stack is not in the `clun` load plan — fully inert).
  - Vendored ironclad + pure-tls + an ~18-lib dep closure (pinned SHAs in DECISIONS 2026-07-13), auto-
    registered via the vendor/*/ scan. 4 purity patches (precise-time → sb-unix:clock-gettime; trivial-
    features endianness → SBCL feature; usocket wait-for-input → sb-sys:wait-until-fd-usable; pure-tls win/mac
    native-cert deps/files stripped) + deleted dead non-SBCL foreign backends. Each patch marked in-file
    `;; clun purity patch (Phase 19):`. KATs: `tests/lisp/crypto/kat-tests.lisp` (own `make test-crypto`
    image); pure-tls suites: `scripts/run-pure-tls-suites.lisp` (`make test-tls`).
  - KAT groups (published vectors, cited): SHA-2 FIPS 180-4, HMAC-SHA256 RFC 4231, HKDF-SHA256 RFC 5869,
    AES-256-GCM NIST, X25519 RFC 7748, ChaCha20-Poly1305 RFC 8439 (composed from ChaCha20+Poly1305; this
    ironclad's AEAD set is eax/etm/gcm) + tamper-rejection. pure-tls suites run: crypto / record / handshake /
    certificate / trust-store / boringssl / x509test / ml-dsa / cancel / security-regression. Excluded (need
    drakma / external openssl|bssl / live network): network / openssl / resumption-interop / cancel-integration.
  - Adversarial review panel (4 dims × find→verify-by-running/reading, 11 agents): **7 findings / 3 confirmed
    (all LOW)** — (1) added trust-store + boringssl suites to the gate (self-contained + passing; 8→10 suites);
    (2) deleted cleanly-removable dead non-SBCL foreign backends (usocket clasp/lispworks, ironclad ecl-opt);
    (3) documented the irreducible reader-conditional non-SBCL FFI baseline (ironclad common/prng, usocket
    ecl/mkcl block) — provably never read/compiled on SBCL; the §1.1 token list reports clean; a scanner
    other-impl-FFI enhancement is a hygiene follow-up.
  - Net-socket-suite flakiness (surfaced under heavy load) FIXED in a follow-up commit: `reactor-poll` prunes
    a handler left on a closed fd instead of letting serve-event's bad-fd error kill the loop (§6; regression
    test `loop/reactor-recovers-from-closed-fd`); the two perf-threshold tests are now best-of-3.

- **Phase 18 — HTTP-CLIENT / FETCH / URL GATE MET + committed (2026-07-13).**
  - `make build` clean; `make test` = **1271 parachute + 42 tests/ts + 74 tests/js** (0 failed);
    `make purity` clean (**199 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 40,654 files: **pass 22,643**, **0 crashes**, **0 regressions** (URL + client are engine-inert;
    the coroutine `lp:*on-foreign-thread*` binding + loop `el-thread` slot are behavior-neutral).
  - **Gate:** fetch vs the Phase-17 `Clun.serve` server, BOTH on one reactor loop (tests/lisp/net/fetch-tests):
    JSON round-trip, text, 4xx/5xx, redirect chains (302→302→200), gzip auto-decode (chipz), already-aborted +
    mid-flight abort → AbortError, `AbortSignal.timeout` → TimeoutError, connection-refused → TypeError, 25
    concurrent `Promise.all` fetches all correct; a WPT-subset URL corpus (tests/lisp/runtime/url-tests):
    components, default-port elision, IPv4/`[IPv6]`, file:, dot-segments, percent-encoding, relative resolution,
    setters, canParse/toJSON, URLSearchParams incl. a linked USP — all green.
  - `src/runtime/web-url.lisp` (URL + URLSearchParams), `src/net/http-client.lisp` (reactor HTTP/1.1 client +
    a response parser added to http-parser.lisp), `src/runtime/web-fetch.lisp` (fetch). Vendored **chipz** @
    `75dfbc6` for gunzip. **Engine/loop change (the risky one):** `lp:run-on-loop` marshals reactor mutations to
    the loop thread (serve-event's fd-handler thread rule) — needed because an `async` body runs on a coroutine
    thread; `el-thread` + `lp:*on-foreign-thread*` distinguish driver-setup (synchronous) from coroutine-setup
    (deferred), so the Phase-16 socket tests are unaffected.
  - Adversarial review panel (6 dims × find→**verify-by-running-the-binary**, 21 agents): **15 findings / 15
    confirmed**, 14 fixed + 1 documented. **2 §6 crashes** — fetch to a port >65535 crashed raw
    (SB-BSD-SOCKETS) → URL parser rejects port >2^16-1 (TypeError); a non-UTF-8 body crashed `text()/json()`
    raw → a lenient U+FFFD decoder. **3 HIGH** — special-scheme `\`→`/` normalization; empty-user+password
    userinfo dropped on serialize (silent password loss); redirect cap resolved the 3xx instead of rejecting.
    MEDIUM (301/302-POST→GET, Host header used resolved IP + dropped port, until-close body bypassed
    *max-body-bytes*, port setter leading-digits) + LOW (IPv6 lower-case, `%2e` dot-segments, GET/HEAD-body →
    TypeError) all fixed; regression-locked in url-tests/fetch-tests. Documented gap: `file:` `C|`→`C:`.
  - DEFERRED 🟡 (tests/conformance/url-fetch-gaps.txt): IDNA/punycode; getter-only protocol/username/password/
    host setters; IPv6 canonical compression; no connection pool (Connection: close per request); blocking DNS
    on the loop thread; cross-origin redirect Authorization/Cookie stripping; streaming bodies; `node:url` (the
    fileURLToPath/pathToFileURL pieces already exist in clun-global.lisp). https → Phase 20.

- **Phase 17 — HTTP-SERVER GATE MET + committed (2026-07-13).**
  - `make build` clean; `make test` = **1172 parachute + 42 tests/ts + 74 tests/js** (0 failed);
    `make purity` clean (**177 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 40,654 files: **pass 22,643**, **0 crashes**, **0 regressions** (incl. the run-loop
    drain-after-reactor + coroutine-prune engine changes — async/generator dirs unaffected).
  - **Gate:** curl interop (GET/JSON/POST-async/404/HEAD/keep-alive, verified against a live
    `clun examples/serve.ts`); malformed-request suite (12 parser tests: bad line/version/CL, obs-fold,
    no-colon, 431/413 limits, incremental, pipelined); **≥30k req/s** loopback with real parsing + a JS
    handler (measured ~33k, tests/lisp/net/http-server-tests); graceful `stop()` drains in-flight;
    **1k-request RSS plateau** (149 MB flat over 5,000 requests after the coroutine-leak fix);
    examples/serve.ts smoke logged.
  - `src/net/http-parser.lisp` (incremental parser) + `src/runtime/web-http.lisp` (Headers/Request/
    Response, shared `%body->octets`) + `src/runtime/clun-serve.lisp` (Clun.serve). Engine: `run-loop`
    drains microtasks after the reactor; `coroutine-resume` prunes completed coroutines. `net:tcp-shutdown`
    (flush-then-close). Header CRLF-stripping (no response splitting).
  - Adversarial review panel (5 dims × find→**verify-by-running**, 16 agents): **11 findings / 2 confirmed
    + fixed** — `new Request({body})` only preserved string bodies (typed-array/ArrayBuffer/number → empty)
    → the shared `%body->octets` used by both the Request ctor and the Response serializer. Proactively
    fixed (own probes): header-injection/response-splitting via CRLF in a header value (now stripped), and
    the async-handler coroutine leak (surfaced by the RSS curve — `realm-coroutines` grew unboundedly).
    Own crash probes: handler throw/undef/number/rejection → 500; a never-resolving handler doesn't wedge
    other connections; server log backtrace-free.
  - DEFERRED 🟡: buffered (non-streaming) request/response bodies; no routes/static/WebSocket/TLS-server
    (TLS → Phase 20); IP-literal hosts (DNS → Phase 18); URL objects → Phase 18; the TS stripper rejects
    object-method-shorthand type annotations (examples/serve.ts uses arrow-fn properties — a Phase-09 gap).

## Phases

Legend: `[x]` done · `[ ]` todo · ⚡ fan-out-friendly · ◇ independent-early.

### Phase 00 — Scaffold, toolchain, purity gate  (deps: none) — **DONE**
- [x] .gitignore / LICENSE (GPL-3.0-or-later) / README stub
- [x] clun.asd + package skeletons per §3.7 (src/packages.lisp)
- [x] Makefile (build / test / purity / clean)
- [x] scripts/purity-scan.lisp (directory scan of src/ + vendor/; §1.1)
- [x] vendor + pin cl-ppcre, parachute (+ dep closure); SHAs in DECISIONS.md
- [x] parachute smoke suite (tests/lisp/smoke.lisp)
- [x] tests/js stdout/exit-code harness **design** (docs/design/phase-00.md); runner deferred to Phase 08
- [x] GitHub Actions CI (ubuntu, pinned SBCL 2.6.4, make build test purity)
- [x] STATE.md seeded with every §5 task list
- [x] DECISIONS.md seeded with §3 pins + vendored SHAs
- [x] Phase 00 review panel (5 dimensions, adversarially verified) + phase-00 commit

### Phase 01 — Engine values & coercions  (deps: 00) ~2k LOC — **DONE**
- [x] docs/design/phase-01.md (data structures, ownership, risks)
- [x] value representation decision (native typecase; micro-bench 4.3x vs tagged struct; DECISIONS.md)
- [x] UTF-16-code-unit strings + UTF-8/WTF-8 boundary converters (WHATWG maximal-subpart decode)
- [x] doubles + trap-mask entry macro (with-js-floats)
- [x] NaN/Inf/−0 helpers
- [x] JS-exception-as-CL-condition bridge (js-condition / js-native-error)
- [x] ToPrimitive/ToNumber/ToString/ToInt32/ToUint32/ToBoolean kernel (+ js-string↔number)
- **Gate PASSED:** 261 parachute assertions over abstract-op edges + UTF-8⇄code-unit round-trips
  incl. lone surrogates/astral pairs; zero regressions; make build/test/purity green.

### Phase 02 — Lexer + parser + scope analysis  (deps: 01) ~7k LOC ⚡(fixtures) — **DONE**
- [x] tokenizer (ASI flags, regex-vs-divide re-scan, template mode stack, escapes, exact offsets, trivia, reentrant)
- [x] full ES2017 parser (classes, destructuring, arrows, generator/async, modules, spread, computed props) — 0 crashes
- [x] scope analyzer — lexical-redeclaration + var/lexical conflict early errors (hoisting/slot-indices/TDZ grow in P03)
- [x] AST printer (ast->sexp)
- [x] vendor test262 @ `d1d583d` + frontmatter parser + runner (`make conformance`) + checked-in pass-list (17,503, only-grows)
- **Gate: #1 no-crashes MET (0/23,713); #3 token-span MET; #2 operationalized via pass-list**
  (74.4% negatives rejected; regression-proof; ~169 regexp-pattern → Phase 10, rest a growing long tail).

### Phase 03 — Core evaluator + object kernel  (deps: 02) ~8k LOC — **DONE (gate MET 72.8%)**
- [x] closure emitter; frames + TDZ sentinel; (with/direct-eval slow frames → loud errors, deferred)
- [x] property tables + full descriptors + defineProperty; prototype chains; per-realm intrinsics indirection
- [x] functions (call/construct, this both modes, arguments — unmapped; sloppy aliasing deferred)
- [x] Array exotic; operators (== table, +, relational, instanceof, in, typeof, delete)
- [x] try/catch/finally, labels (incl. labelled break/continue), switch, for-in order; Error objects with .stack
- **Gate MET:** curated `language/` slice (minus gen/async/modules) 72.8% both modes; execution
  pass-list workflow live (`make conformance-exec`, crash- + regression-gated, only-grows).

### Phase 04 — Stdlib core  (deps: 03) ~9k LOC ⚡ — **DONE (gate MET: built-ins 83.5%, curated 81.0%)**
- [x] Object, Function, Array (ES2017), String (code-unit exact), Number, Boolean, Math
- [x] JSON (own parser/printer + Ryū port for Number→String; known-answer vectors)
- [x] Error hierarchy (+ES2022 cause); Symbol + well-knowns + registry; Map/Set/WeakMap/WeakSet (SBCL weak tables); iterator protocol; +Reflect
- [x] Date (UTC core; TZif deferred); global wiring + URI fns; eval/Function (parser in-image)
- **Gate:** built-ins slices for these globals ≥ 65% ✔ (83.5%); overall curated ≥ 55% ✔ (81.0%); Ryū vectors pass ✔.

### Phase 05 — Event loop core  (deps: 01; independent of 02–04) ◇ ~2.3k LOC — **DONE (gate MET)**
- [x] serve-event wrapper + startup capability probe (poll, fd>1023); self-pipe; mailbox integration
- [x] binary-heap timers; handle refcounting + ref/unref
- [x] signal delivery (enqueue-only); worker pool; graceful stop
- **Gate:** timer-ordering ✓; cross-thread wake < 5 ms ✓; process alive iff refs>0 ✓; SIGINT → loop
  event ✓; microtask-drain points honored (stub queue) ✓.

### Phase 06 — Async engine: generators, promises, modules  (deps: 04, 05) ~2.5k LOC — **DONE (gate MET)**
- [x] **thread-per-coroutine** (§3.1 fallback, not lowering — DECISIONS 2026-07-11); Generator objects (next/return/throw, yield*)
- [x] Promise + job queue (engine-owned; nextTick ahead of microtasks); capability+species; async functions
- [x] for-await (sync+async iterables); async generators; ~ESM linking/TLA → **deferred to Phase 07**
- [x] unhandled-rejection tracking → error (exit 1 at CLI); async-test262 runner support ($DONE/doneprintHandle)
- **Gate:** Promise 76.1% / generators ~78.5% / async 78.1% / for-await 78.7% (each ≥75% ✔); 0 regressions ✔; ordering corpus ✔.

### Phase 07 — Module resolution & CJS  (deps: 06) ~2.5k LOC ⚡(fixtures) — **DONE (gate MET)**
- [x] src/resolver/ pure CL (relative/absolute/bare, ext probing, dir index, main/exports/imports w/ conditions+patterns, self-refs, scoped, symlink realpath); + src/sys/ paths/fs/json (engine-free)
- [x] resolution corpus green (101 assertions / 40+ scenarios, engine-free parachute); + review-panel edge cases
- [x] loader-hook wiring; CJS require (wrapper idiom, this=module.exports, cache, cycles→partial, throw→evict, .cjs/.mjs/"type" gating)
- [x] ESM linking (Option-A frame, live thunks, early errors) + ESM↔CJS interop; JSON modules; import.meta.url/dirname/filename/main
- **Gate MET:** resolution corpus green; fixture app (ESM entry → CJS dep + scoped ESM pkg w/ exports maps + JSON + import.meta) runs; build/test(887)/purity(128) ✓; parse 17,512 / exec 19,540, 0 crashes, 0 regressions.

### Phase 08 — CLI shell, console, process  (deps: 07) ~3k LOC — **DONE (gate MET)**
- [x] dispatcher + exact flags (-e/-p as script — awaits promise; positional-stop; --cwd/--silent/--revision/--backtrace)
- [x] .env autoload ($VAR expansion, quotes, comments); the shared inspector (clun.engine) + full console spec (§3.6)
- [x] process core (argv/env/exit/exitCode/platform/arch/pid/cwd/chdir/versions/stdout.write/isTTY/hrtime/memoryUsage/on('exit'))
- [x] uncaught-error rendering (Name: message + stack, exit 1; stack overflow → RangeError; no Lisp backtrace w/o --backtrace); exit 0/1/2
- [x] **tests/js harness runner** (scripts/run-js-fixtures.lisp, `.out`/`.exit`/`.err`/`.argv` convention; wired into make test via test-js)
- **Gate MET:** run/eval matrix (13 JS fixtures) green; console subset matches Bun; build/test(976 parachute + 13 JS)/purity(138) ✓; parse 17,512 / exec 19,540, 0 crashes, 0 regressions.

### Phase 09 — TypeScript stripping  (deps: 08) ~2.5k LOC ⚡(corpus) — **DONE (gate MET)**
- [x] strip pass per §3.3 sharing the engine lexer (recursive-descent scanner over the token stream; balanced skip-type; exact-length whitespace / position-preserving)
- [x] error catalog (enum/namespace-runtime/param-props/decorators/import=/export=/angle-cast); .tsx rejection — all clean unsupported-ts-syntax → JS SyntaxError w/ line:col
- [x] 65-pair corpus (authored, no vendored amaro) incl. adversarial (< ambiguity, arrow generics, multiline, regex-after-type, template-with-type, postfix !); loader wiring (*ts-strip-hook*, read-source-for) for .ts/.mts/.cts + resolver .mts/.cts formats
- **Gate MET:** corpus green (strip byte-exact+same-length, errors w/ line:col, strip→run outputs); build/test(1004 parachute + 33 TS + 45 JS)/purity(143) ✓; parse 17,512 / exec 19,540, 0 crashes, 0 regressions.

### Phase 10 — RegExp  (deps: 04) ~3k LOC — **DONE (gate MET: RegExp 76.1%, String methods 96.9%)**
- [x] JS regex parser → own AST; AST → CL-PPCRE parse trees (group numbering, named-group map, i/m/s; u via down-translation; JS-vs-PPCRE fixes for . \s \w \b ^ $ octal empty-class baked into the tree)
- [x] RegExp object (lastIndex g/y w/ :real-start-pos absolute anchors, exec/test, flag validation, EscapeRegExpPattern source; /d indices deferred)
- [x] String match/matchAll/replace/replaceAll/split/search with $1/$<name> templates + fn replacer (incl. named groups arg); @@ delegation only when arg is an Object; Symbol.{match,…,species} statics exposed
- [x] loud SyntaxError for documented gaps (\p{}, /v, var-length lookbehind, bad flags/names); UCD table generator scaffolded (scripts/gen-unicode-tables.lisp) for later \p{}
- **Gate MET:** built-ins/RegExp/** 76.1% (696/915) ≥60%; String regex methods 96.9% (283/292) ≥75%; zero crashes/regressions; gaps enumerated in tests/conformance/regexp-gaps.txt.

### Phase 11 — Binary data + BigInt  (deps: 04) ~3k LOC — **DONE (gate MET: BigInt 96.1%, TypedArray 67.8%, DataView 70.5%, overall 80.4%)**
- [x] ArrayBuffer (ub8, half-heap alloc cap), DataView + all 11 TypedArray kinds (ldb/dpb + sb-kernel float bits; integer-indexed exotic over the buffer), detach (bytes→NIL, all views observe)
- [x] TextEncoder/TextDecoder (UTF-8; USV lone-surrogate→U+FFFD + BOM strip; non-utf8 label → RangeError)
- [x] BigInt = plain CL integer, threaded through values/typeof/coercions/all operators; literals (front-end already done); BigInt() ctor + toString(radix) + asIntN/asUintN; mixing/`+bigint`/`Number(bigint)`/JSON → TypeError
- **Gate MET:** BigInt 96.1% (73/76) / TypedArray 67.8% (835/1231) / DataView 70.5% (346/491) each ≥65%; overall curated 80.4% (22,638/28,163) ≥80%; 0 crashes; 0 regressions; gaps in tests/conformance/bigint-binary-gaps.txt.

### Phase 12 — Node-compat wave 1 (sync)  (deps: 08; 10 for assert.match) ~4k LOC ⚡⚡ (flagship fan-out) — **DONE (gate MET)**
- [x] builtin-module substrate: engine `*builtin-module-builder*` hook + `try-builtin-module` (CJS require + both ESM dep loops) + runtime registry/install; node: + bare names, per-realm cache
- [x] node:path (posix; win32 present-but-throwing), node:os (over clun.sys /proc+CL), node:querystring (null-proto parse)
- [x] node:util (format/inspect→shared/promisify/callbackify/inherits/deprecate/isDeepStrictEqual/types/stripVTControl)
- [x] node:events (full sync EventEmitter: snapshot emit, self-removing once by identity, newListener, error-throw)
- [x] node:assert (strict family + loose equal, throws w/ class-validation + match, AssertionError name/code + ctor)
- [x] Clun.inspect/deepEquals(shared)/which/nanoseconds/fileURLToPath/pathToFileURL/sleep; structuredClone (deep + Date + cycles)
- [x] crypto.randomUUID/getRandomValues via pure /dev/urandom (clun.sys:os-random-bytes + engine crypto-fill-random); full ironclad → Phase 19 (logged)
- **Gate MET:** per-module fixtures (tests/js/node/*) green; build/test(parachute + 42 TS + 53 JS)/purity(159) ✓; parse 17,512 / exec 22,638, 0 crashes, 0 regressions. Fan-out: 5 modules by parallel write-only subagents. Review panel 25/26 confirmed + fixed.

### Phase 13 — Files: fs substrate + node:fs + Buffer surface  (deps: 11, 12; loop 05 for async) ~4.5k LOC — **DONE (gate MET)**
- [x] src/sys fs layer (path discipline, errno→.code/.errno/.syscall/.path; `with-fs` maps syscall-error + file-error; async = Promise-over-sync, worker-pool deferred)
- [x] node:buffer (Buffer extends Uint8Array; alloc/from/concat/compare/copy(memmove)/fill/indexOf/subarray(shared)/toString+write; numeric read/write with one OOB→RangeError guard)
- [x] node:fs sync core (23 fns), fs/promises (14), callback shims; Stats/Dirent/constants
- [x] Clun.file/Clun.write (lazy file text/json/arrayBuffer/bytes/exists; string|TypedArray|ArrayBuffer sinks); mkdtemp/tmp helpers
- **Gate MET:** tests/js/node fixtures (buffer/bufedge/fsops/fsedge/clunfile) green — bracket paths, symlink chains, ENOENT/EISDIR, Buffer KAT + OOB/overlap/pad/encoding, Clun.file lazy; build/test(1110+42+58)/purity(161) ✓; exec 22,638, 0 crashes/regressions; deliberate gaps in tests/conformance/fs-buffer-gaps.txt.

### Phase 14 — Async product wave  (deps: 06, 12, 13) ~1.5k LOC — **DONE (gate MET)**
- [x] timers globals + Timer ref/unref/hasRef/refresh/close/@@toPrimitive real loop accounting + setImmediate/clearImmediate + node:timers + node:timers/promises ({signal,ref}; setInterval async iterator)
- [x] process.nextTick queue (pre-existing, verified ordering); events.once reject-on-error + {signal} + cleanup; captureRejections; assert.rejects/doesNotReject
- [x] Clun.sleep/sleepSync (pre-existing); queueMicrotask (pre-existing); AbortController/AbortSignal (abort/timeout/any); for-await IteratorClose engine fix
- **Gate MET:** tests/js/async/{ordering,timers,tpromises,unref,abort,evonce} exact-output green; build/test(1110+42+64)/purity(163) ✓; exec 22,643 (+5 IteratorClose, pass-list regenerated), 0 crashes/regressions. Review panel 2/7 confirmed + fixed (process.exit-in-async §6 backtrace; AbortSignal construct message).

### Phase 15 — Test runner  (deps: 14; 10 for -t) ~4k LOC — **DONE (gate MET)**
- [x] discovery (*.{test,spec}.*/*_{test,spec}.* walk, skip node_modules/dotdirs; positional path + substring filters)
- [x] collection + hook scheduler (Bun-exact ordering + failure semantics; .only per-file isolation, --ci guard)
- [x] matchers (~22) on shared eng:js-deep-equal/inspector; .not; .resolves/.rejects (Jest-async); per-test + setDefaultTimeout + --timeout machinery
- [x] reporter (result lines + summary, timing omitted for determinism) + LCS diffs + exit codes; --bail, --todo
- [x] self-hosting: meta-tests + hook-order byte-exact via the fixture harness (tests/js/testrunner/*), run under `make test`
- **Gate MET:** meta-test matrix (pass/fail/skip/todo/only/bail/-t 0-match/zero-tests→1) + hook-order byte-exact green; build/test(1110+42+74)/purity(170) ✓; exec 22,643, 0 crashes/regressions. Review panel 8/10 confirmed + fixed.

### Phase 16 — Sockets  (deps: 05) ◇ ~1.8k LOC — **DONE (gate MET)**
- [x] non-blocking connect (EINPROGRESS)/accept/read/write w/ EAGAIN→NIL; `(octets . offset)` write queue + backpressure (zero-copy displaced-view partial sends; edge-triggered on-drain)
- [x] port-0 real-port; error→JS-code mapping (ECONNREFUSED/EADDRINUSE/…); write-to-closed → catchable socket-error (`:nosignal`, no SIGPIPE); idempotent close w/ full handler removal; ref'd handle liveness. IPv6 structurally present (lightly tested); DNS → Phase 18
- **Gate MET:** echo 2,000 sequential + 500 concurrent green; /proc/self/fd stable (0 leaks over 400 cycles); throughput ~131–137 MB/s ≥100; build/test(1122+42+74)/purity(172) ✓; exec 22,643, 0 crashes/regressions. Review panel 4/6 confirmed + fixed (zero-byte-write crash; on-drain edge semantics).

### Phase 17 — HTTP server + Clun.serve  (deps: 14, 16) ~3.5k LOC — **DONE (gate MET)**
- [x] own incremental HTTP/1.1 parser (accumulate-then-parse; content-length + chunked in; 400/431/413; pipelining); Request/Response/Headers web classes (shared %body->octets, reused by Phase-18 fetch)
- [x] Clun.serve({port,hostname,fetch,error}) → Server{stop(graceful),url,port}; keep-alive, Content-Length out, 431/413, HEAD, Date/Connection; sync + Promise<Response> handlers; header CRLF-stripping (no response splitting)
- [x] Clun.file responses (buffered); 503 shedding; net:tcp-shutdown (flush-then-close); engine: run-loop drains microtasks after the reactor + coroutine-resume prunes completed coroutines (leak fix)
- **Gate MET:** curl interop + malformed suite (12 parser tests) + ≥30k req/s (~33k) + graceful stop + 1k-req RSS plateau (149 MB flat) + serve.ts smoke; build/test(1172+42+74)/purity(177) ✓; exec 22,643, 0 crashes/regressions. Review 2/11 confirmed + fixed (Request body types); + header-injection & coroutine-leak fixed.

### Phase 18 — HTTP client, fetch, URL  (deps: 14, 16; 11 for bodies) ~3.5k LOC — **DONE (gate MET)**
- [x] WHATWG URL/URLSearchParams minus IDNA (loud error non-ASCII; IPv4/`[IPv6]` host; relative resolution incl. `%2e` + `\`→`/`; percent-encode sets; linked USP; re-serializing setters). node:url deprioritized (fileURLToPath/pathToFileURL already exist)
- [x] reactor HTTP/1.1 client (response parser + de-chunk + read-until-close, timeout, redirects ≤20, gzip via **vendored chipz** @ 75dfbc6). No pool yet (Connection: close); blocking DNS
- [x] fetch API (Request/Response/Headers reused, text/json/arrayBuffer/bytes buffered + lenient UTF-8, AbortSignal already/mid-flight/timeout, network/DNS errors → TypeError). Engine: `lp:run-on-loop` reactor-thread marshalling (`el-thread` + `lp:*on-foreign-thread*`)
- **Gate MET:** fetch vs Phase-17 server on ONE loop (JSON/text/4xx-5xx/redirect chain/gzip/abort→AbortError/timeout + 25 concurrent) + a WPT-subset URL corpus; build/test(1271+42+74)/purity(199) ✓; exec 22,643, 0 crashes/regressions. Review panel 15/15 confirmed (2 §6 crashes, 3 HIGH) — 14 fixed + 1 documented.

### Phase 19 — Crypto foundation: ironclad KATs + pure-tls vendoring  (deps: 00; ironclad landed in 12) ◇ ~1k LOC glue — **DONE (gate MET)**
- [x] KAT suites (SHA-2/HMAC FIPS, HKDF RFC 5869, AES-GCM NIST, x25519 RFC 7748, ChaCha20-Poly1305 RFC 8439) — `make test-crypto`, 24 assertions over ironclad, published vectors
- [x] vendor **ironclad + pure-tls + ~18-lib closure** (Appendix B) pinned (SHAs in DECISIONS); cl-cancel/**precise-time** purity patch (precise-time → sb-unix:clock-gettime)
- [x] strip windows/macos verify files (+ dead non-SBCL foreign backends); run pure-tls crypto/record/handshake/cert(+trust-store/boringssl/x509/ml-dsa/cancel/security-regression) suites — `make test-tls`, 10 suites/342 checks; extend make purity (667 files); upstream patch-issue note in DECISIONS. node:url deprioritized. Ironclad os-prng routing for getRandomValues deferred (kept /dev/urandom)
- **Gate MET:** KATs pass (`make test-crypto`); pure-tls suites pass (`make test-tls`, 10/342); `make purity` clean over 667 files; build/test(1271+42+74) green; exec 22,643, 0 crashes/regressions. Review 3/7 confirmed (all LOW). (Follow-up: the Phase-16 net-socket bad-fd flakiness that surfaced here is now FIXED — reactor-poll prunes closed-fd handlers.)

### Phase 20 — HTTPS  (deps: 18, 19) ~1.5k LOC — **DONE (gate MET)**
- [x] TLS streams via the worker pool (blocking pure-tls handshake/IO off the JS thread) — src/net/tls-client.lisp `https-request`; web-fetch `%do-fetch` dispatches by scheme; abort/timeout close the worker socket; lazy worker spawn
- [x] trust store (system PEM bundle probe, `$SSL_CERT_FILE`/`$SSL_CERT_DIR` overrides); hostname verification (pure-tls verify-hostname). **Security patch: `+verify-required+` + null peer cert now fails closed** (closed a cert-auth bypass). Pool keys gain TLS config → deferred with the pool
- [x] test CA (`scripts/gen-test-certs.sh`) + in-process pure-tls server fixture; verify-function negative matrix + a deterministic fetch fail-closed test; posture labeling (§3.4) in README. `node:url`/pool deferred
- **Gate MET:** hermetic transport round-trip + verify matrix + fetch-fails-closed; live smoke logged (example.com both ways; badssl.com negatives all reject). build/test(1286+42+74)/test-tls(10/342)/test-crypto(24)/purity(669) green; exec 22,643, 0 crashes/regressions. Fail-closed + §6 crash-safety + abort/timeout verified by hand (review panel hung on a live fetch). Gap: registry.npmjs.org pure-tls protocol_version.

### Phase 21 — Semver + registry client + local registry fixture  (deps: 00 semver; 18 client) ◇(semver) ~2.5k LOC ⚡(fixtures)
- [ ] semver port (versions, prerelease precedence, ranges ^ ~ - || * x, includePrerelease) + node-semver fixture corpus at 100%
- [ ] registry client (abbreviated-metadata Accept, scoped %2F, retries, --registry, .npmrc-lite)
- [ ] local registry fixture (in-process server + hand-built .tgz for ~8 pkgs w/ conflict/scoped/bin/pax-longname); dist.integrity real; gzip + ETag/304
- **Gate:** semver corpus 100%; metadata round-trips incl. scoped/gzip/304; fixture server reusable as a make target.

### Phase 22 — Tarball + integrity  (deps: 13; 21 fixtures) ◇ ~700 LOC
- [ ] streaming chipz-inflate → hand-rolled ustar/pax reader (pax path/linkpath/size, gnu L longname, package/ strip, mode bits)
- [ ] SRI sha512 verify-then-commit (temp dir + rename); content-addressed cache
- **Gate:** real-package corpus extracts; mandated traversal suite (abs names, .. variants, symlink/hardlink escape, NUL/., device/FIFO reject, setuid strip, size overflow, dup last-wins) all handled per spec.

### Phase 23 — Install: resolver, linker, lockfile, CLI  (deps: 20, 21, 22) ~4k LOC
- [ ] breadth-first resolution (highest-satisfying, cycle-safe), hoisted layout + nested conflict dirs, os/cpu optional-dep filtering
- [ ] bin symlinks + chmod into node_modules/.bin; clun.lock (versioned JSON, deterministic); --frozen-lockfile drift error
- [ ] add/remove edit package.json (-d/-D, -E/--exact) + reinstall; --dry-run/--production/--no-save; lifecycle scripts skipped+logged
- **Gate:** fixture-graph e2e (install → clun run → exact output); reinstall from lock offline → byte-identical lock; frozen drift errors; live `clun add ms` logged.

### Phase 24 — Spawn + package scripts  (deps: 14; 23 e2e) ~2k LOC
- [ ] Clun.spawn (run-program wrapper: cmd/cwd/env, pipe|inherit|ignore, non-blocking into reactor, .exited promise, exitCode/signalCode, kill, onExit) + spawnSync
- [ ] clun run <script> (sh -c, ancestor .bin PATH walk, pre/post, npm_* env, --if-present, arg passthrough); dispatcher merge
- **Gate:** spawn matrix; 10 MB dual-pipe child drained w/o deadlock; 1,000 spawns → zero zombies; scripts fixture; examples/e2e.sh green + hermetic.

### Phase 25 — Performance pass  (deps: all engine phases) ~3k LOC
- [ ] shapes (scls/hcls-style tree + dict fallback) behind storage protocol; inline caches at property sites; direct call paths
- [ ] string-builder for += loops; optional COMPILE tiering (background thread) — measure first
- [ ] benchmark suite (Richards/DeltaBlue/splay) + docs/benchmarks.md (honest methodology)
- **Gate:** pass-list unchanged or grown; ≥5× on benchmark suite vs Phase-24 baseline; overall curated test262 ≥ 90%.

### Phase 26 — Hardening, docs, release  (deps: everything)
- [ ] error-message audit (named resource, violated constraint + rejected value, note: remedy; no Lisp backtraces w/o --backtrace)
- [ ] stress pass (50k-eval loop, long-run serve, biggest fixture tree ×20 — RSS plateaus)
- [ ] Ctrl-C mid-serve/mid-install clean exit; partial installs don't corrupt; TZif local-time task (or defer w/ matrix note)
- [ ] README (what/why, install-from-source, quickstart, architecture, compat matrix, TLS posture, contributing); CI release job
- [ ] final adversarial review sweep; triage → fix safety/error-path findings, log style findings
- **Gate:** §1.4 Definition of Done, every item checked w/ evidence links here; tag v0.1.0.
