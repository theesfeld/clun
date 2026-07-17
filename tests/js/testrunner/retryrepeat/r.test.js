let retryAttempts = 0;
const retryHooks = [];

describe('retry policy', () => {
  beforeEach(() => retryHooks.push('before'));
  afterEach(() => retryHooks.push('after'));

  test('passes on the third attempt', () => {
    retryAttempts++;
    if (retryAttempts < 3) throw new Error('retry me');
  }, { retry: 3 });
});

test('retry reruns hooks for every attempt', () => {
  expect(retryAttempts).toBe(3);
  expect(retryHooks).toEqual(['before', 'after', 'before', 'after', 'before', 'after']);
});

let assertionAttempts = 0;
test('assertion contracts can trigger a retry', () => {
  assertionAttempts++;
  expect.assertions(1);
  if (assertionAttempts > 1) expect(assertionAttempts).toBe(2);
}, { retry: 1 });

test('assertion retry count', () => {
  expect(assertionAttempts).toBe(2);
});

let repeatAttempts = 0;
const repeatHooks = [];

describe('repeat policy', () => {
  beforeEach(() => repeatHooks.push('before'));
  afterEach(() => repeatHooks.push('after'));

  test('runs the initial attempt plus repeats', () => {
    repeatAttempts++;
  }, { repeats: 2 });
});

test('repeat reruns hooks for every attempt', () => {
  expect(repeatAttempts).toBe(3);
  expect(repeatHooks).toEqual(['before', 'after', 'before', 'after', 'before', 'after']);
});

let failedRepeatAttempts = 0;
test('repeat retains a middle failure', () => {
  failedRepeatAttempts++;
  if (failedRepeatAttempts === 2) throw new Error('middle repeat failure');
}, { repeats: 2 });

test('repeat continues after a failed iteration', () => {
  expect(failedRepeatAttempts).toBe(3);
});

let expectedFailureAttempts = 0;
test.failing('expected failure stops retries', () => {
  expectedFailureAttempts++;
  throw new Error('expected');
}, { retry: 3 });

test('expected failure attempt count', () => {
  expect(expectedFailureAttempts).toBe(1);
});

test('retry and repeats are mutually exclusive', () => {
  expect(() => {
    test('invalid options', () => {}, { retry: 1, repeats: 1 });
  }).toThrow('Cannot set both retry and repeats');
});
