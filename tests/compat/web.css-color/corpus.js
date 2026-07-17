const names = "aliceblue,antiquewhite,aqua,aquamarine,azure,beige,bisque,black,blanchedalmond,blue,blueviolet,brown,burlywood,cadetblue,chartreuse,chocolate,coral,cornflowerblue,cornsilk,crimson,cyan,darkblue,darkcyan,darkgoldenrod,darkgray,darkgreen,darkgrey,darkkhaki,darkmagenta,darkolivegreen,darkorange,darkorchid,darkred,darksalmon,darkseagreen,darkslateblue,darkslategray,darkslategrey,darkturquoise,darkviolet,deeppink,deepskyblue,dimgray,dimgrey,dodgerblue,firebrick,floralwhite,forestgreen,fuchsia,gainsboro,ghostwhite,gold,goldenrod,gray,green,greenyellow,grey,honeydew,hotpink,indianred,indigo,ivory,khaki,lavender,lavenderblush,lawngreen,lemonchiffon,lightblue,lightcoral,lightcyan,lightgoldenrodyellow,lightgray,lightgreen,lightgrey,lightpink,lightsalmon,lightseagreen,lightskyblue,lightslategray,lightslategrey,lightsteelblue,lightyellow,lime,limegreen,linen,magenta,maroon,mediumaquamarine,mediumblue,mediumorchid,mediumpurple,mediumseagreen,mediumslateblue,mediumspringgreen,mediumturquoise,mediumvioletred,midnightblue,mintcream,mistyrose,moccasin,navajowhite,navy,oldlace,olive,olivedrab,orange,orangered,orchid,palegoldenrod,palegreen,paleturquoise,palevioletred,papayawhip,peachpuff,peru,pink,plum,powderblue,purple,rebeccapurple,red,rosybrown,royalblue,saddlebrown,salmon,sandybrown,seagreen,seashell,sienna,silver,skyblue,slateblue,slategray,slategrey,snow,springgreen,steelblue,tan,teal,thistle,tomato,turquoise,violet,wheat,white,whitesmoke,yellow,yellowgreen".split(",");

let hash = 0;
for (let nameIndex = 0; nameIndex < names.length; nameIndex++) {
  const name = names[nameIndex];
  const hex = Clun.color(name, "hex");
  if (typeof hex !== "string") throw new Error(`named color did not parse: ${name}`);
  hash += (parseInt(hex.slice(1), 16) * (nameIndex + 1)) + name.length;
}
console.log("named", names.length, hash);
console.log("transparent", Clun.color("transparent", "rgba"), Clun.color("transparent", "css"));

const vectors = [
  ["hex", "#123", "[rgba]"],
  ["hex-alpha", "#1234", "[rgba]"],
  ["rgb-modern", "rgb(10% 20% 30% / 40%)", "[rgba]"],
  ["rgb-legacy", "rgba(1, 2, 3, .5)", "[rgba]"],
  ["hsl", "hsl(-.5turn 100% 50% / 25%)", "[rgba]"],
  ["hwb", "hwb(120 20% 30% / none)", "[rgba]"],
  ["lab", "lab(50% 20 30 / 40%)", "hex"],
  ["lch", "lch(50% 20 30deg / 40%)", "hex"],
  ["oklab", "oklab(50% .1 .1 / 40%)", "hex"],
  ["oklch", "oklch(62.8% .258 29.23deg / 40%)", "hex"],
  ["srgb", "color(srgb .1 .2 .3 / 40%)", "hex"],
  ["linear", "color(srgb-linear .1 .2 .3 / 40%)", "hex"],
  ["p3", "color(display-p3 .1 .2 .3 / 40%)", "hex"],
  ["a98", "color(a98-rgb .1 .2 .3 / 40%)", "hex"],
  ["prophoto", "color(prophoto-rgb .1 .2 .3 / 40%)", "hex"],
  ["rec2020", "color(rec2020 .1 .2 .3 / 40%)", "hex"],
  ["xyz", "color(xyz .1 .2 .3 / 40%)", "hex"],
  ["xyz-d50", "color(xyz-d50 .1 .2 .3 / 40%)", "hex"],
  ["css-lab", "lab(50% 20 30 / 40%)", "css"],
  ["css-oklab", "oklab(50% .1 .1 / 40%)", "css"],
  ["css-p3", "color(display-p3 .1 .2 .3 / 40%)", "css"],
  ["css-xyz-d50", "color(xyz-d50 .1 .2 .3 / 40%)", "css"],
];
for (const [id, input, format] of vectors) {
  console.log("vector", id, JSON.stringify(Clun.color(input, format)));
}

const roundTrips = [
  "#1234",
  "rgb(10% 20% 30% / 40%)",
  "lab(50% 20 30 / 40%)",
  "oklch(62.8% .258 29.23deg / 40%)",
  "color(display-p3 .1 .2 .3 / 40%)",
  "color(xyz-d50 .1 .2 .3 / 40%)",
];
let roundTripCount = 0;
for (const input of roundTrips) {
  const css = Clun.color(input, "css");
  if (Clun.color(css, "hex") !== Clun.color(input, "hex")) {
    throw new Error(`CSS output did not preserve byte color: ${input} -> ${css}`);
  }
  roundTripCount++;
}
console.log("roundtrip", roundTripCount);

const order = [];
const object = {
  get r() { order.push("r"); return 1; },
  get g() { order.push("g"); return 2; },
  get b() { order.push("b"); return 3; },
  get a() { order.push("a"); return .5; },
};
const objectResult = Clun.color(object, "[rgba]");
console.log("getters", order.length, JSON.stringify(objectResult), order.join(","));

const arrayOrder = [];
const array = [1, 2, 3, 4];
Object.defineProperty(array, "0", { get() { arrayOrder.push("0"); return 1; } });
Object.defineProperty(array, "1", { get() { arrayOrder.push("1"); return 2; } });
Object.defineProperty(array, "2", { get() { arrayOrder.push("2"); return 3; } });
Object.defineProperty(array, "3", { get() { arrayOrder.push("3"); return 4; } });
console.log("array-getters", JSON.stringify(Clun.color(array, "[rgba]")), arrayOrder.join(","));

let abrupt = "";
try {
  Clun.color({ get r() { throw new Error("stop"); }, get g() { abrupt += "g"; } });
} catch (error) {
  abrupt = `${error.message}:${abrupt || "stopped"}`;
}
console.log("abrupt", abrupt);
