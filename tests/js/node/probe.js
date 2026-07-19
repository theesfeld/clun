const names=["assert","assert/strict","crypto","zlib","stream","module","sqlite","process","console","fs/promises","path/posix","path/win32","child_process","net","http","dns","async_hooks","perf_hooks","constants","sys","tls","http2","dgram","cluster","vm","v8","wasi","worker_threads","inspector","trace_events","repl","test","punycode","string_decoder","diagnostics_channel","domain","tty","readline","os","events","fs","buffer","url","util","timers","querystring"];
let ok=0, fail=0;
for (const n of names) {
  try { const m = require("node:"+n); if (m==null) throw new Error("null"); console.log("ok", n); ok++; }
  catch (e) { console.log("FAIL", n, String(e.message||e).slice(0,100)); fail++; }
}
console.log("summary", ok, fail);
