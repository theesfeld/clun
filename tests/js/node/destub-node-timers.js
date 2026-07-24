// #339 residual destubs: timers enroll/unenroll/active, module.syncBuiltinESMExports,
// perf_hooks timeline/observer, async_hooks resource/destroy/ALS, readline lines.
const timers = require("node:timers");
const mod = require("node:module");
const {
  performance,
  PerformanceObserver,
  monitorEventLoopDelay,
  createHistogram,
} = require("node:perf_hooks");
const {
  AsyncLocalStorage,
  AsyncResource,
  createHook,
  executionAsyncId,
  executionAsyncResource,
} = require("node:async_hooks");
const readline = require("node:readline");
const { Readable, PassThrough } = require("node:stream");
const fs = require("node:fs");

// --- timers.enroll / unenroll / active ---
let fired = 0;
const item = {
  _onTimeout() { fired++; }
};
timers.enroll(item, 5);
timers.unenroll(item);
// after unenroll, should not fire
setTimeout(() => {
  if (fired !== 0) throw new Error("unenroll failed to clear: " + fired);

  let armed = 0;
  const item2 = {
    _onTimeout() { armed++; }
  };
  timers.enroll(item2, 5);
  timers.active(item2);
  setTimeout(() => {
    if (armed < 1) throw new Error("enroll/active did not fire");

    // --- module.registerHooks + deregister ---
    let resolveHits = 0;
    const handle = mod.registerHooks({
      resolve(specifier, context, next) {
        resolveHits++;
        if (typeof next === "function") return next(specifier);
        return { url: specifier, shortCircuit: true };
      }
    });
    if (!handle || typeof handle.deregister !== "function") {
      throw new Error("registerHooks must return deregister handle");
    }
    handle.deregister();
    if (typeof mod.register !== "function") throw new Error("register missing");

    // --- module.syncBuiltinESMExports: real snapshot refresh ---
    if (typeof mod.syncBuiltinESMExports !== "function") {
      throw new Error("syncBuiltinESMExports missing");
    }
    const syncRet = mod.syncBuiltinESMExports();
    if (syncRet !== undefined) throw new Error("syncBuiltinESMExports return");
    const snap = fs["%esmSnap%"];
    if (!snap || typeof snap !== "object") {
      throw new Error("sync must create %esmSnap% on cached builtins");
    }
    if (typeof snap.readFile !== "function") {
      throw new Error("snap missing readFile after seed");
    }
    const fakeRead = function fakeReadFile() { return "synced"; };
    const prevRead = fs.readFile;
    fs.readFile = fakeRead;
    mod.syncBuiltinESMExports();
    if (snap.readFile !== fakeRead) {
      throw new Error("sync did not refresh existing snap binding");
    }
    fs.readFile = prevRead;
    mod.syncBuiltinESMExports();
    fs.__brandNewForSyncTest = 1;
    mod.syncBuiltinESMExports();
    if (snap.__brandNewForSyncTest === 1) {
      throw new Error("sync must not add new export names");
    }
    delete fs.__brandNewForSyncTest;

    // --- perf_hooks timeline + PerformanceObserver ---
    const t0 = performance.now();
    if (typeof t0 !== "number" || t0 < 0) throw new Error("performance.now");
    performance.mark("a");
    performance.mark("b");
    performance.measure("a-to-b", "a", "b");
    const marks = performance.getEntriesByType("mark");
    const measures = performance.getEntriesByType("measure");
    if (marks.length < 2) throw new Error("marks not stored: " + marks.length);
    if (measures.length < 1) throw new Error("measures not stored");
    if (typeof measures[0].duration !== "number") throw new Error("measure duration");
    const byName = performance.getEntriesByName("a");
    if (byName.length < 1) throw new Error("getEntriesByName");
    const all = performance.getEntries();
    if (all.length < 3) throw new Error("getEntries");

    let obsHits = 0;
    const obs = new PerformanceObserver((list) => {
      obsHits += list.getEntries().length;
    });
    obs.observe({ entryTypes: ["mark"] });
    performance.mark("obs-mark");
    if (obsHits < 1) throw new Error("PerformanceObserver callback not fired");
    const pending = obs.takeRecords();
    // pending may include the mark (also delivered via callback); length is finite
    if (!Array.isArray(pending) && typeof pending.length !== "number") {
      throw new Error("takeRecords shape");
    }
    obs.disconnect();
    const hitsAfter = obsHits;
    performance.mark("after-disconnect");
    if (obsHits !== hitsAfter) throw new Error("observer should ignore after disconnect");

    performance.clearMarks();
    if (performance.getEntriesByType("mark").length !== 0) throw new Error("clearMarks");
    performance.clearMeasures();
    if (performance.getEntriesByType("measure").length !== 0) throw new Error("clearMeasures");

    const hist = createHistogram();
    hist.record(100);
    hist.record(200);
    if (!(hist.count >= 2)) throw new Error("histogram count");
    if (!(hist.min <= hist.max)) throw new Error("histogram min/max");
    if (typeof hist.mean !== "number") throw new Error("histogram mean");
    hist.recordDelta();
    hist.recordDelta();
    const eld = monitorEventLoopDelay({ resolution: 10 });
    eld.enable();
    eld.disable();
    if (typeof eld.enable !== "function" || typeof eld.disable !== "function") {
      throw new Error("ELD histogram methods");
    }

    // --- async_hooks ---
    const als = new AsyncLocalStorage();
    const v = als.run({ x: 42 }, () => als.getStore().x);
    if (v !== 42) throw new Error("ALS run/getStore");
    als.enterWith({ y: 1 });
    if (als.getStore().y !== 1) throw new Error("ALS enterWith");
    const exited = als.exit(() => als.getStore());
    if (exited !== undefined) throw new Error("ALS exit should hide store");
    als.disable();
    if (als.getStore() !== undefined) throw new Error("ALS disable");

    const topRes = executionAsyncResource();
    if (topRes === null || typeof topRes !== "object") {
      throw new Error("executionAsyncResource top-level must be object");
    }

    let inits = 0;
    let destroys = 0;
    const hook = createHook({
      init() { inits++; },
      destroy() { destroys++; }
    });
    hook.enable();
    const ar = new AsyncResource("Test");
    if (inits < 1) throw new Error("createHook init not fired");
    const scoped = ar.runInAsyncScope(() => {
      const res = executionAsyncResource();
      if (res !== ar) throw new Error("executionAsyncResource in scope");
      return 9;
    });
    if (scoped !== 9) throw new Error("runInAsyncScope");
    ar.emitDestroy();
    if (destroys < 1) throw new Error("emitDestroy must fire destroy hooks");
    ar.emitDestroy(); // second call must not re-fire
    if (destroys !== 1) throw new Error("emitDestroy must be once-only: " + destroys);
    hook.disable();
    if (typeof executionAsyncId() !== "number") throw new Error("executionAsyncId");

    // --- readline line buffering (no ANSI writes to stdout) ---
    const input = new Readable({ read() {} });
    const output = new PassThrough();
    const rl = readline.createInterface({ input, output });
    let lineGot = null;
    rl.on("line", (ln) => { lineGot = ln; });
    let questionAns = null;
    rl.question("q?", (ans) => { questionAns = ans; });
    input.push("hello\n");
    if (lineGot !== "hello") throw new Error("readline line event: " + lineGot);
    if (questionAns !== "hello") throw new Error("readline question: " + questionAns);
    rl.write("world\n");
    if (lineGot !== "world") throw new Error("readline write feed: " + lineGot);
    rl.close();

    // ANSI helpers write to a sink stream only (never process.stdout)
    const sinkChunks = [];
    const sink = new PassThrough();
    sink.on("data", (c) => sinkChunks.push(String(c)));
    readline.cursorTo(sink, 2, 3);
    readline.moveCursor(sink, 1, -1);
    readline.clearLine(sink, 0);
    readline.clearScreenDown(sink);
    if (sinkChunks.length < 1) throw new Error("readline ANSI helpers wrote nothing");
    readline.emitKeypressEvents(sink);

    console.log("destub-node-timers-ok");
  }, 30);
}, 20);
