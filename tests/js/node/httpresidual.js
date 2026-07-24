// #339 residual destubs: node:http / https / tls / http2 real surfaces.
// Hang-safe: hard timeout + close HTTP server before h2 + process.exit on success.
const http = require("http");
const https = require("https");
const tls = require("tls");
const http2 = require("http2");

function assert(cond, msg) {
  if (!cond) throw new Error(msg || "assert");
}

// --- tls.createSecureContext stores and exposes options ---
const sc = tls.createSecureContext({
  minVersion: "TLSv1.2",
  maxVersion: "TLSv1.3",
  rejectUnauthorized: false,
  servername: "localhost",
});
assert(sc && sc.minVersion === "TLSv1.2", "secureContext minVersion");
assert(sc.maxVersion === "TLSv1.3", "secureContext maxVersion");
assert(sc.rejectUnauthorized === false, "secureContext rejectUnauthorized");
assert(sc.servername === "localhost", "secureContext servername");

// --- tls.checkServerIdentity (CN / SAN / wildcard) ---
const okId = tls.checkServerIdentity("example.com", {
  subject: { CN: "example.com" },
  subjectaltname: "DNS:example.com, DNS:www.example.com",
});
assert(okId === undefined, "checkServerIdentity should accept CN match");

const okWild = tls.checkServerIdentity("www.example.com", {
  subject: { CN: "*.example.com" },
  subjectaltname: "DNS:*.example.com",
});
assert(okWild === undefined, "checkServerIdentity wildcard single label");

const badMulti = tls.checkServerIdentity("a.b.example.com", {
  subject: { CN: "*.example.com" },
  subjectaltname: "DNS:*.example.com",
});
assert(badMulti && typeof badMulti.message === "string", "wildcard rejects multi-label");

const badId = tls.checkServerIdentity("evil.example", {
  subject: { CN: "example.com" },
  subjectaltname: "DNS:example.com",
});
assert(badId && typeof badId.message === "string", "checkServerIdentity should reject mismatch");

// --- constructors call-without-new ---
const sc2 = tls.SecureContext({ minVersion: "TLSv1.2" });
assert(sc2 && sc2.minVersion === "TLSv1.2", "SecureContext() without new");
const tlsSock = tls.TLSSocket();
assert(tlsSock && typeof tlsSock === "object", "TLSSocket() without new");

// --- tls.createSecurePair (legacy, exceeds Bun) ---
const pair = tls.createSecurePair(sc, false, false, true);
assert(pair.cleartext && pair.encrypted, "securePair sides");
assert(typeof pair.cleartext.write === "function", "securePair write");

// --- http2 settings pack/unpack ---
const settings = http2.getDefaultSettings();
assert(settings.headerTableSize === 4096, "default headerTableSize");
const packed = http2.getPackedSettings({
  headerTableSize: 4096,
  enablePush: true,
  maxFrameSize: 16384,
});
assert(packed && typeof packed.length === "number" && packed.length >= 6, "getPackedSettings length");
const unpacked = http2.getUnpackedSettings(packed);
assert(unpacked.headerTableSize === 4096, "unpacked headerTableSize");
assert(unpacked.maxFrameSize === 16384, "unpacked maxFrameSize");
assert(http2.constants.NGHTTP2_SETTINGS === 4, "constants.SETTINGS");

// --- Http2Session illegal constructor ---
let threw = false;
try {
  new http2.Http2Session();
} catch (e) {
  threw = true;
  assert(
    e && (e.name === "TypeError" || /constructor|Illegal/i.test(String(e.message || e))),
    "Http2Session TypeError"
  );
}
assert(threw, "Http2Session must throw");

// --- Http2ServerRequest / Response construct ---
const h2req = new http2.Http2ServerRequest(null, {
  ":method": "POST",
  ":path": "/x",
  ":scheme": "http",
  ":authority": "localhost",
});
assert(h2req.method === "POST", "Http2ServerRequest method");
assert(h2req.url === "/x", "Http2ServerRequest url");
assert(typeof h2req.setEncoding === "function", "Http2ServerRequest setEncoding");
h2req.setEncoding("utf8");

const h2res = new http2.Http2ServerResponse(null);
assert(h2res.statusCode === 200, "Http2ServerResponse statusCode");
h2res.setHeader("x-a", "1");
assert(h2res.getHeader("x-a") === "1", "Http2ServerResponse getHeader");
h2res.writeHead(201, { "content-type": "text/plain" });
assert(h2res.headersSent === true, "Http2ServerResponse headersSent");

// --- Agent constructors store options (with and without new) ---
const agent = new http.Agent({ keepAlive: true, maxSockets: 7 });
assert(agent.maxSockets === 7, "http.Agent maxSockets");
assert(agent.keepAlive === true, "http.Agent keepAlive");
agent.destroy();

const agent2 = http.Agent({ maxSockets: 4 });
assert(agent2 && agent2.maxSockets === 4, "http.Agent() without new");

