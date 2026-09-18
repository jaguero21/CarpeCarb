const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const { VerificationException } = require("@apple/app-store-server-library");
const {
  PREMIUM_PRODUCT_IDS,
  peekEnvironment,
  isActiveTransaction,
  createAppStore,
} = require("../src/appStore");

const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
const fakeJws = (payload) => `${b64url({ alg: "ES256" })}.${b64url(payload)}.sig`;

const appStore = createAppStore({
  rootCerts: [fs.readFileSync(path.join(__dirname, "..", "certs", "AppleRootCA-G3.cer"))],
  bundleId: "com.jamesaguero.mycarbtracker",
  appAppleId: 1234567890,
  signingKey: "unused-in-these-tests",
  keyId: "unused",
  issuerId: "unused",
});

test("premium product IDs match the app", () => {
  assert.deepEqual([...PREMIUM_PRODUCT_IDS].sort(), ["premium_monthlysub", "premium_yearly"]);
});

test("peekEnvironment reads Production and Sandbox", () => {
  assert.equal(peekEnvironment(fakeJws({ environment: "Production" })), "Production");
  assert.equal(peekEnvironment(fakeJws({ environment: "Sandbox" })), "Sandbox");
});

test("peekEnvironment rejects malformed input and other environments", () => {
  assert.throws(() => peekEnvironment("not-a-jws"), /Malformed JWS/);
  assert.throws(() => peekEnvironment("a.%%%.c"), /Malformed JWS payload/);
  assert.throws(() => peekEnvironment(fakeJws({ environment: "Xcode" })), /Unsupported environment/);
  assert.throws(() => peekEnvironment(fakeJws({})), /Unsupported environment/);
});

test("isActiveTransaction requires a premium product, future expiry, and no revocation", () => {
  const now = Date.parse("2026-09-18T12:00:00Z");
  const active = { productId: "premium_yearly", expiresDate: now + 1000 };
  assert.equal(isActiveTransaction(active, now), true);
  assert.equal(isActiveTransaction({ ...active, productId: "other_app_premium" }, now), false);
  assert.equal(isActiveTransaction({ ...active, expiresDate: now }, now), false);
  assert.equal(isActiveTransaction({ ...active, expiresDate: undefined }, now), false);
  assert.equal(isActiveTransaction({ ...active, revocationDate: now - 1 }, now), false);
});

// Regression for review finding #3: the old verifier trusted any chain whose
// root subject contained "CN=Apple Root CA". This fixture is signed by a
// self-made chain with exactly that subject (see scripts/make-forged-jws.js).
test("verifyTransaction rejects a JWS signed by a forged 'Apple Root CA - G3' chain", async () => {
  const forged = fs.readFileSync(path.join(__dirname, "fixtures", "forged-jws.txt"), "utf8").trim();
  await assert.rejects(appStore.verifyTransaction(forged), VerificationException);
});

test("verifyTransaction rejects garbage before touching the verifier", async () => {
  await assert.rejects(appStore.verifyTransaction("garbage"), /Malformed JWS/);
});

test("fetchSubscriptionStatus rejects unsupported environments", async () => {
  await assert.rejects(appStore.fetchSubscriptionStatus("1000", "Xcode"), /Unsupported environment/);
});
