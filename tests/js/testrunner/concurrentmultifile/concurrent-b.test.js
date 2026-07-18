// Multi-file concurrent B: realm isolation from file A.
const shared = globalThis.__cmf = globalThis.__cmf || { a: [], b: [] };

test.concurrent("b1", async () => {
  shared.b.push("b1");
  await new Promise((r) => setTimeout(r, 1));
  expect(shared.a.length).toBe(0);
});

test.concurrent("b2", async () => {
  shared.b.push("b2");
  await new Promise((r) => setTimeout(r, 1));
});

test("b-assert", () => {
  expect(shared.b).toContain("b1");
  expect(shared.b).toContain("b2");
  expect(shared.a.length).toBe(0);
});
