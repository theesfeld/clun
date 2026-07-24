// #339 residual destubs: domain, dns servers, crypto fips flag, dgram broadcast, child kill.
const domain = require("domain");
const dns = require("dns");
const crypto = require("crypto");
const dgram = require("dgram");
const { spawnSync } = require("child_process");

const d = domain.create();
let saw = false;
d.on("error", () => { saw = true; });
d.run(() => { throw new Error("x"); });
if (!saw) throw new Error("domain.run did not catch");

dns.setServers(["9.9.9.9"]);
const servers = dns.getServers();
if (!servers.includes("9.9.9.9")) throw new Error("dns.setServers");

crypto.setFips(false);
if (crypto.getFips() !== 0) throw new Error("getFips must stay 0 (non-FIPS)");
if (crypto.setEngine("clun") !== true) throw new Error("setEngine");

const sock = dgram.createSocket("udp4");
sock.bind(0);
sock.setBroadcast(true);
sock.setTTL(4);
sock.close();

const r = spawnSync("/bin/echo", ["hi"], { encoding: "utf8" });
if (String(r.stdout).trim() !== "hi") throw new Error("spawnSync");
if (!(r.pid > 0)) throw new Error("spawnSync pid");

console.log("destub-residuals-ok");
