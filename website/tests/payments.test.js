import test from "node:test";
import assert from "node:assert/strict";
import {
  DOWNLOAD_URL,
  DOWNLOADS,
  MAX_AMOUNT_CENTS,
  parseAmount,
  createPaymentIntent,
} from "../src/payments.js";

test("US dollar input preserves cents without rounding fractional cents", () => {
  for (const [raw, cents] of [
    ["0", 0],
    ["0.00", 0],
    [" 2 ", 200],
    ["1.1", 110],
    [".01", 1],
    ["19.99", 1999],
    ["001.05", 105],
    ["1000.00", MAX_AMOUNT_CENTS],
  ]) {
    assert.deepEqual(parseAmount(raw), { ok: true, cents }, raw);
  }
});

test("ambiguous, signed, exponent, and non-decimal amounts are rejected", () => {
  for (const raw of [
    "", " ", "-1", "-0", "+1", "1e2", "0x10", "Infinity", "NaN",
    "$2", "1,000", "1,50", "1.001", "1.", ".", "2 3", "2\n3",
    "<script>", null, undefined, 1, NaN, Infinity, {}, [],
  ]) {
    const result = parseAmount(raw);
    assert.equal(result.ok, false, String(raw));
    assert.equal(typeof result.error, "string");
    assert.equal("cents" in result, false);
  }
});

test("the amount ceiling rejects overflow instead of silently capping a payment", () => {
  for (const raw of ["1000.01", "1001", "9999999999999999", "0".repeat(1000)]) {
    assert.equal(parseAmount(raw).ok, false, raw);
  }
});

test("a zero download immediately resolves to the fixed DMG release asset", () => {
  for (const raw of ["0", "0.0", "0.00", ".00"]) {
    assert.deepEqual(createPaymentIntent(raw), {
      ok: true,
      kind: "download",
      url: DOWNLOAD_URL,
    });
  }
  const url = new URL(DOWNLOAD_URL);
  assert.equal(url.origin, "https://github.com");
  assert.equal(url.pathname, "/soloiaros/snowy-mac/releases/latest/download/Snowy-macOS-arm64.dmg");
});

test("a support-only zero amount does not unexpectedly start a download", () => {
  assert.deepEqual(createPaymentIntent("0", "support"), {
    ok: true,
    kind: "no-contribution",
  });
});

test("zero-dollar Windows downloads use the pinned installer for the chosen architecture", () => {
  for (const architecture of ["x64", "arm64"]) {
    const context = `windows-${architecture}`;
    const url = new URL(DOWNLOADS[context]);
    assert.equal(url.origin, "https://github.com");
    assert.equal(url.pathname, `/soloiaros/snowy-mac/releases/download/windows-v0.1.4.0/Snowy-Setup-${architecture}.exe`);
    assert.deepEqual(createPaymentIntent("0", context), {
      ok: true,
      kind: "download",
      url: url.href,
    });
  }
});

test("positive amounts never pretend that checkout or payment has completed", () => {
  for (const context of [...Object.keys(DOWNLOADS), "support"]) {
    const intent = createPaymentIntent("2.50", context);
    assert.deepEqual(intent, {
      ok: true,
      kind: "checkout",
      amountCents: 250,
      currency: "usd",
      context,
    });
    assert.equal("url" in intent, false);
  }
  assert.equal(createPaymentIntent("-2", "download").ok, false);
  assert.equal(createPaymentIntent("1", "https://example.com").ok, false);
  assert.equal(createPaymentIntent("1", "constructor").ok, false);
  assert.equal(createPaymentIntent("1", ["windows-x64"]).ok, false);
});
