test('missing done times out', done => {}, 5);

test.failing('done timeout is not an expected failure', done => {}, 5);

describe('callback hook boundary', () => {
  beforeEach(done => {
    done(new Error('callback hook failed'));
  });

  test.failing('hook error is not an expected failure', done => {
    done(new Error('body failure'));
  });
});
