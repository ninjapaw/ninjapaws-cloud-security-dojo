const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");

const app = require("../src/app.js");

function getJson(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, (res) => {
      let body = "";
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => {
        try {
          resolve({ statusCode: res.statusCode, json: JSON.parse(body) });
        } catch (error) {
          reject(new Error(`Invalid JSON from ${url}: ${body}`));
        }
      });
    });
    req.on("error", reject);
  });
}

test("vulnerable environment falls back to env status when runtime evidence is missing", async () => {
  const originalStatus = process.env.VULNERABILITY_STATUS;
  const originalPort = process.env.PORT;
  process.env.VULNERABILITY_STATUS = "vulnerable";
  process.env.PORT = "4311";

  const server = app.listen(4311);
  try {
    const result = await getJson("http://127.0.0.1:4311/api/status");
    assert.equal(result.statusCode, 200);
    assert.equal(result.json.vulnerability.status, "vulnerable");
    assert.equal(result.json.vulnerability.detected, true);
  } finally {
    await new Promise((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
    if (originalStatus === undefined) {
      delete process.env.VULNERABILITY_STATUS;
    } else {
      process.env.VULNERABILITY_STATUS = originalStatus;
    }
    if (originalPort === undefined) {
      delete process.env.PORT;
    } else {
      process.env.PORT = originalPort;
    }
  }
});
