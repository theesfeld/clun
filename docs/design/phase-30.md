# Phase 30: Glob API

## 1. Objective and boundary

Phase 30 converts `filesystem.glob` from `No` to an evidence-backed `Yes` by adding the
complete Bun-shaped public Glob surface to Clun:

```js
const glob = new Clun.Glob(pattern);

glob.match(path);          // boolean
glob.scan(optionsOrCwd);   // AsyncIterableIterator<string>
glob.scanSync(optionsOrCwd); // IterableIterator<string>
```

The namespace is deliberately `Clun`, not `Bun`. This phase does not add a `Bun` global, a
`bun` module alias, Node's `fs.glob` functions, multiple-pattern arrays, or exclude patterns.
Those APIs are not part of the `Bun.Glob` compatibility row.

The canonical live source of truth is
[issue #4](https://github.com/theesfeld/clun/issues/4). The issue owns live status, SemVer
disposition, review findings, exact-commit receipts, release evidence, and closeout. This document
freezes the implementation contract. `PLAN.md` and `STATE.md` remain derived surfaces.

At this design checkpoint, issue #4 is `in-progress`, has a `minor` disposition, and is assigned to
release `0.1.0-dev.12` / tag `v0.1.0-dev.12`. Synchronization work must preserve those canonical
fields while replacing any stale generated contract or checklist text with this accepted contract.

Phase 13 supplies filesystem and error primitives. Phase 27 supplies the compatibility ledger,
four-target evidence, and generated public claims. Both dependencies must remain complete before
implementation merges.

## 2. Frozen references and evidence priority

The phase uses the two already-pinned Bun baselines for different purposes:

| Role | Version/ref | Exact commit | Relevant paths |
|---|---|---|---|
| Public executable baseline | Bun 1.3.14 | `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` | `docs/runtime/glob.mdx`, `packages/bun-types/bun.d.ts`, `src/runtime/api/Glob.classes.ts`, `src/runtime/api/glob.zig`, `src/js/builtins/Glob.ts`, `src/glob/{matcher,GlobWalker}.zig`, `test/js/bun/glob/` |
| Forward engineering inventory | Bun 1.4.0-dev | `c1076ce95effb909bfe9f596919b5dba5567d550` | the same docs/types/class definition, `src/runtime/api/glob.rs`, `src/glob/{matcher,GlobWalker}.rs`, and `test/js/bun/glob/` |

The Bun 1.3.14 release archives and SHA-256 values for all four supported targets are canonical in
`compat/upstream-assets.tsv`. Oracle tooling must accept only an asset whose target and digest match
that table. A `bun` found on `PATH` is never evidence.

Evidence priority is:

1. observable behavior from the SHA-pinned Bun 1.3.14 executable;
2. the stable public type and documentation contract;
3. stable tests and implementation at the exact stable commit;
4. safety and correctness fixes in the exact engineering commit; and
5. explicitly recorded Clun improvements where Bun makes no ordering promise or the stable behavior
   is unsafe.

The stable upstream inventory has 1,519 `expect` sites in `match.test.ts`, 54 in `scan.test.ts`,
four in `proto.test.ts`, and the path-length, stress, and leak suites. The engineering inventory has
1,531 match expectations and 84 scan expectations, plus expanded path-length and symlink cases.
Counts are only a drift alarm: acceptance requires a row-level inventory with no silent skips.

### 2.1 Stable, engineering, and Clun dispositions

| Behavior | Bun 1.3.14 | Engineering pin | Phase 30 disposition |
|---|---|---|---|
| Public class, descriptors, argument rules, matcher syntax | supported | unchanged | match exactly |
| Comma inside a character class nested in braces | can be mistaken for a branch separator | fixed | adopt engineering fix |
| Malformed class consuming sibling brace text | a class can cross alternative ownership boundaries | unchanged | keep every malformed class branch-local |
| Sequential nested brace depth leaking into suffix text | later punctuation can be skipped as if still inside a brace | unchanged | validate suffix text with lexical brace ownership |
| Sequential brace-alternative explosion | no explicit branch budget | 10,000 explored branches | adopt 10,000-branch budget |
| Very deep skipped brace text | vulnerable to narrow depth counters | uses a wide pre-scan counter; 40,000 unclosed opens fail safely | adopt engineering behavior |
| Explicit dot directory followed by wildcard, such as `.dotdir/*.txt` | incorrectly hidden without `dot: true` | explicitly named dot segments work | adopt engineering behavior |
| Literal symlink component with `followSymlinks: false` | not consistently traversed | literal components traverse; wildcard components do not | adopt engineering behavior |
| Followed symlink cycles | eventually fail by path length in some cases | per-branch ancestor detection; first alias visit remains visible | adopt engineering behavior |
| Cousin symlinks sharing a target | may be suppressed by broad dedupe strategies | both independent branches are visited | adopt engineering behavior |
| Oversized cwd and joined traversal paths | fixed-buffer edge failures | explicit `ENAMETOOLONG` coverage | adopt engineering behavior |
| Absolute pattern containing no wildcard | incorrectly returns no result | literal absolute path is resolved and tested | adopt engineering behavior |
| Result ordering | implementation/readdir order; undocumented | still undocumented | Clun returns deterministic sorted results as an extension |
| Async iterator cancellation | eager scan continues after iterator close | no public cancellation guarantee | Clun cancels outstanding traversal on `return`/`throw` |
| Error `path` containing a trailing internal NUL | observable on some stable failures | implementation detail | return the logical path without a NUL |

The engineering choices above are not presented as Bun 1.3.14 executable outcomes. Each divergence
must be a named fixture and a decision on issue #4 and in `DECISIONS.md` before the public row becomes
`Yes`.

## 3. Exact JavaScript class contract

### 3.1 Namespace and constructor descriptors

`install-clun-glob` installs one own property on the existing realm-local `Clun` object:

```text
Clun.Glob: writable=true, enumerable=true, configurable=false
```

The constructor is an ordinary native class constructor with this exact observable shape:

| Observation | Required value |
|---|---|
| `typeof Clun.Glob` | `"function"` |
| `Clun.Glob.name` | `"Glob"` |
| `Clun.Glob.length` | `0` |
| own constructor keys | `length`, `name`, `prototype` |
| own `name` descriptor | writable false, enumerable false, configurable true |
| own `length` descriptor | writable false, enumerable false, configurable true |
| own `prototype` descriptor | writable false, enumerable false, configurable false |
| call without `new` | `TypeError: Glob constructor cannot be invoked without 'new'` |
| subclass construction | honors `new.target`; the instance uses the subclass prototype |

The constructor requires one supplied argument even though its declared length is zero. It first
brand-checks for a primitive JavaScript String or an object with the String internal slot; plain
objects fail without invoking conversion hooks. After that gate, it applies ordinary `ToString` to
the accepted value. This distinction is observable for a boxed String:

| Call | Result |
|---|---|
| `new Clun.Glob()` | `Error: Glob.constructor: expected 1 arguments, got 0` |
| `new Clun.Glob(undefined)` | `Error: Glob.constructor: first argument is not a string` |
| `new Clun.Glob(null)` | the same type error |
| `new Clun.Glob(1)` | the same type error |
| `new Clun.Glob({ toString() { return "*"; } })` | the same type error; hook is not called |
| `new Clun.Glob(new String("*"))` | succeeds |
| branded boxed String whose `Symbol.toPrimitive` returns `1` | succeeds with pattern `"1"` |
| branded boxed String whose conversion hook throws | the same thrown value propagates by identity |
| `new Clun.Glob("")` | succeeds and stores an empty pattern |

For a branded boxed String, ordinary string-hint conversion observes overridden `Symbol.toPrimitive`,
`toString`, and `valueOf` in the standard order. A primitive result such as `1`, `null`, or
`undefined` becomes `"1"`, `"null"`, or `"undefined"`; a non-primitive result or abrupt completion
has ordinary `ToString` behavior. The implementation must not extract the boxed internal slot
directly. The converted pattern is copied at construction, is not exposed as a property, and cannot
change later.

### 3.2 Prototype and instance shape

`Clun.Glob.prototype` has `%Object.prototype%` as its prototype and these own keys in this order:

```text
match, scan, scanSync, constructor, Symbol(Symbol.toStringTag)
```

The exact descriptors are:

| Key | Value shape | Writable | Enumerable | Configurable |
|---|---|---:|---:|---:|
| `match` | native function, name `"match"`, length 1 | true | true | false |
| `scan` | native function, name `""`, length 1 | true | true | true |
| `scanSync` | native function, name `""`, length 1 | true | true | true |
| `constructor` | the `Clun.Glob` constructor | true | false | true |
| `Symbol.toStringTag` | `"Glob"` | false | false | true |

All three methods are non-constructible and have no own `prototype` property. Their own `name` and
`length` descriptors are non-writable, non-enumerable, and configurable.

A direct instance has no own properties, is extensible, and reports `[object Glob]`. Genuine
subclass instances are valid receivers. `match`, `scan`, and `scanSync` reject every other receiver
synchronously with a JavaScript `TypeError`; no Common Lisp condition may cross the boundary.

### 3.3 `match` argument and return

`match` requires one supplied primitive String or branded boxed String. It applies the same
brand-check-then-ordinary-`ToString` algorithm as the constructor:

```text
missing        -> Error: Glob.matchString: expected 1 arguments, got 0
undefined/null/number/Symbol/plain object
               -> Error: Glob.matchString: first argument is not a string
boxed String   -> accepted; its ordinary conversion hooks are observable
```

Plain-object hooks are not called. Boxed-String hooks may return a non-String primitive, which is
then stringified, and an abrupt hook result propagates by identity. Constructor and match fixtures
cover each conversion route independently.

The return is a JavaScript Boolean primitive. Matching is side-effect free and reentrant; the same
Glob may be used by concurrent scans and matches because its compiled pattern is immutable.

## 4. Frozen pattern language

### 4.1 Anchoring and character model

The pattern is anchored to the complete candidate string. There is no implicit leading or trailing
`**`. Matching is case-sensitive and performs no Unicode normalization.

One matcher character is one Unicode scalar or one preserved lone surrogate, not one UTF-8 byte and
not one UTF-16 code unit. Thus `?` matches one emoji and one lone surrogate. Character-class ranges
compare decoded scalar values. Ill-formed sequences remain bounded and deterministic.

On Clun's supported Linux and macOS targets, `/` is the only path separator. A backslash is the
escape introducer and is not a separator. Windows separator behavior is not a Phase 30 claim.

### 4.2 Operators

| Syntax | Required behavior |
|---|---|
| `?` | exactly one non-separator character |
| `*` | zero or more non-separator characters |
| `**` | zero or more characters including separators only when used as a complete path component; otherwise it behaves as repeated segment wildcard syntax |
| `[abc]` | one class member; a class can match `/` |
| `[a-z]` | inclusive scalar range; reversed ranges match nothing |
| `[!abc]`, `[^abc]` | negated class |
| `{a,b}` | one branch; branches may contain every supported operator |
| leading `!` | negate the complete result; every additional leading `!` toggles it again |
| `\\x` | escape the following character |

Globstar must handle all zero-segment and backtracking cases in the pinned corpus, including
`src/**/*.ts` matching `src/x.ts`, repeated globstars, globstar inside braces, trailing `/**`, and
no early lock-in at `**/*abc*`.

Each brace alternative has its own left matcher boundary, so `{**/b,x}` and `{x,**/b}` match `b`.
Brace delimiters are not right component boundaries: `{**}` remains segment-only and does not match
`a/b`, and the `**` branch in `{**,x}/b` does not acquire the slash outside the group.

Classes follow the stable matcher, including these less obvious rules:

- `]` is a literal class member when it appears first;
- `-` is literal at either edge and denotes a range only with valid endpoints;
- commas inside classes nested in braces are class members, not brace separators;
- class escapes use the same escape decoder as the rest of the pattern; and
- unlike `?` and `*`, a class is permitted to match `/` because that is measured Bun behavior.

Brace discovery and class matching have separate bracket cursors. Brace discovery leaves bracket
state at the first unescaped `]`, while the actual class matcher can treat an initial `]` as a class
member. This measured distinction keeps later brace and suffix validation observable. The engineering
comma-in-class rule also applies to an unterminated class: its commas cannot manufacture alternatives.
Each compiled alternative owns its parse range, so a malformed class cannot consume a closing bracket
from a sibling branch. Sequential nested alternatives likewise cannot leak dynamic brace depth into
suffix punctuation. These two Clun corrections are frozen in
`tests/compat/filesystem.glob/differential-dispositions.tsv`.

Brace matching does not pre-expand alternatives. Active matching nests at most ten brace groups.
Skipped or unselected text can contain deeper braces without overflowing a counter. At most 10,000
brace branches may be explored in one `match` call; exhausting the budget makes remaining branches
non-matching. This cap is shared by direct matching and each scanner candidate.

### 4.3 Escapes, negation, and unsupported extglobs

Backslash escapes a following character. The frozen implementation also recognizes Bun's C-style
escape values:

```text
\\a -> a       \\b -> backspace       \\n -> newline
\\r -> carriage return                 \\t -> tab
```

Every other escaped character is literal. A trailing backslash is an invalid pattern and matches
nothing. `\\!` is a literal exclamation mark; only an unescaped run at index zero toggles negation.
Removing that run does not itself create a raw globstar component boundary (`!**` remains
segment-only), except that Bun collapses adjacent complete double-star components, so `!**/**`
complements a repeated-globstar match.

Extglobs are not supported by Bun.Glob and are not added by Clun. `@(a|b)` and `+(a|b)` are literal
text. `!(a|b)` is leading whole-pattern negation applied to the literal pattern `(a|b)`, not an
extglob. Numeric brace ranges, POSIX character classes, ignore/exclude lists, and nocase flags are
also absent.

### 4.4 Empty and malformed patterns

The constructor never rejects a pattern for syntax. An empty pattern matches only an empty string.
Unterminated classes, a trailing escape, or an unusable brace branch simply fail to match. Sibling
brace branches that are valid remain usable even when an unselected sibling contains malformed or
over-depth text. In an unterminated comma-bearing brace group, every branch terminated by a comma
remains usable and only the unfinished tail is ignored. The shipped malformed-pattern corpus freezes
the exact stable/engineering results instead of replacing them with a new parser error API.

Measured anchor cases include:

| Pattern | Candidate | Result |
|---|---|---:|
| `""` | `""` | true |
| `""` | `"x"` | false |
| `"["` | `"["` | false |
| `"[]"` | `"[]"` | false |
| `"{a}"` | `"a"` | true |
| `"{a,b"` | `"a"` | true |
| `"{a,b,c"` | `"b"` | true |
| `"{a,b,c"` | `"c"` | false |
| trailing `\\` | any candidate | false |

These are behavior rows, not a recommendation to accept malformed patterns in unrelated APIs.

Direct `match()` has no dotfile suppression. For example, `*` matches `.x`, and `**/*` matches
`a/.x`. Dot rules below apply only while enumerating a filesystem.

## 5. Scan option contract

### 5.1 Accepted argument forms

Both scan methods accept the same optional argument:

```ts
type GlobScanOptions = {
  cwd?: string;
  dot?: boolean;
  absolute?: boolean;
  followSymlinks?: boolean;
  throwErrorOnBrokenSymlink?: boolean;
  onlyFiles?: boolean;
};
```

Missing, `undefined`, or `null` selects all defaults. A primitive String passed directly is the
`cwd`. A boxed String passed directly is an options object, not the cwd shorthand, and therefore
goes through the six property lookups below. Every other non-object value throws a native `Error`
synchronously:

```text
scan: expected first argument to be an object
scanSync: expected first argument to be an object
```

### 5.2 Property lookup, order, and value interpretation

For an options object, properties are read exactly once in this order:

1. `onlyFiles`
2. `throwErrorOnBrokenSymlink`
3. `followSymlinks`
4. `absolute`
5. `cwd`
6. `dot`

Lookup honors own properties and custom prototypes but stops before an inherited realm
`Object.prototype`. Polluting `Object.prototype` therefore has no effect. Getters run with the
original options object as receiver. Exceptions propagate by identity and stop all later access.

`undefined`, `null`, and an empty String retain the default. Every other value is consumed, but a
flag is true only for the Boolean primitive `true`; a Boolean `false`, number, Symbol, boxed Boolean,
boxed non-Boolean, or nonempty String sets it false. This preserves Bun's measured option parser and
is intentionally not ordinary `ToBoolean`.

| Option | Default | Effect |
|---|---:|---|
| `onlyFiles` | true | false includes matching directories and symlink entries |
| `throwErrorOnBrokenSymlink` | false | with followed links, broken targets raise `ENOENT` |
| `followSymlinks` | false | wildcard traversal may descend through directory symlinks |
| `absolute` | false | returned paths and a relative cwd are resolved from the captured process cwd |
| `cwd` | process cwd | scan root; when consumed, must pass the primitive/branded-boxed String gate and ordinary `ToString` |
| `dot` | false | wildcard components may consume leading-dot entries |

Because `absolute` is read before `cwd`, a getter-selected absolute mode affects relative-cwd
resolution. A consumed non-String `cwd` throws `Error: scan*: invalid `cwd`, not a string` without
invoking plain-object conversion hooks. A branded boxed String passes that gate and is then converted
with ordinary `ToString`: its `Symbol.toPrimitive`, `toString`, and `valueOf` hooks are observable,
primitive hook results including `1`, `null`, and `undefined` are stringified, and abrupt completion
propagates by identity. Empty converted cwd means the captured process cwd. Fixtures distinguish a
direct boxed String options object from the same object supplied as `options.cwd`.

## 6. Filesystem traversal contract

### 6.1 Root, returned paths, and duplicates

The process cwd is captured when the scan method is called. Later `chdir` calls cannot retarget an
in-flight scan. Relative patterns and cwd values use lexical `/` components. An absolute pattern is
anchored at its absolute root.

Scanning has a component parser in front of the matcher. It splits the original pattern at every
raw `/` without considering an escape, character class, or brace context, then compiles each
component independently. Direct `match` does not perform this pre-split. These stable divergences
are mandatory fixtures:

| Pattern | Direct `match` | Filesystem scan |
|---|---|---|
| `{LICENSE,src/*}` | matches `LICENSE` and `src/x` | no result: the raw slash splits the brace text |
| `a\/b` | matches `a/b` | no result: the raw slash leaves an invalid trailing escape component |
| `[a/]` | can match `/` | the raw slash splits the class text |

A final raw `/` is a directory constraint, not part of the returned path. Thus `dir/` can return
`dir` only when it resolves to a directory and `onlyFiles` is false; it never returns `dir/`, and a
file at that spelling does not match. Leading raw slash still denotes the absolute root rather than
an empty ordinary component.

For relative output, an explicit leading `./` or `../` in the pattern is preserved. Explicit `..`
components are allowed to traverse above `cwd`, matching Bun; Glob is not a filesystem sandbox.
The walker must never invent a `.` or `..` directory entry, however, and wildcard or dotfile logic
must not escape a root unless the pattern explicitly contains `..`.

`absolute: true` returns absolute lexical paths while preserving a symlink alias in the matched
path. It does not replace the visible path with `realpath`. Directory matches do not acquire a
trailing separator.

Stable Bun 1.3.14 incorrectly returns an empty set for an all-literal absolute pattern even when the
file or directory exists; the pinned engineering implementation fixes that path. Clun adopts the
named engineering divergence: it resolves and tests the literal absolute target, returns its exact
absolute spelling when its type satisfies `onlyFiles` and the trailing-directory constraint, and
still returns no result for a nonexistent target. Absolute wildcard patterns retain stable behavior.

The same path is returned at most once. Clun collects the complete successful result set and sorts
it by JavaScript code-unit order before either iterator exposes it. This produces identical
`scanSync` and `scan` order for an unchanged tree. Bun documents no result order, so differential
tests compare sets and separately verify Clun's deterministic extension.

### 6.2 Dot entries

With `dot: false`, wildcard components cannot consume a segment whose first character is `.`.
An explicitly dot-prefixed component is still honored:

```text
.env                    finds .env
.dotdir/*.txt           enters .dotdir and finds visible .txt children
.*/inner.txt            can match .dotdir/inner.txt
**/.dotdir/inner.txt    can advance to an explicitly named .dotdir
**/*.txt                does not recurse through hidden directories
```

The look-ahead for an explicit dot component works for real directories, symlinked directories,
and entries whose filesystem type must be discovered with `lstat`/`stat`. `dot: true` removes this
wildcard suppression but does not synthesize `.` or `..`.

### 6.3 Files, directories, and symlinks

The default `onlyFiles: true` returns regular files and followed file symlinks, not directories or
broken links. With `onlyFiles: false`, matching directories and symlink entries are returned.

`followSymlinks` controls wildcard traversal, not a literal path the caller explicitly wrote:

- a literal `linkdir/file.txt` or `linkdir/**/*.txt` resolves through `linkdir` even when false;
- `*/file.txt`, `link*/file.txt`, and a globstar do not descend through a directory symlink when
  false; and
- wildcard traversal descends through such links when true.

Broken symlinks are included only when `onlyFiles` is false. `throwErrorOnBrokenSymlink` has an
effect only when `followSymlinks` is true: if true, opening the broken target raises `ENOENT`; if
false, the broken entry is retained or omitted according to `onlyFiles`.

Cycle tracking is per traversal branch, not global. A followed link that resolves to the branch's
current directory is entered once so the alias-visible children can match, then a repeated target
in that same ancestry is not descended again. Independent cousin links to the same target are both
visited. The key is the followed target's `(device,inode)` when available, with canonical real path
as the documented fallback; it is not a global visited-directory set.

### 6.4 Error behavior and path limits

`scanSync` performs its walk before returning the Generator, so cwd, `ENOTDIR`, permission,
`ENAMETOOLONG`, and broken-link failures throw synchronously. `scan` validates its receiver and
options synchronously, schedules traversal immediately, returns an AsyncGenerator, and rejects the
first pending `next()` promise if traversal fails.

Filesystem errors are ordinary JS Error objects with `code`, negative `errno`, `syscall`, and the
logical `path`. The path contains no implementation NUL. `ENOENT`, `ENOTDIR`, `EACCES`, `ELOOP`,
and `ENAMETOOLONG` are preserved rather than converted into empty results, except that a literal
nonexistent final path and a nonmatching path simply produce no match as in Bun.

The scanner uses Bun-compatible native path ceilings: 4,096 encoded bytes on Linux and 1,024 on
macOS. A cwd over the target ceiling fails before any fixed-size or pathname operation. A directory
that cannot be opened within the ceiling raises `ENAMETOOLONG`. Constructing a returned absolute
leaf path may exceed the traversal ceiling when the parent was still openable; no fixed output
join buffer may truncate it. Pattern matching itself uses dynamically sized strings and has no
filesystem path cap.

NUL-bearing filesystem paths are rejected before a pathname or POSIX call. Deep `.`/`..` runs,
255-byte segments, inaccessible directories, broken links, and self/cross cycles are mandatory
adversarial fixtures.

## 7. Iterator, cancellation, and concurrency semantics

`scanSync` returns a real Generator object:

```text
Object.prototype.toString.call(result) === "[object Generator]"
result[Symbol.iterator]() === result
```

`scan` returns a real AsyncGenerator object:

```text
Object.prototype.toString.call(result) === "[object AsyncGenerator]"
result[Symbol.asyncIterator]() === result
result.next() is a Promise
```

Stable Bun does not create the blank function-specific prototype layer used by an ordinary
source-level generator. Every result directly inherits the shared realm `%GeneratorPrototype%` or
`%AsyncGeneratorPrototype%` across calls and across Glob instances. Those intrinsic prototypes own
the generator methods and tag, and inherit from `%IteratorPrototype%` or
`%AsyncIteratorPrototype%` respectively:

```text
Reflect.ownKeys(Object.getPrototypeOf(syncResult))
  === ["next", "return", "throw", "constructor", Symbol.toStringTag]
Object.getPrototypeOf(syncResult) === %GeneratorPrototype%
Object.getPrototypeOf(%GeneratorPrototype%) === %IteratorPrototype%
Object.getPrototypeOf(syncResult1) === Object.getPrototypeOf(syncResult2)

Reflect.ownKeys(Object.getPrototypeOf(asyncResult))
  === ["next", "return", "throw", "constructor", Symbol.toStringTag]
Object.getPrototypeOf(asyncResult) === %AsyncGeneratorPrototype%
Object.getPrototypeOf(%AsyncGeneratorPrototype%) === %AsyncIteratorPrototype%
Object.getPrototypeOf(asyncResult1) === Object.getPrototypeOf(asyncResult2)
```

The implementation must use the corresponding intrinsic directly, without adding the ordinary
generator's blank function-specific layer or substituting an Array, Promise of Array, array
iterator, or object with instance-level closure methods. Focused fixtures must also prove that
ordinary source generators retain their distinct blank layer.

### 7.1 Producer-backed engine path

The existing Clun coroutine implementation creates one `sb-thread` when a coroutine is first
resumed. Phase 30 must not use that path for Glob iterators: it cannot bound 1,000 concurrent scans.
The engine instead gains producer-backed variants within the existing `js-generator` and
`js-async-generator` brands. A discriminated backend dispatches intrinsic prototype operations to
either the unchanged coroutine driver or a native producer state record. `scanSync` uses a
vector/index producer over its already-complete result. `scan` uses a scan producer and the existing
AsyncGenerator request queue, but never allocates a coroutine or per-scan thread. Focused engine
tests prove that ordinary source-level generators and async generators retain their current
coroutine behavior.

Async traversal is submitted immediately to the fixed worker pool. Worker threads handle only
engine-free Common Lisp strings, compiled pattern data, stats, cancellation tokens, and conditions.
JavaScript objects, AsyncGenerator request queues, state commits, and Promise settlement remain on
the event-loop thread. One thousand scans therefore create at most the configured fixed worker
threads, plus `O(number-of-scans)` small producer/job records and result storage actually completed.

`src/loop/workers.lisp` gains a cancellable job handle rather than pretending the current
`worker-submit` handle can cancel work. The new submit operation returns a job with an atomic token
and `queued`, `running`, `cancel-requested`, and terminal state. Its idempotent cancel operation
removes loop liveness immediately for a still-queued job, or requests cooperative stop from a
running job; exactly one completion/cancellation owner releases the registered loop resource and
invokes at most one terminal callback. A cancelled queued thunk is harmless when later dequeued.
A running blocking syscall is not terminated unsafely, but the walker must observe cancellation
before making another accessor call. Existing `worker-submit` behavior remains source-compatible
and receives regression coverage.

### 7.2 Request and settlement races

Each async scan producer begins in `traversing` and owns its token and cancellable worker job. All
transitions below are serialized on the event-loop thread; the token is the only state read by a
worker.

- A worker success or failure becomes observable only when its loop callback commits `ready` or
  `failed`. If that commit wins, queued requests are processed in AsyncGenerator FIFO order: ready
  values satisfy preceding `next` requests; the first applicable `next` observes a filesystem
  failure; later `return`/`throw` use ordinary completed-generator rules.
- Enqueuing the first `return` or `throw` while the producer is still `traversing` wins cancellation
  even if the worker has finished but its callback has not committed. The producer becomes
  `cancelling`, the token and job are cancelled once, and a late worker value or error is discarded.
- After cancellation acknowledgement, every earlier pending `next` resolves to
  `{ value: undefined, done: true }`. The winning `return(value)` then Await-adopts `value` and
  resolves `{ value, done: true }`, or rejects with the adoption failure. A winning `throw(reason)`
  rejects with the identical reason. Requests queued later observe ordinary completed-generator
  behavior. This is the named Clun cancellation extension and has explicit differential fixtures.
- If success/failure already committed before the abrupt request is enqueued, no cancellation is
  attempted. Realm teardown first cancels every registered scan producer, waits for running jobs to
  acknowledge and release their loop resources, suppresses their late callbacks, and only then
  destroys the loop. Because the realm and its pending capabilities are then unreachable, teardown
  does not invent post-destruction Promise settlement; tests inspect resource release directly.

Cancellation closes every open traversal resource under `unwind-protect`, releases the job handle,
publishes no late values, and does not affect another scan using the same immutable Glob. Generator
and realm teardown must leave no live coroutine, job handle, fd, or retained result vector.

## 8. Bounded matcher and walker

The core matcher must not expand braces into a Cartesian product or translate patterns into a host
regular expression. It compiles the pattern into immutable tokens/control edges and evaluates with
memoized `(program-counter, candidate-index, brace-state)` states. The wildcard-only path is bounded
by `O(pattern-length * candidate-length)` visited states; brace traversal adds at most the frozen
10,000 branch transitions. No path allocates the Cartesian expansion or recursive candidate copies.

The following limits are semantic and executable:

| Resource | Limit/requirement |
|---|---|
| active brace nesting | 10 |
| explored brace alternatives | 10,000 per match |
| matcher recursion | none on candidate or star count; bounded brace parser stack only |
| directory depth | iterative work stack; no Lisp recursion proportional to tree depth |
| duplicate storage | one entry per returned path |
| traversal ancestry | proportional to current branch depth, structurally shared where practical |
| open directories | bounded; every open is paired on success, error, and cancellation |
| worker count | existing fixed/lazy Clun pool only; zero Glob coroutine threads |

The directory accessor is incremental. The walker checks its token immediately before and after
each entry delivery/classification and before pushing a child. Real `sb-ext:map-directory` callbacks
perform that check per entry and signal a private cancellation unwind; every open directory is
closed by `unwind-protect`. If cancellation races a blocking entry read, that one in-flight call may
finish, but no next accessor call begins.

`tests/lisp/glob/synthetic-accessor-tests.lisp` supplies a virtual million-entry tree without
creating a million host files. A zero-match walk must keep peak retained working memory below
64 MiB above the post-warmup baseline. A match-all walk is permitted `O(number-of-results)` output
storage. In the deterministic cancellation fixture, accessor visit 128 flips the token before it
returns; the walker must unwind immediately, make no visit 129, and release its job handle.
Measurements record SBCL version, target, entry count, baseline, peak, and retained bytes; they are
boundedness evidence, not a Bun performance claim.

Adversarial pattern tests include 100,000 stars/questions, 40,000 unclosed braces, more than ten
active nested branches, ten sequential ten-way brace groups, long nonmatching suffixes, invalid
surrogates, and repeated globstars. Every case has an explicit operation/state budget and must not
overflow the Lisp stack or hang.

## 9. Pure Common Lisp architecture

The implementation has four ownership layers:

1. `src/glob/matcher.lisp` owns immutable pattern compilation, Unicode/lone-surrogate iteration,
   negation, classes, braces, wildcard/globstar transitions, budgets, and direct matching. It has no
   engine or filesystem dependency.
2. `src/glob/walker.lisp` owns raw-slash pattern components, path-prefix and trailing-directory
   semantics, dot filtering, duplicate suppression, deterministic ordering, symlink ancestry,
   per-entry cancellation checks, and an incremental accessor protocol used by real and synthetic
   filesystems. It depends only on `clun.sys` and the matcher.
3. `src/sys/fs.lisp` adds an error-preserving directory-entry primitive based on
   `sb-ext:map-directory` with `:classify-symlinks nil`, followed by explicit `lstat`/`stat`. This is
   required to see broken links; the existing `read-directory` loses that information and must not
   be used by the Glob walker.
4. `src/runtime/clun-glob.lisp` owns the class/prototype descriptors, branded-String conversion,
   mitigated option lookup, error conversion, worker submission, direct intrinsic result prototypes,
   producer construction, and cancellation/settlement state machine.

`clun.asd` loads the new engine-free `glob` module after `sys` and before `engine`, then loads the
runtime bridge before `clun-global.lisp`. `src/packages.lisp` exports only the narrow matcher/walker
entry points required by runtime and tests. `install-clun-global` installs one realm-local class.

Two intentional core changes are required. The generator structs and intrinsic operation dispatch
gain the producer backend described above while retaining coroutine as the default. The loop worker
pool gains the cancellable job/token/release primitive with exact-once terminal ownership. Neither
change alters source-level generator APIs or the existing `worker-submit` contract; focused engine,
loop, teardown, and race tests must prove those non-Glob paths are unchanged.

Implementation is pure Common Lisp. There is no CFFI, native glob library, libc `glob`, embedded
implementation JavaScript/TypeScript, shell-out, regex translation, or runtime dependency on Bun,
Node, Deno, fast-glob, minimatch, or micromatch. The Bun repository is read-only. Implementation
algorithms are independently written; transformed MIT-derived fixture data retains provenance and
the required notice.

The matcher API is reusable by test discovery and package tooling only where their documented
semantics are identical. Phase 30 must not silently replace their current filters or broaden this
public compatibility claim to Node `fs.glob`.

## 10. Implementation split

The realistic unit is approximately 3.5-4.5k implementation LOC plus generated/translated fixture
data, not the old 2.5k sketch. It can be developed in parallel behind stable internal contracts:

1. **Matcher and corpus:** engine-free compiler/matcher, stable and engineering row inventory,
   malformed/adversarial tests, and direct Bun differential runner.
2. **Filesystem walker:** incremental entry accessor, raw-slash/trailing-directory component model,
   absolute-literal fix, symlinks/cycles/errors, deterministic dedupe/order, cancellation bounds,
   synthetic accessor, and stress tests.
3. **Runtime and loop core:** exact class/descriptors/branded-String coercions, shared direct
   intrinsic result prototypes, producer-backed Generator/AsyncGenerator paths, cancellable worker jobs,
   deterministic settlement races, and ordinary generator/worker regression tests.
4. **Integration and release evidence:** combine the three behind `Clun.Glob`, run the complete
   shipped-binary corpus, update ledgers/public docs/version in one release unit, and obtain all
   target receipts.

Matcher and walker contracts should land together in the Phase 30 PR unless issue #4 is explicitly
split into reviewed child milestones. No child milestone may promote the public ledger early.

## 11. Shipped evidence and inventory

The implementation unit adds at least:

| Path | Purpose |
|---|---|
| `tests/compat/filesystem.glob/api.js` + `.out` | class, descriptors, branded-String hooks, arguments, receivers, option getters/defaults/errors, direct intrinsic iterator prototypes |
| `tests/compat/filesystem.glob/match-corpus.tsv` | every translated stable and engineering pattern/path/result row with provenance |
| `tests/compat/filesystem.glob/match.js` + `.out` | execute the complete public matcher corpus through `build/clun` |
| `tests/compat/filesystem.glob/scan.sh` | create a hermetic real tree and assert raw component splitting, trailing slash, absolute literals, sync/async paths, dot rules, files/directories, errors, symlinks, cycles, and cancellation races |
| `tests/compat/filesystem.glob/upstream-inventory.tsv` | one disposition for every applicable upstream test/assertion; no silent skip |
| `tests/lisp/glob/matcher-tests.lisp` | token/control flow, malformed input, budgets, Unicode, and adversaries |
| `tests/lisp/glob/walker-tests.lisp` | real and virtual accessor behavior, order, dedupe, errors, cancellation, and million-entry bounds |
| `tests/lisp/runtime/glob-tests.lisp` | realm shape, shared direct intrinsic prototypes, producer brands, worker settlement races, 1,000-scan thread bounds, teardown, and ordinary-generator blank-layer regression |
| `scripts/glob-oracle-check.sh` | digest-check pinned Bun asset and compare canonical stable rows/trees with the shipped Clun binary |

The upstream inventory disposition vocabulary is `executed`, `translated`, or `not-applicable`.
Every not-applicable row requires a specific reason such as Windows-only behavior, Bun's internal GC
API, or the Node `fs.glob` surface. Unsupported syntax and failing upstream cases are not
not-applicable; they need explicit expected rows.

`make compat FEATURE=filesystem.glob` registers at least four pieces of evidence:

- public API/descriptor fixture;
- complete match corpus fixture;
- hermetic filesystem/symlink checked script; and
- static focused matcher/walker/adversary suite.

Executable evidence runs `build/clun`, not an internal Lisp shortcut. Compatibility CI additionally
runs the pinned-oracle checker on Linux and macOS x64/arm64. Oracle output canonicalizes only the
temporary absolute root and compares scanner sets because Bun makes no ordering promise; every
other value, error category, pattern result, and option effect remains exact.

## 12. Ledger, SemVer, synchronization, and publication

Adding `Clun.Glob` and changing `filesystem.glob` from `No` to `Yes` is SemVer `minor`. Canonical
issue #4 assigns this work to release `0.1.0-dev.12` and immutable tag `v0.1.0-dev.12`. The version
transition and public surfaces change only in the reviewed release unit; the tag is created only on
the squash-merge commit and is never moved or reused.

After all candidate evidence is green, the same reviewed release unit updates:

- `compat/features.tsv`, `compat/evidence.tsv`, all four `compat/platforms.tsv` rows, references,
  and release metadata;
- `src/version.lisp`, ASDF/core version assertions, installer default, and version tests;
- generated `README.md`, `site/index.html`, and `docs/releases/current.md`;
- `PLAN.md`, `STATE.md`, `DECISIONS.md`, this design, and the canonical issue.

The candidate ledger detail is `` `Clun.Glob` match and filesystem scan `` and the gap becomes `-`.
It is not a published `Yes` until the squash merge, immutable tag, four native assets and checksums,
published-ledger reconciliation, Pages deployment, hosted installer smoke, and issue evidence all
identify the same commit and release.

## 13. Acceptance gates

Phase 30 is complete only when all of these are true:

1. `make test-glob` passes the complete matcher, real/virtual walker, runtime, security, stress,
   leak, cancellation, and upstream-inventory suites.
2. `make compat FEATURE=filesystem.glob` passes every registered shipped-binary and static evidence
   row with no skipped applicable upstream row.
3. The SHA-pinned Bun oracle differential passes on `linux-x64`, `linux-arm64`, `darwin-x64`, and
   `darwin-arm64`; engineering-only fixes have separate named expectations and issue decisions.
4. The 10,000-branch cap, deep malformed patterns, path ceilings, million-entry virtual tree,
   symlink cycles/cousins, 1,000 concurrent scans, and cancellation bounds all pass with recorded
   resource receipts.
5. `make build`, `make test`, and `make purity` pass.
6. `make docs-check`, `make public-claims-check`, `make roadmap-check`, and live roadmap verification
   pass after the issue and generated public claim are synchronized.
7. `BASE_SHA=<phase-base> HEAD_SHA=<candidate> make version-transition-check` accepts the exact
   release unit as `minor`, version `0.1.0-dev.12`, and agrees with issue #4.
8. Compatibility CI produces successful exact-candidate receipts for all four supported targets.
9. Independent review confirms the descriptor/coercion contract, complete corpus ownership,
   matcher bounds, path and symlink discipline, async cancellation, pure-CL implementation, and
   absence of public overclaims.
10. Release assets, checksums, Pages, `https://clun.sh/install`, ledger, README, site, release notes,
    `STATE.md`, and issue #4 agree before the issue closes.

## 14. Explicit nonclaims and pre-implementation blockers

Phase 30 does not claim or add:

- a `Bun` global or import from `bun`;
- Node `fs.glob`, `fs.globSync`, or `fs.promises.glob`;
- arrays of patterns, `exclude`, ignore files, extglobs, nocase matching, or numeric brace ranges;
- Windows path/separator or release support;
- streaming output before a scan's result set is complete;
- a filesystem sandbox around cwd;
- compatibility with every npm glob package; or
- a performance advantage over Bun, Node, Deno, fast-glob, minimatch, or micromatch.

Issue #4 is already `in-progress`, has the `minor` disposition, and assigns
`0.1.0-dev.12` / `v0.1.0-dev.12`; those live fields must not be reset. Before implementation
continues, its stale generated contract/checklist text must be synchronized with this accepted
design, including the branded-String, scanner-component, direct-intrinsic-prototype, producer, cancellable-job,
and race contracts. The filesystem enumerator still needs an incremental error-preserving path, and
native macOS plus non-host architecture receipts remain CI obligations. None of those blockers
permits a reduced public surface or an early `Yes`.

The truthful completed claim is narrow: Clun ships the full `Clun.Glob` class contract for matching
and sync/async filesystem scanning, with the frozen Bun syntax and options, selected pinned
engineering safety fixes, deterministic Clun order, pure Common Lisp implementation, and successful
shipped-binary evidence on all four supported Linux/macOS targets.
