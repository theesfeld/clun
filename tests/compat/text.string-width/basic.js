// Frozen Bun binding contract: oven-sh/bun c1076ce95effb909bfe9f596919b5dba5567d550.
function caught(fn) {
  try {
    fn();
    return null;
  } catch (error) {
    return error;
  }
}

const stringWidth = Clun.stringWidth;
const descriptor = Object.getOwnPropertyDescriptor(Clun, "stringWidth");
console.log(
  "api",
  stringWidth.name,
  stringWidth.length,
  typeof stringWidth,
  Object.prototype.hasOwnProperty.call(stringWidth, "prototype"),
  descriptor.writable,
  descriptor.enumerable,
  descriptor.configurable,
);
console.log(
  "call-shape",
  stringWidth.call({ ignored: true }, "abc"),
  caught(function () { new stringWidth("abc"); }).name,
);
const nameDescriptor = Object.getOwnPropertyDescriptor(stringWidth, "name");
const lengthDescriptor = Object.getOwnPropertyDescriptor(stringWidth, "length");
console.log(
  "function-descriptors",
  nameDescriptor.writable,
  nameDescriptor.enumerable,
  nameDescriptor.configurable,
  lengthDescriptor.writable,
  lengthDescriptor.enumerable,
  lengthDescriptor.configurable,
);

console.log(
  "coercion",
  stringWidth(),
  stringWidth(undefined),
  stringWidth(null),
  stringWidth(false),
  stringWidth(123),
);
console.log(
  "widths",
  stringWidth("hello"),
  stringWidth("a\t\nb\x7f"),
  stringWidth("e\u0301"),
  stringWidth("\u4e2d\u6587"),
  stringWidth("\ud83d\ude00"),
  stringWidth("\ud83d\udc69\u200d\ud83d\udcbb"),
  stringWidth("\ud83c\uddfa\ud83c\uddf8"),
);

const ansi = "\x1b[31mred\x1b[0m";
console.log(
  "ansi",
  stringWidth(ansi),
  stringWidth(ansi, { countAnsiEscapeCodes: false }),
  stringWidth(ansi, { countAnsiEscapeCodes: true }),
);
console.log(
  "count-option",
  stringWidth(ansi, { countAnsiEscapeCodes: null }),
  stringWidth(ansi, { countAnsiEscapeCodes: undefined }),
  stringWidth(ansi, { countAnsiEscapeCodes: "" }),
  stringWidth(ansi, { countAnsiEscapeCodes: 0 }),
  stringWidth(ansi, { countAnsiEscapeCodes: NaN }),
  stringWidth(ansi, { countAnsiEscapeCodes: "false" }),
);

const ambiguous = "\u2605";
console.log(
  "ambiguous-option",
  stringWidth(ambiguous),
  stringWidth(ambiguous, { ambiguousIsNarrow: null }),
  stringWidth(ambiguous, { ambiguousIsNarrow: "" }),
  stringWidth(ambiguous, { ambiguousIsNarrow: false }),
  stringWidth(ambiguous, { ambiguousIsNarrow: 0 }),
  stringWidth(ambiguous, { ambiguousIsNarrow: NaN }),
  stringWidth(ambiguous, { ambiguousIsNarrow: "false" }),
);

let reads = [];
const optionPrototype = {};
Object.defineProperty(optionPrototype, "countAnsiEscapeCodes", {
  configurable: true,
  get: function () { reads.push("count"); return true; },
});
Object.defineProperty(optionPrototype, "ambiguousIsNarrow", {
  configurable: true,
  get: function () { reads.push("ambiguous"); return false; },
});
console.log(
  "inherited-getters",
  stringWidth("\x1b[31m\u2605\x1b[0m", Object.create(optionPrototype)),
  reads.join(","),
);

try {
  Object.prototype.countAnsiEscapeCodes = true;
  Object.prototype.ambiguousIsNarrow = false;
  console.log(
    "prototype-pollution",
    stringWidth("\x1b[31m\u2605\x1b[0m", {}),
    stringWidth("\x1b[31m\u2605\x1b[0m", Object.prototype),
  );
} finally {
  delete Object.prototype.countAnsiEscapeCodes;
  delete Object.prototype.ambiguousIsNarrow;
}

