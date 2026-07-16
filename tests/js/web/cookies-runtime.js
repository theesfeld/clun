function check(condition, label) {
  if (!condition) throw new Error("cookie runtime check failed: " + label);
}

function checkDataDescriptor(object, key, writable, enumerable, configurable, label) {
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  check(!!descriptor, label + " descriptor");
  check(descriptor.writable === writable, label + " writable");
  check(descriptor.enumerable === enumerable, label + " enumerable");
  check(descriptor.configurable === configurable, label + " configurable");
}

function checkThrows(fn, name, message, code, label) {
  try {
    fn();
  } catch (error) {
    check(error.name === name, label + " name");
    check(error.message === message, label + " message");
    check((error.code || null) === code, label + " code");
    return;
  }
  throw new Error("cookie runtime check failed: " + label + " did not throw");
}

const clunCookie = Object.getOwnPropertyDescriptor(Clun, "Cookie");
const clunCookieMap = Object.getOwnPropertyDescriptor(Clun, "CookieMap");
check(!clunCookie.writable && clunCookie.enumerable && !clunCookie.configurable, "Clun.Cookie descriptor");
check(!clunCookieMap.writable && clunCookieMap.enumerable && !clunCookieMap.configurable, "Clun.CookieMap descriptor");
checkDataDescriptor(Clun.Cookie, "prototype", false, false, false, "Cookie.prototype property");
checkDataDescriptor(Clun.Cookie, "parse", true, true, false, "Cookie.parse");
checkDataDescriptor(Clun.Cookie, "from", true, true, false, "Cookie.from");
check(Clun.Cookie.parse.length === 1 && Clun.Cookie.from.length === 3, "Cookie static lengths");
check(
  Reflect.ownKeys(Clun.Cookie.prototype).map(String).join(",") ===
    "constructor,name,value,domain,path,expires,maxAge,secure,httpOnly,sameSite,partitioned,isExpired,toString,toJSON,serialize,Symbol(Symbol.toStringTag)",
  "Cookie prototype order",
);

const base = new Clun.Cookie("base", "value");
check(base.domain === null, "default domain");
check(base.path === "/", "default path");
check(base.expires === undefined && base.maxAge === undefined, "default expiry");
check(!base.secure && !base.httpOnly && !base.partitioned, "default flags");
check(base.sameSite === "lax", "default sameSite");
check(Object.getPrototypeOf(base.toJSON()) === null, "Cookie JSON null prototype");
check(Reflect.ownKeys(base).length === 0, "Cookie private state");
checkThrows(
  () => Clun.Cookie("a", "b"),
  "TypeError",
  "Use `new Cookie(...)` instead of `Cookie(...)`",
  "ERR_ILLEGAL_CONSTRUCTOR",
  "Cookie illegal call",
);
checkThrows(
  () => new Clun.Cookie(""),
  "TypeError",
  "Invalid cookie string: empty",
  null,
  "Cookie empty constructor string",
);
checkThrows(
  () => Clun.Cookie.parse(""),
  "TypeError",
  "Invalid cookie name: contains invalid characters",
  null,
  "Cookie.parse empty string",
);
checkThrows(
  () => Clun.Cookie.parse(),
  "TypeError",
  "Not enough arguments",
  "ERR_MISSING_ARGS",
  "Cookie.parse zero arguments",
);
for (const value of [undefined, null, false, 0, Symbol("missing")]) {
  checkThrows(
    () => new Clun.Cookie(value),
    "TypeError",
    "Not enough arguments",
    "ERR_MISSING_ARGS",
    "Cookie one-argument primitive",
  );
}
checkThrows(
  () => Clun.Cookie.from(),
  "TypeError",
  "Not enough arguments",
  "ERR_MISSING_ARGS",
  "Cookie.from zero arguments",
);
checkThrows(
  () => Clun.Cookie.from("name"),
  "TypeError",
  "Not enough arguments",
  "ERR_MISSING_ARGS",
  "Cookie.from one argument",
);
check(new Clun.Cookie({ name: "absent" }).value === "", "CookieInit absent value default");
check(
  new Clun.Cookie({ name: "present", value: undefined }).value === "undefined",
  "CookieInit present undefined value",
);
checkThrows(
  () => Clun.Cookie.prototype.toString.call(Object.create(Clun.Cookie.prototype)),
  "TypeError",
  "Can only call Cookie.toString on instances of Cookie",
  "ERR_INVALID_THIS",
  "Cookie brand",
);
check(Clun.Cookie.from("from", "value", 42).name === "from", "Cookie.from primitive options");

