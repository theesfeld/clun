function check(condition, label) {
  if (!condition) throw new Error("proxy runtime check failed: " + label);
}

function typeError(fn, label) {
  try {
    fn();
  } catch (error) {
    check(error.name === "TypeError", label + " error type");
    return;
  }
  throw new Error("proxy runtime check failed: " + label + " did not throw");
}

check(typeof Proxy === "function", "global type");
check(Proxy.name === "Proxy" && Proxy.length === 2, "constructor name and length");
check(!Object.prototype.hasOwnProperty.call(Proxy, "prototype"), "no prototype property");
const revocableDescriptor = Object.getOwnPropertyDescriptor(Proxy, "revocable");
check(
  revocableDescriptor.writable && !revocableDescriptor.enumerable && revocableDescriptor.configurable,
  "revocable descriptor",
);
check(Proxy.revocable.name === "revocable" && Proxy.revocable.length === 2, "revocable metadata");
typeError(() => Proxy({}, {}), "constructor call");
typeError(() => new Proxy(1, {}), "primitive target");
typeError(() => new Proxy({}, null), "primitive handler");

const log = [];
const target = { x: 1, doomed: 2 };
const proto = { marker: true };
const handler = {
  getPrototypeOf(value) { log.push("getPrototypeOf"); return Reflect.getPrototypeOf(value); },
  setPrototypeOf(value, next) { log.push("setPrototypeOf"); return Reflect.setPrototypeOf(value, next); },
  isExtensible(value) { log.push("isExtensible"); return Reflect.isExtensible(value); },
  preventExtensions(value) { log.push("preventExtensions"); Object.preventExtensions(value); return true; },
  getOwnPropertyDescriptor(value, key) { log.push("getOwnPropertyDescriptor"); return Reflect.getOwnPropertyDescriptor(value, key); },
  defineProperty(value, key, descriptor) { log.push("defineProperty"); return Reflect.defineProperty(value, key, descriptor); },
  has(value, key) { log.push("has"); return Reflect.has(value, key); },
  get(value, key, receiver) { log.push("get"); return Reflect.get(value, key, receiver); },
  set(value, key, next, receiver) { log.push("set"); return Reflect.set(value, key, next, value); },
  deleteProperty(value, key) { log.push("deleteProperty"); return Reflect.deleteProperty(value, key); },
  ownKeys(value) { log.push("ownKeys"); return Reflect.ownKeys(value); },
};
const all = new Proxy(target, handler);
check(Object.getPrototypeOf(all) === Object.prototype, "getPrototypeOf trap");
check(Reflect.setPrototypeOf(all, proto), "setPrototypeOf trap");
check(Object.isExtensible(all), "isExtensible trap");
check(Object.getOwnPropertyDescriptor(all, "x").value === 1, "getOwnPropertyDescriptor trap");
Object.defineProperty(all, "made", { value: 3, configurable: true });
check("x" in all, "has trap");
check(all.x === 1, "get trap");
check(Reflect.set(all, "x", 4), "set trap");
check(Reflect.deleteProperty(all, "doomed"), "deleteProperty trap");
check(Reflect.ownKeys(all).join(",") === "x,made", "ownKeys trap");
check(Reflect.preventExtensions(all), "preventExtensions trap");
check(
  log.join(",") ===
    "getPrototypeOf,setPrototypeOf,isExtensible,getOwnPropertyDescriptor,defineProperty,has,get,set,deleteProperty,ownKeys,preventExtensions",
  "all internal traps",
);

let reads = 0;
let writes = 0;
const cached = new Proxy({ x: 1 }, {
  get(value, key) { reads++; return reads; },
  set(value, key, next) { writes++; value[key] = next; return true; },
});
const first = cached.x;
const second = cached.x;
cached.x = 4;
cached.x = 5;
check(first === 1 && second === 2 && reads === 2 && writes === 2, "inline caches never bypass traps");

const virtual = Object.getOwnPropertyDescriptor(
  new Proxy({}, { getOwnPropertyDescriptor() { return { value: 9, configurable: true }; } }),
  "virtual",
);
check(
  virtual.value === 9 && !virtual.writable && !virtual.enumerable && virtual.configurable,
  "virtual descriptor completion",
);

