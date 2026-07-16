// Frozen Bun API contract: oven-sh/bun c1076ce95effb909bfe9f596919b5dba5567d550,
// docs/runtime/semver.mdx and src/semver_jsc/SemverObject.rs.
function throws(fn) {
  try {
    fn();
    return false;
  } catch (error) {
    return true;
  }
}

function message(fn) {
  try {
    fn();
    return "NO_THROW";
  } catch (error) {
    return error.message;
  }
}

function errorName(fn) {
  try {
    fn();
    return "NO_THROW";
  } catch (error) {
    return error.name;
  }
}

console.log(
  "api",
  Object.keys(Clun.semver).join(","),
  Clun.semver.satisfies.name,
  Clun.semver.satisfies.length,
  Clun.semver.order.name,
  Clun.semver.order.length,
);

const satisfiesDescriptor = Object.getOwnPropertyDescriptor(Clun.semver, "satisfies");
const orderDescriptor = Object.getOwnPropertyDescriptor(Clun.semver, "order");
const namespaceDescriptor = Object.getOwnPropertyDescriptor(Clun, "semver");
console.log(
  "descriptors",
  satisfiesDescriptor.writable,
  satisfiesDescriptor.enumerable,
  satisfiesDescriptor.configurable,
  orderDescriptor.writable,
  orderDescriptor.enumerable,
  orderDescriptor.configurable,
);
const originalSemver = Clun.semver;
console.log(
  "namespace-descriptor",
  namespaceDescriptor.writable,
  namespaceDescriptor.enumerable,
  namespaceDescriptor.configurable,
  Reflect.set(Clun, "semver", {}),
  Reflect.deleteProperty(Clun, "semver"),
  Clun.semver === originalSemver,
);

console.log(
  "documented-ranges",
  Clun.semver.satisfies("1.0.0", "^1.0.0"),
  Clun.semver.satisfies("1.0.0", "^1.0.1"),
  Clun.semver.satisfies("1.0.0", "~1.0.0"),
  Clun.semver.satisfies("1.0.0", "~1.0.1"),
  Clun.semver.satisfies("1.0.0", "1.0.x"),
  Clun.semver.satisfies("1.0.0", "1.0.0 - 2.0.0"),
);

console.log(
  "range-forms",
  Clun.semver.satisfies("2.4.1", "2.x"),
  Clun.semver.satisfies("2.4.1", "1.x || >=2.4.0"),
  Clun.semver.satisfies("0.2.9", "^0.2.3"),
  Clun.semver.satisfies("0.3.0", "^0.2.3"),
  Clun.semver.satisfies("9.8.7", "*"),
);

console.log(
  "prerelease-build",
  Clun.semver.satisfies("1.2.3-beta.2", ">=1.2.3-beta.1 <1.2.3"),
  Clun.semver.satisfies("1.3.0-beta.1", "^1.2.3"),
  Clun.semver.satisfies("1.2.3+build.9", "1.2.3"),
);

console.log(
  "order",
  Clun.semver.order("1.0.0", "1.0.0"),
  Clun.semver.order("1.0.0", "1.0.1"),
  Clun.semver.order("1.0.1", "1.0.0"),
  Clun.semver.order("1.0.0-alpha", "1.0.0"),
  Clun.semver.order("1.0.0-alpha.10", "1.0.0-alpha.2"),
  Clun.semver.order("1.0.0+one", "1.0.0+two"),
);
console.log(
  "order-types",
  typeof Clun.semver.order("1.0.0", "1.0.0"),
  typeof Clun.semver.order("1.0.0", "2.0.0"),
  typeof Clun.semver.order("2.0.0", "1.0.0"),
);
console.log(
  "satisfies-types",
  typeof Clun.semver.satisfies("1.0.0", "^1.0.0"),
  typeof Clun.semver.satisfies("1.0.0", "^2.0.0"),
);

const versionLike = { toString: function () { return "1.2.3"; } };
const rangeLike = { toString: function () { return "^1.0.0"; } };
const laterLike = { toString: function () { return "2.0.0"; } };
const satisfies = Clun.semver.satisfies;
const order = Clun.semver.order;
console.log(
  "stringlike",
  Clun.semver.satisfies(versionLike, rangeLike),
  Clun.semver.order(versionLike, laterLike),
);
console.log(
  "detached-extras",
  satisfies.call({ ignored: true }, "1.2.3", "^1.0.0", "extra"),
  order.call(null, "1.2.3", "2.0.0", "extra"),
);
console.log(
  "normalization",
  Clun.semver.satisfies("=1.2.3", "1.2.3"),
  Clun.semver.satisfies(" v1.2.3 ", "= 1.2.3"),
  Clun.semver.order("v1.2.3", "=1.2.3"),
);

