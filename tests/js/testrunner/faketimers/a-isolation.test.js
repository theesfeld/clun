test("fake timers stay inside their file realm", () => {
  vi.useFakeTimers({ now: 123 });
  setTimeout(() => {}, 10);
  expect(vi.isFakeTimers()).toBe(true);
  expect(vi.getTimerCount()).toBe(1);
  expect(Date.now()).toBe(123);
});
