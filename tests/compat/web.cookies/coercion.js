function check(condition, label) {
  if (!condition) throw new Error("web.cookies coercion: " + label);
}

function capture(fn) {
  try {
    fn();
    return { threw: false };
  } catch (error) {
    return { threw: true, error };
  }
}

function checkError(fn, name, message, code, label) {
  const result = capture(fn);
  check(result.threw, label + " throws");
  check(result.error.name === name, label + " name");
  check(result.error.message === message, label + " message");
  check((result.error.code || null) === code, label + " code");
}

checkError(
  () => Clun.Cookie("a", "b"),
  "TypeError",
  "Use `new Cookie(...)` instead of `Cookie(...)`",
  "ERR_ILLEGAL_CONSTRUCTOR",
  "Cookie call",
);
checkError(
  () => Clun.CookieMap(),
  "TypeError",
  "Use `new CookieMap(...)` instead of `CookieMap(...)`",
  "ERR_ILLEGAL_CONSTRUCTOR",
  "CookieMap call",
);
checkError(() => new Clun.Cookie(), "TypeError", "Not enough arguments", "ERR_MISSING_ARGS", "missing Cookie args");
checkError(() => new Clun.Cookie(""), "TypeError", "Invalid cookie string: empty", null, "empty constructor string");
checkError(() => Clun.Cookie.parse(""), "TypeError", "Invalid cookie name: contains invalid characters", null, "empty parse");
checkError(() => new Clun.Cookie({}), "TypeError", "name is required", null, "missing init name");
checkError(() => new Clun.Cookie("a", "b", 1), "TypeError", "Options must be an object", null, "primitive options");
checkError(() => new Clun.CookieMap(1), "TypeError", "Invalid initializer type", null, "primitive map initializer");

check(new Clun.Cookie("a", "b", null).path === "/", "null options");
check(new Clun.Cookie("a", "b", undefined).path === "/", "undefined options");
check(Clun.Cookie.from("a", "b", 42).path === "/", "Cookie.from ignores primitive options");
check(new Clun.Cookie({ name: "absent-value" }).value === "", "absent CookieInit value");
check(new Clun.Cookie({ name: "explicit-value", value: undefined }).value === "undefined", "explicit undefined CookieInit value");

const log = [];
const init = {};
for (const key of ["name", "value", "domain", "path", "expires", "maxAge", "secure", "httpOnly", "partitioned", "sameSite"]) {
  Object.defineProperty(init, key, {
    enumerable: true,
    get() {
      log.push(key);
      if (key === "name") return "ordered";
      if (key === "value") return "v";
      if (key === "domain") return "example.com";
      if (key === "path") return "/x";
      if (key === "expires") return 0;
      if (key === "maxAge") return 1;
      if (key === "sameSite") return "none";
      return true;
    },
  });
}
const ordered = new Clun.Cookie(init);
check(log.join(",") === "name,value,domain,path,expires,maxAge,secure,httpOnly,partitioned,sameSite", "CookieInit member order");
check(ordered.toString().indexOf("Domain=example.com; Path=/x") !== -1, "ordered options applied");

let lateReads = 0;
const badInit = {};
Object.defineProperty(badInit, "name", { get() { return "bad name"; } });
Object.defineProperty(badInit, "value", { get() { lateReads++; return "v"; } });
checkError(() => new Clun.Cookie(badInit), "TypeError", "Invalid cookie name: contains invalid characters", null, "init abrupt completion");
check(lateReads === 0, "later init getter skipped");

const optionLog = [];
const options = {};
for (const key of ["domain", "path", "expires", "maxAge", "secure", "httpOnly", "partitioned", "sameSite"]) {
  Object.defineProperty(options, key, {
    get() {
      optionLog.push(key);
      if (key === "domain") return null;
      if (key === "path") return undefined;
      if (key === "expires") return null;
      if (key === "maxAge") return 2;
      if (key === "sameSite") return "lax";
      return false;
    },
  });
}
new Clun.Cookie("positional", "v", options);
check(optionLog.join(",") === "domain,path,expires,maxAge,secure,httpOnly,partitioned,sameSite", "positional option order");

