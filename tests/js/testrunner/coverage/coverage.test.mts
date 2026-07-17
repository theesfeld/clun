import { add, choose } from "./subject.mts";

test("reports source-aligned TypeScript coverage", () => {
  expect(add(2, 3)).toBe(5);
  expect(choose(true)).toBe("yes");
});
