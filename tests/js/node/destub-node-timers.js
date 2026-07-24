// #339 residual destubs: timers enroll/unenroll/active, module.registerHooks,
// perf_hooks timeline/histogram, async_hooks ALS/disable/createHook, readline lines.
const timers = require("node:timers");
const mod = require("node:module");
const { performance, monitorEventLoopDelay, createHistogram } = require("node:perf_hooks");
const { AsyncLocalStorage, AsyncResource, createHook, executionAsyncId } = require("node:async_hooks");
const readline = require("node:readline");
const { Readable, PassThrough } = require("node:stream");

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

    // --- perf_hooks ---
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

    let inits = 0;
    const hook = createHook({
      init() { inits++; }
    });
    hook.enable();
    const ar = new AsyncResource("Test");
    const scoped = ar.runInAsyncScope(() => 9);
    if (scoped !== 9) throw new Error("runInAsyncScope");
    ar.emitDestroy();
    hook.disable();
    if (typeof executionAsyncId() !== "number") throw new Error("executionAsyncId");

    // --- readline line buffering ---
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

    console.log("destub-node-timers-ok");
  }, 30);
}, 20);
