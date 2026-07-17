test('resolvesTo matches fulfilled values, including nested positions', async () => {
  await expect(Promise.resolve('clun runtime')).toEqual(
    expect.resolvesTo.stringContaining('clun'),
  );
  await expect({ value: Promise.resolve({ ready: true }) }).toEqual({
    value: expect.resolvesTo.objectContaining({ ready: true }),
  });
  await expect([Promise.resolve(12)]).toEqual([
    expect.resolvesTo.closeTo(12.001, 2),
  ]);
  await expect(Promise.reject(new Error('wrong settlement'))).toEqual(
    expect.not.resolvesTo.stringContaining('clun'),
  );
  expect('not a promise').not.toEqual(expect.resolvesTo.anything());
});

test('rejectsTo matches rejection reasons and supports negation', async () => {
  await expect(Promise.reject(new Error('network unavailable'))).toEqual(
    expect.rejectsTo.objectContaining({ message: expect.stringContaining('network') }),
  );
  await expect({ reason: Promise.reject('E_STOP') }).toEqual({
    reason: expect.rejectsTo.stringMatching(/^E_/),
  });
  await expect(Promise.resolve('not rejected')).toEqual(
    expect.not.rejectsTo.stringContaining('E_'),
  );
  await expect(Promise.reject('E_OTHER')).toEqual(
    expect.not.rejectsTo.stringContaining('STOP'),
  );
  expect(7).not.toEqual(expect.rejectsTo.any(Number));
});

test('settlement asymmetric matchers wait for timer-driven promises', async () => {
  const delayed = new Promise(resolve => setTimeout(() => resolve('ready'), 5));
  await expect({ delayed }).toEqual({
    delayed: expect.resolvesTo.stringMatching(/^ready$/),
  });
});

test('async nested equality distinguishes aliases from cycles', async () => {
  const shared = { value: Promise.resolve(42) };
  await expect({ first: shared, second: shared }).toEqual({
    first: { value: expect.resolvesTo.any(Number) },
    second: { value: expect.resolvesTo.any(Number) },
  });
});