let laterGetterCount = 0;
const invalidNameInit = {};
Object.defineProperty(invalidNameInit, "name", { get() { return "bad name"; } });
Object.defineProperty(invalidNameInit, "value", { get() { laterGetterCount++; return "value"; } });
checkThrows(
  () => new Clun.Cookie(invalidNameInit),
  "TypeError",
  "Invalid cookie name: contains invalid characters",
  null,
  "CookieInit name validation",
);
check(laterGetterCount === 0, "CookieInit abrupt member order");

const invalidDomainOptions = {};
Object.defineProperty(invalidDomainOptions, "domain", { get() { return "UPPER"; } });
Object.defineProperty(invalidDomainOptions, "path", { get() { laterGetterCount++; return "/"; } });
checkThrows(
  () => new Clun.Cookie("ordered", "value", invalidDomainOptions),
  "TypeError",
  "Invalid cookie domain: contains invalid characters",
  null,
  "Cookie options domain validation",
);
check(laterGetterCount === 0, "Cookie options abrupt member order");

const emptyDomain = new Clun.Cookie("domain", "v", { domain: "" });
check(emptyDomain.domain === "", "empty domain getter");
check(!("domain" in emptyDomain.toJSON()), "empty domain JSON omission");
check(emptyDomain.toString().indexOf("Domain=") === -1, "empty domain serialization omission");
emptyDomain.domain = null;
check(emptyDomain.domain === "null", "domain setter USV conversion");

const expiry = new Clun.Cookie("expiry", "v", { expires: 1 });
const cached = expiry.expires;
check(expiry.expires === cached, "expires cache identity");
cached.setTime(1001);
check(expiry.expires !== cached && expiry.expires.getTime() === 1000, "expires cache repair");
const repaired = expiry.expires;
expiry.expires = 1;
check(expiry.expires !== repaired, "expires setter cache invalidation");
check(expiry.toJSON().expires !== expiry.expires, "expires JSON freshness");
checkThrows(
  () => { expiry.expires = true; },
  "TypeError",
  "The argument 'expires' Invalid expires value. Must be a Date or a number. Received true",
  "ERR_INVALID_ARG_VALUE",
  "expires invalid value",
);
expiry.maxAge = "2";
check(expiry.maxAge === 2 && !expiry.isExpired(), "maxAge setter coercion");
expiry.maxAge = -0;
check(Object.is(expiry.maxAge, -0), "negative zero preservation");
check(expiry.toString().indexOf("Max-Age=0") !== -1, "negative zero spelling");
expiry.maxAge = null;
check(expiry.maxAge === undefined, "maxAge clear");
expiry.sameSite = "STRICT";
check(expiry.sameSite === "strict", "sameSite setter case folding");

const alternate = function Alternate() {};
const reflected = Reflect.construct(Clun.Cookie, ["reflect", "v"], alternate);
check(Object.getPrototypeOf(reflected) === Clun.Cookie.prototype, "Cookie ignored newTarget");
check(!(reflected instanceof alternate), "Cookie alternate instanceof");

checkDataDescriptor(Clun.CookieMap, "prototype", false, false, false, "CookieMap.prototype property");
check(
  Reflect.ownKeys(Clun.CookieMap.prototype).map(String).join(",") ===
    "constructor,get,toSetCookieHeaders,has,set,delete,entries,keys,values,forEach,toJSON,size,Symbol(Symbol.iterator),Symbol(Symbol.toStringTag)",
  "CookieMap prototype order",
);
check(Clun.CookieMap.prototype[Symbol.iterator] === Clun.CookieMap.prototype.entries, "CookieMap iterator alias");
const sizeDescriptor = Object.getOwnPropertyDescriptor(Clun.CookieMap.prototype, "size");
check(!!sizeDescriptor.get && sizeDescriptor.set === undefined, "CookieMap size accessor");
check(sizeDescriptor.enumerable && !sizeDescriptor.configurable, "CookieMap size descriptor");

const map = new Clun.CookieMap("a=1; a=2; empty=");
map.set({ name: "default-empty" });
check(
  map.get("default-empty") === null &&
    map.toSetCookieHeaders().some((value) => value.indexOf("default-empty=") === 0),
  "CookieMap.set absent value defaults to empty tombstone",
);
check(map.get() === null && !map.has(), "CookieMap zero argument lookup");
check(map.get(undefined) === null && map.get(null) === null, "CookieMap supplied nullish lookup");
check(map.size === 3 && map.get("empty") === "", "CookieMap duplicate and empty originals");
check([...map].map((entry) => entry.join("=")).join("|") === "a=1|a=2|empty=", "CookieMap iteration");

