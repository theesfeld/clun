function errorName(fn) {
  try {
    fn();
    return "NO_THROW";
  } catch (error) {
    return error.name + ":" + (error.code || "-");
  }
}

const cookieDescriptor = Object.getOwnPropertyDescriptor(Clun, "Cookie");
console.log(
  Reflect.ownKeys(Clun.Cookie).map(String).join(","),
  Clun.Cookie.length,
  cookieDescriptor.writable,
  cookieDescriptor.enumerable,
  cookieDescriptor.configurable,
);
console.log(Object.keys(Clun.Cookie.prototype).join(","));

const cookie = new Clun.Cookie("sid", "hello world", {
  domain: "example.com",
  secure: true,
  httpOnly: true,
  sameSite: "strict",
});
console.log(
  cookie.toString(),
  cookie instanceof Clun.Cookie,
  Object.prototype.toString.call(cookie),
  Reflect.ownKeys(cookie).length,
);
cookie.expires = 0;
const firstDate = cookie.expires;
const jsonDate = cookie.toJSON().expires;
firstDate.setTime(1);
console.log(
  cookie.expires.getTime(),
  cookie.expires === firstDate,
  jsonDate === cookie.expires,
);
console.log(
  errorName(() => Clun.Cookie.prototype.toString.call({})),
  errorName(() => Clun.Cookie("a", "b")),
);

const map = new Clun.CookieMap("a=1; a=2; empty=");
console.log(
  map.get("a"),
  map.has("empty"),
  map.size,
  [...map].map((entry) => entry.join("=")).join("|"),
);
map.set(cookie);
cookie.value = "changed";
map.delete("a");
console.log(
  map.get("a"),
  map.get("sid"),
  map.toSetCookieHeaders().join("|"),
  JSON.stringify(map.toJSON()),
);
const iterator = map.entries();
console.log(
  Object.prototype.toString.call(map),
  Object.prototype.toString.call(iterator),
  iterator[Symbol.iterator]() === iterator,
  Reflect.ownKeys(map).length,
);

const headers = new Headers([
  ["cookie", "a=1"],
  ["cookie", "b=2"],
  ["set-cookie", "x=1"],
  ["set-cookie", "y=2"],
]);
console.log(
  headers.get("cookie"),
  headers.get("set-cookie"),
  headers.getAll("set-cookie").join("|"),
  headers.getSetCookie().join("|"),
);
console.log([...headers].map((entry) => entry.join(":")).join("|"));
console.log(
  errorName(() => Headers.prototype.get.call({}, "x")),
  errorName(() => headers.set("bad\rname", "x")),
  headers.get("cookie"),
);

const response = new Response("ok");
const request = new Request("https://example.com");
console.log(
  response instanceof Response,
  Reflect.ownKeys(response).join(","),
  errorName(() => Response.prototype.text.call({})),
  Object.getPrototypeOf(request) === Request.prototype,
  "cookies" in request,
);
