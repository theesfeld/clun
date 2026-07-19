// Issue #185 — cloud.s3 full port fixture.
// Pure-CL AWS SigV4 S3 client: Clun.s3 / Clun.S3Client surface.

const s3 = Clun.s3;
const S3Client = Clun.S3Client;

function keysOf(obj) {
  return Object.keys(obj).sort().join(",");
}

console.log(
  typeof s3,
  typeof S3Client,
  typeof s3.file,
  typeof s3.write,
  typeof s3.delete,
  typeof s3.list,
  typeof s3.exists,
  typeof s3.size,
  typeof s3.stat,
  typeof s3.presign,
  typeof s3.copy,
  typeof s3.deleteObjects,
  s3.backend,
);

const client = new S3Client({
  accessKeyId: "AKIA_TEST",
  secretAccessKey: "secret_test",
  bucket: "demo",
  region: "us-east-1",
  endpoint: "http://127.0.0.1:9000",
  pathStyle: true,
});

console.log(
  typeof client,
  typeof client.file,
  typeof client.write,
  typeof client.delete,
  typeof client.list,
  typeof client.presign,
  client.backend,
);

const url = client.presign("hello.txt", { expiresIn: 60, method: "GET" });
console.log(
  typeof url,
  url.indexOf("X-Amz-Algorithm=") >= 0,
  url.indexOf("X-Amz-Signature=") >= 0,
  url.indexOf("hello.txt") >= 0,
);

const file = client.file("path/to/obj.bin");
console.log(
  typeof file,
  file.name,
  typeof file.text,
  typeof file.write,
  typeof file.delete,
  typeof file.exists,
  typeof file.stat,
  typeof file.presign,
);

try {
  client.file(1);
  console.log("file-type-error", "missing");
} catch (e) {
  console.log("file-type-error", e && e.name, e && e.code);
}

console.log("ok");
