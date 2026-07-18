// Serial tests must not share overlapping start/end with concurrent neighbors.

let activeGroup = [];
function tick() {
  return new Promise((resolve) => {
    activeGroup.push(resolve);
    setTimeout(() => {
      const fn = activeGroup.shift();
      if (fn) fn();
    }, 0);
  });
}

const log = [];

test.concurrent("c1", async () => {
  log.push("c1-start");
  await tick();
  log.push("c1-end");
});
test.concurrent("c2", async () => {
  log.push("c2-start");
  await tick();
  log.push("c2-end");
});
test("serial-mid", async () => {
  log.push("s-start");
  await tick();
  log.push("s-end");
});
test.concurrent("c3", async () => {
  log.push("c3-start");
  await tick();
  log.push("c3-end");
});
test.concurrent("c4", async () => {
  log.push("c4-start");
  await tick();
  log.push("c4-end");
});

test("assert isolation", () => {
  // concurrent pair c1/c2 both start before either ends
  const c1s = log.indexOf("c1-start");
  const c2s = log.indexOf("c2-start");
  const c1e = log.indexOf("c1-end");
  const c2e = log.indexOf("c2-end");
  expect(c1s).toBeGreaterThanOrEqual(0);
  expect(c2s).toBeGreaterThanOrEqual(0);
  expect(Math.max(c1s, c2s)).toBeLessThan(Math.min(c1e, c2e));

  // serial-mid fully completes between the two concurrent groups
  const ss = log.indexOf("s-start");
  const se = log.indexOf("s-end");
  expect(ss).toBeGreaterThan(Math.max(c1e, c2e));
  expect(se).toBeGreaterThan(ss);

  const c3s = log.indexOf("c3-start");
  const c4s = log.indexOf("c4-start");
  expect(c3s).toBeGreaterThan(se);
  expect(c4s).toBeGreaterThan(se);
  expect(Math.max(c3s, c4s)).toBeLessThan(Math.min(log.indexOf("c3-end"), log.indexOf("c4-end")));
});
