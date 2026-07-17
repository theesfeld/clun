// Frozen Bun contract: oven-sh/bun c1076ce95effb909bfe9f596919b5dba5567d550.
function errorSummary(fn) {
  try {
    fn();
    return "NO_THROW";
  } catch (error) {
    return error.name + "|" + error.code + "|" + error.message;
  }
}

const hash = Clun.hash;
const password = Clun.password;
console.log(
  "api",
  typeof hash,
  Object.keys(hash).join(","),
  Object.keys(password).join(","),
  password.hash.name,
  password.hash.length,
  password.hashSync.name,
  password.hashSync.length,
  password.verify.name,
  password.verify.length,
  password.verifySync.name,
  password.verifySync.length,
);

const input = "hello world";
console.log(
  "hash-vectors",
  hash(input).toString(16),
  hash.wyhash(input).toString(16),
  hash.adler32(input).toString(16),
  hash.crc32(input).toString(16),
  hash.cityHash32(input).toString(16),
  hash.cityHash64(input).toString(16),
  hash.xxHash32(input).toString(16),
  hash.xxHash64(input).toString(16),
  hash.xxHash3(input).toString(16),
  hash.murmur32v2(input).toString(16),
  hash.murmur32v3(input).toString(16),
  hash.murmur64v2(input).toString(16),
  hash.rapidhash(input).toString(16),
);
console.log(
  "hash-types",
  typeof hash.adler32(input),
  typeof hash.crc32(input),
  typeof hash.cityHash32(input),
  typeof hash.xxHash32(input),
  typeof hash.murmur32v2(input),
  typeof hash.murmur32v3(input),
  typeof hash(input),
  typeof hash.cityHash64(input),
  typeof hash.xxHash64(input),
  typeof hash.xxHash3(input),
  typeof hash.murmur64v2(input),
  typeof hash.rapidhash(input),
);

const padded = new Uint8Array([0, 0, 104, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100, 0]);
const typed = new Uint8Array(padded.buffer, 2, 11);
const view = new DataView(padded.buffer, 2, 11);
const exact = new Uint8Array([104, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100]);
console.log(
  "binary-ranges",
  hash(typed) === hash(input),
  hash(view) === hash(input),
  hash(exact.buffer) === hash(input),
  hash.xxHash3(typed, 42) === hash.xxHash3(input, 42),
  hash.xxHash64("", 16269921104521594740n) === 3224619365169652240n,
);

const bcrypt = password.hashSync("password", { algorithm: "bcrypt", cost: 4 });
const argon = password.hashSync("password", {
  algorithm: "argon2id",
  memoryCost: 8,
  timeCost: 1,
});
const defaultArgon = password.hashSync("default-password");
console.log(
  "password-roundtrip",
  bcrypt.substring(0, 7),
  password.verifySync("password", bcrypt),
  password.verifySync("wrong", bcrypt),
  argon.indexOf("$argon2id$v=19$m=8,t=1,p=1$") === 0,
  password.verifySync("password", argon),
  password.verifySync("wrong", argon),
);
console.log(
  "password-defaults",
  defaultArgon.indexOf("$argon2id$v=19$m=65536,t=2,p=1$") === 0,
  password.verifySync("default-password", defaultArgon),
  bcrypt !== password.hashSync("password", { algorithm: "bcrypt", cost: 4 }),
  argon !== password.hashSync("password", {
    algorithm: "argon2id",
    memoryCost: 8,
    timeCost: 1,
  }),
);

const passwordBytes = new Uint8Array([112, 97, 115, 115, 119, 111, 114, 100]);
console.log(
  "password-binary",
  password.verifySync(passwordBytes, bcrypt),
  password.verifySync(new DataView(passwordBytes.buffer), bcrypt),
);

const longBcrypt = "$2b$10$PsJ3/W82mzNJoP0rSblfvet2ab9jZg2aH7tIxr1B8uFLJwuWk/jTi";
const externalArgon = "$argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi";
console.log(
  "cross-tool",
  password.verifySync("hello".repeat(100), longBcrypt),
  password.verifySync("password", externalArgon),
  password.verifySync("wrong", externalArgon),
);

console.log(
  "errors",
  errorSummary(function () { password.hashSync("password", { algorithm: "unknown" }); }),
  errorSummary(function () {
    password.verifySync(
      "password",
      "$argon2id$v=16$m=8,t=1,p=1$c29tZXNhbHQ$AAAAAA",
    );
  }),
);

let asyncInvalidReturned = false;
let asyncInvalidCode = "NO_THROW";
try {
  password.verify(
    "password",
    "$argon2id$v=16$m=8,t=1,p=1$c29tZXNhbHQ$AAAAAA",
  );
  asyncInvalidReturned = true;
} catch (error) {
  asyncInvalidCode = error.code;
}
console.log("async-verify-admission", asyncInvalidReturned, asyncInvalidCode);

let tick = 0;
setTimeout(function () { tick++; }, 0);
password.hash("password", {
  algorithm: "argon2id",
  memoryCost: 8,
  timeCost: 1,
}).then(function (encoded) {
  console.log(
    "async-hash",
    tick,
    encoded.indexOf("$argon2id$v=19$m=8,t=1,p=1$") === 0,
    password.verifySync("password", encoded),
  );
  return password.verify("password", encoded);
}).then(function (valid) {
  console.log("async-verify", valid);
});
