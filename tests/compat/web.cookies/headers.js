function check(condition, label) {
  if (!condition) throw new Error("web.cookies headers: " + label);
}

function checkError(fn, name, message, label) {
  try {
    fn();
  } catch (error) {
    check(error.name === name, label + " name");
    check(error.message === message, label + " message");
    return;
  }
  throw new Error("web.cookies headers: " + label + " did not throw");
}

function dataDescriptor(object, key, writable, enumerable, configurable) {
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  check(!!descriptor, key + " descriptor exists");
  check(descriptor.writable === writable, key + " writable");
  check(descriptor.enumerable === enumerable, key + " enumerable");
  check(descriptor.configurable === configurable, key + " configurable");
}

dataDescriptor(Headers.prototype, "getAll", true, true, true);
dataDescriptor(Headers.prototype, "getSetCookie", true, true, true);
check(Headers.prototype.getAll.length === 1, "getAll arity");
check(Headers.prototype.getSetCookie.length === 0, "getSetCookie arity");
for (const [method, args] of [
  ["get", []],
  ["has", []],
  ["set", []],
  ["set", ["x"]],
  ["append", []],
  ["append", ["x"]],
  ["delete", []],
]) {
  try {
    Reflect.apply(Headers.prototype[method], new Headers(), args);
    throw new Error("web.cookies headers: missing " + method + " did not throw");
  } catch (error) {
    check(error.name === "TypeError", "missing " + method + " name");
    check(error.message === "Not enough arguments", "missing " + method + " message");
    check(error.code === "ERR_MISSING_ARGS", "missing " + method + " code");
  }
}
checkError(() => new Headers().getAll(), "TypeError", "Missing argument", "missing getAll argument");
checkError(() => new Headers(null), "TypeError", "Type error", "Headers null initializer");
checkError(
  () => new Request("https://example.com/", { headers: null }),
  "TypeError",
  "Type error",
  "Request null HeadersInit",
);
checkError(
  () => new Response(null, { headers: null }),
  "TypeError",
  "Type error",
  "Response null HeadersInit",
);
const headersInitOrder = [];
checkError(
  () => new Headers([
    [{ toString() { headersInitOrder.push("first"); return "x"; } }],
    [{ toString() { headersInitOrder.push("later"); throw new Error("later conversion"); } }, "v"],
  ]),
  "Error",
  "later conversion",
  "Headers materializes before pair validation",
);
check(headersInitOrder.join("|") === "first|later", "Headers two-phase initializer order");

const headers = new Headers([
  ["z-last", "z"],
  ["cookie", "a=1"],
  ["set-cookie", "x=1"],
  ["a-first", "a"],
  ["cookie", "b=2"],
  ["set-cookie", "y=2"],
]);
check(headers instanceof Headers && Object.getPrototypeOf(headers) === Headers.prototype, "canonical Headers identity");
check(Reflect.ownKeys(headers).length === 0, "private Headers state");
check(headers.get("cookie") === "a=1; b=2", "constructed Cookie join");
check(headers.get("set-cookie") === "x=1, y=2", "Set-Cookie joined get");
checkError(() => headers.getAll("cookie"), "TypeError", "Only \"set-cookie\" is supported.", "getAll ordinary field");
check(headers.getAll("set-cookie").join("|") === "x=1|y=2", "Set-Cookie getAll fields");
check(headers.getSetCookie().join("|") === "x=1|y=2", "getSetCookie fields");
checkError(() => headers.getAll("missing"), "TypeError", "Only \"set-cookie\" is supported.", "getAll missing field");
check(headers.getSetCookie() !== headers.getSetCookie(), "fresh result arrays");

const entries = [...headers].map((entry) => entry.join(":"));
check(
  entries.join("|") === "a-first:a|cookie:a=1; b=2|z-last:z|set-cookie:x=1|set-cookie:y=2",
  "iteration view",
);
check([...headers.keys()].join("|") === "a-first|cookie|z-last|set-cookie|set-cookie", "keys view");
check([...headers.values()].join("|") === "a|a=1; b=2|z|x=1|y=2", "values view");
const calls = [];
headers.forEach(function (value, name, owner) {
  calls.push(name + ":" + value + ":" + (owner === headers) + ":" + (this === calls));
}, calls);
check(
  calls.join("|") ===
    "a-first:a:true:true|cookie:a=1; b=2:true:true|z-last:z:true:true|set-cookie:x=1:true:true|set-cookie:y=2:true:true",
  "forEach view",
);
const liveForEachHeaders = new Headers([["a", "1"], ["b", "2"]]);
const liveForEachCalls = [];
liveForEachHeaders.forEach((value, name) => {
  liveForEachCalls.push(name + "=" + value);
  if (name === "a") liveForEachHeaders.append("c", "3");
});
check(liveForEachCalls.join("|") === "a=1|b=2|c=3", "live forEach append");
checkError(
  () => new Headers().forEach(),
  "TypeError",
  "Cannot call callback on a non-function",
  "empty forEach validates callback",
);
checkError(
  () => new Headers().forEach(1),
  "TypeError",
  "Cannot call callback on a non-function",
  "empty forEach rejects non-callable callback",
);

