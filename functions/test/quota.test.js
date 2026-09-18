const test = require("node:test");
const assert = require("node:assert/strict");
const {
  FREE_DAILY_LOOKUP_LIMIT,
  parseTzOffset,
  dayKey,
  applyReservation,
  applyRelease,
  createQuotaStore,
} = require("../src/quota");
const { createFakeFirestore } = require("./helpers/fakeFirestore");

test("free limit is 4", () => {
  assert.equal(FREE_DAILY_LOOKUP_LIMIT, 4);
});

test("parseTzOffset accepts integers and clamps to ±14h", () => {
  assert.equal(parseTzOffset(-300), -300);
  assert.equal(parseTzOffset(2000), 840);
  assert.equal(parseTzOffset(-2000), -840);
});

test("parseTzOffset turns missing or non-integer values into UTC", () => {
  assert.equal(parseTzOffset(undefined), 0);
  assert.equal(parseTzOffset("-300"), 0);
  assert.equal(parseTzOffset(-300.5), 0);
  assert.equal(parseTzOffset(NaN), 0);
});

test("dayKey uses the caller's local calendar day", () => {
  const nowMs = Date.parse("2026-09-18T03:30:00Z"); // 22:30 on the 17th in UTC-5
  assert.equal(dayKey(nowMs, 0), "2026-09-18");
  assert.equal(dayKey(nowMs, -300), "2026-09-17");
  assert.equal(dayKey(nowMs, 330), "2026-09-18"); // UTC+5:30
});

test("dayKey rolls over exactly at local midnight", () => {
  const offset = -240; // UTC-4 (e.g. EDT)
  assert.equal(dayKey(Date.parse("2026-09-18T03:59:59Z"), offset), "2026-09-17");
  assert.equal(dayKey(Date.parse("2026-09-18T04:00:00Z"), offset), "2026-09-18");
});

test("dayKey follows a DST change through the reported offset", () => {
  const instant = Date.parse("2026-11-01T04:30:00Z");
  assert.equal(dayKey(instant, -240), "2026-11-01"); // EDT: 00:30
  assert.equal(dayKey(instant, -300), "2026-10-31"); // EST: 23:30
});

test("applyReservation starts a new day at one", () => {
  assert.deepEqual(applyReservation(null, "2026-09-18", 4), {
    allowed: true, used: 1, next: { dayKey: "2026-09-18", count: 1 },
  });
  assert.deepEqual(applyReservation({ dayKey: "2026-09-17", count: 4 }, "2026-09-18", 4), {
    allowed: true, used: 1, next: { dayKey: "2026-09-18", count: 1 },
  });
});

test("applyReservation counts up to the limit, then refuses", () => {
  assert.deepEqual(applyReservation({ dayKey: "2026-09-18", count: 3 }, "2026-09-18", 4), {
    allowed: true, used: 4, next: { dayKey: "2026-09-18", count: 4 },
  });
  assert.deepEqual(applyReservation({ dayKey: "2026-09-18", count: 4 }, "2026-09-18", 4), {
    allowed: false, used: 4, next: null,
  });
});

test("applyRelease only decrements the matching day", () => {
  assert.deepEqual(applyRelease({ dayKey: "2026-09-18", count: 2 }, "2026-09-18"), { dayKey: "2026-09-18", count: 1 });
  assert.equal(applyRelease({ dayKey: "2026-09-19", count: 2 }, "2026-09-18"), null);
  assert.equal(applyRelease({ dayKey: "2026-09-18", count: 0 }, "2026-09-18"), null);
  assert.equal(applyRelease(null, "2026-09-18"), null);
});

test("reserveLookup allows 4 per day and throws daily-quota on the 5th", async () => {
  const db = createFakeFirestore();
  const store = createQuotaStore({ db, now: () => Date.parse("2026-09-18T15:00:00Z") });

  for (let i = 1; i <= 4; i++) {
    const r = await store.reserveLookup("u1", -300);
    assert.deepEqual(r, { dayKey: "2026-09-18", used: i, limit: 4 });
  }
  await assert.rejects(store.reserveLookup("u1", -300), (err) => {
    assert.equal(err.code, "resource-exhausted");
    assert.deepEqual(err.details, { reason: "daily-quota", used: 4, limit: 4 });
    return true;
  });
  assert.ok(db.docs.get("lookupQuota/u1").expiresAt instanceof Date);
});

test("releaseLookup gives a reserved lookup back", async () => {
  const db = createFakeFirestore();
  const store = createQuotaStore({ db, now: () => Date.parse("2026-09-18T15:00:00Z") });

  const r = await store.reserveLookup("u1", 0);
  await store.releaseLookup("u1", r.dayKey);
  assert.equal(db.docs.get("lookupQuota/u1").count, 0);
});
