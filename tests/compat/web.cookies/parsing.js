function check(condition, label) {
  if (!condition) throw new Error("web.cookies parsing: " + label);
}

function checkThrows(fn, name, message, label, code = null) {
  try {
    fn();
  } catch (error) {
    check(error.name === name, label + " name");
    check(error.message === message, label + " message");
    check((error.code || null) === code, label + " code");
    return;
  }
  throw new Error("web.cookies parsing: " + label + " did not throw");
}

const complete = Clun.Cookie.parse(
  "sid=a%20b; Domain=EXAMPLE.COM; Path=/app; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=+0012junk; Secure; HttpOnly; Partitioned; SameSite=Strict",
);
check(complete.name === "sid" && complete.value === "a%20b", "literal parsed value");
check(complete.domain === "example.com" && complete.path === "/app", "domain and path");
check(complete.expires.getTime() === 784111777000, "IMF date");
check(complete.maxAge === 12, "decimal-prefix Max-Age");
check(complete.secure && complete.httpOnly && complete.partitioned, "presence flags");
check(complete.sameSite === "strict", "sameSite parse");
check(
  complete.toString() ===
    "sid=a%2520b; Domain=example.com; Path=/app; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=12; Secure; HttpOnly; Partitioned; SameSite=Strict",
  "canonical serialization",
);

const repeated = Clun.Cookie.parse(
  "x=y; Domain=bad_domain; Domain=last.example; Path=/one; Path=relative; Expires=bad; Expires=Sunday, 06-Nov-94 08:49:37 GMT; Max-Age=5; Max-Age=x; SameSite=None; SameSite=bogus",
);
check(repeated.domain === "last.example", "last domain candidate");
check(repeated.path === "/one", "invalid repeated path retained");
check(repeated.expires.getTime() === 784111777000, "RFC850 date");
check(repeated.maxAge === 5, "invalid repeated maxAge retained");
check(repeated.sameSite === "none", "invalid repeated sameSite retained");

checkThrows(
  () => Clun.Cookie.parse("x=y; Domain=first.example; Domain=bad_domain"),
  "TypeError",
  "Invalid cookie domain: contains invalid characters",
  "final domain validation",
);

const dateCases = [
  ["Sun Nov  6 08:49:37 1994", 784111777000],
  ["06 Nov 1994 08:49:37 GMT", 784111777000],
  ["Nov 06 1994 03:49:37 EST", 784111777000],
  ["11/06/1994 08:49:37 Z", 784111777000],
];
for (const entry of dateCases) {
  const parsed = Clun.Cookie.parse("date=v; Expires=" + entry[0]);
  check(parsed.expires.getTime() === entry[1], "date family " + entry[0]);
}

const maxAgeCases = [
  ["+0012junk", 12, "12"],
  ["12 34", 12, "12"],
  ["1.9", 1, "1"],
  ["9007199254740993", 9007199254740992, "9007199254740992"],
  ["9223372036854775807", 9223372036854776000, "9223372036854776000"],
  ["-9223372036854775808", -9223372036854776000, "-9223372036854776000"],
];
for (const entry of maxAgeCases) {
  const parsed = Clun.Cookie.parse("max=v; Max-Age=" + entry[0] + "; Path=/");
  check(parsed.maxAge === entry[1], "Max-Age value " + entry[0]);
  check(parsed.toString().indexOf("Max-Age=" + entry[2]) !== -1, "Max-Age spelling " + entry[0]);
}

for (const invalid of ["+", "-", "", "x1", "9223372036854775808", "-9223372036854775809"]) {
  const parsed = Clun.Cookie.parse("max=v; Max-Age=7; Max-Age=" + invalid + "; Path=/");
  check(parsed.maxAge === 7, "invalid Max-Age retained " + invalid);
}

const extendedPositive = new Clun.Cookie("future", "v", { expires: 253402300800 });
check(extendedPositive.toString().indexOf("Sat, 01 Jan 10000 00:00:00 GMT") !== -1, "extended positive year");
const extendedNegative = new Clun.Cookie("past", "v", { expires: -62198755200 });
check(extendedNegative.toString().indexOf("Fri, 01 Jan -0001 00:00:00 GMT") !== -1, "extended negative year");

const encoded = new Clun.Cookie("encoded", "AZ az;+%/=");
check(encoded.toString().indexOf("encoded=AZ%20az%3B%2B%25%2F%3D") === 0, "percent encoding");
const euro = new Clun.Cookie("euro", "\u20ac");
check(euro.toString().indexOf("euro=%E2%82%AC") === 0, "UTF-8 encoding");

checkThrows(() => Clun.Cookie.parse(), "TypeError", "Not enough arguments", "parse missing argument", "ERR_MISSING_ARGS");
checkThrows(() => Clun.Cookie.parse("a"), "TypeError", "Invalid cookie string: empty", "single-character fast path");
checkThrows(() => Clun.Cookie.parse("missing-equals"), "TypeError", "Invalid cookie string: no '=' found", "missing equals");
checkThrows(() => Clun.Cookie.parse("missing; Path=/"), "TypeError", "Invalid cookie string: no '=' found", "missing pair equals");
checkThrows(() => Clun.Cookie.parse("="), "TypeError", "Invalid cookie string: empty", "bare equals");
checkThrows(() => Clun.Cookie.parse("=value"), "TypeError", "Invalid cookie string: name cannot be empty", "empty name");
checkThrows(() => Clun.Cookie.parse("x=y\rInjected: yes"), "TypeError", "cookie string is not a valid HTTP header value", "CR rejection");
checkThrows(() => Clun.Cookie.parse("x=y\nInjected: yes"), "TypeError", "cookie string is not a valid HTTP header value", "LF rejection");
checkThrows(() => Clun.Cookie.parse("x=y\0Injected: yes"), "TypeError", "cookie string is not a valid HTTP header value", "NUL rejection");
checkThrows(() => Clun.Cookie.parse(" x=y"), "TypeError", "cookie string is not a valid HTTP header value", "leading whitespace rejection");
checkThrows(() => Clun.Cookie.parse("x=y "), "TypeError", "cookie string is not a valid HTTP header value", "trailing whitespace rejection");

console.log("web.cookies parsing ok");
