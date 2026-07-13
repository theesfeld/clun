test('primitives', () => {
  expect(2 + 2).toBe(4);
  expect('hi').toBe('hi');
  expect(NaN).toBeNaN();
  expect(null).toBeNull();
  expect(undefined).toBeUndefined();
  expect(1).toBeDefined();
  expect(0).toBeFalsy();
  expect('x').toBeTruthy();
});
test('numbers', () => {
  expect(5).toBeGreaterThan(3);
  expect(5).toBeGreaterThanOrEqual(5);
  expect(2).toBeLessThan(3);
  expect(3.14159).toBeCloseTo(3.14, 2);
});
test('collections', () => {
  expect({a:1, b:{c:2}}).toEqual({a:1, b:{c:2}});
  expect({a:1, b:2, x:undefined}).toEqual({a:1, b:2});
  expect([1,2,3]).toContain(2);
  expect([{a:1}]).toContainEqual({a:1});
  expect('hello').toMatch(/ell/);
  expect('hello').toHaveLength(5);
  expect({a:{b:1}}).toHaveProperty('a.b', 1);
  expect({a:1, b:2, c:3}).toMatchObject({a:1, c:3});
});
test('instance + throw + not', () => {
  expect(new TypeError('x')).toBeInstanceOf(TypeError);
  expect(() => { throw new RangeError('bad'); }).toThrow('bad');
  expect(() => { throw new RangeError('bad'); }).toThrow(RangeError);
  expect(3).not.toBe(4);
  expect([1,2]).not.toContain(9);
});
test('strict vs loose', () => {
  expect({a:1}).toStrictEqual({a:1});
  expect(0.1 + 0.2).toBeCloseTo(0.3);
});
