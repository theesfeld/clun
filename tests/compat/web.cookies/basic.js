function check(condition, label) {
  if (!condition) throw new Error("web.cookies basic: " + label);
}

function dataDescriptor(object, key, writable, enumerable, configurable) {
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  const label = String(key);
  check(!!descriptor, label + " descriptor exists");
  check(descriptor.writable === writable, label + " writable");
  check(descriptor.enumerable === enumerable, label + " enumerable");
  check(descriptor.configurable === configurable, label + " configurable");
}

const cookieBinding = Object.getOwnPropertyDescriptor(Clun, "Cookie");
const mapBinding = Object.getOwnPropertyDescriptor(Clun, "CookieMap");
check(!cookieBinding.writable && cookieBinding.enumerable && !cookieBinding.configurable, "Cookie binding");
check(!mapBinding.writable && mapBinding.enumerable && !mapBinding.configurable, "CookieMap binding");
check(Reflect.ownKeys(Clun.Cookie).map(String).join(",") === "length,name,prototype,parse,from", "Cookie own keys");
check(Clun.Cookie.name === "Cookie" && Clun.Cookie.length === 2, "Cookie name and length");
dataDescriptor(Clun.Cookie, "length", false, false, true);
dataDescriptor(Clun.Cookie, "name", false, false, true);
dataDescriptor(Clun.Cookie, "prototype", false, false, false);
dataDescriptor(Clun.Cookie, "parse", true, true, false);
dataDescriptor(Clun.Cookie, "from", true, true, false);
check(Clun.Cookie.parse.length === 1 && Clun.Cookie.from.length === 3, "static arities");
check(
  Reflect.ownKeys(Clun.Cookie.prototype).map(String).join(",") ===
    "constructor,name,value,domain,path,expires,maxAge,secure,httpOnly,sameSite,partitioned,isExpired,toString,toJSON,serialize,Symbol(Symbol.toStringTag)",
  "Cookie prototype order",
);
dataDescriptor(Clun.Cookie.prototype, "constructor", true, false, true);
for (const key of ["name", "value", "domain", "path", "expires", "maxAge", "secure", "httpOnly", "sameSite", "partitioned"]) {
  const descriptor = Object.getOwnPropertyDescriptor(Clun.Cookie.prototype, key);
  check(!!descriptor.get, key + " getter");
  check((key === "name") === (descriptor.set === undefined), key + " setter shape");
  check(descriptor.enumerable && descriptor.configurable, key + " accessor flags");
}
for (const key of ["isExpired", "toString", "toJSON", "serialize"]) {
  dataDescriptor(Clun.Cookie.prototype, key, true, true, true);
  check(Clun.Cookie.prototype[key].length === 0, key + " arity");
}
dataDescriptor(Clun.Cookie.prototype, Symbol.toStringTag, false, false, true);

const cookie = new Clun.Cookie("sid", "hello world");
check(cookie.name === "sid" && cookie.value === "hello world", "name and value");
check(cookie.domain === null && cookie.path === "/", "domain and path defaults");
check(cookie.expires === undefined && cookie.maxAge === undefined, "expiry defaults");
check(!cookie.secure && !cookie.httpOnly && !cookie.partitioned, "flag defaults");
check(cookie.sameSite === "lax" && !cookie.isExpired(), "sameSite and expiry defaults");
check(cookie.toString() === "sid=hello%20world; Path=/; SameSite=Lax", "default serialization");
check(cookie.serialize() === cookie.toString(), "serialize alias behavior");
check(cookie instanceof Clun.Cookie, "Cookie instanceof");
check(Object.prototype.toString.call(cookie) === "[object Cookie]", "Cookie tag");
check(Reflect.ownKeys(cookie).length === 0, "Cookie private state");

const json = cookie.toJSON();
check(Object.getPrototypeOf(json) === null, "Cookie JSON null prototype");
check(
  Reflect.ownKeys(json).join(",") === "name,value,path,secure,sameSite,httpOnly,partitioned",
  "Cookie JSON key order",
);
check(json.name === "sid" && json.value === "hello world" && json.path === "/", "Cookie JSON values");

const emptyDomain = new Clun.Cookie("domain", "v", { domain: "" });
check(emptyDomain.domain === "", "explicit empty domain getter");
check(!Object.prototype.hasOwnProperty.call(emptyDomain.toJSON(), "domain"), "empty domain JSON omission");
check(emptyDomain.toString().indexOf("Domain=") === -1, "empty domain wire omission");

