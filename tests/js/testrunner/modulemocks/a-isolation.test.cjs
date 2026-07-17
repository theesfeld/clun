test('module mocks start isolated in the first file', () => {
  mock.module('./virtual-first.cjs', () => ({ value: 'first' }));
  expect(require('./virtual-first.cjs').value).toBe('first');
});
