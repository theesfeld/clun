const descriptor = Object.getOwnPropertyDescriptor(Clun, "color");
console.log("api", Clun.color.name, Clun.color.length, typeof Clun.color);
console.log("descriptor", descriptor.writable, descriptor.enumerable, descriptor.configurable);

console.log(
  "formats",
  Clun.color("red"),
  Clun.color("red", "hex"),
  Clun.color("red", "HEX"),
  Clun.color("red", "rgb"),
  Clun.color("red", "rgba"),
  Clun.color("red", "number"),
);
console.log("arrays", JSON.stringify(Clun.color("#1234", "[rgb]")), JSON.stringify(Clun.color("#1234", "[rgba]")));
console.log("objects", JSON.stringify(Clun.color("#1234", "{rgb}")), JSON.stringify(Clun.color("#1234", "{rgba}")));
console.log(
  "rgba-alpha",
  Clun.color("#0001", "rgba"),
  Clun.color("#1234", "rgba"),
  Clun.color("#12345678", "rgba"),
  Clun.color("rgba(0,0,0,.1)", "rgba"),
  Clun.color("rgba(0,0,0,.5)", "rgba"),
);

console.log(
  "aliases",
  Clun.color("red", "ansi-16") === Clun.color("red", "ansi_16"),
  Clun.color("red", "ansi-256") === Clun.color("red", "ansi256"),
  Clun.color("red", "ansi-16m") === Clun.color("red", "ansi-24bit"),
);
console.log(
  "ansi",
  JSON.stringify(Clun.color("black", "ansi-16")),
  JSON.stringify(Clun.color("red", "ansi-256")),
  JSON.stringify(Clun.color("red", "ansi-16m")),
);

console.log(
  "input",
  JSON.stringify(Clun.color(new Uint8Array([1, 2, 3, 4]), "[rgba]")),
  JSON.stringify(Clun.color({ r: 1, g: 2, b: 3, a: 0.5 }, "[rgba]")),
  JSON.stringify(Clun.color(0xff0000, "[rgba]")),
  JSON.stringify(Clun.color(0x80ff0000, "[rgba]")),
);
console.log(
  "object-alpha",
  JSON.stringify(Clun.color({ r: 1, g: 2, b: 3, a: 0 }, "[rgba]")),
  JSON.stringify(Clun.color({ r: 1, g: 2, b: 3, a: NaN }, "[rgba]")),
  JSON.stringify(Clun.color({ r: 1, g: 2, b: 3, a: -0.5 }, "[rgba]")),
  JSON.stringify(Clun.color({ r: 1, g: 2, b: 3, a: 1e308 }, "[rgba]")),
  JSON.stringify(Clun.color({ r: 1, g: 2, b: 3, a: -1e308 }, "[rgba]")),
);

console.log(
  "syntax",
  Clun.color("rgb(100% 0% 50% / 25%)", "hex"),
  Clun.color("rgb(1,2,3,.5)", "css"),
  Clun.color("hsl(.5turn 100% 50%)", "hex"),
  Clun.color("hwb(0 0% 0% / 50%)", "hex"),
);
console.log(
  "wide",
  Clun.color("lab(50% 20 30)", "hex"),
  Clun.color("lch(50% 20 30)", "hex"),
  Clun.color("oklab(50% .1 .1)", "hex"),
  Clun.color("color(display-p3 1 0 0)", "hex"),
  Clun.color("color(xyz-d50 .96422 1 .82521)", "hex"),
);
console.log(
  "color-css",
  Clun.color("color(srgb 1 0 0 / none)", "css"),
  Clun.color("color(xyz-d65 1 1 1)", "css"),
);

// Pinned engineering corrections deliberately supersede the stable executable bugs.
console.log(
  "engineering",
  Clun.color("oklch(62.8% .258 29.23deg)", "hex"),
  Clun.color("oklab(45.2% -0.032 -0.312)", "hex"),
  Clun.color("lab(29.5683% 68.2874 -112.0297)", "hex"),
  Clun.color("hsl(120 none 50%)", "hsl"),
  Clun.color("lab(50% none 30)", "lab"),
);
console.log(
  "normalization",
  Clun.color("rgb (255 0 0)") === null,
  Clun.color("hsl(none,0%,0%)") === null,
  Clun.color("rgb(1.4 0 0)", "hsl"),
  Clun.color("lab(25% -150 -150)", "hex"),
  Clun.color("lab(50% 100 100)", "hex"),
);
console.log(
  "precision-projections",
  Clun.color("rgb(1,2,3)", "hsl"),
  Clun.color("rgb(1,2,3)", "lab"),
  Clun.color("red", "lab"),
);
console.log(
  "none",
  Clun.color("rgb(0 0 0 / none)", "css"),
  Clun.color("color(display-p3 none 0 0 / none)", "css"),
);

console.log(
  "invalid",
  Clun.color("not-a-color") === null,
  Clun.color("red trailing") === null,
  Clun.color("rgb(1%,2,3)") === null,
  Clun.color("hsl(0 1 0.5)") === null,
  Clun.color("rgb(1. 2 3)") === null,
  Clun.color("hwb(0, 0%, 0%)") === null,
  Clun.color("x".repeat(1048577)) === null,
);
console.log(
  "bounds",
  typeof Clun.color("lab(1e308% 1e308 1e308)", "css") === "string",
  Clun.color("oklab(1e308% 1e308 1e308)", "lab") === null,
  Clun.color("oklch(1e308% 1e308 1e308)", "lab") === null,
  Clun.color("\u{1f600}".repeat(524289)) === null,
);

let touched = false;
let formatCode = "";
try {
  Clun.color({ get r() { touched = true; return 1; } }, "bad-format");
} catch (error) {
  formatCode = error.code;
}
let missingCode = "";
try {
  Clun.color();
} catch (error) {
  missingCode = error.code;
}
let constructError = false;
try {
  new Clun.color("red");
} catch (error) {
  constructError = error instanceof TypeError;
}
console.log("errors", formatCode, touched, missingCode, constructError);

let arrayError;
try {
  Clun.color([]);
} catch (error) {
  arrayError = error;
}
let channelError;
try {
  Clun.color([true, 0, 0]);
} catch (error) {
  channelError = error;
}
console.log(
  "input-errors",
  arrayError.name,
  arrayError.code === undefined,
  arrayError.message === "Expected array length 3 or 4",
  channelError.name,
  channelError.code,
);
