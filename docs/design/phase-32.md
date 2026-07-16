# Phase 32: Cookies and CookieMap

Status: acceptance candidate. It becomes accepted only after independent pinned-behavior,
architecture/security, and evidence review is recorded on issue #6.

## 1. Objective and boundary

Phase 32 converts web.cookies from No to an evidence-backed Yes by adding Clun.Cookie,
Clun.CookieMap, and server-request cookies. Cookie and CookieMap match the selected Bun
construction, parsing, serialization, mutation, descriptor, coercion, error, iteration, and JSON
contracts. The request getter exists only on requests delivered by the Phase 17 Clun.serve fetch
handler.

The canonical live source of truth is issue #6. It owns status, accepted decisions, four-target
receipts, SemVer disposition, release evidence, and closeout. Phase 17 and Phase 27 are the declared
dependencies.

This phase does not add a Bun global, browser cookie jar, document.cookie, the asynchronous Cookie
Store API, Phase 50 routes, browser storage policy, or a general claim that Clun implements every
HTTP cookie specification.

## 2. Frozen references and evidence priority

The phase uses two Bun references for distinct purposes:

| Role | Version/ref | Exact revision | Relevant paths |
| --- | --- | --- | --- |
| Public executable baseline | Bun 1.3.14 | 0d9b296af33f2b851fcbf4df3e9ec89751734ba4 | docs/runtime/cookies.mdx, packages/bun-types/bun.d.ts, packages/bun-types/serve.d.ts, src/jsc/bindings/Cookie.cpp, src/jsc/bindings/CookieMap.cpp, src/jsc/bindings/webcore/JSCookie.cpp, src/jsc/bindings/webcore/JSCookieMap.cpp, test/js/bun/cookie/ |
| Forward engineering inventory | Bun 1.4.0-dev | c1076ce95effb909bfe9f596919b5dba5567d550 | the stable paths plus src/runtime/webcore/CookieMap.rs, src/runtime/webcore/Request.rs, src/runtime/server/RequestContext.rs, src/jsc/bindings/JSBunRequest.cpp, test/js/bun/http/bun-serve-cookies.test.ts, test/js/bun/util/cookie.test.js, docs/runtime/http/cookies.mdx |

The pinned linux-x64-baseline archive has SHA-256
a063908ae08b7852ca10939bbdc6ceed3ddabce8fb9402dce83d65d73b36e6c7. The extracted stable
executable used as the survey oracle is
/home/glenda/Projects/clun/tmp-test/bun-1.3.14/bun-linux-x64/bun. It reports 1.3.14 and has
SHA-256 9fd36f87e4b90b07632b987a2e4ec81ca15a62c81bf983190cea6d715be2ad74. The other three
release-target archives remain pinned by compat/upstream-assets.tsv. The executable hash, rather
than its temporary extraction path, identifies the frozen observable oracle.

Evidence priority is:

1. observable results from the pinned Bun 1.3.14 executable;
2. stable public types, documentation, and tests at the exact stable revision;
3. engineering tests and implementation at the exact engineering revision;
4. independently derived RFC and security vectors; and
5. Clun-specific server integration and resource-bound tests.

No Bun source is copied. Fixtures record independently written inputs and observable outputs. The
read-only checkout at /home/glenda/Projects/bun is provenance, not an implementation dependency.

### 2.1 Stable, engineering, and Clun dispositions

The engineering revision contains corrections made after Bun 1.3.14. Phase 32 selects them
explicitly rather than accidentally mixing revisions:

| Behavior | Bun 1.3.14 | Engineering revision | Phase 32 |
| --- | --- | --- | --- |
| Expires serialization | noncanonical day/zone spelling | Date.toUTCString-compatible fixed UTC shape | use the engineering shape, with explicitly documented extended years |
| Expires plus Max-Age parse order | an Expires value can be discarded depending on order | both retained; Max-Age only controls isExpired precedence | use engineering behavior |
| Repeated valid attributes | inconsistent for some orderings | last valid occurrence wins | use engineering behavior |
| Request Cookie name decoding | percent-decodes names | preserves names literally; values remain forgiving-decoded | use engineering behavior |
| Delete of __Secure- or __Host- name | tombstone can omit Secure | case-insensitive prefix adds Secure | use engineering behavior |
| Record initializer order | hash-backed order can drift | JavaScript property order retained | use engineering behavior |
| Finite numeric expires outside Date's TimeClip range | unchecked conversion can create invalid/overflowed state | still lacks an explicit pre-conversion bound | reject with the numeric-expiration RangeError before conversion |
| Date grammar and year outside four-digit IMF-fixdate | zone-less general forms use host-local time; legacy formatter is noncanonical | Date.toUTCString-compatible extended year | use an explicit timezone grammar, treat only exact asctime as zone-less UTC, reject other zone-less forms, and use the exact extended-year spelling |

All other observed behavior follows the public baseline unless this document records a narrower
correctness or safety decision. In particular:

- constructor maxAge considers only an actual Number: NaN is the absent sentinel, positive and
  negative Infinity serialize as Max-Age=Infinity and Max-Age=-Infinity, and the getter preserves
  negative zero even though serialization spells it 0; the setter rejects non-finite coercions;
- creation and mutation do not enforce __Secure- or __Host- prefix invariants;
- Partitioned does not implicitly require Secure;
- CookieMap iterators remain live, including pinned repetition behavior after front-of-view
  mutation; and
- standalone Cookie and CookieMap inputs have no phase-specific fixed size cap.

Those are observable compatibility choices, not recommendations for browser cookie policy. Future
stricter behavior requires an explicit opt-in or a separately reviewed contract change.

The first six rows are forward engineering corrections selected over stable behavior. The final
two rows are Clun safety/determinism decisions: checked TimeClip conversion and host-independent
date parsing/extended-year formatting. Both require explicit issue #6 and DECISIONS.md records.

## 3. Exact public JavaScript contract

### 3.1 Clun namespace properties

Installation adds Cookie and then CookieMap as own data properties on the realm's existing Clun
object. Each is non-writable, enumerable, and non-configurable. Reinstalling the runtime reuses the
realm's constructor/prototype pair rather than replacing a non-configurable property or sharing
mutable state across realms.

### 3.2 Cookie constructor and descriptors

Cookie has name Cookie and length 2. Its name and length properties are non-writable,
non-enumerable, and configurable. Its prototype property is non-writable, non-enumerable, and
non-configurable. Calling it without new throws:

    TypeError: Use `new Cookie(...)` instead of `Cookie(...)`

Its static own properties appear after length, name, and prototype:

| Property | Function length | Writable | Enumerable | Configurable |
| --- | ---: | --- | --- | --- |
| parse | 1 | true | true | false |
| from | 3 | true | true | false |

Cookie.prototype own property order is exactly:

    constructor
    name
    value
    domain
    path
    expires
    maxAge
    secure
    httpOnly
    sameSite
    partitioned
    isExpired
    toString
    toJSON
    serialize
    Symbol.toStringTag

The constructor property is writable, non-enumerable, and configurable. Every string-named Cookie
accessor and method is enumerable and configurable. Methods are writable and have length 0. name is
getter-only; mutable properties have a getter and setter. Symbol.toStringTag is the non-writable,
non-enumerable, configurable value Cookie. Object.prototype.toString therefore returns
[object Cookie].

### 3.3 CookieMap constructor and descriptors

CookieMap has name CookieMap and length 1. Its name, length, and prototype descriptors match
Cookie's constructor descriptors. Calling it without new throws the corresponding error:

    TypeError: Use `new CookieMap(...)` instead of `CookieMap(...)`

CookieMap.prototype own property order is exactly:

    constructor
    get
    toSetCookieHeaders
    has
    set
    delete
    entries
    keys
    values
    forEach
    toJSON
    size
    Symbol.iterator
    Symbol.toStringTag

Method lengths are:

| Method | Length |
| --- | ---: |
| get | 1 |
| toSetCookieHeaders | 0 |
| has | 1 |
| set | 2 |
| delete | 1 |
| entries | 0 |
| keys | 0 |
| values | 0 |
| forEach | 1 |
| toJSON | 0 |

The constructor property is writable, non-enumerable, and configurable. All string-named methods
are writable, enumerable, and configurable. size is an enumerable, non-configurable getter without
a setter. Symbol.iterator is writable, non-enumerable, configurable, and is the same function
object as entries. Symbol.toStringTag is the non-writable, non-enumerable, configurable value
CookieMap.

CookieMap iterators return themselves from Symbol.iterator and report [object CookieMap Iterator].
Their prototype exposes an enumerable, writable, configurable next method. Wrong receivers throw
TypeError rather than exposing a Common Lisp condition. Where Bun attaches ERR_INVALID_THIS, Clun
attaches the same code.

### 3.4 Cookie overloads and defaults

The accepted forms are:

    new Clun.Cookie(name, value, options?)
    new Clun.Cookie(cookieHeaderString)
    new Clun.Cookie(cookieInitObject)
    Clun.Cookie.parse(cookieHeaderString)
    Clun.Cookie.from(name, value, options?)

