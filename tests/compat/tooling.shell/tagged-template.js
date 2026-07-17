function assert(condition, message) {
  if (!condition) throw new Error(message);
}

let sameSite;
function cacheProbe(value) {
  return inspect`cache:${value}:site`;
}

function inspect(strings, value) {
  assert(Object.isFrozen(strings), "cooked strings must be frozen");
  assert(Object.isFrozen(strings.raw), "raw strings must be frozen");
  assert(Object.getOwnPropertyDescriptor(strings, "raw").enumerable === false,
    "raw must be non-enumerable");
  if (!sameSite && strings[0] === "cache:") sameSite = strings;
  if (strings[0] === "cache:") assert(strings === sameSite, "same site must reuse its object");
  return value;
}

assert(cacheProbe(1) === 1 && cacheProbe(2) === 2, "substitutions must preserve values");

const receiver = {
  name: "receiver",
  tag(strings, value) {
    return `${this.name}:${strings.join("|")}:${value}`;
  },
};
assert(receiver.tag`left${7}right` === "receiver:left|right:7", "member receiver");

const order = [];
const holder = {
  get tag() {
    order.push("get");
    return function () {
      order.push("call");
    };
  },
};
function key() { order.push("key"); return "tag"; }
function substitution() { order.push("substitution"); return 1; }
holder[key()]`x${substitution()}y`;
assert(order.join(",") === "key,get,substitution,call", "evaluation order");

let substitutions = 0;
try {
  ({ tag: 1 }).tag`x${substitutions++}y`;
  throw new Error("non-callable tag must throw");
} catch (error) {
  assert(error.name === "TypeError", "non-callable tag error");
}
assert(substitutions === 0, "callability must be checked before substitutions");

function invalidEscape(strings) {
  assert(strings[0] === undefined, "invalid escape cooked value");
  return strings.raw[0];
}
const raw = invalidEscape`\x`;
assert(raw.length === 2 && raw.charCodeAt(0) === 92 && raw.charCodeAt(1) === 120,
  "invalid escape raw value");

console.log("tagged-template-ok");
