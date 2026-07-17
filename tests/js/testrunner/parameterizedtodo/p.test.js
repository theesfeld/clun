let hookCalls = 0;

describe.todo('todo group', () => {
  beforeEach(() => {
    hookCalls++;
  });

  test('expected incomplete behavior', () => {
    expect(hookCalls).toBe(1);
    throw new Error('still incomplete');
  });

  test('unexpectedly complete behavior', () => {
    expect(hookCalls).toBe(2);
  });
});
