function caught(fn) {
  try {
    fn();
    return "NO_THROW";
  } catch (error) {
    return error.name + ":" + error.message;
  }
}

function keys(object) {
  return Reflect.ownKeys(object).map(function (key) {
    return typeof key === "symbol" ? key.toString() : key;
  }).join("|");
}

const constructorDescriptor = Object.getOwnPropertyDescriptor(Clun, "Glob");
const prototypeDescriptor = Object.getOwnPropertyDescriptor(Clun.Glob, "prototype");
console.log(
  "constructor",
  typeof Clun.Glob,
  Clun.Glob.name,
  Clun.Glob.length,
  keys(Clun.Glob),
  constructorDescriptor.writable,
  constructorDescriptor.enumerable,
  constructorDescriptor.configurable,
  prototypeDescriptor.writable,
  prototypeDescriptor.enumerable,
  prototypeDescriptor.configurable,
);

console.log("prototype", keys(Clun.Glob.prototype));
for (const name of ["match", "scan", "scanSync"]) {
  const descriptor = Object.getOwnPropertyDescriptor(Clun.Glob.prototype, name);
  console.log(
    "method",
    name,
    descriptor.value.name,
    descriptor.value.length,
    Object.prototype.hasOwnProperty.call(descriptor.value, "prototype"),
    descriptor.writable,
    descriptor.enumerable,
    descriptor.configurable,
  );
}

const glob = new Clun.Glob("**/*.js");
class DerivedGlob extends Clun.Glob {}
const derived = new DerivedGlob("*.txt");
console.log(
  "instance",
  Object.prototype.toString.call(glob),
  keys(glob),
  Object.getPrototypeOf(derived) === DerivedGlob.prototype,
  derived.match("x.txt"),
);

console.log(
  "constructor-errors",
  caught(function () { Clun.Glob("*"); }),
  caught(function () { new Clun.Glob(); }),
  caught(function () { new Clun.Glob(undefined); }),
  caught(function () { new Clun.Glob({ toString: function () { return "*"; } }); }),
);

const boxed = new String("ignored");
const sentinel = new RangeError("boxed sentinel");
let conversionLog = [];
boxed[Symbol.toPrimitive] = function (hint) {
  conversionLog.push(hint);
  return "*.js";
};
const boxedGlob = new Clun.Glob(boxed);
console.log("boxed", boxedGlob.match("x.js"), conversionLog.join("|"));
boxed[Symbol.toPrimitive] = function () { throw sentinel; };
let identity = false;
try { new Clun.Glob(boxed); } catch (error) { identity = error === sentinel; }
console.log("boxed-error", identity);

console.log(
  "match",
  glob.match("a/b.js"),
  glob.match("a/b.txt"),
  caught(function () { glob.match(); }),
  caught(function () { glob.match(1); }),
  caught(function () { Clun.Glob.prototype.match.call({ }, "x.js"); }),
);

const root = ".";
const scanGlob = new Clun.Glob("__clun_glob_api_no_match__");
let reads = [];
const optionPrototype = {};
for (const name of [
  "onlyFiles",
  "throwErrorOnBrokenSymlink",
  "followSymlinks",
  "absolute",
  "cwd",
  "dot",
]) {
  Object.defineProperty(optionPrototype, name, {
    get: function () {
      reads.push(name);
      if (name === "cwd") return root;
      if (name === "dot") return true;
      return undefined;
    },
  });
}
const options = Object.create(optionPrototype);
const sync = scanGlob.scanSync(options);
const syncValues = [...sync];
console.log(
  "options",
  reads.join("|"),
  Object.prototype.toString.call(sync),
  sync[Symbol.iterator]() === sync,
  syncValues.length,
);

try {
  Object.prototype.dot = true;
  console.log(
    "prototype-pollution",
    [...scanGlob.scanSync({ cwd: root })].length,
  );
} finally {
  delete Object.prototype.dot;
}

console.log(
  "option-errors",
  caught(function () { scanGlob.scanSync(1); }),
  caught(function () { scanGlob.scanSync({ cwd: 1 }); }),
);

const asyncIterator = scanGlob.scan({ cwd: root });
const firstPromise = asyncIterator.next();
console.log(
  "async-shape",
  Object.prototype.toString.call(asyncIterator),
  asyncIterator[Symbol.asyncIterator]() === asyncIterator,
  firstPromise instanceof Promise,
  keys(Object.getPrototypeOf(asyncIterator)),
);

(async function () {
  const values = [];
  let step = await firstPromise;
  while (!step.done) {
    values.push(step.value);
    step = await asyncIterator.next();
  }
  console.log("async-values", values.length);

  const cancelled = scanGlob.scan({ cwd: root });
  const cancellation = await cancelled.return("stopped");
  console.log("async-return", cancellation.value, cancellation.done);
})();
