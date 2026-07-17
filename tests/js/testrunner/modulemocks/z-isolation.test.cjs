test('module mocks do not cross file realms', () => {
  expect(() => require('./virtual-first.cjs')).toThrow('Cannot find module');
});
