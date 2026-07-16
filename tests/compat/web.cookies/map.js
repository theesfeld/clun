function check(condition, label) {
  if (!condition) throw new Error("web.cookies map: " + label);
}

function codeUnits(value) {
  const result = [];
  for (let index = 0; index < value.length; index++) result.push(value.charCodeAt(index).toString(16));
  return result.join(",");
}

function checkThrows(fn, name, message, label) {
  try {
    fn();
  } catch (error) {
    check(error.name === name, label + " name");
    check(error.message === message, label + " message");
    return;
  }
  throw new Error("web.cookies map: " + label + " did not throw");
}

for (const initializer of [undefined, null, ""]) {
  check(new Clun.CookieMap(initializer).size === 0, "empty initializer");
}
check(new Clun.CookieMap().size === 0, "zero-argument constructor");
const pairs = new Clun.CookieMap([["a", "1"], ["a", "2"], ["empty", ""]]);
check(pairs.size === 3, "pair initializer duplicates");
check([...pairs].map((entry) => entry.join("=")).join("|") === "a=1|a=2|empty=", "pair order");
const record = new Clun.CookieMap({ z: "last", a: "first" });
check([...record].map((entry) => entry.join("=")).join("|") === "z=last|a=first", "record property order");
checkThrows(
  () => new Clun.CookieMap([{}]),
  "TypeError",
  "Expected each element to be an array of two strings",
  "pair element brand",
);
checkThrows(
  () => new Clun.CookieMap([["only-one"]]),
  "TypeError",
  "Expected arrays of exactly two strings",
  "pair arity",
);

const parsed = new Clun.CookieMap("a=1; ignored; =skip; a=2; empty=; %5F%5FHost-name=literal+plus");
check(parsed.size === 4, "parsed map filtering");
check(parsed.get("a") === "1" && parsed.get("empty") === "", "first lookup and empty value");
check(parsed.get("%5F%5FHost-name") === "literal+plus", "literal encoded name and plus");
check(parsed.get("__Host-name") === null, "cookie names do not percent-decode");

check(codeUnits(new Clun.CookieMap("bad=%").get("bad")) === "fffd", "short percent");
check(codeUnits(new Clun.CookieMap("bad=%1").get("bad")) === "fffd,31", "one hex digit");
check(codeUnits(new Clun.CookieMap("bad=%ZZ").get("bad")) === "fffd", "nonhex pair");
check(codeUnits(new Clun.CookieMap("bad=%C0%AF").get("bad")) === "fffd", "overlong UTF-8");
check(codeUnits(new Clun.CookieMap("bad=%E2%28%A1").get("bad")) === "fffd,28,fffd", "broken UTF-8 continuation");
check(new Clun.CookieMap("euro=%E2%82%AC").get("euro") === "\u20ac", "valid UTF-8 percent decode");
check(new Clun.CookieMap("plus=hello+world").get("plus") === "hello+world", "plus stays literal");

const raw = new Clun.CookieMap("raw=\u00e9").get("raw");
check(raw === "\u00e9", "no-percent raw Unicode mode");
const switched = new Clun.CookieMap("raw=\u00e9; encoded=%41");
check(codeUnits(switched.get("raw")) === "c3,a9", "header-global percent switch");
check(switched.get("encoded") === "A", "global switch encoded pair");
check(codeUnits(new Clun.CookieMap("raw=\u00e9; ignored%").get("raw")) === "c3,a9", "percent switch from skipped segment");

const zero = new Clun.CookieMap("a=1");
check(zero.get() === null && zero.has() === false, "zero-argument lookup");
check(zero.set() === undefined && zero.delete() === undefined && zero.get("a") === "1", "zero-argument mutation no-op");
check(zero.get(undefined) === null && zero.get(null) === null, "explicit nullish lookup");
const nullishNames = new Clun.CookieMap("undefined=u; null=n");
check(nullishNames.get(undefined) === "u" && nullishNames.has(undefined), "explicit undefined key conversion");
check(nullishNames.get(null) === "n" && nullishNames.has(null), "explicit null key conversion");
checkThrows(() => zero.delete(undefined), "TypeError", "Cookie name is required", "explicit undefined delete");
checkThrows(() => zero.delete(null), "TypeError", "Cookie name is required", "explicit null delete");
checkThrows(() => zero.set("only"), "TypeError", "Not enough arguments", "one primitive set");
checkThrows(() => zero.set(undefined), "TypeError", "Not enough arguments", "explicit undefined set");
checkThrows(() => zero.set(null), "TypeError", "Not enough arguments", "explicit null set");
checkThrows(() => zero.delete("a", undefined), "TypeError", "Options must be an object", "explicit undefined delete options");
checkThrows(() => zero.delete("a", null), "TypeError", "Options must be an object", "explicit null delete options");

