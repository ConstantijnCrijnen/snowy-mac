import test from "node:test";
import assert from "node:assert/strict";
import { SnowEngine, FLOOR_ID } from "../src/snow-engine.js";

const body = (id, x, y, width = 200, height = 200, extra = {}) => ({
  id,
  x,
  y,
  width,
  height,
  radius: 12,
  ...extra,
});
const create = (obstacles = [], options = {}) => {
  const engine = new SnowEngine({
    width: 1000,
    height: 800,
    seed: 91,
    ...options,
  });
  engine.setObstacles(obstacles);
  engine.clear();
  engine.setIntensity(0);
  return engine;
};
const close = (actual, expected, message, tolerance = 0.01) =>
  assert.ok(
    Math.abs(actual - expected) <= tolerance,
    `${message}: expected ${expected}, got ${actual}`,
  );
const run = (engine, count = 120) => {
  for (let i = 0; i < count; i++) engine.step(1 / 30);
};
const seed = (engine, id, height = 6) => {
  const p = engine.profile(id);
  for (let i = 0; i < p.count; i++) {
    const x = i * p.spacing;
    p.heights[i] =
      x >= 20 && x <= p.body.width - 20 ? Math.min(height, p.capacity[i]) : 0;
  }
};

test("falling snow continues after profiles reach their limit", () => {
  const engine = create([
    body("window", 100, 200, 400),
    body("dock", 200, 720, 600, 70, { kind: "dock" }),
  ]);
  for (const p of engine.profiles.values())
    for (let i = 0; i < p.count; i++) p.heights[i] = p.capacity[i];
  engine.setIntensity(1);
  engine.step(1 / 30);
  const before = engine.flakes.map((p) => [p.x, p.y]);
  run(engine, 8);
  assert.equal(engine.flakes.length, 160);
  assert.ok(
    engine.flakes.some((p, i) => p.x !== before[i][0] || p.y !== before[i][1]),
  );
  assert.ok(Math.max(...engine.profile("window").heights) <= 18);
  assert.ok(Math.max(...engine.profile("dock").heights) <= 13);
  assert.ok(Math.max(...engine.profile(FLOOR_ID).heights) <= 28);
});

test("calm flakes drift gently and wrap only after reaching a screen edge", () => {
  const engine = create();
  engine.setIntensity(1);
  engine.flakes.push({
    x: 500,
    y: 100,
    radius: 1,
    opacity: 1,
    speed: 30,
    drift: 0,
    phase: 0,
  });
  engine.step(1 / 30);
  assert.ok(
    Math.abs(engine.flakes[0].x - 500) < 1,
    "an in-bounds flake must not receive a wrap offset",
  );
  assert.ok(engine.flakes[0].y > 100);
});

test("bottom Dock collects ambient and transported snow", () => {
  const engine = create([body("dock", 200, 720, 600, 70, { kind: "dock" })]);
  engine.setIntensity(1);
  run(engine, 90);
  assert.ok(engine.profile("dock").height(300) > 0.5);
  engine.setIntensity(0);
  const before = engine.stats.totalMass;
  close(engine.addLoose(30, 500, 690), 0, "field accepts Dock-bound snow");
  run(engine, 90);
  assert.ok(engine.profile("dock").area > 30);
  close(engine.stats.totalMass, before + 30, "transport preserves area", 0.1);
});

test("sky masks prevent snowfall below windows without banning pushed snow there", () => {
  const engine = create([body("window", 200, 200, 400, 300)]);
  engine.setIntensity(1);
  run(engine, 120);
  const floor = engine.profile(FLOOR_ID);
  close(floor.height(400), 0, "no direct deposition through a roof", 0.0001);
  assert.ok(floor.height(100) > 0);
  close(
    engine.deposit(FLOOR_ID, 400, 24),
    0,
    "manual snow may reach sheltered floor",
  );
  assert.ok(floor.height(400) > 0);
});

