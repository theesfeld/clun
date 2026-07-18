test("accessor descriptors", () => {
  const obj = {};
  Object.defineProperty(obj, "g", {
    enumerable: true,
    get() { return 1; },
  });
  Object.defineProperty(obj, "gs", {
    enumerable: true,
    get() { return 2; },
    set(_v) {},
  });
  Object.defineProperty(obj, "hidden", {
    enumerable: false,
    value: 3,
  });
  expect(obj).toMatchInlineSnapshot(`{
  "g": [Getter],
  "gs": [Getter/Setter],
}`);
});

test("pathological strings and unicode", () => {
  expect("tab\there").toMatchInlineSnapshot(`"tab\\there"`);
  expect("null\u0000byte").toMatchInlineSnapshot(`"null\\x00byte"`);
  expect("emoji 🎯 and 中文").toMatchInlineSnapshot(`"emoji 🎯 and 中文"`);
  expect("`backtick`").toMatchInlineSnapshot(`"\\\`backtick\\\`"`);
});