const other = new Headers([["cookie", "other=1"]]);
check(Headers.prototype.get.call(other, "cookie") === "other=1", "borrowed branded receiver");
checkError(() => Headers.prototype.get.call({}, "cookie"), "TypeError", "Illegal invocation", "plain receiver");
checkError(() => Headers.prototype.get.call({ "%store%": [["cookie", "forged=1"]] }, "cookie"), "TypeError", "Illegal invocation", "forged store");
const ordinaryDuplicates = new Headers([["x-test", "one"], ["x-test", "two"]]);
check(ordinaryDuplicates.get("x-test") === "one, two", "ordinary duplicate join");
check([...ordinaryDuplicates].length === 1 && [...ordinaryDuplicates][0][1] === "one, two", "ordinary duplicate iteration");

const nestedIterable = new Headers(new Set([
  new Set(["x-nested", "yes"]),
  new Set(["set-cookie", "nested=1"]),
]));
check(nestedIterable.get("x-nested") === "yes", "nested iterable initializer");
check(nestedIterable.getSetCookie().join("|") === "nested=1", "nested iterable Set-Cookie");
checkError(
  () => new Headers(new Set([new Set(["short"])])),
  "TypeError",
  "Header sub-sequence must contain exactly two items",
  "short nested pair",
);
checkError(
  () => new Headers(new Set([new Set(["long", "value", "extra"])])),
  "TypeError",
  "Header sub-sequence must contain exactly two items",
  "long nested pair",
);

let innerClosed = false;
let outerClosed = false;
let innerStep = 0;
let outerStep = 0;
const throwingHeaderValue = {
  toString() {
    throw new Error("header value boom");
  },
};
const pairIterator = {
  next() {
    innerStep++;
    if (innerStep === 1) return { value: "x-close", done: false };
    if (innerStep === 2) return { value: throwingHeaderValue, done: false };
    return { value: undefined, done: true };
  },
  return() {
    innerClosed = true;
    return { value: undefined, done: true };
  },
};
const pairIterable = {
  [Symbol.iterator]() {
    return pairIterator;
  },
};
const outerIterator = {
  next() {
    outerStep++;
    if (outerStep === 1) return { value: pairIterable, done: false };
    return { value: undefined, done: true };
  },
  return() {
    outerClosed = true;
    return { value: undefined, done: true };
  },
};
const closingInitializer = {
  [Symbol.iterator]() {
    return outerIterator;
  },
};
checkError(() => new Headers(closingInitializer), "Error", "header value boom", "abrupt value conversion");
check(innerClosed && outerClosed, "abrupt initializer closes nested iterators");

let terminalInnerClosed = false;
let terminalOuterClosed = false;
let terminalOuterStep = 0;
const terminalPairIterable = {
  [Symbol.iterator]() {
    return {
      next() {
        throw new Error("inner next boom");
      },
      return() {
        terminalInnerClosed = true;
        return { value: undefined, done: true };
      },
    };
  },
};
const terminalInitializer = {
  [Symbol.iterator]() {
    return {
      next() {
        terminalOuterStep++;
        if (terminalOuterStep === 1) return { value: terminalPairIterable, done: false };
        return { value: undefined, done: true };
      },
      return() {
        terminalOuterClosed = true;
        return { value: undefined, done: true };
      },
    };
  },
};
checkError(() => new Headers(terminalInitializer), "Error", "inner next boom", "abrupt inner next");
check(!terminalInnerClosed && terminalOuterClosed, "throwing inner next only closes outer iterator");

const recordReads = [];
const recordInit = {};
Object.defineProperty(recordInit, "hidden", {
  enumerable: false,
  get() {
    recordReads.push("hidden");
    return "no";
  },
});
Object.defineProperty(recordInit, "visible", {
  enumerable: true,
  get() {
    recordReads.push("visible");
    return "yes";
  },
});
const ignoredSymbol = Symbol("ignored");
Object.defineProperty(recordInit, ignoredSymbol, {
  enumerable: true,
  get() {
    recordReads.push("symbol");
    return "no";
  },
});
const recordHeaders = new Headers(recordInit);
check(recordHeaders.get("visible") === "yes", "enumerable record member");
check(recordHeaders.get("hidden") === null, "non-enumerable record member ignored");
check(recordReads.join("|") === "visible", "record getter filtering");

const recordOrder = [];
const orderedRecord = {};
Object.defineProperty(orderedRecord, "bad name", {
  enumerable: true,
  get() {
    recordOrder.push("bad.get");
    return { toString() { recordOrder.push("bad.str"); return "value"; } };
  },
});
Object.defineProperty(orderedRecord, "later", {
  enumerable: true,
  get() {
    recordOrder.push("later.get");
    return { toString() { recordOrder.push("later.str"); throw new Error("later record conversion"); } };
  },
});
checkError(
  () => new Headers(orderedRecord),
  "Error",
  "later record conversion",
  "record values convert before name validation",
);
check(
  recordOrder.join("|") === "bad.get|bad.str|later.get|later.str",
  "record conversion order",
);

