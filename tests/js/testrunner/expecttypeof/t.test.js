// Runtime expectTypeOf chain (type-level API is compile-time only).
test("expectTypeOf is chainable at runtime", () => {
  expect(typeof expectTypeOf).toBe("function");
  const chain = expectTypeOf({ a: 1 });
  expect(typeof chain.toMatchObjectType).toBe("function");
  expect(chain.toMatchObjectType()).toBe(chain);
  expect(chain.not).toBe(chain);
});
