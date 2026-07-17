let globalAttempts = 0;
test('global retry passes on the third attempt', () => {
  globalAttempts++;
  if (globalAttempts < 3) throw new Error('global retry');
});

let overrideAttempts = 0;
test('per-test zero disables global retry', () => {
  overrideAttempts++;
  throw new Error('no retry');
}, { retry: 0 });

test('global and override attempt counts', () => {
  expect(globalAttempts).toBe(3);
  expect(overrideAttempts).toBe(1);
});
