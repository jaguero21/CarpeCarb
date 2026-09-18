// Generates a StoreKit-2-shaped JWS signed by a self-made certificate chain
// whose root claims the subject "CN=Apple Root CA - G3". Used as a regression
// fixture: a correct verifier must reject it (review finding #3).
// Usage: node scripts/make-forged-jws.js > test/fixtures/forged-jws.txt
"use strict";
const { execFileSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "forged-jws-"));
const ossl = (...args) => execFileSync("openssl", args, { cwd: dir, stdio: "pipe" });

for (const name of ["root", "int", "leaf"]) {
  ossl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", `${name}.key`);
}
ossl("req", "-new", "-x509", "-key", "root.key", "-days", "3650", "-out", "root.pem",
  "-subj", "/CN=Apple Root CA - G3/OU=Apple Certification Authority/O=Apple Inc./C=US");
ossl("req", "-new", "-key", "int.key", "-out", "int.csr",
  "-subj", "/CN=Apple Worldwide Developer Relations Certification Authority/OU=G6/O=Apple Inc./C=US");
fs.writeFileSync(path.join(dir, "ca.ext"), "basicConstraints=critical,CA:true\n");
ossl("x509", "-req", "-in", "int.csr", "-CA", "root.pem", "-CAkey", "root.key",
  "-CAcreateserial", "-days", "3650", "-extfile", "ca.ext", "-out", "int.pem");
ossl("req", "-new", "-key", "leaf.key", "-out", "leaf.csr",
  "-subj", "/CN=Prod ECC Mac App Store and iTunes Store Receipt Signing/OU=Apple Worldwide Developer Relations/O=Apple Inc./C=US");
ossl("x509", "-req", "-in", "leaf.csr", "-CA", "int.pem", "-CAkey", "int.key",
  "-CAcreateserial", "-days", "3650", "-out", "leaf.pem");

const der = (name) => new crypto.X509Certificate(fs.readFileSync(path.join(dir, `${name}.pem`))).raw.toString("base64");
const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");

const now = Date.now();
const header = { alg: "ES256", x5c: [der("leaf"), der("int"), der("root")] };
const payload = {
  transactionId: "2000000999999999",
  originalTransactionId: "2000000999999999",
  bundleId: "com.jamesaguero.mycarbtracker",
  productId: "premium_yearly",
  purchaseDate: now,
  expiresDate: now + 10 * 365 * 24 * 3600 * 1000,
  type: "Auto-Renewable Subscription",
  inAppOwnershipType: "PURCHASED",
  signedDate: now,
  environment: "Production",
};
const signingInput = `${b64url(header)}.${b64url(payload)}`;
const signature = crypto.sign("sha256", Buffer.from(signingInput), {
  key: fs.readFileSync(path.join(dir, "leaf.key")),
  dsaEncoding: "ieee-p1363",
}).toString("base64url");
fs.rmSync(dir, { recursive: true, force: true });
process.stdout.write(`${signingInput}.${signature}\n`);
