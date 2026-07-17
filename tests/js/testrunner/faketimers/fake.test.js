afterEach(() => vi.useRealTimers());

test("activation and restoration", () => {
  const realSetTimeout = setTimeout;
  expect(vi.isFakeTimers()).toBe(false);
  expect(vi.useFakeTimers()).toBe(vi);
  expect(vi.isFakeTimers()).toBe(true);
  expect(setTimeout.clock).toBe(true);
  expect(vi.useRealTimers()).toBe(vi);
  expect(vi.isFakeTimers()).toBe(false);
  expect(setTimeout).toBe(realSetTimeout);
});

test("next timer ordering and nested scheduling", () => {
  vi.useFakeTimers({ now: 1000 });
  const order = [];
  setTimeout(() => order.push("ten"), 10);
  setTimeout(() => {
    order.push("nine");
    setTimeout(() => order.push("fourteen"), 5);
  }, 9);
  setTimeout(() => order.push("twenty"), 20);

  vi.advanceTimersToNextTimer();
  expect(order).toEqual(["nine"]);
  expect(Date.now()).toBe(1009);
  expect(performance.now()).toBe(9);
  vi.advanceTimersToNextTimer();
  vi.advanceTimersToNextTimer();
  vi.advanceTimersToNextTimer();
  expect(order).toEqual(["nine", "ten", "fourteen", "twenty"]);
  expect(vi.getTimerCount()).toBe(0);
});

test("interval advancement and clearing", () => {
  vi.useFakeTimers({ now: 5000 });
  const ticks = [];
  const interval = setInterval(value => ticks.push([value, Date.now(), performance.now()]), 6, "tick");
  vi.advanceTimersByTime(10);
  expect(ticks).toEqual([["tick", 5006, 6]]);
  vi.advanceTimersByTime(10);
  expect(ticks).toEqual([["tick", 5006, 6], ["tick", 5012, 12], ["tick", 5018, 18]]);
  clearInterval(interval);
  expect(vi.getTimerCount()).toBe(0);
  vi.advanceTimersByTime(100);
  expect(ticks).toHaveLength(3);
});

test("pending and all timer drains", () => {
  vi.useFakeTimers();
  const pending = [];
  const fast = setInterval(() => pending.push("24"), 24);
  const slow = setInterval(() => pending.push("100"), 100);
  vi.runOnlyPendingTimers();
  expect(pending).toEqual(["24", "24", "24", "24", "100"]);
  clearInterval(fast);
  clearInterval(slow);
  expect(vi.getTimerCount()).toBe(0);

  const nested = [];
  setTimeout(() => nested.push("ten"), 10);
  setTimeout(() => {
    nested.push("nine");
    setTimeout(() => nested.push("fourteen"), 5);
  }, 9);
  setTimeout(() => nested.push("twenty"), 20);
  expect(vi.runAllTimers()).toBe(vi);
  expect(nested).toEqual(["nine", "ten", "fourteen", "twenty"]);
});

test("clearAllTimers cancels pending work", () => {
  vi.useFakeTimers();
  const order = [];
  setTimeout(() => order.push("timeout"), 10);
  setInterval(() => order.push("interval"), 20);
  expect(vi.getTimerCount()).toBe(2);
  expect(vi.clearAllTimers()).toBe(vi);
  expect(vi.getTimerCount()).toBe(0);
  vi.advanceTimersByTime(100);
  expect(order).toEqual([]);
});

test("system time rebases Date without moving performance", () => {
  const realBefore = Date.now();
  jest.useFakeTimers({ now: new Date("2000-01-01T00:00:00.000Z") });
  expect(Date.now()).toBe(946684800000);
  expect(new Date().toISOString()).toBe("2000-01-01T00:00:00.000Z");
  expect(performance.now()).toBe(0);
  expect(jest.now()).toBe(946684800000);
  jest.setSystemTime(0);
  expect(Date.now()).toBe(0);
  jest.setSystemTime(new Date("2026-01-01T12:00:00.000Z"));
  expect(Date.now()).toBe(1767268800000);
  expect(new Date().toISOString()).toBe("2026-01-01T12:00:00.000Z");
  expect(performance.now()).toBe(0);
  jest.advanceTimersByTime(1500);
  expect(Date.now()).toBe(1767268801500);
  expect(new Date().toISOString()).toBe("2026-01-01T12:00:01.500Z");
  expect(performance.now()).toBe(1500);
  jest.setSystemTime();
  expect(Date.now()).toBeGreaterThanOrEqual(realBefore);
  jest.setSystemTime(-1);
  expect(Date.now()).toBe(-1);
  jest.useRealTimers();
  jest.setSystemTime(42);
  jest.useFakeTimers();
  expect(Date.now()).toBe(42);
});

test("timer handles refresh and preserve extra arguments", () => {
  vi.useFakeTimers();
  const values = [];
  const timeout = setTimeout((a, b) => values.push(a + b), 5, "a", "b");
  expect(+timeout).toBeGreaterThan(0);
  expect(timeout.hasRef()).toBe(true);
  expect(timeout.unref()).toBe(timeout);
  expect(timeout.hasRef()).toBe(false);
  expect(timeout.ref()).toBe(timeout);
  clearTimeout(timeout);
  expect(vi.getTimerCount()).toBe(0);
  expect(timeout.refresh()).toBe(timeout);
  vi.advanceTimersByTime(5);
  expect(values).toEqual(["ab"]);
  expect(vi.getTimerCount()).toBe(0);
});

test("inactive and invalid operations fail deterministically", () => {
  expect(() => vi.getTimerCount()).toThrow("Fake timers are not active");
  expect(() => vi.advanceTimersByTime(1)).toThrow("Fake timers are not active");
  expect(() => vi.useFakeTimers(1)).toThrow("expects an options object");
  vi.useFakeTimers();
  expect(() => vi.advanceTimersByTime(-1)).toThrow("out of range");
  expect(() => vi.advanceTimersByTime("1")).toThrow("expects a number");
});