const mutation = new Clun.CookieMap("a=1; a=2; empty=");
const retained = new Clun.Cookie("retained", "one");
mutation.set(retained);
retained.value = "two";
check(mutation.get("retained") === "two", "set retains Cookie object");
mutation.set("a", "new");
check(mutation.get("a") === "new" && mutation.size === 3, "set coalesces duplicates");
mutation.set("gone", "");
check(!mutation.has("gone"), "modified empty value absent");
check(mutation.toSetCookieHeaders().some((value) => value.indexOf("gone=") === 0), "modified empty emits response field");
mutation.delete("retained");
check(!mutation.has("retained"), "delete removes value");
check(mutation.toSetCookieHeaders().some((value) => value.indexOf("retained=; Path=/; Expires=Thu, 01 Jan 1970") === 0), "delete tombstone");

const absentValue = new Clun.CookieMap();
absentValue.set({ name: "absent-value" });
check(absentValue.get("absent-value") === null && !absentValue.has("absent-value"), "absent CookieInit value is empty");
check(
  absentValue.toSetCookieHeaders().some((value) => value.indexOf("absent-value=; Path=/; SameSite=Lax") === 0),
  "absent CookieInit value remains a response mutation",
);
const explicitUndefined = new Clun.CookieMap();
explicitUndefined.set({ name: "explicit-undefined", value: undefined });
check(explicitUndefined.get("explicit-undefined") === "undefined", "explicit undefined CookieInit value conversion");
check(explicitUndefined.has("explicit-undefined"), "explicit undefined CookieInit value remains live");
check(
  explicitUndefined.toSetCookieHeaders().some((value) => value.indexOf("explicit-undefined=undefined;") === 0),
  "explicit undefined CookieInit value response field",
);

const orderedDelete = { name: "victim" };
let pathRead = 0;
Object.defineProperty(orderedDelete, "domain", { get() { return "UPPER"; } });
Object.defineProperty(orderedDelete, "path", { get() { pathRead++; return "/"; } });
checkThrows(() => mutation.delete(orderedDelete), "TypeError", "Invalid cookie domain: contains invalid characters", "delete member validation");
check(pathRead === 0, "delete abrupt member order");

const coalesce = new Clun.CookieMap();
coalesce.set("x", "one");
coalesce.delete("x");
coalesce.set("x", "final");
check(coalesce.toSetCookieHeaders().length === 1, "set-delete-set coalesces");
check(coalesce.toSetCookieHeaders()[0].indexOf("x=final") === 0, "set-delete-set final field");
check(coalesce.toSetCookieHeaders() !== coalesce.toSetCookieHeaders(), "fresh Set-Cookie arrays");

const live = new Clun.CookieMap("a=1; b=2");
const iterator = live.entries();
check(iterator.next().value.join("=") === "a=1", "live iterator first");
live.set("c", "3");
check(iterator.next().value.join("=") === "a=1", "live iterator pinned repetition");
check(iterator.next().value.join("=") === "b=2", "live iterator tail");
check(iterator.next().done, "live iterator done");
const deletionLive = new Clun.CookieMap("a=1; b=2; c=3");
const deletionIterator = deletionLive.entries();
check(deletionIterator.next().value.join("=") === "a=1", "deletion iterator first");
deletionLive.delete("a");
check(deletionIterator.next().value.join("=") === "c=3", "deletion iterator current-view cursor");
check(deletionIterator.next().done, "deletion iterator done");

const callbackLog = [];
live.forEach(function (value, name, owner) {
  callbackLog.push(name + "=" + value + ":" + (owner === live) + ":" + (this === callbackLog));
}, callbackLog);
check(callbackLog.join("|") === "c=3:true:true|a=1:true:true|b=2:true:true", "forEach contract");
checkThrows(
  () => new Clun.CookieMap().forEach(),
  "TypeError",
  "Cannot call callback on a non-function",
  "empty forEach validates callback",
);
checkThrows(
  () => new Clun.CookieMap().forEach(1),
  "TypeError",
  "Cannot call callback on a non-function",
  "empty forEach rejects non-callable callback",
);

const pollution = new Clun.CookieMap([["__proto__", "safe"], ["constructor", "also-safe"]]).toJSON();
check(Object.getPrototypeOf(pollution) === Object.prototype, "JSON normal prototype");
check(Object.prototype.hasOwnProperty.call(pollution, "__proto__"), "JSON __proto__ own property");
check(pollution.__proto__ === "safe" && pollution.constructor === "also-safe", "pollution values preserved as data");

console.log("web.cookies map ok");