const overloadMap = new Clun.CookieMap();
const ignoredCookie = new Clun.Cookie("object-cookie", "kept");
overloadMap.set(ignoredCookie, "ignored");
overloadMap.set({ name: "object-init", value: "kept" }, "ignored");
function functionInit() {}
Object.defineProperty(functionInit, "name", { value: "function-init" });
overloadMap.set(functionInit);
check(overloadMap.get("object-cookie") === "kept", "CookieMap.set Cookie overload with extra argument");
check(overloadMap.get("object-init") === "kept", "CookieMap.set init overload with extra argument");
check(
  overloadMap.get("function-init") === null &&
    overloadMap.toSetCookieHeaders().some((value) => value.indexOf("function-init=") === 0),
  "CookieMap.set function init absent value",
);
const retained = new Clun.Cookie("retained", "one");
map.set(retained);
retained.value = "two";
check(map.get("retained") === "two", "CookieMap retains Cookie");
map.set("gone", "");
check(!map.has("gone") && map.toSetCookieHeaders().some((value) => value.indexOf("gone=") === 0), "modified empty semantics");
map.delete("__Host-token");
check(map.toSetCookieHeaders().some((value) => value.indexOf("__Host-token=; Path=/;") === 0 && value.indexOf("Secure") !== -1), "prefix tombstone");

const invalidDelete = { name: "delete-me" };
Object.defineProperty(invalidDelete, "domain", { get() { return "UPPER"; } });
Object.defineProperty(invalidDelete, "path", { get() { laterGetterCount++; return "/"; } });
checkThrows(
  () => map.delete(invalidDelete),
  "TypeError",
  "Invalid cookie domain: contains invalid characters",
  null,
  "CookieMap delete validation",
);
check(laterGetterCount === 0, "CookieMap delete abrupt member order");

const live = new Clun.CookieMap("a=1; b=2");
const liveIterator = live.entries();
check(liveIterator.next().value.join("=") === "a=1", "live iterator first");
live.set("c", "3");
check(liveIterator.next().value.join("=") === "a=1", "live iterator repetition");
check(liveIterator.next().value.join("=") === "b=2", "live iterator tail");
check(liveIterator.next().done, "live iterator done");
live.set("after-done", "4");
check(liveIterator.next().done, "exhausted iterator remains done after mutation");
const emptyIteratorMap = new Clun.CookieMap();
const emptyIterator = emptyIteratorMap.entries();
check(emptyIterator.next().done, "empty iterator initial exhaustion");
emptyIteratorMap.set("later", "1");
check(emptyIterator.next().done, "initially empty iterator remains done");
check(Object.prototype.toString.call(liveIterator) === "[object CookieMap Iterator]", "iterator tag");
check(Reflect.ownKeys(liveIterator).length === 0, "iterator private state");
const iteratorPrototype = Object.getPrototypeOf(liveIterator);
check(Reflect.ownKeys(iteratorPrototype).map(String).join(",") === "next,Symbol(Symbol.toStringTag)", "iterator prototype keys");
checkThrows(
  () => iteratorPrototype.next.call({}),
  "TypeError",
  "Cannot call next() on a non-Iterator object",
  "ERR_INVALID_THIS",
  "iterator next brand",
);
check(iteratorPrototype[Symbol.iterator].call({}).constructor === Object, "inherited generic iterator method");

const pollution = new Clun.CookieMap([["__proto__", "safe"], ["constructor", "also-safe"]]).toJSON();
check(Object.getPrototypeOf(pollution) === Object.prototype, "CookieMap JSON normal prototype");
check(Object.prototype.hasOwnProperty.call(pollution, "__proto__"), "CookieMap JSON __proto__ own property");
check(pollution.__proto__ === "safe" && pollution.constructor === "also-safe", "CookieMap JSON pollution values");
checkThrows(
  () => Clun.CookieMap.prototype.get.call({}, "a"),
  "TypeError",
  "Can only call CookieMap.get on instances of CookieMap",
  "ERR_INVALID_THIS",
  "CookieMap brand",
);

