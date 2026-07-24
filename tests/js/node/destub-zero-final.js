// #339 final residual fixtures: process end, module.register, worker start flag,
// WASI path_open/fd_read/path_filestat_get host import surfaces, inventory smoke.
const assert = require("assert");
const moduleApi = require("module");
const { MessageChannel } = require("worker_threads");
const wasiMod = require("wasi");

// --- process.stdout.end / writableEnded ---
assert.strictEqual(typeof process.stdout.write, "function");
assert.strictEqual(typeof process.stdout.end, "function");
assert.strictEqual(process.stdout.writableEnded, false);
assert.strictEqual(process.stderr.writableEnded, false);
process.stdout.write("");

// --- module.syncBuiltinESMExports + register string specifier ---
assert.strictEqual(typeof moduleApi.syncBuiltinESMExports, "function");
moduleApi.syncBuiltinESMExports();
moduleApi.register("clun:test-register-hook");
const regs = moduleApi._registeredSpecifiers;
assert.ok(Array.isArray(regs), "registeredSpecifiers array");
assert.ok(regs.includes("clun:test-register-hook"), "specifier recorded");

// --- worker_threads MessagePort#start ---
const { port1, port2 } = new MessageChannel();
assert.strictEqual(typeof port1.start, "function");
port1.start();
assert.strictEqual(typeof port1.postMessage, "function");
assert.strictEqual(typeof port1.close, "function");
port1.postMessage({ ok: 1 });
port1.close();
port2.close();

// --- WASI imports expose path_open / fd_read / path_filestat_get ---
assert.strictEqual(typeof wasiMod.WASI, "function");
const w = new wasiMod.WASI({ args: ["clun", "x"], env: { CLUN_Z: "1" } });
// wasiImport is the preview1 import table; getImportObject nests it under the name.
const wrapped = typeof w.getImportObject === "function" ? w.getImportObject() : null;
const ns =
  (wrapped && wrapped.wasi_snapshot_preview1) ||
  w.wasiImport;
assert.ok(ns, "wasi import table");
assert.strictEqual(typeof ns.path_open, "function", "path_open");
assert.strictEqual(typeof ns.fd_read, "function", "fd_read");
assert.strictEqual(typeof ns.path_filestat_get, "function", "path_filestat_get");
assert.strictEqual(typeof ns.fd_write, "function", "fd_write");
assert.strictEqual(typeof ns.fd_close, "function", "fd_close");
assert.strictEqual(typeof ns.fd_seek, "function", "fd_seek");
assert.strictEqual(typeof ns.fd_fdstat_get, "function", "fd_fdstat_get");

// --- os / domain / v8 / inspector / crypto honesty ---
const os = require("os");
assert.strictEqual(typeof os.setPriority, "function");
assert.strictEqual(typeof os.getPriority, "function");
const domain = require("domain");
assert.strictEqual(typeof domain.create, "function");
const v8 = require("v8");
assert.strictEqual(typeof v8.takeCoverage, "function");
assert.strictEqual(typeof v8.stopCoverage, "function");
const inspector = require("inspector");
assert.strictEqual(typeof inspector.Session, "function");
const crypto = require("crypto");
assert.strictEqual(crypto.getFips(), 0);
crypto.setFips(true);
assert.strictEqual(crypto.getFips(), 0); // honest: not a FIPS module

console.log("destub-zero-final-ok");
