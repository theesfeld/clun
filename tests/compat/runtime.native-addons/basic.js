// Issues #178 / #265 — runtime.native-addons: pure-CL host + machine load/hook.

function summary(fn) {
  try {
    return "OK:" + String(fn());
  } catch (error) {
    return "ERR:" + error.name + "|" + (error.code || "") + "|" + error.message;
  }
}

const ffi = require("bun:ffi");
const { dlopen, FFIType, ptr, read, write, suffix, CString, viewSource, linkSymbols } = ffi;

console.log(
  "api",
  typeof dlopen,
  typeof FFIType,
  typeof FFIType.i32,
  typeof ptr,
  typeof read.u32,
  typeof write.u32,
  typeof CString,
  typeof suffix,
  typeof viewSource,
  typeof Clun.ffi,
  Clun.ffi.backend,
  typeof Clun.native.dlopen,
  typeof Clun.napi.defineAddon,
  typeof process.dlopen,
);

const lib = dlopen("clun_demo", {
  add: { args: [FFIType.i32, "i32"], returns: "i32" },
  mul: { args: ["i32", "i32"], returns: "i32" },
  version: { args: [], returns: "cstring" },
  write_u32: { args: ["ptr", "u32"], returns: "void" },
  read_u32: { args: ["ptr"], returns: "u32" },
});

console.log("call", lib.symbols.add(2, 40), lib.symbols.mul(6, 7));

const ver = new CString(lib.symbols.version());
console.log("cstring", ver.toString());

const buf = new Uint8Array(16);
const p = ptr(buf);
write.u32(p, 0, 0x11223344);
console.log("mem", read.u32(p, 0) === 0x11223344 ? "ok" : "bad", read.u8(p, 0));

lib.symbols.write_u32(p, 7);
console.log("via-lib", lib.symbols.read_u32(p));

const vs = viewSource({
  add: { args: ["i32", "i32"], returns: "i32" },
});
console.log("viewSource", Array.isArray(vs) && vs[0].indexOf("add") >= 0 ? "ok" : "bad");

Clun.ffi.registerLibrary("js_adder", {
  add: {
    args: ["i32", "i32"],
    returns: "i32",
    fn: function (a, b) {
      return a + b;
    },
  },
});
const lib2 = Clun.ffi.dlopen("js_adder", {
  add: { args: ["i32", "i32"], returns: "i32" },
});
console.log("register", lib2.symbols.add(100, 23));

const listed = Clun.ffi.listLibraries();
console.log(
  "list",
  listed.indexOf("clun_demo") >= 0 || listed.indexOf("libclun_demo") >= 0 ? "demo" : "missing",
  listed.indexOf("js_adder") >= 0 ? "js" : "nojs",
);

const mod = { exports: {} };
process.dlopen(mod, "clun_napi_demo");
console.log("napi", mod.exports.hello(), mod.exports.add(1, 2), mod.exports.version);

Clun.napi.defineAddon("user_addon", function (exports) {
  exports.ping = function () {
    return "pong";
  };
  exports.n = 3;
});
const mod2 = { exports: {} };
Clun.native.dlopen(mod2, "user_addon");
console.log("define", mod2.exports.ping(), mod2.exports.n);

// Machine-code path: system C library abs(int) via pure-CL host boundary (#265).
const libcNames =
  process.platform === "darwin"
    ? ["libSystem.B.dylib", "libc.dylib"]
    : ["libc.so.6", "libm.so.6"];
let machine = "skip";
for (let i = 0; i < libcNames.length; i++) {
  const name = libcNames[i];
  const r = summary(function () {
    const mlib = dlopen(name, {
      abs: { args: ["i32"], returns: "i32" },
    });
    const v = mlib.symbols.abs(-42);
    mlib.close();
    return v;
  });
  if (r.indexOf("OK:") === 0) {
    machine = "abs:" + r.slice(3);
    break;
  }
}
console.log("machine", machine);

console.log(
  "errors",
  summary(function () {
    return dlopen("definitely-missing-lib-xyz", { f: { returns: "void" } });
  }).split("|")[0],
);

lib.close();
console.log("done", suffix.length > 0 ? "suffix" : "nosuffix");
