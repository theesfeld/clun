test('mock order starts at one in second file', () => {
  const fn = mock();
  fn();
  expect(fn.mock.invocationCallOrder).toEqual([1]);
});
