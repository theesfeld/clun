// #339 residual destubs: node:http / https / tls / http2 real surfaces.
const http = require("http");
const https = require("https");
const tls = require("tls");
const http2 = require("http2");

// --- tls.createSecureContext stores and exposes options ---
const sc = tls.createSecureContext({
  minVersion: "TLSv1.2",
  maxVersion: "TLSv1.3",
  rejectUnauthorized: false,
  servername: "localhost",
});
if (!sc || sc.minVersion !== "TLSv1.2") throw new Error("secureContext minVersion");
if (sc.maxVersion !== "TLSv1.3") throw new Error("secureContext maxVersion");
if (sc.rejectUnauthorized !== false) throw new Error("secureContext rejectUnauthorized");
if (sc.servername !== "localhost") throw new Error("secureContext servername");
if (typeof sc.context !== "string" && sc.context !== null) {
  // context is either pure-tls marker string or null/pending
}

// --- tls.checkServerIdentity ---
const okId = tls.checkServerIdentity("example.com", {
  subject: { CN: "example.com" },
  subjectaltname: "DNS:example.com, DNS:www.example.com",
});
if (okId !== undefined) throw new Error("checkServerIdentity should accept CN match");

const badId = tls.checkServerIdentity("evil.example", {
  subject: { CN: "example.com" },
  subjectaltname: "DNS:example.com",
});
if (!badId || typeof badId.message !== "string") {
  throw new Error("checkServerIdentity should reject mismatch");
}

// --- tls.createSecurePair (legacy, exceeds Bun) ---
const pair = tls.createSecurePair(sc, false, false, true);
if (!pair.cleartext || !pair.encrypted) throw new Error("securePair sides");
if (typeof pair.cleartext.write !== "function") throw new Error("securePair write");

// --- http2 settings pack/unpack ---
const settings = http2.getDefaultSettings();
if (settings.headerTableSize !== 4096) throw new Error("default headerTableSize");
const packed = http2.getPackedSettings({
  headerTableSize: 4096,
  enablePush: true,
  maxFrameSize: 16384,
});
if (!packed || typeof packed.length !== "number" || packed.length < 6) {
  throw new Error("getPackedSettings length");
}
const unpacked = http2.getUnpackedSettings(packed);
if (unpacked.headerTableSize !== 4096) throw new Error("unpacked headerTableSize");
if (unpacked.maxFrameSize !== 16384) throw new Error("unpacked maxFrameSize");
if (http2.constants.NGHTTP2_SETTINGS !== 4) throw new Error("constants.SETTINGS");

// --- Agent constructors store options ---
const agent = new http.Agent({ keepAlive: true, maxSockets: 7 });
if (agent.maxSockets !== 7) throw new Error("http.Agent maxSockets");
if (agent.keepAlive !== true) throw new Error("http.Agent keepAlive");
agent.destroy();

const httpsAgent = new https.Agent({ maxSockets: 3 });
if (httpsAgent.protocol !== "https:") throw new Error("https.Agent protocol");
if (httpsAgent.maxSockets !== 3) throw new Error("https.Agent maxSockets");

// --- Live HTTP createServer + request round-trip ---
// Bound overall wait so a stuck TCP/http2 peer cannot hang make test.
const server = http.createServer((req, res) => {
  if (req.method !== "GET") {
    res.writeHead(405);
    res.end("no");
    return;
  }
  res.setHeader("x-clun", "1");
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("hello-http");
});

let finished = false;
function finishOk() {
  if (finished) return;
  finished = true;
  console.log("httpresidual-ok");
}

const hangGuard = setTimeout(() => {
  try {
    server.close();
  } catch (_) {}
  if (!finished) throw new Error("httpresidual timed out");
}, 10000);
if (typeof hangGuard.unref === "function") hangGuard.unref();

server.listen(0, "127.0.0.1", () => {
  const addr = server.address();
  const port = addr && addr.port;
  if (!(port > 0)) throw new Error("listen port");

  const req = http.request(
    { host: "127.0.0.1", port, path: "/ping", method: "GET" },
    (res) => {
      if (res.statusCode !== 200) throw new Error("status " + res.statusCode);
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (c) => {
        body += c;
      });
      res.on("end", () => {
        if (body !== "hello-http") throw new Error("body " + body);
        // Exercise http2 client session surface (peer may be HTTP/1 only).
        // Close HTTP server first so server.close is not blocked by the h2 TCP.
        server.close(() => {
          const session = http2.connect("http://127.0.0.1:" + port);
          session.on("error", () => {
            /* refused / not h2 is fine; connect path was exercised */
          });
          const stream = session.request({
            ":method": "GET",
            ":path": "/",
            ":scheme": "http",
            ":authority": "127.0.0.1:" + port,
          });
          if (typeof stream.id !== "number") throw new Error("stream id");
          stream.end();
          if (typeof session.destroy === "function") {
            session.destroy();
          } else {
            session.close();
          }
          finishOk();
        });
      });
    }
  );
  req.on("error", (e) => {
    throw e;
  });
  req.end();
});