const httpsAgent = new https.Agent({ maxSockets: 3 });
assert(httpsAgent.protocol === "https:", "https.Agent protocol");
assert(httpsAgent.maxSockets === 3, "https.Agent maxSockets");
const httpsAgent2 = https.Agent({ maxSockets: 2 });
assert(httpsAgent2 && httpsAgent2.maxSockets === 2, "https.Agent() without new");

// --- IncomingMessage / ServerResponse / ClientRequest constructors ---
const im = new http.IncomingMessage(null);
assert(typeof im.setEncoding === "function", "IncomingMessage setEncoding");
im.setEncoding("utf8");
assert(typeof im.pause === "function" && typeof im.resume === "function", "IncomingMessage pause/resume");
assert(im.isPaused() === false, "IncomingMessage isPaused false");
im.pause();
assert(im.isPaused() === true, "IncomingMessage isPaused true");
im.resume();

const sr = new http.ServerResponse(im);
assert(typeof sr.setHeader === "function", "ServerResponse setHeader");
sr.setHeader("X-Test", "yes");
assert(sr.getHeader("x-test") === "yes", "ServerResponse getHeader casefold");
assert(sr.hasHeader("x-test") === true, "ServerResponse hasHeader");
assert(sr.getHeaderNames().indexOf("x-test") >= 0, "ServerResponse getHeaderNames");
sr.write("part-a");
sr.write("part-b");
sr.end("part-c");
assert(sr.finished === true || sr.writableEnded === true, "ServerResponse ended");

// ClientRequest offline: header/write/abort surfaces without connecting.
const cr = http.request({ host: "127.0.0.1", port: 1, path: "/", method: "POST" });
cr.setHeader("x-clun-req", "1");
assert(cr.getHeader("x-clun-req") === "1", "ClientRequest setHeader/getHeader");
assert(cr.hasHeader("x-clun-req") === true, "ClientRequest hasHeader");
cr.setNoDelay(true);
cr.setSocketKeepAlive(true, 1000);
assert(cr.write("body-chunk") === true, "ClientRequest write buffers");
let aborted = false;
cr.on("abort", () => {
  aborted = true;
});
cr.abort();
assert(cr.aborted === true, "ClientRequest aborted");
assert(aborted === true, "ClientRequest abort event");

// --- Live HTTP createServer + request round-trip ---
// Bound overall wait so a stuck TCP/http2 peer cannot hang make test.
const server = http.createServer((req, res) => {
  if (req.method === "POST" && req.url === "/echo") {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (c) => {
      body += c;
    });
    req.on("end", () => {
      res.setHeader("x-clun", "1");
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.write("echo:");
      res.end(body);
    });
    return;
  }
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
  // Force exit: leftover TCP handles from h2 connect can keep the loop alive.
  process.exit(0);
}

const hangGuard = setTimeout(() => {
  try {
    server.close();
  } catch (_) {}
  if (!finished) {
    console.error("httpresidual timed out");
    process.exit(1);
  }
}, 8000);
if (typeof hangGuard.unref === "function") hangGuard.unref();

server.listen(0, "127.0.0.1", () => {
  const addr = server.address();
  const port = addr && addr.port;
  assert(port > 0, "listen port");

  const req = http.request(
    { host: "127.0.0.1", port, path: "/ping", method: "GET", timeout: 3000 },
    (res) => {
      assert(res.statusCode === 200, "status " + res.statusCode);
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (c) => {
        body += c;
      });
      res.on("end", () => {
        assert(body === "hello-http", "body " + body);

        // POST with write buffering on ClientRequest / ServerResponse.
        const post = http.request(
          { host: "127.0.0.1", port, path: "/echo", method: "POST", timeout: 3000 },
          (pres) => {
            let pbody = "";
            pres.setEncoding("utf8");
            pres.on("data", (c) => {
              pbody += c;
            });
            pres.on("end", () => {
              assert(pbody === "echo:payload", "post body " + pbody);

              // Close HTTP server first so server.close is not blocked by h2 TCP.
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
                assert(typeof stream.id === "number", "stream id");
                assert(stream.write("x") === true, "http2 stream write");
                stream.end();

                let pingCb = false;
                session.ping((err, duration, payload) => {
                  pingCb = true;
                  assert(err === null || err === undefined, "ping err");
                  assert(typeof duration === "number", "ping duration");
                  assert(payload && payload.length === 8, "ping payload");
                });

                setTimeout(() => {
                  assert(pingCb === true, "ping callback fired");
                  if (typeof session.goaway === "function") session.goaway(0);
                  if (typeof session.destroy === "function") {
                    session.destroy();
                  } else {
                    session.close();
                  }
                  finishOk();
                }, 50);
              });
            });
          }
        );
        post.on("error", (e) => {
          throw e;
        });
        post.setHeader("content-type", "text/plain");
        post.write("pay");
        post.end("load");
      });
    }
  );
  req.on("error", (e) => {
    throw e;
  });
  req.end();
});