Only an actual primitive string in the one-argument constructor selects header parsing. An object
selects CookieInit member access. A missing argument throws Not enough arguments. A missing or empty
CookieInit name throws name is required.

The positional constructor accepts an options object, null, or undefined. Any other primitive
third argument throws Options must be an object; null and undefined select defaults. Cookie.from
ignores every primitive third argument, matching the pinned executable.
Cookie.parse always applies the complete cookie-header contract below.

Cookie and CookieMap intentionally ignore newTarget when allocating. Reflect.construct with a
different newTarget and construction through a JavaScript subclass return a base branded instance
whose immediate prototype is Cookie.prototype or CookieMap.prototype, respectively. The result is
not an instance of the subclass. This pinned behavior is covered directly rather than accidentally
using an ordinary derived-constructor allocation path.

Every Cookie has this observable default state:

| Property | Default |
| --- | --- |
| name | required string |
| value | required string |
| domain | null |
| path | / |
| expires | undefined |
| maxAge | undefined |
| secure | false |
| httpOnly | false |
| sameSite | lax |
| partitioned | false |

name is immutable after construction. Sloppy assignment is ignored; strict assignment throws the
normal getter-only property TypeError.

toString and serialize return the same full Set-Cookie serialization. isExpired returns a boolean.
toJSON returns a new null-prototype object with this exact conditional key order:

    name, value, [domain], path, [expires], [maxAge],
    secure, sameSite, httpOnly, partitioned

domain distinguishes absence from an explicit empty string. Omitted, null, or undefined domain
produces a null getter. An explicitly supplied or assigned empty string produces an empty-string
getter, but serialization omits Domain and toJSON omits the domain key for both null and empty.
Directly assigning null performs ToUSVString and therefore stores "null", which is emitted.

Absent expires and maxAge keys are omitted from toJSON. A present toJSON expires value is always a
fresh branded Date representing the stored millisecond instant; it never reuses the expires getter
cache.

The expires getter caches one Date only while that Date's internal [[DateValue]] still equals the
stored expiry. Mutating the returned Date to a different millisecond value causes the next getter
to return a fresh Date restored to the stored expiry. Mutating it to the same value preserves
identity. Every successful expires assignment invalidates the cache even when it assigns the same
instant, so the next getter returns a fresh object.

### 3.5 CookieInit lookup and abrupt completion

For the object constructor and CookieMap.set(object), members are read and immediately converted or
validated in this exact order:

1. name with ToUSVString; stop with name is required when empty;
2. value with ToUSVString when present, otherwise the empty string; an explicitly present
   undefined value becomes the string undefined;
3. domain with ToUSVString;
4. path with ToUSVString;
5. expires with the expiration rules below;
6. maxAge, accepted only when the value is an actual JavaScript Number;
7. secure with ToBoolean;
8. httpOnly with ToBoolean;
9. partitioned with ToBoolean; and
10. sameSite with ToUSVString and validation.

The positional constructor converts positional name and value first, then reads only domain through
sameSite from options in the same order. It does not read options.name or options.value.

Each getter executes at most once. Getter, conversion, or validation failure propagates immediately
and prevents every later getter. ToUSVString replaces lone UTF-16 surrogates with U+FFFD. Boolean
conversion follows JavaScript ToBoolean and invokes no user coercion hook.

For constructor options, null or undefined domain and path mean absent/default rather than the
strings null or undefined. Direct domain and path setters perform ToUSVString, so null becomes
"null".

### 3.6 Expiration, Max-Age, and SameSite

expires accepts undefined or null to clear it, a branded Date with a valid internal [[DateValue]],
a finite Number interpreted as epoch seconds, or a string parsed as an HTTP date. Date detection is
an internal runtime brand check: it reads the internal numeric value directly and never gets or
calls a user-visible getTime property. Date subclasses retain the Date brand; a plain lookalike,
Object.create(Date.prototype), and a Proxy around a Date do not. Rejected lookalikes cannot run a
getTime getter as a side effect.

The accepted millisecond range is JavaScript TimeClip's inclusive
[-8640000000000000, 8640000000000000]. A branded Date with NaN internal value throws RangeError
with expires must be a valid Date (or Number). Numeric seconds must be finite; multiplication by
1000 must remain inside the same inclusive millisecond range before conversion. Non-finite or
out-of-range numeric input throws RangeError with expires must be a valid Number (or Date).
Fractional milliseconds are truncated toward zero only after the range check; negative values and
both exact endpoints are accepted. This explicit check avoids the pinned implementation's
unchecked floating-to-integer overflow.

A string is converted with ToUSVString, parsed as an HTTP date, and accepted only when its resulting
milliseconds are finite and inside the same range. An invalid or out-of-range date string throws
TypeError with Invalid cookie expiration date. Every other type throws TypeError with
ERR_INVALID_ARG_VALUE.

The constructor's maxAge member is considered only when it is an actual Number; a numeric string is
treated as absent. NaN selects absence. Positive/negative Infinity and negative zero are stored,
and the getter preserves them. toJSON includes stored infinities as Numbers, so JSON.stringify of
that result applies ordinary Infinity-to-null behavior. The direct setter applies IDLDouble
coercion: null or undefined clears it, coercible strings become numbers, negative zero remains
negative zero, and a non-finite result throws TypeError with The provided value is non-finite.

isExpired returns maxAge <= 0 when maxAge exists. Otherwise, when expires exists, it performs the
engineering comparison currentTimeMilliseconds > expiresMilliseconds, and otherwise returns
false. Equality is not expired and one millisecond after is expired. A positive Max-Age therefore
overrides a past Expires value and remains not expired rather than counting down from construction.
Injected-clock tests freeze the equality boundary.

The constructor accepts only lowercase strict, lax, and none for sameSite. The setter and header
parser accept them case-insensitively and expose lowercase. Any other present value throws:

    Invalid sameSite value. Must be 'strict', 'lax', or 'none'

secure, httpOnly, and partitioned use ToBoolean through JavaScript properties or CookieInit.

### 3.7 Error contract

The stable executable freezes at least these argument-boundary errors:

| Operation | Error message | Code when present |
| --- | --- | --- |
| call Cookie without new | Use `new Cookie(...)` instead of `Cookie(...)` | ERR_ILLEGAL_CONSTRUCTOR |
| call CookieMap without new | Use `new CookieMap(...)` instead of `CookieMap(...)` | ERR_ILLEGAL_CONSTRUCTOR |
| new Cookie() | Not enough arguments | ERR_MISSING_ARGS |
| new Cookie(one non-string primitive) | Not enough arguments | ERR_MISSING_ARGS |
| new Cookie("") | Invalid cookie string: empty | none |
| Cookie.parse("") | Invalid cookie name: contains invalid characters | none |
| CookieInit without name | name is required | none |
| Cookie.from with fewer than two arguments | Not enough arguments | ERR_MISSING_ARGS |
| positional options other than object/null/undefined | Options must be an object | none |
| invalid sameSite | Invalid sameSite value. Must be 'strict', 'lax', or 'none' | none |
| invalid expiration string | Invalid cookie expiration date | none |
| invalid CookieMap initializer primitive | Invalid initializer type | none |
| pair-array element is not an Array | Expected each element to be an array of two strings | none |
| pair Array has the wrong length | Expected arrays of exactly two strings | none |
| Cookie wrong receiver | Can only call Cookie.<member> on instances of Cookie | ERR_INVALID_THIS |
| CookieMap wrong receiver | Can only call CookieMap.<member> on instances of CookieMap | ERR_INVALID_THIS |
| CookieMap.set with one primitive | Not enough arguments | ERR_MISSING_ARGS |
| CookieMap.delete with explicit undefined/null/non-string | Cookie name is required | none |

Zero arguments are not normalized to one explicit undefined argument. CookieMap.get(), has(),
set(), and delete() return null, false, undefined, and undefined respectively without mutation.
Fixtures contrast each with explicit undefined and null. Constructor calls without new retain
ERR_ILLEGAL_CONSTRUCTOR.

Invalid Date and non-finite numeric expires values use Bun's RangeError spelling. Invalid other
expires types use the pinned ERR_INVALID_ARG_VALUE TypeError spelling. The differential fixture
freezes complete name, message, code, and error-class observations for every public overload; this
table is not permission to normalize unlisted errors.

## 4. Parsing, mutation, and server lifecycle

### 4.1 Validation and serialization

Cookie name validation is equivalent to:

    ^[\u0021-\u003A\u003C\u003E-\u007E]+$

It excludes the empty string, semicolon, equals, controls, space, and non-ASCII characters. Cookie
path validation is equivalent to:

    ^[\u0020-\u003A\u003D-\u007E]*$

It excludes semicolon, less-than, controls, and non-ASCII characters. Programmatic paths need not
begin with slash. Domain validation accepts only lowercase ASCII letters, digits, dot, and hyphen.
It intentionally does not perform complete DNS, public-suffix, or host/domain policy validation.

Failures use:

    Invalid cookie name: contains invalid characters
    Invalid cookie path: contains invalid characters
    Invalid cookie domain: contains invalid characters

Serialization emits attributes in this exact order:

    name=encoded-value
    Domain=...
    Path=...
    Expires=...
    Max-Age=...
    Secure
    HttpOnly
    Partitioned
    SameSite=...

