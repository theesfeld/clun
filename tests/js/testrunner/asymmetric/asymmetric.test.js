test('any matches constructors and primitive wrappers', () => {
  class Thing {}

  expect('jest').toEqual(expect.any(String));
  expect(new String('jest')).toEqual(expect.any(String));
  expect(1).toEqual(expect.any(Number));
  expect(new Number(1)).toEqual(expect.any(Number));
  expect(true).toEqual(expect.any(Boolean));
  expect(1n).toEqual(expect.any(BigInt));
  expect(Symbol('x')).toEqual(expect.any(Symbol));
  expect(() => {}).toEqual(expect.any(Function));
  expect([]).toEqual(expect.any(Array));
  expect(new Thing()).toEqual(expect.any(Thing));
  expect(null).toEqual(expect.any(Object));
  expect({}).toEqual(expect.any(Object));
  expect(() => {}).not.toEqual(expect.any(Object));
  expect(() => expect.any()).toThrow('any() expects to be passed a constructor function');
});

test('anything excludes only nullish values', () => {
  expect(0).toEqual(expect.anything());
  expect(false).toEqual(expect.anything());
  expect('').toEqual(expect.anything());
  expect(null).not.toEqual(expect.anything());
  expect(undefined).not.toEqual(expect.anything());
});

test('arrayContaining composes with nested matchers', () => {
  const received = [1, 'x-ray', { active: true }];

  expect(received).toEqual(
    expect.arrayContaining([
      expect.any(Number),
      expect.stringMatching(/^x-/),
      expect.objectContaining({ active: expect.any(Boolean) }),
    ]),
  );
  expect(expect.arrayContaining([1])).toEqual(received);
  expect(received).not.toEqual(expect.arrayContaining([2]));
  expect(received).toEqual(expect.not.arrayContaining([2]));
  expect('not an array').toEqual(expect.not.arrayContaining([]));
});

test('objectContaining preserves nested equality and property lookup', () => {
  const inherited = Object.create({ inherited: 7 });
  const token = Symbol('token');

  expect({ profile: { name: 'Clun', active: true }, extra: 1 }).toEqual(
    expect.objectContaining({
      profile: {
        name: expect.stringContaining('lu'),
        active: expect.any(Boolean),
      },
    }),
  );
  expect({ first: { second: {}, third: {} } }).not.toEqual(
    expect.objectContaining({ first: { second: {} } }),
  );
  expect(inherited).toEqual(expect.objectContaining({ inherited: 7 }));
  expect({ a: undefined }).toEqual(expect.objectContaining({ a: undefined }));
  expect({}).not.toEqual(expect.objectContaining({ a: undefined }));
  expect({ a: 1 }).toEqual(expect.not.objectContaining({ a: 2 }));
  expect({ [token]: 'ok' }).toEqual(
    expect.objectContaining({ [token]: expect.stringContaining('o') }),
  );
});

test('string and numeric asymmetric families are deterministic', () => {
  expect('hello world').toEqual(expect.stringContaining(new String('world')));
  expect('hello world').toEqual(expect.stringMatching('h.llo'));
  expect('hello world').toEqual(expect.stringMatching(/world$/));
  expect('hello world').toEqual(expect.not.stringContaining('mars'));
  expect('hello world').toEqual(expect.not.stringMatching(/^mars/));
  expect(1.234).toEqual(expect.closeTo(1.23, 2));
  expect(1.24).toEqual(expect.not.closeTo(1.23, 2));
  expect(Infinity).toEqual(expect.closeTo(Infinity));
  expect(-Infinity).not.toEqual(expect.closeTo(Infinity));
  expect('not a number').not.toEqual(expect.not.closeTo(1));
});

test('asymmetric values integrate across matcher surfaces', () => {
  const fn = mock(value => value);
  fn('route', 42, { ok: true });

  expect(fn).toHaveBeenCalledWith(
    expect.stringMatching(/^rou/),
    expect.any(Number),
    expect.objectContaining({ ok: expect.any(Boolean) }),
  );
  expect(fn).toHaveReturnedWith(expect.stringContaining('rou'));
  expect([{ id: 7 }]).toContainEqual(expect.objectContaining({ id: expect.any(Number) }));
  expect({ nested: { value: 3 } }).toHaveProperty('nested.value', expect.any(Number));
  expect({ nested: { value: 3 } }).toMatchObject({
    nested: { value: expect.closeTo(3.001, 2) },
  });
  expect(() => {
    const error = new Error('boom');
    error.code = 'E_BOOM';
    throw error;
  }).toThrow(expect.objectContaining({ message: 'boom', code: 'E_BOOM' }));

  const odd = { asymmetricMatch: value => value % 2 === 1 };
  expect({ value: 3 }).toEqual({ value: odd });
});

test('invalid asymmetric factory inputs throw', () => {
  expect(() => expect.arrayContaining('x')).toThrow();
  expect(() => expect.not.arrayContaining('x')).toThrow();
  expect(() => expect.objectContaining(1)).toThrow();
  expect(() => expect.not.objectContaining(null)).toThrow();
  expect(() => expect.stringContaining([])).toThrow();
  expect(() => expect.stringMatching({})).toThrow();
  expect(() => expect.closeTo('1')).toThrow();
  expect(() => expect.not.closeTo(1, '2')).toThrow();
});