reads = [];
const untouchedOptions = {};
Object.defineProperty(untouchedOptions, "countAnsiEscapeCodes", {
  get: function () { reads.push("count"); throw new Error("options touched"); },
});
console.log("empty-short-circuit", stringWidth("", untouchedOptions), reads.length);

reads = [];
const orderedInput = {
  toString: function () { reads.push("input"); return ansi; },
};
const orderedOptions = {};
Object.defineProperty(orderedOptions, "countAnsiEscapeCodes", {
  get: function () { reads.push("count"); return true; },
});
Object.defineProperty(orderedOptions, "ambiguousIsNarrow", {
  get: function () { reads.push("ambiguous"); return true; },
});
console.log("access-order", stringWidth(orderedInput, orderedOptions), reads.join(","));

const inputSentinel = new RangeError("input sentinel");
const throwingInput = {
  toString: function () { reads.push("input"); throw inputSentinel; },
};
reads = [];
let error = caught(function () { stringWidth(throwingInput, orderedOptions); });
console.log("input-error", error === inputSentinel, error.name, error.message, reads.join(","));

const optionSentinel = new RangeError("option sentinel");
const throwingOptions = {};
Object.defineProperty(throwingOptions, "countAnsiEscapeCodes", {
  get: function () { reads.push("count"); throw optionSentinel; },
});
Object.defineProperty(throwingOptions, "ambiguousIsNarrow", {
  get: function () { reads.push("ambiguous"); return true; },
});
reads = [];
error = caught(function () { stringWidth("x", throwingOptions); });
console.log("option-error", error === optionSentinel, error.name, error.message, reads.join(","));
error = caught(function () { stringWidth(Symbol("x")); });
console.log("symbol-error", error.name, error.message);

const toPrimitiveSymbol = {};
toPrimitiveSymbol[Symbol.toPrimitive] = function () { return Symbol("primitive"); };
const toStringSymbol = {
  toString: function () { return Symbol("string"); },
};
const valueOfSymbol = {
  toString: function () { return {}; },
  valueOf: function () { return Symbol("value"); },
};
const symbolErrors = [
  toPrimitiveSymbol,
  toStringSymbol,
  valueOfSymbol,
  Object(Symbol("wrapped")),
].map(function (input) {
  const symbolError = caught(function () { stringWidth(input); });
  return symbolError.name + ":" + symbolError.message;
});
console.log("indirect-symbol-errors", symbolErrors.join(" | "));

const primitiveSentinel = new RangeError("primitive sentinel");
const throwingPrimitive = {};
throwingPrimitive[Symbol.toPrimitive] = function (hint) {
  reads.push("primitive:" + hint);
  throw primitiveSentinel;
};
reads = [];
error = caught(function () { stringWidth(throwingPrimitive, orderedOptions); });
console.log(
  "primitive-error",
  error === primitiveSentinel,
  error.name,
  error.message,
  reads.join(","),
);

const valueSentinel = new RangeError("value sentinel");
const throwingValueOf = {
  toString: function () { reads.push("toString"); return {}; },
  valueOf: function () { reads.push("valueOf"); throw valueSentinel; },
};
reads = [];
error = caught(function () { stringWidth(throwingValueOf, orderedOptions); });
console.log(
  "valueof-error",
  error === valueSentinel,
  error.name,
  error.message,
  reads.join(","),
);
console.log(
  "primitive-options",
  stringWidth("abc", null),
  stringWidth("abc", false),
  stringWidth("abc", 1),
  stringWidth("abc", Symbol("options")),
);

const replacement = function () { return -1; };
Clun.stringWidth = replacement;
const assignmentWorked = Clun.stringWidth === replacement;
const deleteError = caught(function () {
  "use strict";
  delete Clun.stringWidth;
});
const redefineError = caught(function () {
  Object.defineProperty(Clun, "stringWidth", { configurable: true });
});
Clun.stringWidth = stringWidth;
console.log(
  "property-mutation",
  assignmentWorked,
  deleteError.name,
  redefineError.name,
  Clun.stringWidth === stringWidth,
);