Attributes are separated by semicolon plus one ASCII space. SameSite is always emitted, including
the default SameSite=Lax. Domain is emitted only when present and nonempty; path is emitted whenever
its stored value is nonempty. SameSite uses Strict, Lax, or None title casing.

The value uses the exact encodeURIComponent pass-through set:

    A-Z a-z 0-9 - _ . ! ~ * ' ( )

Every other scalar is replacement-mode UTF-8 encoded and every resulting byte is emitted as a
percent sign plus two uppercase hexadecimal digits. Spaces, semicolons, plus, percent, and
non-ASCII bytes are therefore encoded. Name, domain, and path are validated rather than
percent-encoded. Fixtures exhaust every ASCII byte plus BMP, astral, and lone-surrogate input.

For years 0000 through 9999, Expires uses the engineering formatter's fixed shape:

    Thu, 01 Jan 1970 00:00:00 GMT

Years outside that interval cannot be IMF-fixdate and use an explicit extended
Date.prototype.toUTCString-compatible spelling. A positive year above 9999 is unprefixed decimal;
a negative year has a minus sign and at least four absolute digits. Examples are:

    Sat, 01 Jan 10000 00:00:00 GMT
    Sat, 13 Sep 275760 00:00:00 GMT
    Fri, 01 Jan -0001 00:00:00 GMT
    Tue, 20 Apr -271821 00:00:00 GMT

The weekday is derived from the same internal UTC instant, day is always two digits, milliseconds
are omitted, and neither host locale nor timezone is consulted. Documentation calls only the
four-digit form IMF-fixdate.

Max-Age uses the pinned JSC Number spelling: negative zero emits 0, both infinities include their
sign, fractions remain fractional, and large/small exponent forms retain e notation.

### 4.2 Cookie.parse

The direct cookie-string wrapper first requires a valid HTTP field value. It rejects leading or
trailing whitespace, CR, LF, NUL, and code points outside the pinned HTTP-header domain.
Observable obs-text accepted by the stable executable remains accepted; general non-Latin-1
Unicode is rejected. This validation occurs before cookie parsing.

Parsing then:

1. finds the first semicolon and treats the preceding text as the name/value pair;
2. requires an equals sign in that pair and splits only at its first occurrence;
3. trims ASCII space and tab around the name and value;
4. validates the name;
5. stores the value literally without percent decoding; and
6. parses remaining semicolon-separated attributes case-insensitively.

Cookie.parse("") reaches name validation and fails with Invalid cookie name: contains invalid
characters, while new Cookie("") fails earlier with Invalid cookie string: empty. The pinned fast
path reports Invalid cookie string: empty only for the one-character no-equals spelling a; longer
no-equals strings report Invalid cookie string: no '=' found. A leading semicolon reports empty,
while a nonempty name segment before a semicolon reports no '=' found. The bare equals spelling =
reports empty, while = followed by any other byte reports Invalid cookie string: name cannot be
empty. A zero-argument call reports Not enough arguments with ERR_MISSING_ARGS. Invalid HTTP field
values report the pinned lowercase spelling cookie string is not a valid HTTP header value.
Fixtures freeze these distinctions. Re-serializing an input value containing percent encodes the
percent again.

Attribute behavior is:

| Attribute | Parse rule |
| --- | --- |
| Domain | trim and lowercase; ignore empty; every nonempty occurrence replaces the candidate, which is validated once after all attributes |
| Path | accept a nonempty value only when it begins with slash and passes path validation; otherwise retain the previous/default value |
| Expires | parse an HTTP date; retain the last valid occurrence and ignore invalid occurrences |
| Max-Age | parse the pinned signed-integer prefix; retain the last valid occurrence and ignore invalid occurrences |
| Secure | true by presence |
| HttpOnly | true by presence |
| Partitioned | true by presence |
| SameSite | accept strict/lax/none case-insensitively; retain the last valid occurrence |
| unknown | ignore |

Repeated valid attributes use the last valid occurrence. Invalid Path, Expires, Max-Age, and
SameSite occurrences are ignored and do not erase an earlier valid value. Domain is intentionally
different: an invalid nonempty later Domain replaces an earlier candidate and final Cookie
validation throws Invalid cookie domain: contains invalid characters. A later valid Domain can
replace an earlier invalid candidate before that final validation. Expires and Max-Age are both
retained; section 3.6 defines expiration precedence.

### 4.2.1 Accepted HTTP-date grammar

The pure Common Lisp parser is table-driven and accepts exactly these ASCII, case-insensitive
families:

    IMF:      Wdy, DD Mon YYYY HH:MM:SS GMT
    RFC850:   Weekday, DD-Mon-YY HH:MM:SS GMT
    asctime:  Wdy SP Mon SP (SP DIGIT | 2DIGIT) SP HH:MM:SS SP YYYY
    DMY:      [Wdy[,]] D[D] (SP|-) Mon (SP|-) (YY|YYYY) HH:MM:SS zone
    MDY:      [Wdy] Mon D[D] YYYY HH:MM:SS zone
    numeric:  MM/DD/YYYY HH:MM:SS zone

Wdy is an English three-letter weekday, Weekday is its full English spelling, and Mon is an
English three-letter month. A supplied weekday is syntax only; a mismatch does not change or
invalidate the date, matching the pinned parser. DD/MM fields are range-checked and the Gregorian
calendar, including leap years, must be valid. Hours are 00-23 and minutes/seconds are 00-59.
ASCII space or tab may replace an indicated SP and one or more are collapsed between tokens; no
other Unicode whitespace is accepted.

YY maps 00-49 to 2000-2049 and 50-99 to 1950-1999. A long year is four to six decimal digits, or a
minus sign followed by four to six digits, and the resulting instant must satisfy the TimeClip
range. Three-digit years, a leading plus, fractional seconds, leap-second 60, and trailing junk are
rejected.

The zone terminal is mandatory for DMY, MDY, and numeric forms. It accepts GMT, UTC, UT, Z,
numeric +HHMM/-HHMM or +HH:MM/-HH:MM offsets, and this fixed abbreviation table:

| Zone | UTC offset |
| --- | ---: |
| EST | -05:00 |
| EDT | -04:00 |
| CST | -06:00 |
| CDT | -05:00 |
| MST | -07:00 |
| MDT | -06:00 |
| PST | -08:00 |
| PDT | -07:00 |

Numeric hours are 00-23 and minutes 00-59. Offset application follows ISO sign semantics: local
08:00 at -0500 is 13:00 UTC. Unknown names reject.

The exact asctime family is the only accepted zone-less form and is interpreted as UTC. Every
other zone-less spelling is rejected rather than inheriting the host timezone, even though pinned
Bun accepts some of them using local time. This is the recorded cross-platform determinism
decision. IMF/RFC850 require GMT exactly; the broader explicit zones are available only through
the DMY/MDY/numeric families.

Direct expires strings use this grammar and throw on failure. Invalid Expires attributes are
ignored under section 4.2's attribute rules. Serialization always emits the selected four-digit or
extended UTC shape from section 4.1.

### 4.2.2 Max-Age decimal-prefix parsing

After semicolon splitting, the Max-Age attribute value is trimmed of ASCII space and tab. Parsing
then:

1. consumes at most one leading plus or minus sign;
2. requires at least one ASCII decimal digit after that sign;
3. consumes the maximal decimal digit prefix and ignores every remaining character;
4. accumulates with checked signed 64-bit arithmetic, including the sign; and
5. treats overflow outside [-9223372036854775808, 9223372036854775807] as invalid.

An invalid occurrence is ignored and retains the previous valid Max-Age, or absence when there was
none. The integer zero has no negative-zero state. A valid signed i64 is converted to an IEEE-754
JavaScript Number with round-to-nearest behavior; the getter and serializer therefore expose the
rounded Number and its pinned JSC spelling rather than the original decimal token.

Frozen boundaries include:

| Attribute text | Observable result |
| --- | --- |
| +0012junk | 12 |
| 12 34 | 12 |
| 1.9 | 1 |
| +, -, empty, x1 | invalid; retain prior |
| 9007199254740993 | 9007199254740992 |
| 9223372036854775807 | 9223372036854776000 |
| 9223372036854775808 | invalid; retain prior |
| -9223372036854775808 | -9223372036854776000 |
| -9223372036854775809 | invalid; retain prior |

Fixtures put internally padded values before another attribute so the cookie-header wrapper's
whole-string trailing-whitespace rejection is tested separately. They cover every sign/digit
transition, both i64 boundaries, one beyond each, 2^53 rounding neighbors, trailing punctuation,
and a valid-then-invalid repeated sequence.

### 4.3 CookieMap initialization

The accepted forms are:

    new Clun.CookieMap()
    new Clun.CookieMap(undefined)
    new Clun.CookieMap(null)
    new Clun.CookieMap(cookieHeaderString)
    new Clun.CookieMap(arrayOfPairs)
    new Clun.CookieMap(record)

undefined, null, and an empty string create an empty map. Any other primitive initializer throws
Invalid initializer type.

