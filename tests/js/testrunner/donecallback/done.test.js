const hookLog = [];

describe('done hooks', () => {
  beforeAll(done => {
    setTimeout(() => {
      hookLog.push('beforeAll');
      done();
    }, 1);
  });

  beforeEach(done => {
    hookLog.push('before');
    done();
  });

  afterEach(done => {
    hookLog.push('after');
    done();
  });

  afterAll(done => {
    setTimeout(() => {
      hookLog.push('afterAll');
      done();
    }, 1);
  });

  test('sync done', done => {
    expect(typeof done).toBe('function');
    done();
  });

  test('timer done', done => {
    setTimeout(() => {
      expect(true).toBe(true);
      done();
    }, 1);
  });
});

test.failing('done error is a callback failure', done => {
  done(new Error('expected done failure'));
});

test.failing('async rejection is a callback failure', async done => {
  throw new Error('expected async rejection');
});

test.failing('async rejection after done is still a failure', async done => {
  done();
  throw new Error('expected rejection after done');
});

test('async completion waits for promise and done', async done => {
  setTimeout(() => done(), 1);
  await new Promise(resolve => setTimeout(resolve, 2));
  expect(true).toBe(true);
});

test.each([[1], [2]])('row done %i', (value, done) => {
  expect(value).toBeGreaterThan(0);
  done();
});

test('callback hooks completed in order', done => {
  expect(hookLog).toEqual([
    'beforeAll',
    'before',
    'after',
    'before',
    'after',
    'afterAll',
  ]);
  done();
});
