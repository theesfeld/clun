test("the next file starts on real timers", () => {
  expect(vi.isFakeTimers()).toBe(false);
  expect(setTimeout.clock).toBeUndefined();
  expect(Date.now()).not.toBe(123);
});
