(async () => {
  const r = Clun.redis;
  await r.set("greeting", "Hello from Clun!");
  const g = await r.get("greeting");
  if (g !== "Hello from Clun!") throw new Error("get mismatch: " + g);
  await r.set("counter", "0");
  const n = await r.incr("counter");
  if (n !== 1) throw new Error("incr mismatch: " + n);
  const ex = await r.exists("greeting");
  if (ex !== 1) throw new Error("exists mismatch: " + ex);
  await r.del("greeting");
  const gone = await r.get("greeting");
  if (gone !== null) throw new Error("del failed");
  const pong = await r.ping();
  if (pong !== "PONG") throw new Error("ping: " + pong);
  console.log("ok");
})();