function frozenTarget() {
  const value = {};
  Object.defineProperty(value, "fixed", { value: 1, writable: false, configurable: false });
  return value;
}
typeError(() => new Proxy(frozenTarget(), { get() { return 2; } }).fixed, "get invariant");
typeError(() => Reflect.set(new Proxy(frozenTarget(), { set() { return true; } }), "fixed", 2), "set invariant");
typeError(() => "fixed" in new Proxy(frozenTarget(), { has() { return false; } }), "has invariant");
typeError(() => Reflect.deleteProperty(new Proxy(frozenTarget(), { deleteProperty() { return true; } }), "fixed"), "delete invariant");
typeError(() => Object.getOwnPropertyDescriptor(new Proxy(frozenTarget(), { getOwnPropertyDescriptor() { return undefined; } }), "fixed"), "descriptor invariant");
typeError(() => Reflect.ownKeys(new Proxy(frozenTarget(), { ownKeys() { return []; } })), "ownKeys omission invariant");
typeError(() => Reflect.ownKeys(new Proxy({}, { ownKeys() { return ["x", "x"]; } })), "ownKeys duplicate invariant");
typeError(() => Reflect.ownKeys(new Proxy({}, { ownKeys() { return [1]; } })), "ownKeys key type");
const duplicateReads = [];
const duplicateKeys = ["x", "x"];
Object.defineProperty(duplicateKeys, "2", {
  get() { duplicateReads.push("2"); return "z"; },
  configurable: true,
});
duplicateKeys.length = 3;
typeError(
  () => Reflect.ownKeys(new Proxy({}, { ownKeys() { return duplicateKeys; } })),
  "ownKeys duplicate check after list creation",
);
check(duplicateReads.join(",") === "2", "ownKeys reads complete before duplicate rejection");

const nonExtensible = {};
Object.preventExtensions(nonExtensible);
typeError(() => Object.isExtensible(new Proxy(nonExtensible, { isExtensible() { return true; } })), "isExtensible invariant");
typeError(() => Reflect.preventExtensions(new Proxy({}, { preventExtensions() { return true; } })), "preventExtensions invariant");
typeError(() => Object.getPrototypeOf(new Proxy(nonExtensible, { getPrototypeOf() { return null; } })), "prototype invariant");
typeError(() => Reflect.setPrototypeOf(new Proxy(nonExtensible, { setPrototypeOf() { return true; } }), null), "set prototype invariant");
typeError(() => Object.defineProperty(new Proxy({}, { defineProperty() { return true; } }), "x", { configurable: false }), "define non-configurable invariant");
typeError(() => Object.defineProperty(new Proxy(nonExtensible, { defineProperty() { return true; } }), "x", { value: 1 }), "define non-extensible invariant");
typeError(() => Object.getOwnPropertyDescriptor(new Proxy(nonExtensible, { getOwnPropertyDescriptor() { return { value: 1, configurable: true }; } }), "x"), "virtual non-extensible invariant");

function Fn(value) { this.value = value; return value + 1; }
const callable = new Proxy(Fn, {
  apply(value, receiver, args) { return Reflect.apply(value, receiver, args) * 2; },
  construct(value, args, newTarget) { return { value: args[0] * 3, newTarget }; },
});
check(callable(2) === 6, "apply trap");
const instance = new callable(4);
check(instance.value === 12 && instance.newTarget === callable, "construct trap");
typeError(() => new (new Proxy(Fn, { construct() { return 1; } }))(), "construct object invariant");

const nestedArray = new Proxy(new Proxy([1, 2], {}), {});
check(Array.isArray(nestedArray), "nested proxy IsArray");
check(Object.prototype.toString.call(nestedArray) === "[object Array]", "proxy array tag");
check(JSON.stringify(nestedArray) === "[1,2]", "proxy array JSON");
check([1].flatMap(() => new Proxy([2, 3], {})).join(",") === "2,3", "proxy flatMap IsArray");
check(
  JSON.stringify({ kept: 1, dropped: 2 }, new Proxy(["kept"], {})) === '{"kept":1}',
  "proxy JSON replacer IsArray",
);
const revokedReplacer = Proxy.revocable([], {});
revokedReplacer.revoke();
typeError(() => JSON.stringify({}, revokedReplacer.proxy), "revoked JSON replacer IsArray");

let prototypeHits = 0;
const exoticPrototype = new Proxy({}, { getPrototypeOf() { prototypeHits++; return null; } });
check(Reflect.setPrototypeOf({}, exoticPrototype) && prototypeHits === 0, "ordinary cycle scan stops at proxy");

const revocable = Proxy.revocable(Fn, {});
check(revocable.revoke.name === "" && revocable.revoke.length === 0, "revoker metadata");
check(Object.keys(revocable).join(",") === "proxy,revoke", "revocable result keys");
const revokedCallable = revocable.proxy;
revocable.revoke();
revocable.revoke();
check(typeof revokedCallable === "function", "revoked callable typeof");
typeError(() => revokedCallable(), "revoked call");
typeError(() => new revokedCallable(), "revoked construct");
typeError(() => revokedCallable.x, "revoked get");
typeError(() => Reflect.ownKeys(revokedCallable), "revoked ownKeys");

const revokedArray = Proxy.revocable([], {});
revokedArray.revoke();
typeError(() => Array.isArray(revokedArray.proxy), "revoked IsArray");

console.log("proxy-runtime-contract ok");
