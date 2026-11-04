import test from "node:test";
import assert from "node:assert/strict";
import {
  clampWindowRect,
  reflowWindowRect,
  normalizeWind,
  parseCommand,
} from "../src/window-geometry.js";

test("window bounds keep controls reachable on narrow and malformed viewports", () => {
  for (const width of [1, 240, 320, 390, 1280]) {
    const bounds = { width, height: 800 };
    const rect = clampWindowRect(
      { x: -2000, y: Infinity, width: 3000, height: 900 },
      bounds,
    );
    assert.ok(rect.x >= 0 && rect.y >= 0);
    assert.ok(rect.x + rect.width <= width);
    assert.ok(rect.y + rect.height <= 800);
    assert.ok(Object.values(rect).every(Number.isFinite));
  }
});
test("reflow retains an accessible window when moving from wide desktop to phone", () => {
  const rect = reflowWindowRect(
    { x: 1000, y: 600, width: 400, height: 280 },
    { width: 1600, height: 1000 },
    { width: 390, height: 1250 },
  );
  assert.ok(rect.x >= 12 && rect.x + rect.width <= 378);
  assert.ok(rect.y >= 12 && rect.y + rect.height <= 1238);
});
test("wind is finite and bounded while diagonal snapping preserves strength", () => {
  const wind = normalizeWind(10, 10);
  assert.ok(Math.hypot(wind.x, wind.y) <= 1.000001);
  const snapped = normalizeWind(0.3, 0.11, true);
  assert.ok(Math.abs(snapped.y) < 0.00001);
  assert.ok(Math.abs(snapped.strength - Math.hypot(0.3, 0.11)) < 0.00001);
  assert.equal(normalizeWind(NaN, Infinity).strength, 0);
});
test("terminal parsing is an exact bounded command allowlist", () => {
  assert.equal(parseCommand("  SNOW  ").name, "snow");
  assert.equal(parseCommand(" snow ").known, true);
  for (const input of [
    "__proto__",
    "constructor",
    "<script>alert(1)</script>",
    'eval("x")',
    "github; rm -rf",
  ])
    assert.equal(parseCommand(input).known, false);
  assert.equal(parseCommand("a".repeat(400)).raw.length, 80);
});