String initialization splits on semicolons. Each segment is split at the first equals sign and
ASCII space/tab is trimmed around the name and value. Segments without equals or with an empty name
are skipped; empty values are retained. Duplicates remain separate and ordered.

Cookie names are literal and are never percent-decoded. This prevents an encoded spelling from
acquiring __Host- or __Secure- semantics after parsing.

### 4.3.1 Forgiving percent and UTF-8 decoding

Value decoding never throws URIError. It freezes Bun 1.3.14's byte scanner, including its
non-ASCII literal behavior; it is not described as a generic WHATWG decoder.

CookieMap computes one has-any-percent result over the complete Cookie header string before it
splits or filters any pairs. With no percent sign anywhere, every retained value is copied as its
original JavaScript string, including raw non-ASCII and lone surrogates. With a percent sign
anywhere, including in a name or a segment that is later skipped, every retained value is converted
to replacement-mode UTF-8 bytes and sent through the decoder, including values that contain no
percent themselves. In that mode, literal ASCII bytes append normally and every literal non-ASCII
UTF-8 byte appends as the same-valued U+00XX code point. Thus raw e-acute becomes U+00C3 U+00A9,
and a replaced lone surrogate's EF BF BD bytes become U+00EF U+00BF U+00BD.

A percent sign starts this byte scanner:

1. with fewer than two following bytes, append U+FFFD, consume only the percent byte, and process
   the remaining byte normally;
2. with two following bytes where either is not an ASCII hex digit, append U+FFFD and consume
   percent plus both bytes;
3. a valid %HH in 00-7F appends that ASCII code unit, including NUL, and consumes one triplet;
4. a valid %HH whose byte has two, three, or four leading one bits starts a candidate of that many
   bytes and requires the rest as immediately adjacent valid continuation %HH triplets;
5. any other non-ASCII %HH cannot start a candidate, consumes its one triplet, and emits U+FFFD;
6. scalar validation rejects overlong forms, surrogate scalars, and values above U+10FFFF; and
7. a valid scalar appends one UTF-16 code unit or surrogate pair.

Replacement consumption is exact. A malformed, missing, or non-continuation triplet encountered
while completing a multibyte candidate emits one U+FFFD for the candidate and leaves the offending
triplet/literal bytes to be processed again. Successfully consumed prefix triplets remain consumed.
A non-candidate byte consumes its triplet and emits one U+FFFD. A two-to-four-byte candidate whose
triplets were all consumed but whose scalar is overlong, a surrogate, or out of range emits one
U+FFFD for the whole candidate. Consequently C0 AF is one rejected overlong candidate, while F8
and each following continuation triplet are separate non-candidate bytes.

The frozen malformed matrix is:

