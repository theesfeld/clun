preloadOrder.push("second");
preloadRealmLoads += 1;

mock.module("./value.mjs", () => ({ value: "mocked" }));
