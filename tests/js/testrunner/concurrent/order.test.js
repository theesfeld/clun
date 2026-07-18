// Bun/Jest-compatible concurrent scheduling: consecutive concurrent tests overlap;
// serial tests form group boundaries. describe.concurrent inherits concurrent mode.

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

test("test 1", async () => {
  console.log("[0] start test 1");
  await tick();
  console.log("[1] end test 1");
  console.log("--- concurrent boundary ---");
});

test.concurrent("test 2", async () => {
  console.log("[0] start test 2");
  await tick();
  console.log("[1] end test 2");
});

test.concurrent("test 3", async () => {
  console.log("[0] start test 3");
  await tick();
  console.log("[2] end test 3");
});

test("test 4", () => {
  console.log("--- concurrent boundary ---");
});

test.concurrent("test 5", async () => {
  console.log("[0] start test 5");
  await tick();
  console.log("[1] end test 5");
});

test.concurrent("test 6", async () => {
  console.log("[0] start test 6");
  await tick();
  console.log("[2] end test 6");
});

describe.concurrent("describe group 7", () => {
  beforeEach(async () => {
    console.log("[0] start before test 7");
    await tick();
    console.log("[3] end before test 7");
  });

  test("test 7", async () => {
    console.log("[3] start test 7");
    await tick();
    console.log("[4] end test 7");
  });
});

describe("describe group 8", () => {
  test.concurrent("test 8", async () => {
    console.log("[0] start test 8");
    await tick();
    await tick();
    await tick();
    await tick();
    console.log("[5] end test 8");
  });
});
