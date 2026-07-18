// Phase 51 Yes evidence: upgrade + echo + Pub/Sub + client WebSocket.
const clients = [];
const server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(req, server) {
    if (server.upgrade(req)) return;
    return new Response("upgrade-failed", { status: 500 });
  },
  websocket: {
    open(ws) {
      ws.subscribe("room");
      clients.push(ws);
    },
    message(ws, message) {
      if (typeof message === "string" && message.startsWith("pub:")) {
        server.publish("room", message.slice(4));
        return;
      }
      ws.send(message);
    },
    close(ws) {
      const i = clients.indexOf(ws);
      if (i >= 0) clients.splice(i, 1);
    },
  },
});
console.log(server.url);
