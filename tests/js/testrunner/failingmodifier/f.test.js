test('modifier surface', () => {
  expect(typeof test.failing).toBe('function');
  expect(it.failing).toBe(test.failing);
  expect(typeof test.failing.each).toBe('function');
  expect(() => test.failing('missing callback')).toThrow(
    'test.failing expects a function as the second argument',
  );
});

test.failing('sync expected failure', () => {
  throw new Error('expected sync failure');
});

test.failing('async expected rejection', async () => {
  throw new Error('expected async rejection');
});

test.failingIf(true)('conditional expected failure', () => {
  throw new Error('expected conditional failure');
});

test.failingIf(false)('conditional normal pass', () => {
  expect(1).toBe(1);
});

test.failing.each([[1], [2]])('each expected failure %i', value => {
  expect(value).toBe(0);
});

test.failing('unexpected pass', () => {});

test.failing('assertion contract stays failed', () => {
  expect.assertions(1);
});

test.failing('timeout stays failed', async () => {
  await new Promise(() => {});
}, 5);

describe('hook boundary', () => {
  beforeEach(() => {
    throw new Error('setup failed');
  });

  test.failing('hook failure stays failed', () => {
    throw new Error('body failure');
  });
});
