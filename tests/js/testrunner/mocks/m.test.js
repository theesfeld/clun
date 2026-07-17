test('mock surface and histories', () => {
  expect(jest.fn).toBe(mock);
  expect(vi.fn).toBe(mock);
  function add(a, b) { return this.base + a + b; }
  const fn = mock(add);
  const receiver = { base: 10, fn };
  expect(fn.getMockName()).toBe('add');
  expect(fn.length).toBe(2);
  expect(fn).not.toHaveBeenCalled();
  expect(receiver.fn(2, 3)).toBe(15);
  expect(fn).toHaveBeenCalledOnce();
  expect(fn).toHaveBeenCalledTimes(1);
  expect(fn).toHaveBeenCalledWith(2, 3);
  expect(fn).toHaveBeenLastCalledWith(2, 3);
  expect(fn).toHaveBeenNthCalledWith(1, 2, 3);
  expect(fn).toHaveReturnedWith(15);
  expect(fn).toHaveLastReturnedWith(15);
  expect(fn).toHaveNthReturnedWith(1, 15);
  expect(fn.mock.calls).toEqual([[2, 3]]);
  expect(fn.mock.lastCall).toEqual([2, 3]);
  expect(fn.mock.contexts[0]).toBe(receiver);
  expect(fn.mock.results).toEqual([{ type: 'return', value: 15 }]);
  expect(fn.mock.invocationCallOrder).toEqual([1]);
});

test('one-shot and default implementations', () => {
  const fn = mock(() => 'fallback');
  expect(fn.mockReturnValueOnce('first')).toBe(fn);
  fn.mockImplementationOnce((value) => 'second-' + value);
  fn.mockReturnValue('default');
  expect(fn()).toBe('first');
  expect(fn('x')).toBe('second-x');
  expect(fn()).toBe('default');
  fn.mockImplementation((value) => value + 1);
  expect(fn(4)).toBe(5);
  expect(fn).toHaveBeenCalledTimes(4);
  expect(fn).toHaveReturnedTimes(4);
  expect(fn).toHaveReturnedWith('second-x');
  expect(fn).toHaveLastReturnedWith(5);
  expect(fn).toHaveNthReturnedWith(2, 'second-x');
  fn.mockName('worker');
  fn.mockName('');
  expect(fn.getMockName()).toBe('worker');
});

test('throw results and clear reset', () => {
  const error = new Error('boom');
  const fn = mock(() => { throw error; });
  expect(() => fn(7)).toThrow('boom');
  expect(fn).toHaveBeenCalledWith(7);
  expect(fn).not.toHaveReturned();
  expect(fn.mock.results).toEqual([{ type: 'throw', value: error }]);
  expect(fn.mockClear()).toBe(fn);
  expect(fn).not.toHaveBeenCalled();
  fn.mockReturnValue(9);
  expect(fn()).toBe(9);
  expect(fn.mockReset()).toBe(fn);
  expect(fn()).toBeUndefined();
});

test('resolved and rejected values', async () => {
  const resolve = mock().mockResolvedValue('default');
  resolve.mockResolvedValueOnce('once');
  await expect(resolve()).resolves.toBe('once');
  await expect(resolve()).resolves.toBe('default');
  const reject = mock().mockRejectedValue(new Error('no'));
  reject.mockRejectedValueOnce(new Error('once-no'));
  await expect(reject()).rejects.toThrow('once-no');
  await expect(reject()).rejects.toThrow('no');
  expect(resolve).toHaveReturnedTimes(2);
  expect(reject).toHaveReturnedTimes(2);
});

test('spies preserve receiver and restore exactly', () => {
  const object = {
    base: 40,
    add(value) { return this.base + value; },
  };
  const original = object.add;
  const spy = spyOn(object, 'add');
  expect(spyOn(object, 'add')).toBe(spy);
  expect(object.add(2)).toBe(42);
  expect(spy).toHaveBeenCalledWith(2);
  spy.mockImplementation(function (value) { return this.base - value; });
  expect(object.add(2)).toBe(38);
  expect(spy).toHaveBeenCalledTimes(2);
  spy.mockRestore();
  expect(object.add).toBe(original);
  expect(object.add(2)).toBe(42);

  const prototype = { inherited(value) { return this.base + value; } };
  const child = Object.create(prototype);
  child.base = 5;
  const inherited = spyOn(child, 'inherited');
  expect(child.hasOwnProperty('inherited')).toBe(true);
  expect(child.inherited(2)).toBe(7);
  expect(inherited).toHaveBeenCalledWith(2);
  inherited.mockRestore();
  expect(child.hasOwnProperty('inherited')).toBe(false);
  expect(child.inherited).toBe(prototype.inherited);
});

test('global mock lifecycle operations', () => {
  const first = mock(() => 1);
  const second = mock(() => 2);
  first();
  second();
  jest.clearAllMocks();
  expect(first).not.toHaveBeenCalled();
  expect(second).not.toHaveBeenCalled();
  expect(first()).toBe(1);
  jest.resetAllMocks();
  expect(first()).toBeUndefined();

  const object = { method() { return 3; } };
  const original = object.method;
  spyOn(object, 'method').mockReturnValue(4);
  expect(object.method()).toBe(4);
  jest.restoreAllMocks();
  expect(object.method).toBe(original);
  expect(object.method()).toBe(3);
});

test('constructors temporary implementations and aliases', async () => {
  const Constructor = mock(function Constructor(value) { this.value = value; });
  const instance = new Constructor(7);
  expect(instance).toBeInstanceOf(Constructor);
  expect(instance.value).toBe(7);
  expect(Constructor.mock.instances[0]).toBe(instance);

  const fn = mock(() => 'normal');
  expect(fn.withImplementation(() => 'temporary', () => fn())).toBe('temporary');
  expect(fn()).toBe('normal');
  await fn.withImplementation(() => 'temporary-async', async () => {
    await Promise.resolve();
    expect(fn()).toBe('temporary-async');
  });
  expect(fn()).toBe('normal');
  expect(() => fn.withImplementation(() => 'temporary-throw', () => {
    throw new Error('temporary stop');
  })).toThrow('temporary stop');
  expect(fn()).toBe('normal');
  const receiver = { fn: mock().mockReturnThis() };
  expect(receiver.fn()).toBe(receiver);

  fn('value');
  expect(fn).toBeCalled();
  expect(fn).toBeCalledTimes(6);
  expect(fn).toBeCalledWith('value');
  expect(fn).lastCalledWith('value');
  expect(fn).nthCalledWith(6, 'value');
  expect(fn).toReturn();
  expect(fn).toReturnTimes(6);
  expect(fn).toReturnWith('normal');
  expect(fn).lastReturnedWith('normal');
  expect(fn).nthReturnedWith(6, 'normal');
});