const deletionReads = [];
const deletionRecord = {};
Object.defineProperty(deletionRecord, "first", {
  enumerable: true,
  get() {
    deletionReads.push("first");
    delete deletionRecord.second;
    return "one";
  },
});
Object.defineProperty(deletionRecord, "second", {
  configurable: true,
  enumerable: true,
  get() {
    deletionReads.push("second");
    return "two";
  },
});
const deletionHeaders = new Headers(deletionRecord);
check(deletionHeaders.get("first") === "one", "record keeps first member");
check(deletionHeaders.get("second") === null, "record rechecks deleted member descriptor");
check(deletionReads.join("|") === "first", "deleted record getter skipped");

const liveHeaders = new Headers([["b", "2"], ["c", "3"]]);
const liveEntries = liveHeaders.entries();
const headersIteratorPrototype = Object.getPrototypeOf(liveEntries);
check(Reflect.ownKeys(liveEntries).length === 0, "private iterator state");
check(liveEntries[Symbol.iterator]() === liveEntries, "iterator self identity");
check(Object.prototype.toString.call(liveEntries) === "[object Headers Iterator]", "iterator tag");
check(
  Reflect.ownKeys(headersIteratorPrototype).map(String).join(",") ===
    "next,Symbol(Symbol.toStringTag)",
  "iterator prototype keys",
);
dataDescriptor(headersIteratorPrototype, "next", true, false, true);
check(headersIteratorPrototype.next.length === 0, "iterator next arity");
const iteratorTag = Object.getOwnPropertyDescriptor(headersIteratorPrototype, Symbol.toStringTag);
check(!!iteratorTag && iteratorTag.value === "Headers Iterator", "iterator tag value");
check(iteratorTag.writable === false && iteratorTag.enumerable === false, "iterator tag flags");
check(iteratorTag.configurable === true, "iterator tag configurable");
checkError(
  () => headersIteratorPrototype.next.call({}),
  "TypeError",
  "Cannot call next() on a non-Iterator object",
  "iterator receiver brand",
);
check(Object.getPrototypeOf(liveHeaders.keys()) === headersIteratorPrototype, "keys iterator prototype");
check(Object.getPrototypeOf(liveHeaders.values()) === headersIteratorPrototype, "values iterator prototype");
check(liveEntries.next().value.join("=") === "b=2", "live iterator first value");
liveHeaders.set("a", "1");
check(liveEntries.next().value.join("=") === "b=2", "live iterator front insertion repetition");
liveHeaders.delete("b");
check(liveEntries.next().done === true, "live iterator deletion exhaustion");
liveHeaders.append("d", "4");
check(liveEntries.next().done === true, "terminal iterator remains exhausted");

const beforeCookie = headers.get("cookie");
checkError(() => headers.set("cookie", "bad\rvalue"), "TypeError", "Invalid HTTP header value", "CR value");
check(headers.get("cookie") === beforeCookie, "value validation before mutation");
checkError(() => headers.set("bad\nname", "value"), "TypeError", "Invalid HTTP header name", "LF name");
check(headers.get("cookie") === beforeCookie, "name validation before mutation");
headers.set("cookie", "replacement=1");
check(
  headers.get("cookie") === "replacement=1" && [...headers].filter((entry) => entry[0] === "cookie").length === 1,
  "set coalesces fields",
);
headers.append("cookie", "second=2");
check(headers.get("cookie") === "replacement=1; second=2", "append Cookie delimiter");

const request = new Request("https://example.com/", { headers });
check(request instanceof Request && Object.getPrototypeOf(request) === Request.prototype, "canonical Request identity");
check(request.headers.get("cookie") === "replacement=1; second=2", "Request header construction");
check(!("cookies" in request), "standalone Request negative cookie surface");
check(Reflect.ownKeys(request).join(",") === "method,url", "Request private headers and body state");

const response = new Response("private-body", {
  headers: [["set-cookie", "one=1"], ["set-cookie", "two=2"]],
});
check(response instanceof Response && Object.getPrototypeOf(response) === Response.prototype, "canonical Response identity");
check(response.headers.getSetCookie().join("|") === "one=1|two=2", "constructed Response Set-Cookie fields");
check(Reflect.ownKeys(response).join(",") === "status,statusText,ok,headers", "Response private body state");
checkError(() => Response.prototype.text.call(Object.create(Response.prototype)), "TypeError", "Illegal invocation", "Response brand");
const fakeResponse = Object.create(Response.prototype);
Object.defineProperty(fakeResponse, "%body%", { value: "forged" });
checkError(() => Response.prototype.text.call(fakeResponse), "TypeError", "Illegal invocation", "forged Response body");

console.log("web.cookies headers ok");
