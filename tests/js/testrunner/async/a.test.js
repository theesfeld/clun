test('resolves', async () => { await expect(Promise.resolve(42)).resolves.toBe(42); });
test('rejects', async () => { await expect(Promise.reject(new Error('boom'))).rejects.toThrow('boom'); });
test('await in body', async () => {
  const v = await new Promise(r => setTimeout(() => r(7), 5));
  expect(v).toBe(7);
});
test('times out', async () => { await new Promise(() => {}); }, 50);
