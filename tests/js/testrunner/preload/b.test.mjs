import { value } from "./value.mjs";

beforeAll(() => console.log("file b beforeAll"));
beforeEach(() => console.log("file b beforeEach"));
afterEach(() => console.log("file b afterEach"));
afterAll(() => console.log("file b afterAll"));

test("second file", () => {
  console.log("second body");
  expect(preloadOrder).toEqual(["first", "second"]);
  expect(preloadRealmLoads).toBe(2);
  expect("ready").toBePreloaded();
  expect(value).toBe("mocked");
});
