import { value } from "./value.mjs";

beforeAll(() => console.log("file a beforeAll"));
beforeEach(() => console.log("file a beforeEach"));
afterEach(() => console.log("file a afterEach"));
afterAll(() => console.log("file a afterAll"));

test("first file", () => {
  console.log("first body");
  expect(preloadOrder).toEqual(["first", "second"]);
  expect(preloadRealmLoads).toBe(2);
  expect("ready").toBePreloaded();
  expect(value).toBe("mocked");
});
