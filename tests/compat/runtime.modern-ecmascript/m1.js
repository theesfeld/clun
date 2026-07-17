// Phase 37 m1 public differential, pinned to Bun 1.3.14 (0d9b296af33f).
let keyCalls = 0;
const key = { toString() { keyCalls++; return "own"; } };
const object = Object.create({ inherited: true });
object.own = true;
try { Object.hasOwn(null, key); } catch (_) {}
console.log("Object.hasOwn", [Object.hasOwn(object, key), Object.hasOwn(object, "inherited"), keyCalls].join(","));

const source = [3, , 1];
const stable = [{ key: 1, id: "a" }, { key: 0, id: "b" }, { key: 1, id: "c" }];
console.log("Array.toReversed", source.toReversed().map(String).join(","), source.join(","));
console.log("Array.toSorted", stable.toSorted((a, b) => a.key - b.key).map(x => x.id).join(","));
console.log("Array.toSpliced", source.toSpliced(1, 1, "x", "y").map(String).join(","), source.join(","));
console.log("Array.with", source.with(-1, 9).map(String).join(","), source.join(","));

let lengthReads = 0;
try {
  Array.prototype.toSorted.call({ get length() { lengthReads++; return 0; } }, {});
} catch (error) {
  console.log("Array.toSorted.order", error.name, lengthReads);
}

const illFormed = "\uD800A\uDC00";
const repaired = illFormed.toWellFormed();
console.log("String.wellFormed", "ok".isWellFormed(), illFormed.isWellFormed(), [repaired.charCodeAt(0), repaired.charCodeAt(2)].join(","));

const error = new TypeError("x");
console.log("Error.isError", Error.isError(error), Error.isError({ name: "TypeError" }), Error.isError(new Proxy(error, {})));

const capability = Promise.withResolvers();
console.log("Promise.withResolvers", capability.promise instanceof Promise, typeof capability.resolve, typeof capability.reject, Object.keys(capability).join(","));
