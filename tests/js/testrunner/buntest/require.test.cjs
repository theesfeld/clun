const { describe, expect, test, jest } = require("bun:test");

describe("bun:test CJS require", () => {
  test("require surface", () => {
    expect(2 * 3).toBe(6);
    expect(typeof jest.fn).toBe("function");
  });
});
