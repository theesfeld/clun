test('mock order starts at one in first file', () => {
  const fn = mock();
  fn();
  expect(fn.mock.invocationCallOrder).toEqual([1]);
});