console.log(
  "invalid",
  Clun.semver.satisfies("not-a-version", "*"),
  Clun.semver.satisfies("1.0.0", "not-a-range"),
  throws(function () { Clun.semver.order("not-a-version", "1.0.0"); }),
  throws(function () { Clun.semver.order("1.0.0", "not-a-version"); }),
);
console.log(
  "strict-improvements",
  Clun.semver.satisfies("", "*"),
  Clun.semver.satisfies("1.2.3.4", "*"),
  Clun.semver.satisfies("01.2.3", "*"),
  Clun.semver.satisfies("1.2.3", "not-a-range"),
  throws(function () { Clun.semver.order("1", "1.0.0"); }),
);

console.log(
  "arity-nonascii",
  throws(function () { Clun.semver.satisfies("1.0.0"); }),
  throws(function () { Clun.semver.order("1.0.0"); }),
  Clun.semver.satisfies("1.0.0", "\u00e4"),
  Clun.semver.order("1.0.0", "\u00e4"),
);

const badStringLike = {
  toString: function () {
    throw new Error("coerce");
  },
};
console.log(
  "conversion",
  errorName(function () { Clun.semver.satisfies(Symbol("x"), "*"); }),
  errorName(function () { Clun.semver.order(Symbol("x"), "1.0.0"); }),
  message(function () { Clun.semver.satisfies(badStringLike, "*"); }),
);

let coercionLog = [];
const orderedLeft = { toString: function () { coercionLog.push("left"); return "1.2.3"; } };
const orderedRight = { toString: function () { coercionLog.push("right"); return "^1.0.0"; } };
const orderedLater = { toString: function () { coercionLog.push("right"); return "2.0.0"; } };
const satisfiesOrdered = Clun.semver.satisfies(orderedLeft, orderedRight);
console.log("satisfies-coercion-order", coercionLog.join(","), satisfiesOrdered);
coercionLog = [];
const orderOrdered = Clun.semver.order(orderedLeft, orderedLater);
console.log("order-coercion-order", coercionLog.join(","), orderOrdered);

const sentinel = new RangeError("sentinel");
const throwingLeft = { toString: function () { coercionLog.push("left"); throw sentinel; } };
const untouchedRight = { toString: function () { coercionLog.push("right"); return "1.0.0"; } };
coercionLog = [];
let caught = null;
try { Clun.semver.satisfies(throwingLeft, untouchedRight); } catch (error) { caught = error; }
console.log("satisfies-first-throw", caught === sentinel, caught.name, caught.message, coercionLog.join(","));
coercionLog = [];
caught = null;
try { Clun.semver.order(throwingLeft, untouchedRight); } catch (error) { caught = error; }
console.log("order-first-throw", caught === sentinel, caught.name, caught.message, coercionLog.join(","));

const secondSentinel = new RangeError("second");
const throwingRight = { toString: function () { coercionLog.push("right"); throw secondSentinel; } };
coercionLog = [];
caught = null;
try { Clun.semver.order(orderedLeft, throwingRight); } catch (error) { caught = error; }
console.log("order-second-throw", caught === secondSentinel, caught.name, caught.message, coercionLog.join(","));

const arityProbe = { toString: function () { coercionLog.push("coerced"); return "1.0.0"; } };
coercionLog = [];
caught = null;
try { Clun.semver.satisfies(arityProbe); } catch (error) { caught = error; }
const satisfiesArityName = caught.name;
const satisfiesArityMessage = caught.message;
const satisfiesArityCoercions = coercionLog.length;
coercionLog = [];
caught = null;
try { Clun.semver.order(arityProbe); } catch (error) { caught = error; }
console.log(
  "arity-before-coercion",
  satisfiesArityName,
  satisfiesArityMessage,
  satisfiesArityCoercions,
  caught.name,
  caught.message,
  coercionLog.length,
);

const validationSentinel = new RangeError("validate second");
const invalidFirst = { toString: function () { coercionLog.push("left"); return "bad"; } };
const validationThrowingRight = {
  toString: function () { coercionLog.push("right"); throw validationSentinel; },
};
coercionLog = [];
caught = null;
try { Clun.semver.satisfies(invalidFirst, validationThrowingRight); } catch (error) { caught = error; }
const satisfiesValidationIdentity = caught === validationSentinel;
const satisfiesValidationName = caught.name;
const satisfiesValidationMessage = caught.message;
const satisfiesValidationLog = coercionLog.join(",");
coercionLog = [];
caught = null;
try { Clun.semver.order(invalidFirst, validationThrowingRight); } catch (error) { caught = error; }
console.log(
  "validation-after-coercion",
  satisfiesValidationIdentity,
  satisfiesValidationName,
  satisfiesValidationMessage,
  satisfiesValidationLog,
  caught === validationSentinel,
  caught.name,
  caught.message,
  coercionLog.join(","),
);

console.log(
  "messages",
  errorName(function () { Clun.semver.satisfies("1.0.0"); }),
  errorName(function () { Clun.semver.order("bad-left", "bad-right"); }),
  message(function () { Clun.semver.satisfies("1.0.0"); }),
  message(function () { Clun.semver.order("1.0.0"); }),
  JSON.stringify(message(function () { Clun.semver.order("bad-left", "bad-right"); })),
  JSON.stringify(message(function () { Clun.semver.order("1.0.0", "bad-right"); })),
);
