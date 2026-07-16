// Frozen public baseline: Bun 1.3.14 at 0d9b296af33f2b851fcbf4df3e9ec89751734ba4.
// Frozen session/numeric engineering inventory: c1076ce95effb909bfe9f596919b5dba5567d550.
function errorSummary(fn) {
  try {
    fn();
    return "NO_THROW";
  } catch (error) {
    return error.name + "|" + error.code + "|" + error.message;
  }
}

const csrf = Clun.CSRF;
console.log("api", typeof csrf, Object.keys(csrf).join(","), csrf.generate.name, csrf.generate.length, csrf.verify.name, csrf.verify.length);

const generateDescriptor = Object.getOwnPropertyDescriptor(csrf, "generate");
const verifyDescriptor = Object.getOwnPropertyDescriptor(csrf, "verify");
const namespaceDescriptor = Object.getOwnPropertyDescriptor(Clun, "CSRF");
console.log(
  "descriptors",
  generateDescriptor.writable,
  generateDescriptor.enumerable,
  generateDescriptor.configurable,
  verifyDescriptor.writable,
  verifyDescriptor.enumerable,
  verifyDescriptor.configurable,
  namespaceDescriptor.writable,
  namespaceDescriptor.enumerable,
  namespaceDescriptor.configurable,
);

const originalNamespace = Clun.CSRF;
const replacementNamespace = {};
const namespaceSet = Reflect.set(Clun, "CSRF", replacementNamespace);
const namespaceChanged = Clun.CSRF === replacementNamespace;
const namespaceDeleted = Reflect.deleteProperty(Clun, "CSRF");
Reflect.set(Clun, "CSRF", originalNamespace);
console.log("namespace", namespaceSet, namespaceChanged, namespaceDeleted, Clun.CSRF === originalNamespace);

const generate = csrf.generate;
const verify = csrf.verify;
const secret = "phase-35-secret";
const detachedToken = generate.call({ ignored: true }, secret);
console.log(
  "callable",
  verify.call(null, detachedToken, { secret: secret }),
  errorSummary(function () { new generate(secret); }).split("|")[0],
  errorSummary(function () { new verify(detachedToken, { secret: secret }); }).split("|")[0],
);

const algorithms = ["sha256", "sha384", "sha512", "sha512-256", "blake2b256", "blake2b512"];
const encodings = ["base64", "base64url", "hex"];
let matrixPass = true;
let lengths = [];
for (const algorithm of algorithms) {
  for (const encoding of encodings) {
    const token = generate(secret, { algorithm: algorithm, encoding: encoding });
    matrixPass = matrixPass && verify(token, { secret: secret, algorithm: algorithm, encoding: encoding });
    lengths.push(token.length);
  }
}
console.log("matrix", matrixPass, lengths.join(","));

// Fixed by pinned Bun 1.3.14's keyed CryptoHasher and accepted by Bun.CSRF.verify.
const bunHexVectors = [
  ["sha256", "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000cb92483c1b9ef64def3b2cad92c10101b7c2de73840c8a298df918dcb2ef9ca6"],
  ["sha384", "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000bd40ec042b2396b0b344b08ba3461c3c417aad43ea2a181afcad9302edae9ebc1f86a7b4db648c86ca63861af771ffa7"],
  ["sha512", "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000b7fc044438f63e657a3a8fafb0f8cdac1b9ccd5abd8f840173a1bfb9e79fcb9cc9f6ccb5032c22bef933216739cd21a867fad8364ab8337014db2d8fc05dd8da"],
  ["sha512-256", "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000f62bae8696339267e1e9157d4f112ce3d0c83d9d2997cb60c2196b1fc6d44d5b"],
  ["blake2b256", "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000d21e0f5b8b5183d3dff039fc9c22bab56cffd184a39087afc53c32465379bf0d"],
  ["blake2b512", "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000ed7d9a113d3b18772a648d40d92fa743a17a92d07ddadd824945a6b98db7dbae94e0166195b7a07c49cb3872ba872590bce3cff3125b21cd7caea91d6d53af32"],
];
let bunVectorsPass = true;
for (const entry of bunHexVectors) {
  bunVectorsPass = bunVectorsPass && verify(entry[1], {
    secret: secret,
    algorithm: entry[0],
    encoding: "hex",
    maxAge: 0,
  });
}
console.log("bun-vectors", bunVectorsPass);