const dated = new Clun.Cookie("dated", "v", { expires: 0 });
const firstGetterDate = dated.expires;
const firstJsonDate = dated.toJSON().expires;
check(firstGetterDate instanceof Date && firstGetterDate.getTime() === 0, "expires Date");
check(firstJsonDate instanceof Date && firstJsonDate.getTime() === 0, "JSON expires Date");
check(firstGetterDate !== firstJsonDate, "JSON Date freshness");
firstGetterDate.setTime(1);
check(dated.expires !== firstGetterDate && dated.expires.getTime() === 0, "mutated cache repair");

function Alternate() {}
const reflectedCookie = Reflect.construct(Clun.Cookie, ["reflect", "v"], Alternate);
check(Object.getPrototypeOf(reflectedCookie) === Clun.Cookie.prototype, "Cookie ignores newTarget");
check(!(reflectedCookie instanceof Alternate), "Cookie rejects alternate prototype");
class CookieSubclass extends Clun.Cookie {}
const subclassCookie = new CookieSubclass("sub", "v");
check(Object.getPrototypeOf(subclassCookie) === Clun.Cookie.prototype, "Cookie subclass base allocation");
check(!(subclassCookie instanceof CookieSubclass), "Cookie subclass instanceof");

check(Clun.CookieMap.name === "CookieMap" && Clun.CookieMap.length === 1, "CookieMap name and length");
dataDescriptor(Clun.CookieMap, "length", false, false, true);
dataDescriptor(Clun.CookieMap, "name", false, false, true);
dataDescriptor(Clun.CookieMap, "prototype", false, false, false);
check(
  Reflect.ownKeys(Clun.CookieMap.prototype).map(String).join(",") ===
    "constructor,get,toSetCookieHeaders,has,set,delete,entries,keys,values,forEach,toJSON,size,Symbol(Symbol.iterator),Symbol(Symbol.toStringTag)",
  "CookieMap prototype order",
);
dataDescriptor(Clun.CookieMap.prototype, "constructor", true, false, true);
const mapMethodLengths = {
  get: 1,
  toSetCookieHeaders: 0,
  has: 1,
  set: 2,
  delete: 1,
  entries: 0,
  keys: 0,
  values: 0,
  forEach: 1,
  toJSON: 0,
};
for (const key of Object.keys(mapMethodLengths)) {
  dataDescriptor(Clun.CookieMap.prototype, key, true, true, true);
  check(Clun.CookieMap.prototype[key].length === mapMethodLengths[key], key + " arity");
}
check(Clun.CookieMap.prototype[Symbol.iterator] === Clun.CookieMap.prototype.entries, "iterator alias");
dataDescriptor(Clun.CookieMap.prototype, Symbol.iterator, true, false, true);
dataDescriptor(Clun.CookieMap.prototype, Symbol.toStringTag, false, false, true);
const sizeDescriptor = Object.getOwnPropertyDescriptor(Clun.CookieMap.prototype, "size");
check(!!sizeDescriptor.get && sizeDescriptor.set === undefined, "size accessor shape");
check(sizeDescriptor.enumerable && !sizeDescriptor.configurable, "size descriptor flags");

const map = new Clun.CookieMap("a=1; empty=");
check(map.size === 2 && map.get("a") === "1" && map.get("empty") === "", "CookieMap basics");
check(Object.prototype.toString.call(map) === "[object CookieMap]", "CookieMap tag");
check(Reflect.ownKeys(map).length === 0, "CookieMap private state");
const mapIterator = map.entries();
check(Object.prototype.toString.call(mapIterator) === "[object CookieMap Iterator]", "iterator tag");
check(mapIterator[Symbol.iterator]() === mapIterator && Reflect.ownKeys(mapIterator).length === 0, "iterator private state");
const mapIteratorPrototype = Object.getPrototypeOf(mapIterator);
dataDescriptor(mapIteratorPrototype, "next", true, true, true);
dataDescriptor(mapIteratorPrototype, Symbol.toStringTag, false, false, true);

const reflectedMap = Reflect.construct(Clun.CookieMap, ["a=1"], Alternate);
check(Object.getPrototypeOf(reflectedMap) === Clun.CookieMap.prototype, "CookieMap ignores newTarget");
class MapSubclass extends Clun.CookieMap {}
const subclassMap = new MapSubclass("a=1");
check(Object.getPrototypeOf(subclassMap) === Clun.CookieMap.prototype, "CookieMap subclass base allocation");
check(!(subclassMap instanceof MapSubclass), "CookieMap subclass instanceof");

console.log("web.cookies basic ok");
