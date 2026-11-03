const finite = (value, fallback) => (Number.isFinite(value) ? value : fallback);
const clamp = (value, low, high) => Math.max(low, Math.min(high, value));

/** Keep every title bar and resize corner reachable, including on very narrow screens. */
export function clampWindowRect(rect, bounds, padding = 12) {
  const bw = Math.max(1, finite(bounds.width, 1)),
    bh = Math.max(1, finite(bounds.height, 1));
  const width = clamp(
    finite(rect.width, 300),
    Math.min(220, Math.max(1, bw - padding * 2)),
    Math.max(1, bw - padding * 2),
  );
  const height = clamp(
    finite(rect.height, 220),
    Math.min(130, Math.max(1, bh - padding * 2)),
    Math.max(1, bh - padding * 2),
  );
  const px = Math.min(padding, (bw - width) / 2),
    py = Math.min(padding, (bh - height) / 2);
  return {
    x: clamp(finite(rect.x, px), px, bw - width - px),
    y: clamp(finite(rect.y, py), py, bh - height - py),
    width,
    height,
  };
}

export function reflowWindowRect(rect, before, after) {
  const cx = (rect.x + rect.width / 2) / Math.max(1, before.width);
  const cy = (rect.y + rect.height / 2) / Math.max(1, before.height);
  return clampWindowRect(
    {
      ...rect,
      x: cx * after.width - rect.width / 2,
      y: cy * after.height - rect.height / 2,
    },
    after,
  );
}

/** Pointer and keyboard controls share a circular, finite wind range. */
export function normalizeWind(x, y, snap = false) {
  x = finite(x, 0);
  y = finite(y, 0);
  const distance = Math.hypot(x, y);
  let angle = Math.atan2(y, x);
  if (snap && distance > 0)
    angle = (Math.round(angle / (Math.PI / 4)) * Math.PI) / 4;
  const strength = Math.min(1, distance);
  return {
    x: Math.cos(angle) * strength,
    y: Math.sin(angle) * strength,
    strength,
    angle,
  };
}

export const terminalCommands = Object.freeze([
  "help",
  "clear",
  "snow",
  "calm",
  "about",
  "github",
  "defrost",
  "mariah",
]);
export function parseCommand(value) {
  const raw = typeof value === "string" ? value.slice(0, 80).trim() : "";
  const name = raw.toLowerCase().split(/\s+/)[0];
  return { raw, name, known: terminalCommands.includes(name) };
}