const aliases = ["SHA-256", "SHA-384", "SHA-512", "SHA-512/256", "sha-512_256", "sha-512256"];
let aliasesPass = true;
for (const algorithm of aliases) {
  const token = generate(secret, { algorithm: algorithm });
  aliasesPass = aliasesPass && verify(token, { secret: secret, algorithm: algorithm });
}
console.log("aliases", aliasesPass);

const defaultToken = generate();
console.log(
  "default-secret",
  verify(defaultToken),
  verify(defaultToken, { secret: undefined }),
  verify(defaultToken, { secret: null }),
  verify(defaultToken, { secret: "wrong" }),
  verify(defaultToken, 42),
);

const bound = generate(secret, { sessionId: "session-a" });
const unbound = generate(secret);
console.log(
  "session",
  verify(bound, { secret: secret, sessionId: "session-a" }),
  verify(bound, { secret: secret }),
  verify(bound, { secret: secret, sessionId: "session-b" }),
  verify(unbound, { secret: secret, sessionId: "session-a" }),
);

const base64 = generate(secret, { encoding: "base64" });
const hex = generate(secret, { encoding: "hex" });
console.log(
  "decoding",
  verify("\n" + base64 + "\t", { secret: secret, encoding: "base64url" }),
  verify(base64 + "\u0000", { secret: secret, encoding: "base64" }),
  verify(hex.toUpperCase(), { secret: secret, encoding: "hex" }),
  verify(base64.substring(0, base64.length - 1), { secret: secret, encoding: "base64" }),
  verify(base64.substring(0, base64.length - 3), { secret: secret, encoding: "base64" }),
  verify("not-a-token", { secret: secret }),
);

const encodingObject = { toString: function () { return "hex"; } };
const coercedEncoding = generate(secret, { encoding: encodingObject });
const undefinedNumeric = generate(secret, { expiresIn: undefined, algorithm: undefined, encoding: undefined });
const negativeZero = generate(secret, { expiresIn: -0 });
console.log(
  "options",
  verify(coercedEncoding, { secret: secret, encoding: encodingObject }),
  verify(undefinedNumeric, { secret: secret }),
  verify(negativeZero, { secret: secret }),
  verify(generate(secret, 42), { secret: secret }),
);

const encodingSentinel = new Error("encoding sentinel");
let encodingCaught = null;
try {
  generate(secret, { encoding: { toString: function () { throw encodingSentinel; } } });
} catch (error) {
  encodingCaught = error;
}
console.log("encoding-abrupt", encodingCaught === encodingSentinel);

let getterLog = [];
const generateOptionsPrototype = {};
Object.defineProperty(generateOptionsPrototype, "expiresIn", { get: function () { getterLog.push("expiresIn"); return 0; } });
Object.defineProperty(generateOptionsPrototype, "sessionId", { get: function () { getterLog.push("sessionId"); return "ordered"; } });
Object.defineProperty(generateOptionsPrototype, "encoding", { get: function () { getterLog.push("encoding"); return "base64url"; } });
Object.defineProperty(generateOptionsPrototype, "algorithm", { get: function () { getterLog.push("algorithm"); return "sha256"; } });
const generateOptions = Object.create(generateOptionsPrototype);
const ordered = generate(secret, generateOptions);
const generateOrder = getterLog.join(",");

