const events = [];

afterEach(() => {
  events.push('afterEach');
});

test('callbacks run after afterEach in registration order', () => {
  onTestFinished(() => {
    events.push('finished 1');
  });
  onTestFinished(() => {
    events.push('finished 2');
  });
  events.push('body');
});

test('async and callback-style cleanup settle before the next test', () => {
  expect(events).toEqual(['body', 'afterEach', 'finished 1', 'finished 2']);
  onTestFinished(async () => {
    await new Promise(resolve => setTimeout(resolve, 2));
    events.push('async finished');
  });
  onTestFinished(done => {
    setTimeout(() => {
      events.push('done finished');
      done();
    }, 2);
  });
  events.push('async body');
});

test.failing('a body failure still runs cleanup', () => {
  expect(events).toEqual([
    'body',
    'afterEach',
    'finished 1',
    'finished 2',
    'async body',
    'afterEach',
    'async finished',
    'done finished',
  ]);
  onTestFinished(() => {
    events.push('failed cleanup');
  });
  throw new Error('expected body failure');
});

test('cleanup from a failed body completed', () => {
  expect(events.at(-2)).toBe('afterEach');
  expect(events.at(-1)).toBe('failed cleanup');
});

test('registration validates callbacks', () => {
  expect(() => onTestFinished(42)).toThrow('expects a callback function');
});
