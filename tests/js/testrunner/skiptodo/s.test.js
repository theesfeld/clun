test('runs', () => { expect(1).toBe(1); });
test.skip('skipped', () => { throw new Error('should not run'); });
test.todo('todo without body');
test.todo('todo with body', () => { expect(1).toBe(2); });
describe.skip('whole block skipped', () => {
  test('nope', () => { throw new Error('no'); });
});
