const loaded = require('./fixture.cjs');

test('CommonJS module mocks update loaded objects in place', () => {
  expect(loaded.value).toBe('original');
  expect(loaded.removed).toBe(true);
  const identity = loaded;
  expect(mock.module('./fixture.cjs', () => ({
    value: 'mocked',
    call: value => 'mock-' + value,
  }))).toBeUndefined();
  expect(loaded).toBe(identity);
  expect(loaded.value).toBe('mocked');
  expect(loaded.removed).toBeUndefined();
  expect(loaded.call('x')).toBe('mock-x');
  expect(require('./fixture.cjs')).toBe(identity);

  mock.module('./fixture.cjs', () => ({ value: 'again' }));
  expect(loaded.value).toBe('again');
  expect(loaded.call).toBeUndefined();
});

test('unresolved modules and Promise factories are loadable', () => {
  mock.module('./missing.cjs', async () => {
    await Promise.resolve();
    return { answer: 42 };
  });
  expect(require('./missing.cjs').answer).toBe(42);
  expect(require('./missing.cjs')).toBe(require('./missing.cjs'));
  mock.module('virtual-package-that-does-not-exist', () => ({ answer: 43 }));
  expect(require('virtual-package-that-does-not-exist').answer).toBe(43);
  mock.module('file:./file-missing.cjs', () => ({ answer: 44 }));
  expect(require('./file-missing.cjs').answer).toBe(44);
});

test('builtin aliases share one mocked module object', () => {
  const fs = require('node:fs');
  mock.module('fs', () => ({ readFileSync: () => 'mock-file' }));
  expect(fs.readFileSync()).toBe('mock-file');
  expect(require('fs')).toBe(fs);
  expect(require('node:fs')).toBe(fs);
});

test('module mock aliases and argument validation match Bun', () => {
  expect(jest.mock).toBe(vi.mock);
  jest.mock('./jest-missing.cjs', () => ({ source: 'jest' }));
  expect(require('./jest-missing.cjs').source).toBe('jest');
  expect(() => mock.module(123, () => ({})))
    .toThrow('mock(module, fn) requires a module name string');
  expect(() => mock.module('package-that-does-not-exist'))
    .toThrow('mock(module, fn) requires a function');
  expect(() => mock.module('./bad.cjs', () => 1))
    .toThrow('mock(module, fn) must return an object');
  expect(() => mock.module('./throws.cjs', () => { throw new Error('factory boom'); }))
    .toThrow('factory boom');
  expect(() => mock.module('./rejects.cjs', async () => { throw new Error('factory reject'); }))
    .toThrow('factory reject');
});

test('mock.restore restores spies without removing module mocks', () => {
  const object = { call() { return 'real'; } };
  const original = object.call;
  spyOn(object, 'call').mockReturnValue('spy');
  expect(object.call()).toBe('spy');
  mock.restore();
  expect(object.call).toBe(original);
  expect(object.call()).toBe('real');
  expect(require('./fixture.cjs').value).toBe('again');
});
