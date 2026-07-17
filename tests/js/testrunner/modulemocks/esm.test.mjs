import defaultValue, { call, value } from './fixture.mjs';
import * as namespace from './fixture.mjs';
import { value as reexported } from './reexport.mjs';

test('ESM live bindings namespaces and re-exports update', () => {
  expect(defaultValue).toBe('original-default');
  expect(value).toBe('original');
  expect(namespace.value).toBe('original');
  expect(reexported).toBe('original');
  expect(call()).toBe('original-call');

  mock.module('./fixture.mjs', () => ({
    default: 'mock-default',
    value: 'mock-value',
    call: () => 'mock-call',
    added: 7,
  }));
  expect(defaultValue).toBe('mock-default');
  expect(value).toBe('mock-value');
  expect(namespace.value).toBe('mock-value');
  expect(namespace.added).toBe(7);
  expect(reexported).toBe('mock-value');
  expect(call()).toBe('mock-call');

  mock.module('./fixture.mjs', () => ({
    default: 'second-default',
    value: 'second-value',
    call: () => 'second-call',
  }));
  expect(defaultValue).toBe('second-default');
  expect(value).toBe('second-value');
  expect(namespace.added).toBeUndefined();
  expect(reexported).toBe('second-value');
  expect(call()).toBe('second-call');
});
