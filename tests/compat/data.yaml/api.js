let failed = 0;
let checked = 0;

function exact(value, expected, space) {
  checked++;
  const actual = Clun.YAML.stringify(value, null, space);
  if (actual !== expected) {
    failed++;
    console.log("FAIL", JSON.stringify(value), JSON.stringify(expected), JSON.stringify(actual));
  }
}

exact(null, "null");
exact(true, "true");
exact(false, "false");
exact(42, "42");
exact(3.14, "3.14");
exact(-17, "-17");
exact(0, "0");
exact(-0, "-0");
exact(Infinity, ".inf");
exact(-Infinity, "-.inf");
exact(NaN, ".nan");

const strings = [
  ["hello", "hello"],
  ["hello world", "hello world"],
  ["", '""'],
  ["true", '"true"'],
  ["false", '"false"'],
  ["null", '"null"'],
  ["123", '"123"'],
  ["line1\nline2", '"line1\\nline2"'],
  ['with "quotes"', '"with \\"quotes\\""'],
  ["with\ttab", '"with\\ttab"'],
  ["with\rcarriage", '"with\\rcarriage"'],
  ["with\x00null", '"with\\0null"'],
  ["&anchor", '"&anchor"'],
  ["*alias", '"*alias"'],
  ["#comment", '"#comment"'],
  ["---", '"---"'],
  ["...", '"..."'],
  ["{flow}", '"{flow}"'],
  ["[flow]", '"[flow]"'],
  ["key: value", '"key: value"'],
  [" leading space", '" leading space"'],
  ["trailing space ", '"trailing space "'],
  ["key:value", "key:value"],
  ["http://example.com", "http://example.com"],
  ["tin:", '"tin:"'],
  ["a,b,c", '"a,b,c"'],
  ["#", '"#"'],
  ["`", '"`"'],
  ["'", '"\'"'],
  ["\\", "\\"],
  ["....", '"...."'],
  ["..", ".."],
  ["abc123", "abc123"],
  ["123abc", "123abc"],
  ["1.2.3", "1.2.3"],
  ["0xNotHex", "0xNotHex"],
  ["no  problem", "no  problem"],
];
for (const pair of strings) exact(pair[0], pair[1]);

const numberLike = [
  "42", "3.14", "-17", "+99", ".5", "-.5", "1e10", "1E10", "1.5e-10",
  "3.14e+5", "0x1F", "0xDEADBEEF", "0XFF", "0o777", "0O644", "011",
  "110", "0000123", "0e6836", "0E6836", "0e0", "0.0", "0.5", "+0",
  "+1", "+1.5", "+1e5", "+1e+5", "-1e-5", "1e+5", "1e-5", "+.inf",
  "+.Inf", "+.INF", "1+5", "1-5", "0+5", "0-5", "123-456", "3.14+2", ".5+3",
];
for (const value of numberLike) exact(value, '"' + value + '"');

const controls = [
  [0x00, '"\\0"'], [0x01, '"\\x01"'], [0x02, '"\\x02"'],
  [0x03, '"\\x03"'], [0x04, '"\\x04"'], [0x05, '"\\x05"'],
  [0x06, '"\\x06"'], [0x07, '"\\a"'], [0x08, '"\\b"'],
  [0x09, '"\\t"'], [0x0a, '"\\n"'], [0x0b, '"\\v"'],
  [0x0c, '"\\f"'], [0x0d, '"\\r"'], [0x0e, '"\\x0e"'],
  [0x0f, '"\\x0f"'], [0x10, '"\\x10"'], [0x1b, '"\\e"'],
  [0x22, '"\\\""'], [0x7f, '"\\x7f"'], [0x85, '"\\N"'],
  [0xa0, '"\\_"'], [0x2028, '"\\L"'], [0x2029, '"\\P"'],
];
for (const pair of controls) exact(String.fromCharCode(pair[0]), pair[1]);

exact([], "[]");
exact({}, "{}");
exact([1, 2, 3], "- 1\n- 2\n- 3", 2);
exact([[1, 2], [3, 4]], "- - 1\n  - 2\n- - 3\n  - 4", 2);
exact([1, [2, 3], 4], "- 1\n- - 2\n  - 3\n- 4", 2);
exact({ a: 1, b: 2 }, "a: 1\nb: 2", 2);
exact({ database: { host: "localhost", port: 5432 } }, "database: \n  host: localhost\n  port: 5432", 2);
exact({ "special-key": "value" }, "special-key: value", 2);
exact({ "123": "numeric" }, '"123": numeric', 2);
exact({ "": "empty" }, '"": empty', 2);
exact({ "true": "keyword" }, '"true": keyword', 2);
exact({ a: undefined, b: undefined }, "{}", 2);
exact({ fn: function () {}, value: 42 }, "value: 42", 2);

const shared = { value: 7 };
const roundTrip = Clun.YAML.parse(Clun.YAML.stringify({ first: shared, second: shared }));
checked++;
if (roundTrip.first !== roundTrip.second || roundTrip.first.value !== 7) failed++;

const cycle = {};
cycle.self = cycle;
const cycleRoundTrip = Clun.YAML.parse(Clun.YAML.stringify(cycle));
checked++;
if (cycleRoundTrip.self !== cycleRoundTrip) failed++;

const astral = "\uD83D\uDE00";
checked++;
if (Clun.YAML.parse(Clun.YAML.stringify(astral)) !== astral) failed++;

function syntaxError(input) {
  try {
    Clun.YAML.parse(input);
    return false;
  } catch (error) {
    return error instanceof SyntaxError;
  }
}

checked += 5;
if (!syntaxError("*missing")) failed++;
if (!syntaxError('"\\uD83D"')) failed++;
if (!syntaxError(Buffer.from([0xff]))) failed++;
if (!syntaxError("[".repeat(258) + "0" + "]".repeat(258))) failed++;
if (Object.prototype.polluted !== undefined ||
    !Object.prototype.hasOwnProperty.call(Clun.YAML.parse("__proto__: {polluted: true}"), "__proto__")) failed++;

console.log("differential", checked, "checked", failed, "failed");
if (failed) process.exitCode = 1;
