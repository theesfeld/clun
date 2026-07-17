const url = new URL("/items?limit=2", "https://example.com/base/");
const headers = new Headers();
headers.set("x-clun-evidence", "present");
const response = new Response("web-body", { status: 201, headers });

console.log(url.href);
console.log(response.status);
console.log(response.headers.get("x-clun-evidence"));
console.log(typeof ReadableStream);
console.log(response.body != null && typeof response.body.getReader === "function");

const streamResponse = new Response("stream-chunk");
void streamResponse.body;
streamResponse.body
  .getReader()
  .read()
  .then((chunk) => {
    console.log(chunk.done === false);
    console.log(new TextDecoder().decode(chunk.value));
    console.log(streamResponse.bodyUsed === true);
  });

response.text().then((body) => console.log(body));
