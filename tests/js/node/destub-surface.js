// Issue #339: previously-stubbed node surfaces must do real work.
const os = require("os");
const v8 = require("v8");
const vm = require("vm");
const inspector = require("inspector");
const wasi = require("wasi");
const repl = require("repl");
const test = require("test");
const cluster = require("cluster");

const load = os.loadavg();
if (load.length !== 3) throw new Error("loadavg length");
if (typeof load[0] !== "number") throw new Error("loadavg type");

const cpus = os.cpus();
if (!cpus.length) throw new Error("cpus empty");
if (!cpus[0].model || !cpus[0].times) throw new Error("cpu shape");

const hs = v8.getHeapStatistics();
if (!(hs.used_heap_size > 0)) throw new Error("heap used");
if (!(hs.total_heap_size > 0)) throw new Error("heap total");

const ctx = vm.createContext({ n: 40 });
if (vm.runInContext("n + 2", ctx) !== 42) throw new Error("vm context");

const url = inspector.open(0);
if (!String(url).startsWith("ws://")) throw new Error("inspector url");
if (typeof inspector.url() !== "string") throw new Error("inspector.url");
inspector.close();

const w = new wasi.WASI({ args: ["x"], env: { K: "V" } });
if (typeof w.wasiImport.args_get !== "function") throw new Error("wasi import");
if (typeof w.start !== "function") throw new Error("wasi start");

const r = repl.start({ prompt: "p> " });
if (typeof r.eval !== "function") throw new Error("repl.eval");
r.close();

if (typeof test.test !== "function") throw new Error("test.test");
if (typeof test.mock.fn !== "function") throw new Error("test.mock.fn");

if (cluster.isPrimary !== true) throw new Error("cluster primary");
if (typeof cluster.fork !== "function") throw new Error("cluster.fork");

console.log("destub-ok");
