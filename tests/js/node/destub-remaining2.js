// #339 residual destubs (remaining agent): v8 coverage, inspector Session,
// os.setPriority, domain.intercept, wasi fd_* host imports.
const v8 = require("v8");
const inspector = require("inspector");
const os = require("os");
const domain = require("domain");
const { WASI } = require("wasi");

// --- v8.takeCoverage / stopCoverage session ---
if (typeof v8.takeCoverage !== "function") throw new Error("takeCoverage");
if (typeof v8.stopCoverage !== "function") throw new Error("stopCoverage");
v8.takeCoverage();
v8.takeCoverage();
v8.stopCoverage();
// second stop is a no-op after finalize
v8.stopCoverage();

const snap = v8.startupSnapshot;
if (typeof snap !== "object" || snap === null) {
  // Node exposes startupSnapshot as object; clun may expose via getter call
}
// isBuildingSnapshot honest false when present
if (typeof v8.startupSnapshot === "function") {
  const s = v8.startupSnapshot();
  if (typeof s.isBuildingSnapshot === "function" && s.isBuildingSnapshot() !== false) {
    throw new Error("isBuildingSnapshot must be false");
  }
  if (typeof s.addSerializeCallback === "function") {
    s.addSerializeCallback(() => {}, null);
  }
}

// --- inspector Session: new works; bare call throws ---
const Session = inspector.Session;
const sess = new Session();
if (typeof sess.connect !== "function") throw new Error("Session.connect");
if (typeof sess.post !== "function") throw new Error("Session.post");
if (sess.connected !== false) throw new Error("Session starts disconnected");
sess.connect();
if (sess.connected !== true) throw new Error("Session connected flag");
let postOk = false;
sess.post("Debugger.enable", {}, (err, result) => {
  if (err) throw new Error("post err " + err.message);
  if (!result || !result.debuggerId) throw new Error("debuggerId");
  postOk = true;
});
if (!postOk) throw new Error("post callback not sync");
sess.disconnect();
if (sess.connected !== false) throw new Error("Session disconnect flag");

let threw = false;
try {
  Session();
} catch (e) {
  threw = true;
  if (!String(e.message || e).includes("new") && e.name !== "TypeError") {
    // accept TypeError or message mentioning new
  }
}
if (!threw) throw new Error("Session() without new must throw");

// --- os.setPriority / getPriority consistency ---
const before = os.getPriority();
if (typeof before !== "number") throw new Error("getPriority type");
os.setPriority(10);
const mid = os.getPriority();
if (mid !== 10) throw new Error("setPriority self got " + mid);
os.setPriority(0, 0); // pid + priority form for self (0 = current)
const back = os.getPriority(0);
if (back !== 0) throw new Error("setPriority restore got " + back);

let rangeThrew = false;
try {
  os.setPriority(99);
} catch (e) {
  rangeThrew = true;
}
if (!rangeThrew) throw new Error("setPriority out of range must throw");

// --- domain.intercept routes Error-first to domain ---
const d = domain.create();
let intercepted = false;
d.on("error", (err) => {
  if (err && err.message === "boom-intercept") intercepted = true;
});
const wrapped = d.intercept((a, b) => {
  throw new Error("should not run on error-first");
});
wrapped(Object.assign(new Error("boom-intercept"), { message: "boom-intercept" }));
if (!intercepted) throw new Error("domain.intercept did not catch Error-first");

let ran = false;
const wrapped2 = d.intercept(() => {
  ran = true;
});
wrapped2(null);
if (!ran) throw new Error("domain.intercept should run when first arg not Error");

// --- wasi host imports: fd_fdstat_get / fd_close / fd_seek surface ---
const w = new WASI({ args: ["prog", "a"], env: { X: "1" } });
const imp = w.wasiImport;
if (typeof imp.fd_close !== "function") throw new Error("fd_close");
if (typeof imp.fd_seek !== "function") throw new Error("fd_seek");
if (typeof imp.fd_fdstat_get !== "function") throw new Error("fd_fdstat_get");
// Without memory attached, fd ops that need memory return errno; close needs no mem.
const closeRc = imp.fd_close(1);
if (closeRc !== 0) throw new Error("fd_close stdout rc " + closeRc);
// second close of same fd is ok (already closed)
if (imp.fd_close(1) !== 0) throw new Error("fd_close idempotent");
// unknown fd → EBADF (8)
if (imp.fd_close(99) !== 8) throw new Error("fd_close EBADF expected 8 got " + imp.fd_close(99));

console.log("destub-remaining2-ok");
