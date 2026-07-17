# Phase 31: YAML API and module loading

Status: accepted for implementation on issue #5's isolated Phase 31 lane.

## 1. Objective and public boundary

Phase 31 converts `data.yaml` from `No` to an evidence-backed `Yes` by adding one pure Common
Lisp YAML implementation shared by the JavaScript API and the module loader. The candidate public
surface is:

```js
Clun.YAML.parse(input)                    // function length 1
Clun.YAML.stringify(value, replacer, space) // function length 3
```

Files ending in `.yaml` or `.yml` are data modules. ESM receives a default export containing the
whole parsed value and named exports for enumerable top-level mapping keys. CommonJS `require`
returns the whole parsed value. A realpath-keyed module record is the single cache identity across
default imports, named imports, namespace imports, and `require`.

`Bun.YAML` is the behavioral reference. Clun exposes the API on its existing `Clun` namespace and
does not introduce a general `Bun` global or a `bun` module alias. A future public claim must name
the implemented YAML contract and module formats rather than implying unrelated Bun surfaces.

The canonical live source of truth is [issue #5](https://github.com/theesfeld/clun/issues/5).
`PLAN.md` is its derived technical contract, `STATE.md` is the derived resume cache, and the
compatibility ledger may change only after every gate in this document is green.

## 2. Survey and frozen references

| Role | Revision | Relevant paths |
| --- | --- | --- |
| Public executable | Bun 1.3.14 | pinned linux-x64 baseline asset used by the compatibility program |
| Engineering inventory | Bun 1.4.0-dev `c1076ce95effb909bfe9f596919b5dba5567d550` | `docs/runtime/yaml.mdx`, `docs/guides/runtime/import-yaml.mdx`, `packages/bun-types/bun.d.ts`, `src/parsers/yaml.rs`, `src/runtime/api/YAMLObject.rs`, `test/js/bun/yaml/`, `test/js/bun/resolve/yaml/` |
| Clun module substrate | current Phase 07 implementation | `src/resolver/resolve.lisp`, `src/engine/modules/` |
| Clun value boundary | current Phase 01-12 implementation | `src/engine/values.lisp`, `objects.lisp`, `builtins-binary.lisp`, `builtins-json.lisp` |

The pinned types define exactly `parse(input)` and `stringify(input, replacer?, space?)`. The
engineering source establishes method arities, text-source coercion, `SyntaxError` translation,
replacer rejection, indentation rules, repeated-object discovery, deterministic anchors, and
identity-preserving conversion of parsed nodes to JavaScript values. The pinned tests add core
schema, flow/block, block-scalar, merge, identity, module, and exact stringify fixtures.

Direct Bun 1.3.14 executable probes record these additional observable facts:

- `Object.keys(Bun.YAML)` is `parse,stringify`; the methods report names `parse`/`stringify` and
  lengths 1/3. The namespace is writable and enumerable but non-configurable. Methods are writable,
  enumerable, and configurable.
- `parse()` and `parse(undefined)` parse the string `"undefined"`; `null`, booleans, numbers, and
  ordinary objects use the text-source coercion path. Symbol conversion throws a JavaScript
  `TypeError`.
- Empty input is `null`. A single document returns its value; two or more documents return an
  array in source order.
- Duplicate explicit mapping keys use the last value. Aliases of a completed mapping or sequence
  preserve JavaScript identity.
- Parse failures are `SyntaxError` instances whose message begins `YAML Parse error:`.
- `stringify(undefined)`, a Symbol, or a function at the root returns `undefined`. BigInt throws.
  A non-nullish replacer throws. A zero/negative/NaN indentation selects flow style; positive
  numeric indentation is integer-truncated and clamped to 10; string indentation uses at most its
  first 10 code units.

Executable observations are evidence, not implementation source. No Rust, Zig, JavaScript, or
TypeScript implementation is copied into Clun.

## 3. Syntax and semantic contract

### 3.1 Accepted YAML language

The parser accepts the YAML 1.2 core-schema subset exercised by the pinned corpus:

- block mappings and sequences, including compact mappings inside sequence entries;
- flow mappings and sequences, including nesting and trailing commas;
- plain, single-quoted, and double-quoted scalars;
- literal (`|`) and folded (`>`) block scalars, explicit indentation 1-9, and strip/clip/keep
  chomping;
- comments and blank lines without treating `#` inside a quoted or non-separated plain scalar as
  a comment;
- document directives, `---` document starts, `...` document ends, and multiple documents;
- anchors, backward aliases, merge keys, and the standard `!!str`, `!!int`, `!!float`, `!!bool`,
  `!!null`, `!!seq`, and `!!map` tags;
- empty nodes, explicit keys, and ordinary scalar mapping keys.

YAML 1.2 core scalar resolution is exact rather than inherited from the Common Lisp reader:

| Spelling | Result |
| --- | --- |
| empty, `~`, `null`, `Null`, `NULL` | null |
| `true`/`false` in lower/title/upper case | boolean |
| YAML 1.1 `yes`, `no`, `on`, `off`, `y`, `n` variants | string |
| decimal integer/float/exponent | JavaScript Number |
| `0o` octal, `0x` hexadecimal | JavaScript Number |
| `.inf`, `+.inf`, `-.inf` case variants | infinity |
| `.nan` case variants | NaN |
| all other valid plain scalars | string |

Quoted scalars remain strings even when a standard tag names another core type. Numeric
resolution rejects malformed sign, base, decimal, and exponent spellings rather than accepting a
prefix. Integers outside exact host parsing range are converted through the same IEEE-754 Number
boundary as other numeric YAML values; they do not become JavaScript BigInt.

### 3.2 Tags and directives

Syntactically valid `%YAML` versions and valid `%TAG` declarations are recognized at document boundaries. Standard short
tags and their `tag:yaml.org,2002:` long forms act as Bun-compatible weak type hints. A compatible
plain scalar resolves to the requested core kind; a quoted scalar or incompatible scalar remains a
string, and collection shape wins over a mismatched core collection tag. Duplicate directives,
malformed handles, invalid placement, or multiple tags on one node are syntax errors.

Application-specific, verbatim, and otherwise unknown tags remain inert node metadata and do not
construct host values. Clun never resolves a YAML tag to a Common Lisp class, function, pathname,
reader form, package symbol, or arbitrary host object. Repeated anchor names shadow lookup for
subsequent aliases while aliases already resolved to the earlier node retain their identity.

### 3.3 Mapping and merge policy

Ordinary duplicate mapping keys use last-explicit-key-wins, matching the pinned executable. The
implementation still records the earlier source location so diagnostics and tests can prove the
policy is deliberate.

For `<<` merge keys:

- the value must be a mapping alias or a sequence of mapping aliases;
- explicit keys in the receiving mapping override merged keys regardless of textual order;
- for a sequence of merge sources, the first source defining a key wins;
- merged values are references to the existing graph nodes, not deep copies;
- multiple merge entries are processed in source order under the same rules;
- merge work is charged against the global edge budget so a merge bomb cannot create unbounded
  host work from a small alias graph.

The literal key `"<<"` when explicitly tagged as a string is an ordinary key rather than a merge.
JavaScript object conversion applies ordinary property-key string conversion. Dangerous-looking
keys such as `__proto__` become own data properties; they must not mutate the output prototype.

### 3.4 Anchors, aliases, and identity

The parser builds a graph, not a tree. An anchor table maps names to node identities. An alias node
resolves to the exact previously anchored node, so two aliases become the same JavaScript object or
array. Repeated scalar aliases preserve value equality; object identity is meaningful only for
collections.

Aliases are backward-only. Undefined aliases, duplicate anchor definitions, aliases used where a
merge mapping is required, and aliases whose target was not fully established by the supported
grammar are syntax errors. Cycles that the accepted grammar can establish are preserved. The
stringifier supports arbitrary JavaScript object/array cycles even if a particular self-referential
source spelling is outside the parser's supported alias placement.

### 3.5 Source locations and errors

The engine-free parser condition carries:

- stable error code;
- one-based line and column;
- zero-based source offset;
- short reason without source contents;
- optional document index.

The JavaScript boundary always translates it to a catchable `SyntaxError` beginning
`YAML Parse error:`. File/module errors append the path and location without exposing host
condition names or backtraces. Invalid UTF-8 at a binary input boundary is a syntax error, not
replacement decoding. Host bounds/type/arithmetic errors are caught at the boundary and must not
escape JavaScript `try`/`catch`.

## 4. Bounded parser architecture

### 4.1 Engine-free graph model

`src/yaml/` defines a package that depends only on Common Lisp. Its public implementation types are:

```text
yaml-stream  -> ordered vector of document root nodes
yaml-node    -> kind, value, anchor, tag, source span
yaml-pair    -> key node, value node, source span, merge marker
```

Node kinds are `:null`, `:boolean`, `:number`, `:string`, `:sequence`, and `:mapping`. Sequence
values are ordered vectors of node references. Mapping values are ordered vectors of pairs. The
model never uses `read`, reader macros, `eval`, package lookup, pathname coercion, or foreign code.

The scanner normalizes CRLF and bare CR to logical line breaks while retaining original offsets.
It recognizes indentation, document markers, properties, quoted/plain/block scalars, flow
punctuation, and comments with explicit states. The parser is recursive descent with a checked
depth counter. Flow and block parsing feed the same node constructors and scalar resolver.

### 4.2 Hard limits

Defaults are part of the security contract and may only be raised by an internal trusted caller:

| Resource | Default limit |
| --- | ---: |
| source bytes/code units | 16 MiB |
| nesting depth | 256 |
| documents | 1,024 |
| graph nodes | 1,000,000 |
| collection edges, including merged edges | 1,000,000 |
| anchors | 100,000 |
| alias references | 1,000,000 |
| scalar output code units | 16 MiB |

Every increment is checked before allocation or recursion. Alias lookup is O(1) expected time and
does not recursively expand a target. Merge materialization is linear in charged source edges.
Quoted escapes and folded scalars push into bounded adjustable character vectors. A limit breach
is a deterministic YAML syntax/resource error, never partial output.

### 4.3 JavaScript conversion

One engine adapter converts a `yaml-stream` to JavaScript:

1. Empty/single/multiple document cardinality selects null, the root value, or a JavaScript array.
2. On first visit to a sequence/mapping node, allocate the JavaScript container and enter it in an
   EQ identity table before converting children.
3. A later visit returns the existing container, preserving aliases and cycles.
4. Mapping properties are created as own enumerable writable configurable data properties.
5. Scalar nodes map only to null, boolean, Number, or string.

The runtime API and module loader call this same adapter. Neither reparses serialized JSON nor forks
the YAML semantics.

## 5. JavaScript API contract

### 5.1 Namespace and methods

`Clun.YAML` is installed once per runtime realm. Its property on `Clun` is writable and enumerable
but non-configurable. `parse` and `stringify` are detached-call-safe native functions with the
pinned names/arities and writable/enumerable/configurable method descriptors. Neither function is
constructible.

`parse` accepts a string, ArrayBuffer, DataView, TypedArray view bytes, and supported Blob/File text
sources when those host classes exist in Clun. A view uses its visible byte offset and length rather
than the whole backing buffer. Binary sources use strict UTF-8. Other inputs follow the pinned
text-source coercion order; Symbol throws its original JavaScript conversion error.

### 5.2 Deterministic stringification

Stringification has two passes. The first performs JavaScript property access in deterministic own
enumerable key order and records every non-callable object/array by identity. The second emits a
YAML document and assigns an anchor on the first occurrence of each repeated identity; later
occurrences emit aliases. Because the object is registered before descending, cycles terminate.

The serializer contract is:

- null/boolean/Number/string emit YAML core scalars; negative zero is `-0`, infinities are `.inf`
  and `-.inf`, and NaN is `.nan`;
- BigInt throws `YAML.stringify cannot serialize BigInt`;
- root undefined/Symbol/function returns undefined; those object properties are omitted and those
  array positions become null;
- a non-nullish replacer throws `YAML.stringify does not support the replacer argument` before
  traversal;
- empty arrays/mappings are `[]`/`{}`;
- no effective `space` emits flow form; effective `space` emits block form using the selected gap;
- string quoting is round-trip driven: empty strings, core keywords/numbers, indicators, flow
  punctuation, unsafe colon/comment contexts, leading/trailing whitespace, controls, line breaks,
  and ambiguous document markers use double quotes with YAML escapes. Valid UTF-16 surrogate
  pairs remain paired code units; a lone surrogate follows the pinned Bun emitter and remains a
  raw code unit, while the parser continues to reject lone raw or escaped surrogates;
- ordinary objects serialize own enumerable string keys only. Getters run once per pass in the
  same order as the pinned implementation, and abrupt completion propagates. A getter that adds a
  previously undiscovered back-edge fails explicitly instead of emitting an unresolved alias;
- anchor names are deterministic, safe plain tokens. A repeated property value prefers its safe
  property name; array items and unsafe/colliding names use monotonic `itemN`/`valueN`; a repeated
  root uses `root`.

Traversal has the same 256-depth, 1,000,000-edge, and 100,000-anchor limits as parsing. Output is
capped at 32 MiB and checked after bounded traversal. Repeated references do not consume expansion
proportional to their target size.

## 6. Module-loader integration

The resolver adds `.yaml` and `.yml` at the end of its Bun-lenient extension probe order and maps
both exact extensions to a distinct `:yaml` format. YAML never inherits package `type` and is never
compiled as JavaScript.

The loader creates and registers the module record before reading/parsing so the realpath cache is
authoritative. Successful evaluation stores the parsed JavaScript value on the record and marks it
evaluated. Failed parsing evicts the record, matching the existing CommonJS retry discipline and
preventing a poisoned partial cache entry.

YAML module export behavior is:

| Consumer | Value |
| --- | --- |
| ESM default import / `{ default as x }` | entire parsed value |
| ESM named import | top-level own mapping property; missing name is link `SyntaxError` |
| ESM namespace | `default` plus deterministic top-level named keys |
| CommonJS `require` | entire parsed value |

A non-mapping top-level document has only a default export. Multi-document input has only a default
export because its outer array is parser-produced rather than a YAML top-level mapping. Named keys
are snapshots of immutable data-module evaluation, consistent with JSON/YAML data semantics.

Import attributes for a non-YAML suffix are not silently ignored. They require parser and resolver
support that validates `type: "yaml"`; if that syntax is not present in the phase entry baseline,
the extension-backed API must remain honest and the attribute form cannot be claimed complete.

## 7. Verification inventory

The focused phase corpus has five layers:

1. Engine-free Lisp tests cover scanner states, core scalars, block/flow collections, quoted
   escapes, block-scalar chomping/folding, documents/directives, tags, merges, duplicate keys,
   locations, and all bounds.
2. Runtime Lisp tests evaluate `Clun.YAML` through a real realm, including descriptors, coercion,
   exact errors, values, stringify formatting, round trips, aliases, and cycles.
3. Module fixtures exercise `.yaml` and `.yml` ESM default/named/namespace imports, CJS require,
   realpath cache identity, empty/scalar/multi-document files, syntax errors, and retry behavior.
4. `tests/compat/data.yaml/` drives the shipped `build/clun` binary over a pinned differential
   corpus. Expected files are locally derived facts and do not contain copied Bun implementation.
5. Security/stress fixtures cover alias storms, merge amplification, deep flow/block structures,
   huge scalars, malformed escapes, invalid UTF-8, anchor shadowing, unresolved aliases, unsafe
   tags, `__proto__`, cycles, and repeated parse failures with bounded memory.

The YAML Test Suite slice used for conformance must be byte-pinned with its upstream license and a
checked-in manifest. Cases outside the supported contract stay visible as failures during work;
the denominator may not be reduced to manufacture a `Yes`. Bun differential fixtures are pinned to
the engineering revision where stable and engineering behavior differ.

## 8. SemVer and publication

This is new backward-compatible public functionality and therefore has SemVer impact `minor`.
Issue #5 assigns the exact `0.1.0-dev.N` candidate only when earlier release-bearing lanes have
landed; this branch must not guess or reserve a tag. Version files, ledger state, README, landing
page, release metadata, and installer defaults change only in the final release-bearing unit after
the implementation and evidence gates pass.

The `data.yaml` row may become `Yes` only when the complete pinned 402-case Bun-generated parser
corpus passes without exclusions and all four supported release targets execute that gate plus the
registered public/module fixtures successfully. No design completion, source-only unit test,
partial corpus, or Linux-only result is a public support claim.

## 9. Acceptance gate

Phase 31 is complete only when:

1. `make test-yaml-upstream-full` passes all 402 cases in the byte-pinned Bun-generated corpus, and
   `make compat FEATURE=data.yaml` passes the registered parse/stringify and module differential
   corpus through `build/clun`.
2. Serializer round trips, repeated-reference identity, supported cycles, duplicate-key policy,
   merge precedence, and block-scalar matrices pass.
3. Alias/merge bombs, depth/source/node/output limits, unsafe tags, malformed input, and invalid
   UTF-8 fail boundedly with catchable JavaScript errors.
4. `.yaml` and `.yml` default/named/namespace imports, CommonJS require, cache identity, and error
   eviction pass.
5. `make build`, `make test`, `make purity`, and `make docs-check` pass.
6. Any public-claim unit passes `make public-claims-check`, roadmap checks, and the exact
   `BASE_SHA=<base> HEAD_SHA=<head> make version-transition-check` required by issue #5.
7. Independent review confirms one parser, pure Common Lisp implementation, no host reader/eval,
   no native dependency, bounded graph work, and no unsupported compatibility claim.

## 10. Non-goals

Phase 31 does not add arbitrary object construction from tags, schema plug-ins, comment-preserving
round-trip editing, YAML AST mutation APIs, a general `Bun` namespace, a `bun` module, formatter
support, hot reload orchestration, or frontend bundling. Hot reload and bundler transforms require
their owning phases. This phase owns the runtime API and runtime data-module contract only.
