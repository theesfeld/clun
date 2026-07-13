test('not run', () => { throw new Error('should be skipped'); });
test.only('only this', () => { expect(1).toBe(1); });
describe('grp', () => {
  test('also skipped', () => { throw new Error('skip'); });
});
