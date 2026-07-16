function check(condition, label) {
  if (!condition) throw new Error("web.cookies security: " + label);
}

function codeUnits(value) {
  const result = [];
  for (let index = 0; index < value.length; index++) result.push(value.charCodeAt(index).toString(16));
  return result.join(",");
}

function checkError(fn, name, message, label) {
  try {
    fn();
  } catch (error) {
    check(error.name === name, label + " name");
    check(error.message === message, label + " message");
    return;
  }
  throw new Error("web.cookies security: " + label + " did not throw");
}

for (const name of ["", "bad name", "bad=name", "bad;name", "bad\rname", "bad\nname", "bad\0name", "\u00e9"]) {
  checkError(() => new Clun.Cookie(name, "v"), "TypeError", "Invalid cookie name: contains invalid characters", "invalid name " + codeUnits(name));
}
for (const path of ["bad;path", "bad<path", "bad\rpath", "bad\npath", "\u00e9"]) {
  checkError(() => new Clun.Cookie("safe", "v", { path }), "TypeError", "Invalid cookie path: contains invalid characters", "invalid path " + codeUnits(path));
}
for (const domain of ["UPPER.example", "bad_domain", "bad\rdomain", "\u00e9.example"]) {
  checkError(() => new Clun.Cookie("safe", "v", { domain }), "TypeError", "Invalid cookie domain: contains invalid characters", "invalid domain " + codeUnits(domain));
}

for (const value of ["x=y\rSet-Cookie: injected=1", "x=y\nSet-Cookie: injected=1", "x=y\0tail"]) {
  checkError(() => Clun.Cookie.parse(value), "TypeError", "cookie string is not a valid HTTP header value", "wire injection");
}
const responseHeaders = new Headers();
checkError(() => responseHeaders.append("set-cookie", "safe=1\r\nX-Evil: yes"), "TypeError", "Invalid HTTP header value", "header injection");
check(responseHeaders.getSetCookie().length === 0, "injection leaves headers unchanged");

const malformed = [
  ["%", "fffd"],
  ["%1", "fffd,31"],
  ["%ZZ", "fffd"],
  ["%G1", "fffd"],
  ["%C2", "fffd"],
  ["%C2%7F", "fffd,7f"],
  ["%C0%80", "fffd"],
  ["%E0%80%AF", "fffd"],
  ["%ED%A0%80", "fffd"],
  ["%F4%90%80%80", "fffd"],
  ["%F8%80%80%80%80", "fffd,fffd,fffd,fffd,fffd"],
  ["%E2%28%A1", "fffd,28,fffd"],
  ["%F1%7F%80%80", "fffd,7f,fffd,fffd"],
  ["%41x%E2%82%AC", "41,78,20ac"],
];
for (const entry of malformed) {
  const value = new Clun.CookieMap("case=" + entry[0]).get("case");
  check(codeUnits(value) === entry[1], "malformed percent " + entry[0]);
}

const pollutionMap = new Clun.CookieMap();
pollutionMap.set("__proto__", "safe");
pollutionMap.set("constructor", "also-safe");
pollutionMap.set("prototype", "data");
const pollution = pollutionMap.toJSON();
check(Object.getPrototypeOf(pollution) === Object.prototype, "pollution JSON prototype");
for (const name of ["__proto__", "constructor", "prototype"]) {
  check(Object.prototype.hasOwnProperty.call(pollution, name), "pollution own property " + name);
}
check(pollution.__proto__ === "safe" && pollution.constructor === "also-safe", "pollution data values");

const prefixes = new Clun.CookieMap();
prefixes.delete("__Secure-session");
prefixes.delete("__HOST-token");
const tombstones = prefixes.toSetCookieHeaders();
check(tombstones.length === 2, "prefix tombstone count");
check(tombstones[0].indexOf("__Secure-session=;") === 0 && tombstones[0].indexOf("Secure") !== -1, "Secure prefix tombstone");
check(tombstones[1].indexOf("__HOST-token=;") === 0 && tombstones[1].indexOf("Secure") !== -1, "Host prefix tombstone");

checkError(() => Clun.Cookie.prototype.serialize.call({}), "TypeError", "Can only call Cookie.serialize on instances of Cookie", "Cookie receiver isolation");
checkError(() => Clun.CookieMap.prototype.toJSON.call({}), "TypeError", "Can only call CookieMap.toJSON on instances of CookieMap", "CookieMap receiver isolation");
checkError(() => Headers.prototype.get.call({ "%store%": [] }, "cookie"), "TypeError", "Illegal invocation", "Headers private store isolation");
checkError(() => Response.prototype.text.call({ "%body%": "forged" }), "TypeError", "Illegal invocation", "Response private body isolation");

function largeHeader(count) {
  const fields = [];
  for (let index = 0; index < count; index++) fields.push("key" + index + "=value" + index);
  return fields.join("; ");
}
for (const count of [1024, 2048, 4096]) {
  const map = new Clun.CookieMap(largeHeader(count));
  check(map.size === count, "large map size " + count);
  check(map.get("key" + (count - 1)) === "value" + (count - 1), "large map tail " + count);
}

const lone = "\ud800";
const noPercent = new Clun.CookieMap("lone=" + lone);
check(codeUnits(noPercent.get("lone")) === "d800", "no-percent lone surrogate preserved");
const percentMode = new Clun.CookieMap("lone=" + lone + "; encoded=%41");
check(codeUnits(percentMode.get("lone")) === "ef,bf,bd", "percent-mode replacement UTF-8 bytes");

console.log("web.cookies security ok");
