import test from "node:test";
import assert from "node:assert/strict";
import {
  defaults,
  readPreferences,
  savePreferences,
} from "../src/preferences.js";

test("preferences survive a reload through the same storage", () => {
  const values = new Map();
  const storage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };
  assert.equal(
    savePreferences(storage, {
      ...defaults,
      tool: "shovel",
      intensity: "flurry",
      windX: -0.8,
    }),
    true,
  );
  assert.deepEqual(readPreferences(storage), {
    ...defaults,
    tool: "shovel",
    intensity: "flurry",
    windX: -0.8,
  });
});
test("malformed and unavailable storage keep the desktop usable", () => {
  assert.deepEqual(readPreferences({ getItem: () => "{broken" }), defaults);
  assert.deepEqual(
    readPreferences({
      getItem: () => {
        throw Error("disabled");
      },
    }),
    defaults,
  );
  assert.equal(
    savePreferences(
      {
        setItem: () => {
          throw Error("full");
        },
      },
      defaults,
    ),
    false,
  );
  const invalid = readPreferences({
    getItem: () =>
      JSON.stringify({
        intensity: "<script>",
        tool: "eval",
        windX: 900,
        paused: "yes",
      }),
  });
  assert.equal(invalid.windX, 1);
  assert.equal(invalid.tool, "glove");
  assert.equal("paused" in invalid, false);
});
