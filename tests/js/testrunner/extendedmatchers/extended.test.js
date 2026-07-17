test('nil and typeof predicates', () => {
  expect(null).toBeNil();
  expect(undefined).toBeNil();
  expect(0).not.toBeNil();
  expect('clun').toBeTypeOf('string');
  expect(1).toBeTypeOf('number');
  expect(1n).toBeTypeOf('bigint');
  expect(Symbol('x')).toBeTypeOf('symbol');
  expect(() => {}).toBeTypeOf('function');
  expect(null).toBeTypeOf('object');
  expect(() => expect(1).toBeTypeOf('integer')).toThrow('valid type string');
});

test('boolean predicates require booleans', () => {
  expect(true).toBeBoolean();
  expect(false).toBeBoolean();
  expect(1).not.toBeBoolean();
  expect(true).toBeTrue();
  expect(false).not.toBeTrue();
  expect(false).toBeFalse();
  expect(0).not.toBeFalse();
});

test('number predicates preserve NaN and finite boundaries', () => {
  expect(NaN).toBeNumber();
  expect(Infinity).toBeNumber();
  expect(1n).not.toBeNumber();
  expect(2).toBeInteger();
  expect(2.5).not.toBeInteger();
  expect(Infinity).not.toBeInteger();
  expect(2.5).toBeFinite();
  expect(NaN).not.toBeFinite();
  expect(Infinity).not.toBeFinite();
});

test('positive and negative predicates follow Bun rounding boundaries', () => {
  expect(1.23).toBePositive();
  expect(0.49).not.toBePositive();
  expect(0.5).toBePositive();
  expect(Infinity).not.toBePositive();
  expect(-1.23).toBeNegative();
  expect(-0.49).not.toBeNegative();
  expect(-0.5).toBeNegative();
  expect(-Infinity).not.toBeNegative();
});

test('object function and symbol predicates distinguish primitives', () => {
  expect({}).toBeObject();
  expect([]).toBeObject();
  expect(class Example {}).toBeObject();
  expect(null).not.toBeObject();
  expect(() => {}).toBeFunction();
  expect(class Example {}).toBeFunction();
  expect({}).not.toBeFunction();
  expect(Symbol.iterator).toBeSymbol();
  expect('symbol').not.toBeSymbol();
});

test('array predicates validate exact array size', () => {
  expect([]).toBeArray();
  expect(new Array(3)).toBeArrayOfSize(3);
  expect([1, 2]).not.toBeArrayOfSize(1);
  expect({ length: 2 }).not.toBeArray();
  expect(() => expect([]).toBeArrayOfSize(1.5)).toThrow('requires the first argument');
});

test('even and odd predicates include BigInt', () => {
  expect(0).toBeEven();
  expect(-8).toBeEven();
  expect(3).toBeOdd();
  expect(-3).toBeOdd();
  expect(2.5).not.toBeEven();
  expect(NaN).not.toBeOdd();
  expect(9007199254740990n).toBeEven();
  expect(9007199254740991n).toBeOdd();
});

test('date and string predicates handle wrappers and invalid dates', () => {
  expect(new Date(0)).toBeDate();
  expect(new Date(NaN)).toBeDate();
  expect(new Date(0)).toBeValidDate();
  expect(new Date(NaN)).not.toBeValidDate();
  expect('clun').toBeString();
  expect(new String('clun')).toBeString();
  expect(1).not.toBeString();
});

test('within uses an inclusive start and exclusive end', () => {
  expect(0).toBeWithin(0, 1);
  expect(3.14).toBeWithin(3, 3.141);
  expect(3.14).not.toBeWithin(3.1, 3.14);
  expect(Infinity).not.toBeWithin(-Infinity, Infinity);
  expect(() => expect(1).toBeWithin('0', 2)).toThrow('first argument');
});

test('whitespace equality removes Bun ASCII whitespace', () => {
  expect(' h e l l o ').toEqualIgnoringWhitespace('hello');
  expect('hello\nworld').toEqualIgnoringWhitespace('hello world');
  expect('hello').not.toEqualIgnoringWhitespace('world');
  expect({}).not.toEqualIgnoringWhitespace('object');
  expect(() => expect('hello').toEqualIgnoringWhitespace({})).toThrow('requires argument to be a string');
});

test('string affix matchers preserve empty-string behavior', () => {
  expect('clun runtime').toInclude('run');
  expect('clun runtime').toStartWith('clun');
  expect('clun runtime').toEndWith('runtime');
  expect('').toInclude('');
  expect('').toStartWith('');
  expect('').toEndWith('');
  expect('clun').not.toInclude('bun');
  expect(() => expect('clun').toInclude(1)).toThrow('first argument');
});

test('repetition counts non-overlapping occurrences', () => {
  expect('abc abc abc').toIncludeRepeated('abc', 3);
  expect('aaaa').toIncludeRepeated('aa', 2);
  expect('aaaa').not.toIncludeRepeated('aa', 3);
  expect('a').toIncludeRepeated('b', 0);
  expect(() => expect('a').toIncludeRepeated('', 1)).toThrow('non-empty string');
  expect(() => expect('a').toIncludeRepeated('a', -0)).toThrow('second argument');
  expect(() => expect('a').toIncludeRepeated('a', 1.5)).toThrow('second argument');
});

test('satisfy requires an exact boolean result', () => {
  expect(3).toSatisfy(value => value === 3);
  expect(3).not.toSatisfy(value => value === 4);
  expect(3).not.toSatisfy(() => 1);
  expect(() => expect(3).toSatisfy(3)).toThrow('must be a function');
  expect(() => expect(3).toSatisfy(() => {
    throw new Error('boom');
  })).toThrow('predicate threw an exception');
});