getterLog = [];
const verifyOptionsPrototype = {};
Object.defineProperty(verifyOptionsPrototype, "secret", { get: function () { getterLog.push("secret"); return secret; } });
Object.defineProperty(verifyOptionsPrototype, "sessionId", { get: function () { getterLog.push("sessionId"); return "ordered"; } });
Object.defineProperty(verifyOptionsPrototype, "maxAge", { get: function () { getterLog.push("maxAge"); return 0; } });
Object.defineProperty(verifyOptionsPrototype, "encoding", { get: function () { getterLog.push("encoding"); return "base64url"; } });
Object.defineProperty(verifyOptionsPrototype, "algorithm", { get: function () { getterLog.push("algorithm"); return "sha256"; } });
const verifyOptions = Object.create(verifyOptionsPrototype);
const orderedValid = verify(ordered, verifyOptions);
console.log("getter-order", generateOrder, getterLog.join(","), orderedValid);

const sentinel = new RangeError("sentinel");
getterLog = [];
const abrupt = {};
Object.defineProperty(abrupt, "expiresIn", { get: function () { getterLog.push("expiresIn"); throw sentinel; } });
Object.defineProperty(abrupt, "sessionId", { get: function () { getterLog.push("sessionId"); return "unreached"; } });
let caught = null;
try { generate(secret, abrupt); } catch (error) { caught = error; }
console.log("abrupt", caught === sentinel, getterLog.join(","));

const loneSurrogate = "\ud800";
const surrogateToken = generate(loneSurrogate, { sessionId: loneSurrogate });
console.log("replacement-utf8", verify(surrogateToken, { secret: loneSurrogate, sessionId: loneSurrogate }));
const replacementVector = "0000018bcfe5687b000102030405060708090a0b0c0d0e0f000000000000000037cc8efed1a9dfb50853bdae26ecf322dcd36703ec4c00e03163e82abca1b92c";
console.log("replacement-vector", verify(replacementVector, { secret: loneSurrogate, encoding: "hex", maxAge: 0 }));

const embeddedExpired = generate(secret, { expiresIn: 1 });
let waitUntil = Date.now() + 5;
while (Date.now() <= waitUntil) {}
const callerExpired = generate(secret, { expiresIn: 0 });
waitUntil = Date.now() + 5;
while (Date.now() <= waitUntil) {}
console.log(
  "wall-clock-expiry",
  verify(embeddedExpired, { secret: secret, maxAge: 0 }),
  verify(callerExpired, { secret: secret, maxAge: 1 }),
);

const overCodeUnits = "x".repeat(1048577);
const overUtf8Bytes = "\u0800".repeat(349526);
console.log(
  "input-caps",
  errorSummary(function () { generate(overCodeUnits); }),
  errorSummary(function () { generate(overUtf8Bytes); }),
  errorSummary(function () { generate(secret, { sessionId: overCodeUnits }); }),
);

console.log("error-generate-required", errorSummary(function () { generate(undefined); }));
console.log("error-generate-type", errorSummary(function () { generate(42); }));
console.log("error-verify-missing", errorSummary(function () { verify(); }));
console.log("error-verify-token", errorSummary(function () { verify(null); }));
console.log("error-secret-type", errorSummary(function () { verify(defaultToken, { secret: 42 }); }));
console.log("error-session-empty", errorSummary(function () { generate(secret, { sessionId: "" }); }));
console.log("error-algorithm", errorSummary(function () { generate(secret, { algorithm: null }); }));
console.log("error-algorithm-object", errorSummary(function () { generate(secret, { algorithm: {} }); }));
console.log("error-encoding", errorSummary(function () { generate(secret, { encoding: null }); }));
console.log("error-number-type", errorSummary(function () { generate(secret, { expiresIn: null }); }));
console.log("error-number-object", errorSummary(function () { generate(secret, { expiresIn: {} }); }));
console.log("error-number-value", errorSummary(function () { generate(secret, { expiresIn: -1 }); }));