const firstHeaders = new Headers([["cookie", "a=1"], ["set-cookie", "x=1"], ["set-cookie", "y=2"]]);
const secondHeaders = new Headers([["cookie", "b=2"]]);
checkThrows(() => new Headers(null), "TypeError", "Type error", null, "Headers null initializer");
checkThrows(
  () => new Request("https://example.com", { headers: null }),
  "TypeError",
  "Type error",
  null,
  "Request null HeadersInit",
);
checkThrows(
  () => new Response(null, { headers: null }),
  "TypeError",
  "Type error",
  null,
  "Response null HeadersInit",
);
checkThrows(() => new Headers([{}]), "TypeError", "Type error", null, "Headers non-array pair");
checkThrows(
  () => new Headers([["x"]]),
  "TypeError",
  "Header sub-sequence must contain exactly two items",
  null,
  "Headers short pair",
);
checkThrows(
  () => new Headers([["x", "y", "z"]]),
  "TypeError",
  "Header sub-sequence must contain exactly two items",
  null,
  "Headers long pair",
);
const headersInitOrder = [];
checkThrows(
  () => new Headers([
    [{ toString() { headersInitOrder.push("first"); return "x"; } }],
    [{ toString() { headersInitOrder.push("later"); throw new Error("later conversion"); } }, "v"],
  ]),
  "Error",
  "later conversion",
  null,
  "Headers materializes before pair validation",
);
check(headersInitOrder.join("|") === "first|later", "Headers two-phase initializer order");
const iterableHeaders = new Headers(new Set([new Set(["x-iterable", "yes"])]));
check(iterableHeaders.get("x-iterable") === "yes", "Headers nested iterable initializer");
const recordHeaders = {};
Object.defineProperty(recordHeaders, "hidden", { value: "no", enumerable: false });
recordHeaders.visible = "yes";
check([...new Headers(recordHeaders)].join() === "visible,yes", "Headers enumerable record members");
const headersIteratorSource = new Headers([["a", "1"], ["b", "2"]]);
const headersIterator = headersIteratorSource.entries();
check(headersIterator.next().value.join("=") === "a=1", "Headers iterator first");
headersIteratorSource.append("c", "3");
check(headersIterator.next().value.join("=") === "b=2", "Headers iterator observes append");
headersIteratorSource.delete("b");
check(headersIterator.next().done, "Headers iterator live deletion exhaustion");
headersIteratorSource.append("d", "4");
check(headersIterator.next().done, "Headers iterator terminal exhaustion");
check(Object.prototype.toString.call(headersIterator) === "[object Headers Iterator]", "Headers iterator tag");
const liveForEachHeaders = new Headers([["a", "1"], ["b", "2"]]);
const liveForEachNames = [];
liveForEachHeaders.forEach((value, name) => {
  liveForEachNames.push(name + "=" + value);
  if (name === "a") liveForEachHeaders.append("c", "3");
});
check(liveForEachNames.join("|") === "a=1|b=2|c=3", "Headers forEach observes append");
const headersIteratorPrototype = Object.getPrototypeOf(headersIterator);
check(
  Reflect.ownKeys(headersIteratorPrototype).map(String).join(",") === "next,Symbol(Symbol.toStringTag)",
  "Headers iterator prototype keys",
);
checkThrows(
  () => headersIteratorPrototype.next.call({}),
  "TypeError",
  "Cannot call next() on a non-Iterator object",
  "ERR_INVALID_THIS",
  "Headers iterator brand",
);
checkDataDescriptor(Headers.prototype, "getAll", true, true, true, "Headers.getAll");
checkDataDescriptor(Headers.prototype, "getSetCookie", true, true, true, "Headers.getSetCookie");
check(firstHeaders instanceof Headers && Object.getPrototypeOf(firstHeaders) === Headers.prototype, "Headers canonical prototype");
check(Reflect.ownKeys(firstHeaders).length === 0, "Headers private store");
check(Headers.prototype.get.call(secondHeaders, "cookie") === "b=2", "Headers borrowed branded receiver");
check(firstHeaders.get("set-cookie") === "x=1, y=2", "Headers joined Set-Cookie get");
check(firstHeaders.getAll("set-cookie").join("|") === "x=1|y=2", "Headers getAll");
check(firstHeaders.getSetCookie().join("|") === "x=1|y=2", "Headers getSetCookie");
check([...firstHeaders].map((entry) => entry.join(":" )).join("|") === "cookie:a=1|set-cookie:x=1|set-cookie:y=2", "Headers distinct iteration");
const beforeInvalidHeader = firstHeaders.get("cookie");
checkThrows(() => firstHeaders.set("cookie", "bad\rvalue"), "TypeError", "Invalid HTTP header value", null, "Headers value validation");
check(firstHeaders.get("cookie") === beforeInvalidHeader, "Headers validation before mutation");
checkThrows(() => Headers.prototype.get.call({ "%store%": [] }, "cookie"), "TypeError", "Illegal invocation", null, "Headers brand");

const response = new Response("private-body");
check(Reflect.ownKeys(response).join(",") === "status,statusText,ok,headers", "Response private body");
check(Object.getPrototypeOf(response) === Response.prototype && response instanceof Response, "Response canonical prototype");
checkThrows(() => Response.prototype.text.call(Object.create(Response.prototype)), "TypeError", "Illegal invocation", null, "Response brand");
const request = new Request("https://example.com", { headers: firstHeaders });
check(Object.getPrototypeOf(request) === Request.prototype && request instanceof Request, "Request canonical prototype");
check(!("cookies" in request), "standalone Request cookie surface");

const largeHeaderParts = [];
for (let index = 0; index < 4096; index++) largeHeaderParts.push("key" + index + "=value" + index);
const largeMap = new Clun.CookieMap(largeHeaderParts.join("; "));
check(largeMap.size === 4096, "CookieMap large direct parse size");
check(largeMap.get("key4095") === "value4095", "CookieMap large direct parse tail");

console.log("cookie-runtime-contract ok");