| Input value | Decoded value |
| --- | --- |
| %41 | A |
| %20 | one space |
| + | + |
| % | U+FFFD |
| %1 | U+FFFD followed by 1 |
| %ZZ, %G1, or %Z1 | U+FFFD |
| %C2%A2 | U+00A2 |
| %E2%82%AC | U+20AC |
| %F0%9F%98%80 | U+1F600 |
| %80 | U+FFFD |
| %C0%AF, %E0%80%AF, %ED%A0%80, %F4%90%80%80 | one U+FFFD |
| %F8%80%80%80%80 | five U+FFFD code points |
| %C2x | U+FFFD followed by x |
| %C2%41 | U+FFFD followed by A |
| %C2%ZZ | two U+FFFD code points |
| %E2%82 or %E2%82x | U+FFFD, optionally followed by x |
| %E2%28%A1 | U+FFFD, (, U+FFFD |
| %F0%9F%92 | one U+FFFD |
| %41x%E2%82%AC | Ax followed by U+20AC |
| e-acute followed by %80 | U+00C3, U+00A9, U+FFFD |

The corpus also exhausts all 256 first-byte triplets, every truncation point for two/three/four-byte
sequences, continuation boundaries, overlong boundaries, surrogate edges, U+10FFFF/U+110000, mixed
literal/encoded text, encoded NUL, raw BMP/astral text, raw lone surrogates, and the header-global
percent switch where a percent in one pair changes non-ASCII literal handling in another.

For pair-array initialization, the outer value and every element must be real JavaScript Arrays.
Each element has exactly two slots. The first value is converted with ToString before the second;
holes become the string undefined. Conversion errors propagate immediately. Invalid entries throw:

    Expected each element to be an array of two strings
    Expected arrays of exactly two strings

A Proxy is never unwrapped or enumerated by the pinned CookieMap initializer. Proxy(array),
Proxy(record), Proxy(function), and a revoked Proxy are all accepted as empty initializers. No
ownKeys, getOwnPropertyDescriptor, or get trap runs. This is a CookieMap dispatch rule only; normal
ECMAScript Proxy internal methods remain observable everywhere else.

Record initialization visits own string property names in JavaScript property order, including
non-enumerable names and excluding Symbols. Integer-index names precede other string names. For
each name, the property getter and ToString conversion complete before the next name. A Common Lisp
hash table must not become observable iteration order.

### 4.4 Lookup, mutation, and JSON

The logical state contains ordered original request pairs and ordered modified Cookie records.
Modified effective entries are observed before untouched originals.

get(name) and has(name) convert a supplied key with IDL USVString, including lone-surrogate
replacement. With zero arguments, get returns null and has returns false without conversion.
Explicit undefined and null are supplied values and become the strings "undefined" and "null";
they are not the zero-argument case. get returns the first effective value or null; has returns a
boolean. An original empty value is effective: get returns the empty string, has returns true, it
counts in size, and it appears in iteration. Duplicate originals remain visible to iteration even
though get and has observe the first value.

set supports:

    map.set(name, value, options?)
    map.set(cookie)
    map.set(cookieInitObject)

A zero-argument set returns undefined without mutation. A one-argument primitive, including
explicit undefined or null, throws Not enough arguments with ERR_MISSING_ARGS. Positional name and
value use ToUSVString, followed by Cookie options. The object overload uses the exact CookieInit
lookup order in section 3.5. Passing an existing Cookie retains that object by reference, so later
Cookie mutation changes map output.

set removes every same-name original and previous modification, appends one modified Cookie, and
returns undefined. A modified Cookie with an empty value is absent from get, has, iteration, size,
and toJSON but remains in the response mutation log and therefore emits Set-Cookie.

delete supports a string name with optional domain/path options and an object with name, domain, and
path. With zero arguments it returns undefined without mutation. Explicit undefined, null, or a
non-string primitive throws Cookie name is required. An object form is accepted only when its
name member is an actual primitive string; a missing or non-string member also throws Cookie name
is required rather than coercing it. Any present positional second argument must be an object;
even explicit undefined or null throws Options must be an object.

Object deletion reads name, domain, and path in that exact order; positional deletion validates its
name before reading options.domain and then options.path. null or undefined domain is omitted.
null or undefined path selects "/", while every other domain/path value receives IDL USVString
conversion and validation. A getter, conversion, or validation error stops before every later
member and before mutation.

A successful delete removes every same-name original and prior modification, then appends exactly
one tombstone, including for a nonexistent name:

    name=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; SameSite=Lax

An explicitly empty path omits Path. Tombstones emit Domain only when domain is both present and
nonempty; null, undefined, omitted, and explicit empty string all omit it. A name beginning
case-insensitively with __Secure- or __Host- adds Secure. get, has, size, iteration, and toJSON then
show the name as absent, while toSetCookieHeaders contains the one final tombstone. delete returns
undefined.

The mutation log coalesces by name: each set or delete removes an earlier modification for that name
and appends the final one. Therefore set x, delete x, set x produces one final Set-Cookie field.
toSetCookieHeaders serializes this ordered mutation-only view and returns a fresh JavaScript Array
on every call. Unchanged original request cookies never appear in it.

size counts remaining originals, including duplicate and empty-valued originals, plus nonempty
modified entries. toJSON returns a normal Object-prototype object in effective order, with the
first value for a duplicate key. Original empty values remain visible; only an empty modified
Cookie has deletion semantics. Properties are created as own data properties, including __proto__,
rather than assigned through the prototype setter.

### 4.5 Iteration and forEach

entries, keys, values, Symbol.iterator, and forEach enumerate effective modified entries first and
then untouched originals. Duplicate originals are retained. Empty modified values and removed
originals are skipped.

forEach invokes callback(value, key, map), honors the optional second thisArg despite its reported
length of 1, and returns undefined. Callback and iterator exceptions propagate normally.

Iterators are live rather than snapshots. Their cursor indexes the current effective concatenated
view. Mutating the front can therefore repeat an entry already returned. The frozen regression is:

1. begin with original a and b;
2. consume a from an iterator;
3. set c; and
4. observe a, then b, then done from that iterator while a fresh map view is c, a, b.

Deletion of originals during iteration receives equivalent live-view coverage. The implementation
may use indices and tombstones internally, but it must preserve these observations and avoid
unbounded recursion.

### 4.6 Headers and HTTP transport corrections

Phase 17's accepted design requires Set-Cookie to remain distinct, but the current implementation
comma-collapses duplicate fields. Phase 32 repairs the transport representation rather than
post-processing a comma-joined string.

Required behavior is:

- duplicate Cookie values combine with semicolon plus one space. This applies at the Headers level,
  so new Headers([["cookie", "a=1"], ["cookie", "b=2"]]).get("cookie") is a=1; b=2 and its
  entries view contains one ["cookie", "a=1; b=2"] pair;
- raw duplicate request Cookie fields use that same Headers behavior;
- ordinary duplicate fields combine with comma plus one space;
- every response Set-Cookie value remains an independent ordered field on the wire;
- Headers.get("set-cookie") returns the pinned comma-plus-space joined view;
- Headers.getAll("set-cookie") and Headers.getSetCookie() return fresh arrays preserving individual
  values and order;
- Headers.entries, keys, values, and forEach expose every Set-Cookie value as a distinct repeated
  entry instead of the get() joined spelling. Non-Set-Cookie names are sorted and merged first;
  Set-Cookie entries follow them in insertion order. forEach receives
  (value, "set-cookie", headers) once per field;
- Headers.getAll has length 1 and throws TypeError with Only "set-cookie" is supported. for any
  other name;
- Headers.getSetCookie has length 0; and
- both new methods are writable, enumerable, and configurable.

HeadersInit conversion follows the pinned two-phase Bun ordering. For a sequence initializer, the
outer iterator is consumed completely before any pair cardinality or HTTP name/value validation.
Each yielded inner iterator is itself consumed completely, with ToString applied to every element
as it is yielded. Abrupt conversion closes each still-live inner/outer iterator, while an iterator
whose next method throws is already terminal and is not closed again. Only after complete
materialization are rows checked in order for exactly two items and then validated and appended.
For a record initializer, the own-key list is snapshotted once; each string key's current descriptor
is rechecked, and every currently enumerable value is read and converted before any key/value is
validated or appended. Symbols and non-enumerable or subsequently deleted properties are skipped.
Headers entries/keys/values iterators and forEach use a live recomputed view, and an iterator stays
terminal after it first reports done.

The incremental request parser retains enough ordered information to implement Cookie's special
combination without losing framing or size accounting. Response, fetch, and serve carry ordered
header pairs instead of converting through a plain object or universally merged alist.

Constructed Headers, parsed Request.headers, Response headers, Clun.serve serialization, and
Phase 18 fetch responses share this exact model. A fetch regression server returns at least two
Set-Cookie lines and proves get, getAll, getSetCookie, entries, keys, values, and forEach preserve
the selected joined-versus-distinct views without a plain-object overwrite.

### 4.6.1 Framing repairs required by ordered raw headers

Replacing early comma collapse must not weaken HTTP/1.1 request framing:

- the configured 16 KiB maximum applies to the complete header section through CRLFCRLF, whether
  the terminator arrives in the first feed or across feeds;
- finding CRLFCRLF in one oversized feed cannot bypass the limit; it returns 431 and closes;
- every Content-Length field and comma-list member is parsed as an unsigned decimal. Multiple
  values are accepted only when all are identical; malformed or conflicting values return 400;
- any simultaneous Transfer-Encoding and Content-Length returns 400;
- Transfer-Encoding is accepted only as one field whose normalized value is exactly chunked.
  Duplicate Transfer-Encoding fields, repeated/comma-list chunked, unsupported coding, or a coding
  before/after chunked returns 400;
- duplicate Connection fields are tokenized across every field in wire order. close dominates
  keep-alive; HTTP/1.0 keep-alive applies only when requested and close is absent;
- Cookie combination occurs only after framing headers pass these checks; and
- a framing or limit error consumes no pipelined successor request and never dispatches JavaScript.

Raw parser/server tests send every critical request both in one write and split across the
terminator, duplicate-header, and body boundary. They cover exact-limit and one-byte-over headers,
identical/conflicting Content-Length, Transfer-Encoding plus Content-Length, duplicate
Transfer-Encoding, duplicate Connection with close/keep-alive conflicts, duplicate Cookie, and a
valid pipelined successor. One-feed and split-feed classification and status must agree.

### 4.6.2 Header validation before storage and serialization

All shared Headers entry points validate the converted name and value before changing the ordered
store:

- a name must be a nonempty ASCII HTTP token using letters, digits, and
  !#$%&'*+-.^_`|~ only, then is lowercased;
- a value uses the pinned ByteString boundary: every code unit must be at most U+00FF;
- NUL, CR, and LF are rejected anywhere in a value;
- every other ByteString code unit, including HTAB, other C0 controls, DEL, and obs-text, is
  accepted;
- only after validation may leading/trailing ASCII space and tab be trimmed; and
- no path strips, replaces, folds, or silently deletes an invalid character.

Headers itself is a branded runtime subtype with a private ordered store and a shared realm-local
Headers.prototype. Prototype methods always use and brand-check their this receiver; they do not
close over the object that originally exposed the method. Borrowing h1.get onto branded h2 reads
h2's store, while a plain or prototype-spoofed receiver throws. %coerce-headers-init recognizes
another Headers only by this unforgeable brand, never by a %store% property or other marker.
Reflect.ownKeys on a fresh Headers exposes no transport state, and delete, assignment, or
Object.defineProperty cannot detach, replace, or forge the store read by JavaScript and the CL
serializer.

The Headers constructor gains one canonical own prototype property that is non-writable,
non-enumerable, and non-configurable. Headers.prototype.constructor points back with
writable=true, enumerable=false, configurable=true. Every new Headers instance inherits that
prototype and is instanceof Headers.

The fixture exhausts the Latin-1 control boundaries and includes U+0100, astral input, NUL, CR, LF,
and CRLF.

The rule applies uniformly to:

- new Headers from pairs, records, or another Headers;
- Headers.set and Headers.append;
- Request and Response constructor header initialization;
- Response statusText, which uses the same ByteString plus NUL/CR/LF rejection before storage;
- Headers produced by the HTTP parser or fetch; and
- manual ordinary and Set-Cookie response fields.

The raw request parser applies the corresponding byte-level name/value rules before constructing
Headers. Invalid names, NUL, bare CR/LF, or malformed lines return 400 and never reach JavaScript;
obs-text bytes remain byte-preserving.

Every operation completes all conversion and validation needed for its one mutation before
removing or appending stored values. A failing set/append/constructor leaves the preexisting store
unchanged and throws the pinned TypeError.

The current %hdr-trim helper that trims CR/LF and the serve-layer %strip-crlf sanitizer are removed.
OWS trimming is a separate space/tab-only operation after validation. Invalid status text, name, or
value is rejected, never transformed into a different valid-looking field.

Before writing a response status line or any header bytes, Clun.serve builds and validates the
complete request-local header block, including automatic cookie fields. Invalid stored data is an
internal invariant failure: it does not get trimmed or partially serialized. The server selects a
clean default 500 response, or closes if a clean response cannot be produced, without emitting a
partial attacker-controlled response.

Regression tests inject CR, LF, CRLF, and NUL through Headers construction, set, append, Response
initialization, manual Set-Cookie, and ordinary manual headers. They assert the JavaScript error,
unchanged stores, zero injected wire fields, and no partial response.

### 4.7 Server-request prototype and response lifecycle

Bun's stable route request exposes cookies only on BunRequest inside routes; its ordinary fetch
Request does not. Clun does not gain routes until Phase 50. Phase 32 deliberately maps the same
observable lifecycle onto a dedicated Clun.serve request subtype. It does not add cookies to the
realm's global Request.prototype. Differential server fixtures use a small Bun routes adapter and a
Clun fetch adapter, then compare shared observable results rather than requiring identical source.

The current native Request constructor has no own prototype property at all, while %make-request
uses a separately cached, observable %RequestProto% object on the global. Phase 32 repairs that
missing canonical constructor/instance wiring before adding cookies:

1. installation creates one canonical realm-local Request.prototype;
2. the global Request constructor gains a non-writable, non-enumerable, non-configurable own
   prototype property pointing to that exact object, whose constructor property points back with
   writable=true, enumerable=false, configurable=true;
3. standalone new Request(...) and non-server internal request construction inherit that exact
   object;
4. one realm-local server-request prototype inherits the canonical Request.prototype; and
5. only %make-server-request, used by Clun.serve dispatch, creates a branded instance on the
   server-request prototype.

The server-request prototype owns the cookies accessor:

| Attribute | Value |
| --- | --- |
| getter name | get cookies |
| getter length | 0 |
| setter | absent |
| enumerable | true |
| configurable | false |

Its complete own-key list is ["cookies"]; it has no constructor or state property. The descriptor
returned by Object.getOwnPropertyDescriptor(serverRequestPrototype, "cookies") is the exact
accessor above.

For a freshly delivered server request:

    Object.getPrototypeOf(request) === serverRequestPrototype
    Object.getPrototypeOf(serverRequestPrototype) === Request.prototype
    request instanceof Request
    Object.prototype.hasOwnProperty.call(request, "cookies") === false
    Object.prototype.hasOwnProperty.call(Request.prototype, "cookies") === false
    "cookies" in request

For a standalone Request:

    Object.getPrototypeOf(new Request(url)) === Request.prototype
    "cookies" in new Request(url) === false
    new Request(url).cookies === undefined

The server-request prototype is not installed as a global and cannot be used as a constructor. It
is observable only through Object.getPrototypeOf on a server request. Repeated getter access on a
valid branded server request returns the same CookieMap. Strict-mode assignment throws the normal
readonly-property TypeError. Calling the getter with Object.create(serverRequestPrototype), a
standalone Request whose prototype was spoofed, or any other unbranded receiver throws the pinned
invalid-receiver TypeError before reading headers or allocating a map.

The first access reads the current Cookie fields directly from the branded private Headers store,
without dispatching through the user-visible request.headers.get property, constructs a map or an
empty map, caches it in the private request slot, and returns it on later access. Overriding or
deleting request.headers.get cannot forge or break the cookie snapshot. Cookie header mutation
before that first access is therefore observable:

- headers.set("cookie", value) replaces the originals used by the lazy map;
- headers.append("cookie", value) contributes through the semicolon-space Cookie join; and
- headers.delete("cookie") makes the lazy map empty.

After request.cookies is cached, later Cookie set/append/delete operations on request.headers do not
change or replace the map. Conversely, CookieMap set/delete never rewrites request.headers. Header
and map state are independent after the one lazy snapshot. Header-only mutation creates no
automatic Set-Cookie field; merely accessing cookies and leaving the map unchanged also emits none.

### 4.7.1 Branded Response selection

The scoped web-http repair also makes Response an unforgeable branded runtime subtype with a
private body slot. The current observable %body% own property is removed. Installation wires one
canonical Response.prototype; new Response, Response.json, and Phase 18 fetch response
construction all allocate the branded subtype and inherit that prototype.

Clun.serve handler and error-handler results are accepted only when the settled value has the real
Response runtime brand. A plain status/headers/body lookalike, Object.create(Response.prototype),
an object whose prototype was reassigned to Response.prototype, a copied descriptor set, and a
Proxy around a Response are non-Responses. They enter the ordinary error/default-500 pipeline.
Prototype identity and duck-typed properties never substitute for the brand.

Reflect.ownKeys on a Response excludes body state. Borrowed body methods brand-check their receiver,
and delete, assignment, or Object.defineProperty on any visible key cannot detach, replace, or
forge the private body consumed by fetch/serve serialization. The CL response-body reader checks
the same brand and reads that slot directly. User-visible public properties remain governed by
their frozen descriptors and the header validation contract.

When the handler produces its final Response, serialization appends each cookie mutation after all
manual response fields. Manual Set-Cookie fields keep their relative order; automatic fields keep
mutation-log order. Every value is written as a separate Set-Cookie field.

The request context follows every completion path:

- a synchronous Response;
- a Promise that fulfills with a Response;
- mutations made after await;
- a synchronous handler throw;
- a rejected handler Promise;
- a user error-handler Response or Promise; and
- the final default error response when no user response is available.

Each connection assigns a monotonically increasing sequence to parsed requests. Fulfilled or failed
handler results may become ready out of order, but pipelined responses commit strictly in request
order. Each sequence owns its request context and cookie snapshot until its turn; a slow first
request cannot cause a fast second request's cookie fields or body to be written first.

Cookie mutations are snapshotted once when that request's final response is serialized. Manual
headers plus automatic mutations are assembled into a request-local ordered serialization view;
the Response object's Headers are not mutated. Returning the same Response object from concurrent
or sequential requests therefore does not accumulate, leak, or duplicate another request's
Set-Cookie fields.

Mutations completed before the serialization snapshot are included, including mutations after
await but before a handler Promise fulfills. A mutation after the snapshot is a normal mutation of
the still-referenced CookieMap object but cannot append another field, rewrite committed bytes, or
affect a later request. Tests deterministically place mutations immediately before and after this
boundary.

A non-Response handler result enters the same error pipeline as a throw. The error handler may
return a Response synchronously or through a Promise. If it throws, rejects, returns a non-Response,
or is absent, the server commits its default 500. Cookie mutations are appended once to whichever
final response is selected. For HEAD, both normal and error responses serialize all applicable
headers, including Set-Cookie, and no body bytes.

Connection teardown before a handler or error-handler Promise settles marks every pending sequence
closed, releases network/context ownership exactly once, and suppresses all later writes. Promise
callbacks may still safely observe JavaScript objects they retain, but cannot access freed socket
state or resurrect automatic emission.

A context is never reused for another keep-alive request, connection, realm, or server. Concurrent
slow and fast requests observe only their own headers and mutations. After final serialization or
connection teardown, network ownership and the automatic-emission sink are released exactly once.
A request or CookieMap retained by JavaScript remains a valid branded object, but later mutations
have no network destination.

## 5. Architecture and security

The implementation remains pure Common Lisp with no CFFI, native cookie library, implementation
JavaScript, or shell-out shortcut.

### 5.1 Engine-independent core

A new src/http/cookies.lisp module, in an engine-free package such as clun.cookies, owns:

- Cookie records and explicit presence bits;
- exact name/path/domain validation;
- Set-Cookie parsing and canonical serialization;
- Cookie request-header parsing;
- HTTP-date parsing and formatting;
- percent encoding and forgiving value decoding;
- original/modification ordering and mutation coalescing; and
- the complete CookieMap state machine: construction from parsed pairs, get, has, set, delete,
  duplicate/empty handling, size, live iteration views, JSON projection, tombstones,
  toSetCookieHeaders, and response-field ordering.

The core accepts ordinary Common Lisp strings, numbers, booleans, and explicit time values. It does
not allocate JavaScript objects, read the clock implicitly in deterministic tests, or depend on
socket/server packages. The runtime bridge performs JavaScript conversion/branding and delegates
all CookieMap semantics to this core; it does not carry a second mutation implementation.

### 5.2 Runtime bridge

The runtime bridge spans a new src/runtime/web-cookies.lisp module and scoped web-http repairs. It
owns:

- realm-local Cookie and CookieMap constructors and prototypes;
- the shared branded Headers representation and cookie-specific header views in web-http;
- exact property descriptor installation;
- branded runtime allocation and private engine slots for Headers, Response, Cookie, CookieMap,
  iterators, and server-request cookie state;
- JavaScript overload resolution, member lookup order, ToString/ToUSVString/ToBoolean conversion,
  and error mapping;
- JavaScript Date conversion and cached getter identity;
- Clun namespace installation; and
- the dedicated server-request prototype and cookies accessor.

Exact enumerable accessors require either a narrowly exported engine descriptor helper or a
dedicated runtime installer built from existing property-descriptor primitives. Changing every
runtime helper's default descriptor is outside this phase.

The preferred storage architecture is a small set of runtime-local defstruct subtypes using
(:include eng:js-object):

- a Headers object carrying its ordered private header store;
- a Response object carrying its private body;
- a Cookie object carrying its Cookie record and cached Date reference;
- a CookieMap object carrying ordered original/modification state;
- a CookieMap iterator carrying map, iteration kind, and live cursor; and
- a server Request subtype carrying its request context and lazy CookieMap cache.

This keeps brands and state in Common Lisp slots on only the affected objects. Adding a generic
private-slot field or side table to every eng:js-object is not accepted because of the Phase 25
memory/performance blast radius. A generic engine-private-slot mechanism is a fallback only if the
subtype design is proven insufficient by a documented engine invariant, benchmarked against the
current object layout, and independently reviewed before implementation.

eng:hidden-prop is not private storage: it creates an observable, configurable JavaScript own
property and is forbidden for Headers store/brand, Response body/brand, Cookie, CookieMap, iterator
cursor, server-request brand/cache, and realm prototype caches. The engine/runtime boundary instead
provides a non-property internal slot or a dedicated branded object subtype. Brand membership is
determined by the allocated runtime object or internal slot, never by prototype identity or a
user-visible marker.

Every public accessor and method checks its required brand before reading arguments or user
properties. Therefore:

- Reflect.ownKeys on Headers, Response, Cookie, CookieMap, iterator, and server-request instances
  excludes every internal state key;
- Object.create(Headers.prototype), Object.create(Response.prototype),
  Object.create(Cookie.prototype), Object.create(CookieMap.prototype), and
  Object.create(serverRequestPrototype) do not create branded receivers;
- borrowing methods/accessors onto plain objects or prototype-spoofed objects throws the exact
  invalid-receiver error;
- setting an object's prototype to a Clun prototype cannot acquire a brand;
- copying prototype descriptors cannot acquire a brand; and
- delete, assignment, or Object.defineProperty on any string or Symbol cannot remove, replace, or
  forge the internal state.

Ordinary JavaScript shadow properties remain governed by JavaScript semantics, but they are never
consulted as the internal brand, Response body, Cookie record, map vectors, iterator cursor,
request context, or cookie cache. They also cannot replace the Headers store. A borrowed original
accessor or method on a genuine branded instance continues to reach that receiver's private slot.

### 5.3 Request identity and HTTP integration

src/net/http-parser.lisp, src/runtime/web-http.lisp, src/runtime/web-fetch.lisp, and
src/runtime/clun-serve.lisp receive scoped ordered-header and request-context changes:

- the parser handles duplicate Cookie without universal comma collapse;
- the parser validates duplicate framing fields and its complete-one-feed size bound before
  dispatch;
- Headers preserves individual Set-Cookie values;
- web-http installs and uses canonical Headers, Request, and Response prototype identities per
  realm;
- a private realm slot caches the server-request prototype whose parent is Request.prototype;
- standalone/fetch construction uses the canonical Request prototype while Clun.serve uses the
  branded server-request subtype;
- Response construction/fetch use the branded private-body subtype and serve/error selection
  rejects every unbranded result;
- fetch builds Headers from ordered pairs rather than an overwriting object;
- serve serializes distinct Set-Cookie lines from a request-local copy without mutating Response;
- dispatch carries one request context across synchronous, Promise, promised error-handler, and
  default-error branches; and
- a per-connection response sequencer preserves HTTP pipeline order and handles teardown before
  settlement.

The old observable %RequestProto%, Headers %store%, and Response %body% properties are removed.
Realm prototype caches and request context references live in private engine/runtime state. No
global or dynamically shared cookie mutation box is permitted. Request identity is the ownership
boundary.

### 5.4 Security and resource contract

The implementation must satisfy all of these:

- network Cookie input remains bounded by the existing 16 KiB aggregate request-header limit;
- parsing, validation, date parsing, encoding, and decoding are iterative and linear in input size;
- no regular-expression backtracking, recursive attribute parser, or recursive percent decoder is
  used;
- malformed percent sequences produce the frozen replacement behavior and never read beyond input;
- name, domain, and path validation prevents CR/LF response-header injection;
- direct cookie-string validation rejects CR, LF, and NUL before parsing;
- encoded Cookie names never gain prefix semantics;
- toJSON handles __proto__, constructor, and prototype as ordinary own keys without pollution;
- no state or brand appears in Reflect.ownKeys or any property descriptor;
- prototype spoofing and borrowed calls cannot bypass brand checks;
- property deletion, assignment, and definition cannot detach or replace private state;
- automatic-emission/network state cannot cross a keep-alive boundary or survive response
  completion/teardown; user-retained JavaScript cookie state has a detached sink;
- output-size arithmetic is checked before allocating encoded strings; and
- Common Lisp conditions are translated at the JavaScript or HTTP boundary.

Standalone API input is already bounded by the JavaScript engine's representable string and Array
sizes. Phase 32 adds no lower arbitrary cap and no silent truncation. Therefore the core may not
obtain boundedness by splitting an unbounded standalone string into a proportional list of copied
substrings.

Cookie, Cookie-header, attribute, date, and percent parsers use cursor/index ranges over the
original string. They allocate only accepted final fields/map entries plus one final decode or
serialization buffer. Date token storage is fixed-size. Percent decoding streams into one builder;
encoding either preflights checked output length and allocates once or uses one geometrically grown
builder. No parser constructs an O(input) temporary token list in addition to its required output
state, and no repeated concatenation creates quadratic copies.

Network parsing additionally has the fixed 16 KiB aggregate bound. Stored CookieMap entries and
serialized output are necessarily proportional to observable result size, while auxiliary scanner
state is constant and ordered-entry metadata is O(entry count). Stress tests compare N, 2N, and 4N
standalone inputs for linear time and a documented constant allocation ratio, then establish an RSS
plateau over repeated bounded network requests.

Cookie prefix creation invariants and browser storage policy remain out of scope. Security tests do
not turn those exclusions into false public claims.

## 6. Differential evidence and acceptance

### 6.1 Shipped-binary and core fixtures

tests/compat/web.cookies contains independently written shipped-binary fixtures:

| Fixture | Coverage |
| --- | --- |
| basic.js / basic.out | namespace, constructor/static/prototype own-key order, descriptors, tags, ignored newTarget/subclasses, defaults, null-versus-empty domain, fresh toJSON Date, JSON shape, serialization, state-free Reflect.ownKeys |
| coercion.js / coercion.out | overload selection, null/undefined options, zero-versus-explicit arguments, IDL USVString keys, member lookup order, abrupt completion, setters, maxAge NaN/infinities/-0/number spelling, Date brand/range/overflow/cache invalidation, brand checks, borrowed/spoofed receivers, errors |
| parsing.js / parsing.out | Set-Cookie parsing, Domain's final-validation and nonempty-emission rules, attributes, date formats including extended years, exact Max-Age decimal-prefix/i64/Number boundaries and precedence, repeated attributes, percent behavior, validation |
| map.js / map.out | all initializers, original/modified empty values, duplicates, the exact malformed-percent matrix and header-global percent switch, zero-argument methods, lookup, set/delete/coalescing, delete member order/nullish/abrupt cases, size, JSON, iterators, live mutation, forEach |
| headers.js / headers.out | branded private Headers store and Response body, receiver/result checks, constructed Cookie joining, validation-before-mutation, distinct Set-Cookie get/getAll/getSetCookie/entries/keys/values/forEach views |
| fetch.js plus run-fetch.sh | duplicate Set-Cookie response fields survive the Phase 18 fetch construction path |
| security.js / security.out | CR/LF/NUL, malformed percent sequences, pollution names, prefix deletion, large linear inputs |
| proxy-runtime.js / proxy-runtime.out | Proxy constructor metadata, all 13 internal methods, forwarding, invariants, revocation, callable/constructable capability, IsArray recursion, and inline-cache exclusion |
| proxy-cookies.js / proxy-cookies.out | pinned CookieMap Proxy object/array/function/revoked empty-initializer behavior plus proxied Date and Response rejection, all without observable traps |
| raw-http.js plus run-raw-http.sh | one/split-feed header limit, duplicate framing fields, TE+CL, Connection precedence, duplicate Cookie, pipeline framing |
| server.js plus run.sh | shipped Clun server, canonical Request identity, server-only prototype/accessor/brand, request.headers lazy-snapshot timing, standalone negative surface, real-Response-only selection including a hostile proxied Response routed to 502 with zero traps, manual/automatic Set-Cookie order, shared Response nonmutation, mutation cutoff, ordered pipelines, sync/async/promised-error/default-500/HEAD paths, teardown, concurrency |

The Bun observation inventory records stable output and the six accepted engineering changes
separately. Standalone cases execute against stable Bun wherever stable is authoritative.
Engineering-difference cases are derived from the pinned engineering source/tests and labeled as
such. Server comparison uses Bun routes only as an adapter for the behavior Bun actually exposes;
Clun does not claim a routes API.

Engine-independent Lisp tests cover:

- every validator boundary;
- HTTP-date accept/reject, TimeClip boundaries, overflow rejection, and four-digit/extended
  formatting vectors;
- Set-Cookie and Cookie header parsing;
- Max-Age sign/prefix, signed-i64 boundary, overflow, 2^53 rounding, and repeated-value vectors;
- percent encode/decode vectors, including the complete malformed UTF-8 matrix, literal non-ASCII,
  and the header-global percent switch;
- ordering, duplicate, empty-value, and coalescing rules;
- expiry precedence with injected time;
- prefix tombstones and injection prevention; and
- allocation/complexity boundaries.

The focused Proxy engine suite additionally covers direct internal-method forwarding,
callable/constructable capability fixed at Proxy creation, revocation, invariant enforcement,
recursive IsArray, ordinary prototype-cycle handling, and the prohibition on inline-cache bypass.

#### Focused Test262 Proxy/Object/Reflect evidence

The vendored Test262 revision has no `built-ins/Proxy` or `built-ins/Reflect` directory. Its
Proxy-observable tests are distributed across language and built-in directories. The focused
manifest below selects all 189 files containing the `Proxy` token; 59 are under `built-ins/Object`
and 27 also exercise `Reflect.*`. It runs the repository's existing execution classifier without
editing or rebinding its skip rules and compares passes against the checked-in execution pass list:

```sh
RIPGREP_CONFIG_PATH= rg -l '\bProxy\b|\bProxy\.revocable\b' \
  vendor-data/test262/test | sort -u > tmp-test/proxy-object-reflect-slice.list

CLUN_EXEC=1 sbcl --dynamic-space-size 4096 \
  --non-interactive --no-userinit --no-sysinit \
  --eval '(defvar cl-user::*clun-test262-library* t)' \
  --load scripts/test262.lisp \
  --eval '(in-package :clun.engine)' \
  --eval '(let* ((manifest (merge-pathnames "tmp-test/proxy-object-reflect-slice.list" cl-user::*clun-root*))
                 (paths (with-open-file (in manifest)
                          (loop for line = (read-line in nil nil) while line
                                collect (merge-pathnames line cl-user::*clun-root*))))
                 (prior (make-hash-table :test (quote equal)))
                 (current (make-hash-table :test (quote equal)))
                 (pass 0) (fail 0) (skip 0) (crash 0)
                 (new-pass nil) (regress nil) (failed nil))
            (dolist (name (load-passlist)) (setf (gethash name prior) t))
            (loop for path in paths for index from 1 do
              (when (zerop (mod index 50)) (sb-ext:gc :full t))
              (let* ((name (rel-name path)) (status (classify-exec path)))
                (setf (gethash name current) status)
                (case status
                  (:pass (incf pass) (unless (gethash name prior) (push name new-pass)))
                  (:fail (incf fail) (push name failed))
                  (:skip (incf skip))
                  (:crash (incf crash) (push name failed)))))
            (dolist (path paths)
              (let ((name (rel-name path)))
                (when (and (gethash name prior)
                           (not (eq :pass (gethash name current))))
                  (push name regress))))
            (format t "FOCUSED total=~d pass=~d fail=~d skip=~d crash=~d new-pass=~d regressions=~d~%"
                    (length paths) pass fail skip crash (length new-pass) (length regress))
            (dolist (name (sort new-pass (function string<)))
              (format t "NEW-PASS ~a~%" name))
            (dolist (name (sort regress (function string<)))
              (format t "REGRESSION ~a -> ~(~a~)~%" name (gethash name current)))
            (dolist (name (sort failed (function string<)))
              (format t "NONPASS ~(~a~) ~a~%" (gethash name current) name)))'
```

Observed output on the Phase 32 candidate:

```text
FOCUSED total=189 pass=14 fail=3 skip=172 crash=0 new-pass=13 regressions=0
NEW-PASS built-ins/Array/prototype/slice/length-exceeding-integer-limit-proxied-array.js
NEW-PASS built-ins/Error/cause_abrupt.js
NEW-PASS built-ins/Object/freeze/throws-when-false.js
NEW-PASS built-ins/Object/keys/proxy-keys.js
NEW-PASS built-ins/Object/preventExtensions/throws-when-false.js
NEW-PASS built-ins/Object/prototype/__proto__/set-cycle-shadowed.js
NEW-PASS built-ins/Object/seal/seal-proxy.js
NEW-PASS built-ins/Object/seal/throws-when-false.js
NEW-PASS built-ins/Object/values/order-after-define-property.js
NEW-PASS built-ins/Promise/prototype/finally/this-value-proxy.js
NEW-PASS built-ins/Symbol/prototype/description/this-val-non-symbol.js
NEW-PASS statements/class/subclass/builtin-objects/Proxy/no-prototype-throws.js
NEW-PASS statements/for-of/iterator-next-result-type.js
NONPASS fail built-ins/Array/fromAsync/this-constructor-operations.js
NONPASS fail built-ins/Array/prototype/reverse/length-exceeding-integer-limit-with-proxy.js
NONPASS fail built-ins/Array/prototype/splice/create-species-length-exceeding-integer-limit.js
```

The three remaining failures were already outside the execution pass list and are owned by the
unimplemented `Array.fromAsync` and pre-existing `reverse`/`splice` greater-than-2^53 algorithm
gaps. They expose no Proxy internal-method regression. No selected prior pass regressed and no
selected test crashed.

Existing HTTP parser, Headers, fetch, and server tests gain the complete duplicate/framing
regressions in sections 4.6 and 4.7. Raw-socket assertions inspect response field lines;
Headers.get alone is insufficient because it intentionally returns a joined view. Constructed
Headers, parsed Request.headers, and fetched Response.headers must produce the same cookie-specific
views.

Prototype/brand regressions additionally prove:

- Headers methods use the branded this receiver's private store, fake %store% properties do not
  pass coercion/brand checks, CL serialization reads that same store, and constructor/prototype
  identity plus descriptors are canonical;
- new Response, Response.json, and fetch responses carry the private body brand; fake/proxied/
  prototype-spoofed results are rejected; %body% properties cannot influence serialization;
- Object.getPrototypeOf(new Request(url)) is the exact global Request.prototype;
- Request's prototype and prototype.constructor descriptors have the frozen attributes;
- every Clun.serve request is instanceof Request;
- the server-request prototype's parent is the exact Request.prototype;
- standalone Request instances and Request.prototype have no cookies property;
- server requests initially have no own cookies property;
- Reflect.ownKeys(serverRequestPrototype) is exactly ["cookies"];
- the exact cookies descriptor lives only on the server-request prototype;
- Object.create, borrowed calls, descriptor copying, and prototype spoofing fail brand checks;
- Reflect.ownKeys exposes no Headers, Response, Cookie, CookieMap, iterator, or request-cache
  state; and
- delete, assignment, and defineProperty cannot mutate, detach, or forge private state.

Constructor/date regressions prove ignored newTarget/subclass allocation, internal Date-value reads
despite an overridden getTime property, rejection of fake/proxied Dates without getter side effects,
both exact TimeClip endpoints, one unit beyond each endpoint, numeric multiplication overflow, and
the selected year spellings. They also prove same-value/different-value mutation of the cached
getter Date, cache invalidation after every successful setter, fresh toJSON Dates, and null versus
empty domain getter/serialization/JSON behavior.

Server lazy-snapshot regressions apply request.headers set, append, and delete before first
request.cookies access and compare the resulting originals. They repeat each operation after cache
creation, prove the map identity/content does not change, mutate the map in both directions, and
prove request.headers never changes.

The implementation registers at least:

| Evidence ID | Kind | Required assertion |
| --- | --- | --- |
| ev.web.cookies.public.v1 | fixture/suite | complete public API, descriptors, coercion, parsing, map, and error contract through build/clun |
| ev.web.cookies.headers.v1 | fixture/checked-script | constructed, parsed, fetched, and serialized Cookie/Set-Cookie header views |
| ev.web.cookies.server.v1 | checked-script | raw HTTP lifecycle and distinct Set-Cookie wire behavior through build/clun |
| ev.web.cookies.core-suite.v1 | suite | engine-independent parser/serializer/date/security tests |
| ev.web.cookies.security.v1 | checked-script/suite | injection, pollution, malformed-input, isolation, and scaling boundaries |

Executable public and server evidence is target-scoped to linux-x64, linux-arm64, darwin-x64, and
darwin-arm64. A static source path or API-presence probe cannot support a platform row. web.cookies
may become Yes only after all four platform rows are supported by executable receipts.

### 6.2 Documentation, ledger, Issue, and release synchronization

The implementation unit updates issue #6 first and keeps these derived/public surfaces synchronized:

- PLAN.md and STATE.md;
- compat/features.tsv, compat/platforms.tsv, compat/evidence.tsv, and references as required;
- README.md and generated site compatibility/phase tracking;
- docs/releases/current.md and release notes;
- DECISIONS.md for every accepted stable/engineering or safety disposition; and
- all version sources named by docs/versioning.md.

There is no publication gap: the ledger cannot say Yes while README/site say No or while target
receipts are absent. Public pages cannot claim support before the ledger and evidence accept it.

This phase adds a backward-compatible public API and therefore has minor SemVer impact. The exact
0.1.0-dev.N identifier is assigned from release state at merge time; this design does not preselect
a stale prerelease number. The release-bearing unit satisfies the bounded version-transition gate,
then follows immutable tag, assets/checksums, ledger/docs, Pages, hosted-installer, and issue-evidence
publication order.

### 6.3 Acceptance gate

Issue #6 may close and web.cookies may become Yes only when:

1. the complete standalone API and raw HTTP differential corpus passes through build/clun;
2. every stable/engineering/safety disposition has dedicated fixtures and issue/DECISIONS.md
   records;
3. exact descriptors, coercion order, abrupt completion, errors, private-slot brands,
   Reflect.ownKeys, spoofed/borrowed receiver failures, duplicate/header order, and live iteration
   cases pass;
4. canonical Request.prototype identity, standalone Request's negative cookie surface, the
   server-only inherited accessor, pre-access request.headers set/append/delete and post-cache
   independence, synchronous, asynchronous, promised-error, default-500, HEAD, pipelined,
   shared-Response, mutation-cutoff, teardown, keep-alive, and concurrent tests prove subtype
   identity, ordered isolation, nonmutation, and one-time emission;
5. constructed/parser/fetch/serve Headers views, conflicting Content-Length, Transfer-Encoding
   plus Content-Length, duplicate Transfer-Encoding/Connection, one-feed/split-feed 16 KiB limits,
   malformed, injection, pollution, Date range/brand, exact Max-Age i64/Number boundaries,
   Domain nonempty omission, the malformed-percent/header-global switch matrix, N/2N/4N
   linear-allocation scaling, and bounded-network RSS-plateau tests pass;
6. executable compatibility receipts pass on all four supported targets;
7. ledger, README, site, Issue, roadmap state, release notes, and version sources agree; and
8. all commands below pass without weakening or skipping existing coverage:

       make compat FEATURE=web.cookies
       make build
       make test
       make purity
       make docs-check
       make public-claims-check
       make roadmap-check

For a release-bearing unit, BASE_SHA=<base> HEAD_SHA=<head> make version-transition-check is also
mandatory. Publication then verifies release assets and checksums plus
curl -fsSL https://clun.sh/install | sh before issue closeout.

### 6.4 Residual exclusions

The accepted Yes is not a claim for Phase 50 routing, browser cookie persistence, document.cookie,
the asynchronous Cookie Store API, TLS policy, HTTP/2 or HTTP/3 cookie compression, public-suffix
enforcement, or browser SameSite decisions. Later integration phases preserve the Phase 32 contract
and add their own executable evidence rather than reopening this row with untracked behavior.
