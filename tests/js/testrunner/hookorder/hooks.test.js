beforeAll(() => console.log('fileBeforeAll'));
afterAll(() => console.log('fileAfterAll'));
beforeEach(() => console.log('fileBeforeEach'));
afterEach(() => console.log('fileAfterEach'));
test('t1', () => {});
describe('A', () => {
  beforeAll(() => console.log('A.beforeAll'));
  afterAll(() => console.log('A.afterAll'));
  beforeEach(() => console.log('A.beforeEach'));
  afterEach(() => console.log('A.afterEach'));
  test('t2', () => {});
  describe('B', () => {
    beforeAll(() => console.log('B.beforeAll'));
    beforeEach(() => console.log('B.beforeEach'));
    afterEach(() => console.log('B.afterEach'));
    afterAll(() => console.log('B.afterAll'));
    test('t3', () => {});
  });
});
