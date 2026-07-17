const path = require("node:path");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const router = new Clun.FileSystemRouter({
  dir: process.env.CLUN_ROUTER_STRESS_PAGES,
  fileExtensions: [".tsx"],
  style: "nextjs",
});

for (let iteration = 0; iteration < 10; iteration++) {
  const routes = router.routes;
  assert(Object.keys(routes).length === 129, "stable 129-route inventory under allocation pressure");
  for (let index = 0; index < 128; index++) {
    assert(
      routes[`/route${index}`] === path.join(process.env.CLUN_ROUTER_STRESS_PAGES, `route${index}/index.tsx`),
      `route${index} inventory entry`,
    );
  }
}

const segmentA = `alpha-${"a".repeat(58)}`;
const segmentB = `bravo-${"b".repeat(58)}`;
const first = router.match(`/${segmentA}/${segmentA}/${segmentA}/${segmentA}`);
const second = router.match(`/${segmentB}/${segmentB}/${segmentB}/${segmentB}`);
assert(first.params.a === segmentA && first.pathname.includes(segmentA), "first retained match remains stable");
assert(second.params.d === segmentB && second.pathname.includes(segmentB), "second retained match remains stable");

const stressUrl = `/${"x".repeat(512)}/${"y".repeat(512)}/${"z".repeat(512)}/${"w".repeat(512)}`;
for (let index = 0; index < 1000; index++) router.match(stressUrl).params;
Clun.gc(true);
const before = process.memoryUsage().rss;
for (let index = 0; index < 30000; index++) {
  const params = router.match(stressUrl).params;
  if (params.a.length !== 512 || params.d.length !== 512) throw new Error("stress params mismatch");
}
Clun.gc(true);
const growth = process.memoryUsage().rss - before;
assert(growth <= 20 * 1024 * 1024, `30,000 matches retained ${growth} RSS bytes`);

console.log(`filesystem.router: 129-route pressure, retained matches, and 30,000-match RSS bound passed (${growth} bytes)`);
