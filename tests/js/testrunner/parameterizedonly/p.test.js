test('excluded by only mode', () => {
  throw new Error('ordinary test ran');
});

test.only.failing.each([[1], [2]])('only expected failure %i', value => {
  expect(value).toBe(0);
});
