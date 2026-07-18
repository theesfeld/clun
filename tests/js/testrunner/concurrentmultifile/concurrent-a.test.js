// Multi-file concurrent A: overlapping async + serial assert.
const shared = globalThis.__cmf = globalThis.__cmf || { a: [], b: [] };

let active = 0;
let maxActive = 0;

test.concurrent("a1", async () => {
  active++;
  maxActive = Math.max(maxActive, active);
  shared.a.push("a1-start");
  await new Promise((r) => setTimeout(r, 5));
  shared.a.push("a1-end");
  active--;
});

test.concurrent("a2", async () => {
  active++;
  maxActive = Math.max(maxActive, active);
  shared.a.push("a2-start");
  await new Promise((r) => setTimeout(r, 5));
  shared.a.push("a2-end");
  active--;
});

test("a-assert", () => {
  expect(maxActive).toBeGreaterThan(1);
  const a1s = shared.a.indexOf("a1-start");
  const a2s = shared.a.indexOf("a2-start");
  const a1e = shared.a.indexOf("a1-end");
  const a2e = shared.a.indexOf("a2-end");
  expect(a1s).toBeGreaterThanOrEqual(0);
  expect(a2s).toBeGreaterThanOrEqual(0);
  expect(Math.max(a1s, a2s)).toBeLessThan(Math.min(a1e, a2e));
});
