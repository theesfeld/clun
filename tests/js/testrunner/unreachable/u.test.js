// expect.unreachable residual surface.
test("expect.unreachable is a function", () => {
  expect(expect.unreachable).toBeTypeOf("function");
});

test("expect.unreachable with message", () => {
  expect(() => expect.unreachable("message here")).toThrow("message here");
});

test("expect.unreachable with Error", () => {
  const error = new Error("message here");
  expect(() => expect.unreachable(error)).toThrow(error);
});

test("expect.unreachable default", () => {
  expect(() => expect.unreachable()).toThrow("reached unreachable code");
});
