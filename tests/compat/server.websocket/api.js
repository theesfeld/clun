// Static-friendly surface probe for WebSocket Yes.
const has = typeof WebSocket === "function";
const c = WebSocket.CONNECTING;
const o = WebSocket.OPEN;
console.log(["WebSocket", has ? "yes" : "no", c, o].join(" "));
process.exit(has && c === 0 && o === 1 ? 0 : 1);