test("wind shadow affects incoming snowfall only and reversal preserves existing piles", () => {
  const engine = create([
    body("wall", 400, 100, 200, 500),
    body("lower", 100, 400, 800, 300),
  ]);
  engine.setWind(1, 0);
  engine.setIntensity(1);
  run(engine, 120);
  const p = engine.profile("lower");
  close(
    p.height(540),
    0,
    "direct snowfall stays suppressed in the shadow",
    0.0001,
  );
  assert.ok(p.height(280) > 0);
  close(
    engine.deposit("lower", 540, 30),
    0,
    "shadow remains physically accessible",
  );
  assert.ok(p.height(540) > 0);
  const heights = [...p.heights],
    before = engine.stats.totalMass;
  engine.setWind(-1, 0);
  assert.deepEqual([...p.heights], heights);
  close(engine.stats.totalMass, before, "wind change never evacuates material");
});

test("new windows erase only covered portions of an existing floor pile", () => {
  const engine = create();
  const floor = engine.profile(FLOOR_ID);
  floor.heights.fill(10);
  engine.setObstacles([body("new", 250, 780, 100, 60)]);
  assert.equal(floor.height(300), 0);
  close(floor.height(200), 10, "left portion remains");
  close(floor.height(400), 10, "right portion remains");
  engine.setObstacles([]);
  assert.equal(
    engine.profile(FLOOR_ID).height(300),
    0,
    "covered snow never resurfaces",
  );
});

test("carried snow stops at stationary window walls in both directions", () => {
  for (const right of [true, false]) {
    const wall = body("wall", 500, 200, 100, 400);
    const engine = create([body("carrier", right ? 100 : 700, 300), wall]);
    seed(engine, "carrier");
    const before = engine.stats.totalMass;
    engine.setObstacles([body("carrier", right ? 750 : 100, 300), wall]);
    assert.ok(
      Math.max(...engine.profile("carrier").heights) < 0.001,
      "cap detaches before crossing entire wall",
    );
    assert.ok(engine.stats.loose + engine.stats.pending > 0);
    for (const i of engine.field.active)
      assert.ok(
        right ? engine.field.point(i).x < 500 : engine.field.point(i).x > 600,
      );
    close(engine.stats.totalMass, before, "wall contact retains area", 0.1);
  }
});

test("uncontacted cap stays attached during translation", () => {
  const wall = body("wall", 600, 200, 100, 400);
  const engine = create([body("carrier", 100, 300), wall]);
  seed(engine, "carrier");
  const heights = [...engine.profile("carrier").heights];
  engine.setObstacles([body("carrier", 250, 300), wall]);
  assert.deepEqual([...engine.profile("carrier").heights], heights);
  assert.equal(engine.stats.loose, 0);
  assert.equal(engine.stats.pending, 0);
});

test("downward contact hands cap area to the receiving window", () => {
  const lower = body("lower", 100, 300, 500, 400);
  const engine = create([body("carrier", 200, 100), lower]);
  seed(engine, "carrier");
  const before = engine.stats.totalMass;
  engine.setObstacles([body("carrier", 200, 320), lower]);
  assert.ok(engine.profile("lower").area > before * 0.9);
  assert.ok(engine.profile("carrier").area < 0.01);
  close(engine.stats.totalMass, before, "handoff preserves area", 0.1);
});

test("an earlier side wall wins over a later lower window in diagonal movement", () => {
  const wall = body("wall", 500, 200, 100, 400),
    lower = body("lower", 0, 450, 1000, 300);
  const engine = create([body("carrier", 100, 100, 200, 150), wall, lower]);
  seed(engine, "carrier");
  const before = engine.stats.totalMass;
  engine.setObstacles([body("carrier", 750, 550, 200, 150), wall, lower]);
  assert.ok(engine.profile("carrier").area < 0.01);
  assert.ok(engine.profile("lower").area < 0.01);
  for (const i of engine.field.active) assert.ok(engine.field.point(i).x < 500);
  close(engine.stats.totalMass, before, "diagonal wall retains area", 0.1);
});

