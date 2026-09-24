const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const fs = require("node:fs");
const { once } = require("node:events");

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

async function withApp(action) {
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    return await action(`http://127.0.0.1:${server.address().port}`);
  } finally {
    await new Promise((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  }
}

test("vulnerable environment falls back to env status when runtime evidence is missing", async () => {
  const originalStatus = process.env.VULNERABILITY_STATUS;
  process.env.VULNERABILITY_STATUS = "vulnerable";
  try {
    await withApp(async (base) => {
      const result = await getJson(`${base}/api/status`);
      assert.equal(result.statusCode, 200);
      assert.equal(result.json.vulnerability.status, "vulnerable");
      assert.equal(result.json.vulnerability.detected, true);
    });
  } finally {
    if (originalStatus === undefined) {
      delete process.env.VULNERABILITY_STATUS;
    } else {
      process.env.VULNERABILITY_STATUS = originalStatus;
    }
  }
});

test("status fields use one runtime evidence snapshot per request", async (context) => {
  const originalRead = fs.readFileSync;
  let reads = 0;
  context.mock.method(fs, "readFileSync", function (file, ...options) {
    if (file !== "/run/ninja-paws-runtime.json")
      return originalRead.call(this, file, ...options);
    reads++;
    return JSON.stringify({
      vulnerability_detected: reads === 1,
      scenario_config_state: reads === 1 ? "vulnerable" : "remediated",
    });
  });
  await withApp(async (base) => {
    const result = await getJson(`${base}/api/status`);
    assert.equal(reads, 1);
    assert.equal(result.json.vulnerability.detected, true);
    assert.equal(result.json.runtime_verification.vulnerability_detected, true);
    const next = await getJson(`${base}/api/status`);
    assert.equal(reads, 2);
    assert.equal(next.json.vulnerability.status, "remediated");
    assert.equal(
      next.json.runtime_verification.scenario_config_state,
      "remediated",
    );
  });
});
