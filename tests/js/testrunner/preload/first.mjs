globalThis.preloadOrder = ["first"];
globalThis.preloadRealmLoads = 1;

expect.extend({
  toBePreloaded(received) {
    return {
      pass: received === "ready",
      message: () => `expected ${received} to be ready`,
    };
  },
});

beforeAll(() => console.log("preload beforeAll"));
beforeEach(() => console.log("preload beforeEach"));
afterEach(() => console.log("preload afterEach"));
afterAll(() => console.log("preload afterAll"));
