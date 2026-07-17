const seen = [];

test.each([
  [1, 2, 3],
  [3, 4, 7],
])('%i + %i = %i', (a, b, expected) => {
  seen.push(expected);
  expect(a + b).toBe(expected);
});

test.skip.each([[1], [2]])('skip row %i', () => {
  throw new Error('skipped row ran');
});

test.todo.each([1, 2])('todo row %i');

test.each([['alpha'], ['beta']]).skipIf(false)('bound row %s', value => {
  seen.push(value);
  expect(typeof value).toBe('string');
});

test.each([[10], [20]]).failing('expected failure %i', value => {
  expect(value).toBe(0);
});

test.each([
  [1.5, null],
  [2.25, true],
])('format %f %j', (number, value) => {
  expect(number > 1).toBe(true);
});

test.each([[NaN], [Infinity]])('non-finite integer %i', value => {
  expect(typeof value).toBe('number');
});

describe.each([['A'], ['B']])('suite %s', label => {
  test.each([[1], [2]])('case %# %i', value => {
    seen.push(label + value);
    expect(value).toBeGreaterThan(0);
  });
});

describe.todoIf(true)('todo suite', () => {
  test('never runs', () => {
    throw new Error('todo suite ran');
  });
});

describe.todoIf(false)('normal suite', () => {
  test('runs', () => {
    seen.push('normal');
    expect(true).toBe(true);
  });
});

describe.if(false)('skipped suite', () => {
  test('never runs', () => {
    throw new Error('conditional suite ran');
  });
});

test('all rows executed in registration order', () => {
  expect(seen).toEqual([3, 7, 'alpha', 'beta', 'A1', 'A2', 'B1', 'B2', 'normal']);
});
