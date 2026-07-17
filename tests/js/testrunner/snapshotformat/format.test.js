test("Bun snapshot primitives and sorted containers", () => {
  expect("line one\nline two").toMatchInlineSnapshot(`
"line one
line two"
`);
  expect({ z: 3, a: [1, { z: 4, a: 2 }] }).toMatchInlineSnapshot(`
{
  "a": [
    1,
    {
      "a": 2,
      "z": 4,
    },
  ],
  "z": 3,
}
`);
});

test("Bun snapshot collection formatting", () => {
  expect(new Map([[1, "one"], ["two", 2]])).toMatchInlineSnapshot(`
Map {
  1 => "one",
  "two" => 2,
}
`);
  expect(new Set([3, "four"])).toMatchInlineSnapshot(`
Set {
  3,
  "four",
}
`);
  expect(new Map()).toMatchInlineSnapshot(`Map {}`);
  expect(new Set()).toMatchInlineSnapshot(`Set {}`);
});

test("Bun snapshot built-in formatting", () => {
  expect(new Date(0)).toMatchInlineSnapshot(`1970-01-01T00:00:00.000Z`);
  expect(new Error("broken")).toMatchInlineSnapshot(`[Error: broken]`);
  expect(new Error()).toMatchInlineSnapshot(`[Error]`);
  expect(Promise.resolve(1)).toMatchInlineSnapshot(`Promise {}`);
  expect(/hello/).toMatchInlineSnapshot(`/hello/`);
  expect(new Number(7)).toMatchInlineSnapshot(`Number {}`);
  expect(new Boolean(true)).toMatchInlineSnapshot(`Boolean {}`);
});

test("Bun snapshot binary and circular formatting", () => {
  expect(new Int8Array()).toMatchInlineSnapshot(`Int8Array []`);
  expect(new Int8Array([1, -2, 3])).toMatchInlineSnapshot(`
Int8Array [
  1,
  -2,
  3,
]
`);
  expect(new ArrayBuffer(0)).toMatchInlineSnapshot(`ArrayBuffer []`);
  expect(new DataView(new ArrayBuffer(0))).toMatchInlineSnapshot(`DataView []`);
  const circular = {};
  circular.self = circular;
  expect(circular).toMatchInlineSnapshot(`
{
  "self": [Circular],
}
`);
});

test("Bun snapshot functions, wrappers, and classes", () => {
  function named(value) { return value; }
  class Example {
    constructor() {
      this.z = 3;
      this.a = 1;
    }
  }
  expect(named).toMatchInlineSnapshot(`[Function: named]`);
  expect(function () {}).toMatchInlineSnapshot(`[Function]`);
  expect(new String("hi")).toMatchInlineSnapshot(`
String {
  "0": "h",
  "1": "i",
}
`);
  expect(new Example()).toMatchInlineSnapshot(`
Example {
  "a": 1,
  "z": 3,
}
`);
  expect(new WeakMap()).toMatchInlineSnapshot(`WeakMap {}`);
  expect(new WeakSet()).toMatchInlineSnapshot(`WeakSet {}`);
  const nullPrototype = Object.create(null);
  nullPrototype.value = 1;
  expect(nullPrototype).toMatchInlineSnapshot(`
{
  "value": 1,
}
`);
});

test("Bun snapshot numeric and Buffer edge values", () => {
  expect(NaN).toMatchInlineSnapshot(`NaN`);
  expect(Infinity).toMatchInlineSnapshot(`Infinity`);
  expect(-Infinity).toMatchInlineSnapshot(`-Infinity`);
  expect(-0).toMatchInlineSnapshot(`-0`);
  expect(123n).toMatchInlineSnapshot(`123n`);
  expect(Symbol("item")).toMatchInlineSnapshot(`Symbol(item)`);
  expect(Buffer.from("hi")).toMatchInlineSnapshot(`
{
  "data": [
    104,
    105,
  ],
  "type": "Buffer",
}
`);
  expect(Buffer.from("")).toMatchInlineSnapshot(`
{
  "data": [],
  "type": "Buffer",
}
`);
});
