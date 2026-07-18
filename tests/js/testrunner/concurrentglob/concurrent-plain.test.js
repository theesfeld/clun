let active = 0;
let maxActive = 0;
test("g1", async () => {
  active++;
  maxActive = Math.max(maxActive, active);
  await new Promise((r) => setTimeout(r, 5));
  active--;
});
test("g2", async () => {
  active++;
  maxActive = Math.max(maxActive, active);
  await new Promise((r) => setTimeout(r, 5));
  active--;
});
test.serial("g-assert", () => {
  expect(maxActive).toBeGreaterThan(1);
});
