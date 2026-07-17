let sawNegatedContext = false;
let sawPromiseContext = '';

expect.extend({
  toBeDivisibleBy(received, divisor) {
    return {
      pass: received % divisor === 0,
      message: () => `${this.utils.printReceived(received)} is not divisible by ${this.utils.printExpected(divisor)}`,
    };
  },
  toEqualWithContext(received, expected) {
    return {
      pass: this.equals(received, expected),
      message: () => 'values were not equal',
    };
  },
  toTrackNegation(received, expected) {
    sawNegatedContext = this.isNot;
    return { pass: received === expected, message: () => 'tracked negation' };
  },
  toTrackPromise(received, expected) {
    sawPromiseContext = this.promise;
    return { pass: received === expected, message: () => 'tracked promise' };
  },
  async toEventuallyEqual(received, expected) {
    await Promise.resolve();
    return { pass: this.equals(received, expected), message: () => 'eventual mismatch' };
  },
});

test('extend installs synchronous matchers and matcher context', () => {
  expect(12).toBeDivisibleBy(3);
  expect(10).not.toBeDivisibleBy(3);
  expect({ nested: [1, 2] }).toEqualWithContext({ nested: [1, 2] });
  expect(1).not.toTrackNegation(2);
  expect(sawNegatedContext).toBe(true);
  expect(() => expect(5).toBeDivisibleBy(2)).toThrow('not divisible');
});

test('custom matchers are available as asymmetric matchers', () => {
  expect({ value: 12 }).toEqual({ value: expect.toBeDivisibleBy(3) });
  expect(10).toEqual(expect.not.toBeDivisibleBy(3));
  expect([6, 7]).toContainEqual(expect.toBeDivisibleBy(3));
  expect({ nested: { value: 9 } }).toMatchObject({
    nested: { value: expect.toBeDivisibleBy(3) },
  });
  sawNegatedContext = false;
  expect(1).toEqual(expect.not.toTrackNegation(2));
  expect(sawNegatedContext).toBe(true);
});

test('async custom matchers compose with direct and asymmetric assertions', async () => {
  await expect('clun').toEventuallyEqual('clun');
  await expect(Promise.resolve(12)).resolves.toEventuallyEqual(12);
  await expect(Promise.reject(15)).rejects.toEventuallyEqual(15);
  await expect(Promise.resolve(2)).resolves.toTrackPromise(2);
  expect(sawPromiseContext).toBe('resolves');
  await expect(Promise.reject(3)).rejects.toTrackPromise(3);
  expect(sawPromiseContext).toBe('rejects');
  await expect({ value: 'async' }).toEqual({
    value: expect.toEventuallyEqual('async'),
  });
  sawNegatedContext = false;
  await expect(Promise.resolve(1)).toEqual(
    expect.not.resolvesTo.toTrackNegation(2),
  );
  expect(sawNegatedContext).toBe(true);
});

test('extend validates definitions and supports replacement', () => {
  expect(() => expect.extend({ invalid: 1 })).toThrow('Must be a function');
  expect.extend({
    toBeDivisibleBy(received) {
      return { pass: received === 42, message: () => 'replacement mismatch' };
    },
  });
  expect(42).toBeDivisibleBy();
  expect(41).not.toBeDivisibleBy();
  expect(() => expect(42).toBeDivisibleBy(7)).not.toThrow();
});

test('extend discovers prototype, class, empty, and numeric matcher keys', () => {
  const inherited = {
    toBeAnswer(received) {
      return { pass: received === 42 };
    },
  };
  const definitions = Object.create(inherited);
  definitions[''] = (received, expected) => ({ pass: received === expected });
  definitions[1073741820] = received => ({ pass: received === 42 });
  expect.extend(definitions);

  class ClassMatchers {
    toBeOdd(received) {
      return { pass: received % 2 === 1 };
    }
  }
  expect.extend(new ClassMatchers());

  expect(42).toBeAnswer();
  expect(1)[''](1);
  expect(typeof expect[1073741820]).toBe('function');
  expect(42)[1073741820]();
  expect(3).toBeOdd();
});

test('custom matcher failures validate results and preserve async rejection', async () => {
  expect.extend({
    invalidResult() {
      return 42;
    },
    missingMessage(received) {
      return { pass: received === 42 };
    },
    async rejectedMatcher() {
      throw new Error('custom rejection');
    },
  });

  expect(() => expect(1).invalidResult()).toThrow('Unexpected return from matcher function');
  expect(() => expect(1).missingMessage()).toThrow('No message was specified');
  await expect(expect(1).rejectedMatcher()).rejects.toThrow('custom rejection');
});