const usv = new Clun.Cookie("usv", "\ud800");
check(usv.value === "\ufffd", "positional USVString replacement");
usv.value = "\udfff";
check(usv.value === "\ufffd", "setter USVString replacement");
usv.domain = null;
usv.path = null;
check(usv.domain === "null" && usv.path === "null", "direct null setter conversion");
usv.sameSite = "STRICT";
check(usv.sameSite === "strict", "sameSite setter case folding");
checkError(
  () => { usv.sameSite = "bogus"; },
  "TypeError",
  "Invalid sameSite value. Must be 'strict', 'lax', or 'none'",
  null,
  "sameSite setter validation",
);
const noBooleanCoercion = { valueOf() { throw new Error("boolean coercion hook ran"); } };
usv.secure = noBooleanCoercion;
usv.httpOnly = noBooleanCoercion;
usv.partitioned = noBooleanCoercion;
check(usv.secure && usv.httpOnly && usv.partitioned, "boolean setters use ToBoolean without hooks");

const max = new Clun.Cookie("max", "v", { maxAge: NaN });
check(max.maxAge === undefined, "constructor NaN omission");
const ignoredStringMax = new Clun.Cookie("max", "v", { maxAge: "4" });
check(ignoredStringMax.maxAge === undefined, "constructor maxAge Number brand");
const infinityMax = new Clun.Cookie("max", "v", { maxAge: Infinity });
check(infinityMax.maxAge === Infinity && infinityMax.toString().indexOf("Max-Age=Infinity") !== -1, "constructor Infinity");
const negativeZeroMax = new Clun.Cookie("max", "v", { maxAge: -0 });
check(Object.is(negativeZeroMax.maxAge, -0), "negative zero getter");
check(negativeZeroMax.toString().indexOf("Max-Age=0") !== -1, "negative zero spelling");
max.maxAge = "2.5";
check(max.maxAge === 2.5 && max.toString().indexOf("Max-Age=2.5") !== -1, "setter IDLDouble coercion");
max.maxAge = null;
check(max.maxAge === undefined, "setter maxAge clear");
checkError(() => { max.maxAge = Infinity; }, "TypeError", "The provided value is non-finite", null, "setter nonfinite");

const expiry = new Clun.Cookie("expiry", "v", { expires: 1 });
const first = expiry.expires;
check(first.getTime() === 1000, "numeric expiry seconds");
first.setTime(1000);
check(expiry.expires === first, "same-value Date mutation preserves cache");
expiry.expires = 1;
check(expiry.expires !== first && expiry.expires.getTime() === 1000, "setter invalidates cache");
const date = new Date(2000);
date.getTime = () => { throw new Error("visible getTime must not run"); };
expiry.expires = date;
check(expiry.expires.getTime() === 2000, "Date internal value read");
class BrandedDate extends Date {}
expiry.expires = new BrandedDate(3000);
check(expiry.expires.getTime() === 3000, "Date subclass retains brand");
const fakeDate = Object.create(Date.prototype);
Object.defineProperty(fakeDate, "getTime", { get() { throw new Error("fake getter ran"); } });
checkError(
  () => { expiry.expires = fakeDate; },
  "TypeError",
  "The argument 'expires' Invalid expires value. Must be a Date or a number. Received Date {}",
  "ERR_INVALID_ARG_VALUE",
  "fake Date rejected",
);
checkError(() => { expiry.expires = new Date(NaN); }, "RangeError", "expires must be a valid Date (or Number)", null, "invalid Date");
checkError(() => { expiry.expires = 8640000000001; }, "RangeError", "expires must be a valid Number (or Date)", null, "TimeClip overflow");
expiry.expires = 8640000000000;
check(expiry.expires.getTime() === 8640000000000000, "positive TimeClip endpoint");
expiry.expires = -8640000000000;
check(expiry.expires.getTime() === -8640000000000000, "negative TimeClip endpoint");
checkError(() => { expiry.expires = "not a date"; }, "TypeError", "Invalid cookie expiration date", null, "invalid date string");
expiry.expires = undefined;
check(expiry.expires === undefined, "expires clear");

check(!Reflect.set(expiry, "name", "changed"), "name is getter-only");
check(expiry.name === "expiry", "name remains immutable");

checkError(
  () => Clun.Cookie.prototype.toString.call(Object.create(Clun.Cookie.prototype)),
  "TypeError",
  "Can only call Cookie.toString on instances of Cookie",
  "ERR_INVALID_THIS",
  "Cookie brand",
);
checkError(
  () => Clun.CookieMap.prototype.get.call(Object.create(Clun.CookieMap.prototype), "a"),
  "TypeError",
  "Can only call CookieMap.get on instances of CookieMap",
  "ERR_INVALID_THIS",
  "CookieMap brand",
);

console.log("web.cookies coercion ok");
