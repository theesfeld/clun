import { afterEach, beforeEach, describe, expect, it, test } from "bun:test";

let n = 0;
beforeEach(() => {
  n += 1;
});
afterEach(() => {
  n = 0;
});

describe("bun:test ESM resolve", () => {
  test("named imports bind to live test APIs", () => {
    expect(1 + 1).toBe(2);
    expect(n).toBe(1);
  });

  it("aliases test as it", () => {
    expect(n).toBe(1);
    expect(2 + 2).toBe(4);
  });
});
