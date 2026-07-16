const url = new URL("/items?limit=2", "https://example.com/base/");
const headers = new Headers();
headers.set("x-clun-evidence", "present");
const response = new Response("web-body", { status: 201, headers });

console.log(url.href);
console.log(response.status);
console.log(response.headers.get("x-clun-evidence"));
response.text().then((body) => console.log(body));