test("existing moving windows plough settled floor snow instead of erasing or hiding it", () => {
  const engine = create([body("window", 100, 700, 100, 100)]);
  const floor = engine.profile(FLOOR_ID);
  for (let i = 0; i < floor.count; i++)
    if (i * floor.spacing > 240 && i * floor.spacing < 350)
      floor.heights[i] = 8;
  const before = engine.stats.totalMass;
  engine.setObstacles([body("window", 260, 700, 100, 100)]);
  assert.ok(engine.profile(FLOOR_ID).height(300) < 0.1);
  close(engine.stats.totalMass, before, "moving boundary retains area", 0.1);
  assert.ok(engine.stats.loose + engine.stats.pending > 0);
});

test("dismissed supports release material into the existing field and it reaches floor", () => {
  const engine = create([body("window", 200, 200)]);
  close(engine.deposit("window", 100, 30), 0, "cap accepts mass");
  const before = engine.stats.totalMass;
  engine.setObstacles([]);
  assert.ok(engine.stats.loose > 0);
  close(engine.stats.totalMass, before, "dismissal retains area");
  run(engine, 160);
  assert.ok(engine.profile(FLOOR_ID).area > 29);
  close(engine.stats.totalMass, before, "falling material has no expiry", 0.1);
});

test("shovel clears the cursor area without turning mass into flying particles", () => {
  const engine = create([body("window", 100, 300, 600)]);
  seed(engine, "window");
  const before = engine.stats.totalMass;
  engine.setTool("shovel");
  engine.step(1 / 30, { x: 400, y: 297 });
  assert.ok(engine.profile("window").height(300) < 0.001);
  for (const i of engine.field.active) {
    const p = engine.field.point(i);
    assert.ok(Math.hypot(p.x - 400, p.y - 297) >= 36);
  }
  close(engine.stats.totalMass, before, "shovel retains area", 0.1);
  assert.equal(
    engine.flakes.length,
    0,
    "transported mass never becomes decorative flakes",
  );
});

test("stationary glove does not vacuum an existing pile", () => {
  const engine = create([body("window", 100, 300, 600)]);
  seed(engine, "window");
  const before = engine.stats.totalMass;
  engine.step(1 / 30, { x: 400, y: 297 });
  engine.step(1 / 30, { x: 400, y: 297 });
  close(
    engine.profile("window").height(300),
    6,
    "stationary glove leaves pile",
  );
  close(engine.stats.totalMass, before, "stationary glove retains area");
});

test("rounded geometry leaves its empty shoulder free and caps taper at edges", () => {
  const engine = create([body("window", 100, 200, 300, 200, { radius: 24 })]);
  const p = engine.profile("window");
  assert.equal(p.heights[0], 0);
  assert.equal(p.heights.at(-1), 0);
  assert.ok(p.base(0) > p.body.y + 23);
  close(
    engine.addLoose(9, 101, 201),
    0,
    "rounded empty corner is not a square collider",
  );
});

test("viewport changes and malformed external geometry keep allocations bounded", () => {
  const engine = create([], { mobile: true });
  engine.resize(16000, 16000);
  engine.setObstacles(
    Array.from({ length: 200 }, (_, id) => body(id, 20, 200, 500, 200)),
  );
  assert.ok(engine.field.mass.length <= 16384);
  assert.ok(engine.obstacles.length <= 24);
  assert.ok(engine.stats.profileSamples <= 1024);
  engine.setObstacles([body("bad", NaN, 1), body("huge", 0, 0, Infinity, 10)]);
  assert.equal(engine.obstacles.length, 0);
  engine.setWind(Infinity, NaN);
  assert.deepEqual(engine.wind, { x: 0, y: 0 });
  engine.step(Infinity);
  assert.ok(Number.isFinite(engine.stats.totalMass));
});

test("reduced motion removes decorative flakes while preserving functional material", () => {
  const engine = create([body("window", 100, 300, 600)], {
    reducedMotion: true,
  });
  seed(engine, "window");
  engine.setIntensity(1);
  engine.setTool("shovel");
  engine.step(1 / 30, { x: 400, y: 297 });
  assert.equal(engine.flakes.length, 0);
  assert.ok(engine.stats.loose + engine.stats.pending > 0);
});
