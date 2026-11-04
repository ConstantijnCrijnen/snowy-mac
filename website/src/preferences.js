export const defaults = Object.freeze({
  intensity: "steady",
  tool: "glove",
  windX: 0.12,
  windY: 0,
});
const finite = (x, fallback) =>
  typeof x === "number" && Number.isFinite(x)
    ? Math.max(-1, Math.min(1, x))
    : fallback;
export function validatePreferences(value) {
  const v = value && typeof value === "object" ? value : {};
  return {
    intensity: ["light", "steady", "flurry"].includes(v.intensity)
      ? v.intensity
      : defaults.intensity,
    tool: ["glove", "shovel"].includes(v.tool) ? v.tool : defaults.tool,
    windX: finite(v.windX, defaults.windX),
    windY: finite(v.windY, defaults.windY),
  };
}
export function readPreferences(storage) {
  try {
    return validatePreferences(JSON.parse(storage.getItem("snowy-weather-v1")));
  } catch {
    return { ...defaults };
  }
}
export function savePreferences(storage, value) {
  try {
    storage.setItem(
      "snowy-weather-v1",
      JSON.stringify(validatePreferences(value)),
    );
    return true;
  } catch {
    return false;
  }
}
