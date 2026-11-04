/**
 * Browser counterpart of SnowCore. Coordinates and mass are CSS points / square points.
 * Stable snow is a shallow height profile; swept snow is bounded cellular material.
 * Decorative flakes never own accumulated mass. There are no timers or DOM reads here.
 */
const EPSILON = 1e-6;
const FLOOR = "$floor";
const clamp = (n, low, high) => Math.max(low, Math.min(high, n));
const finite = (n, fallback = 0) => (Number.isFinite(n) ? n : fallback);
const lerp = (a, b, t) => a + (b - a) * t;
const smooth = (t) => t * t * (3 - 2 * t);

function contains(body, x, y, padding = 0) {
  const r = body.radius + padding;
  if (
    x < body.x - padding ||
    x > body.x + body.width + padding ||
    y < body.y - padding ||
    y > body.y + body.height + padding
  )
    return false;
  const cx = clamp(x, body.x + body.radius, body.x + body.width - body.radius);
  const cy = clamp(y, body.y + body.radius, body.y + body.height - body.radius);
  return (x - cx) ** 2 + (y - cy) ** 2 <= r * r;
}

function verticalSpan(body, x) {
  if (x < body.x || x > body.x + body.width) return null;
  const edge = Math.min(x - body.x, body.x + body.width - x);
  const r = body.radius;
  const inset =
    edge < r ? r - Math.sqrt(Math.max(0, r * r - (r - edge) ** 2)) : 0;
  return [body.y + inset, body.y + body.height - inset];
}

function rayBody(start, end, body, radius = 0) {
  const x0 = body.x,
    y0 = body.y,
    x1 = x0 + body.width,
    y1 = y0 + body.height;
  const r = body.radius;
  const dx = end.x - start.x,
    dy = end.y - start.y;
  if (contains(body, start.x, start.y, radius - 0.001)) {
    const distances = [
      Math.abs(start.x - x0 + radius),
      Math.abs(x1 + radius - start.x),
      Math.abs(start.y - y0 + radius),
      Math.abs(y1 + radius - start.y),
    ];
    const face = distances.indexOf(Math.min(...distances));
    const normal = [
      [-1, 0],
      [1, 0],
      [0, -1],
      [0, 1],
    ][face];
    return {
      time: 0,
      x: start.x + normal[0] * distances[face],
      y: start.y + normal[1] * distances[face],
      nx: normal[0],
      ny: normal[1],
    };
  }
  let hit = null;
  const consider = (time, x, y, nx, ny) => {
    if (time >= 0 && time <= 1 && (!hit || time < hit.time))
      hit = { time, x, y, nx, ny };
  };
  for (let face = 0; face < 4; face++) {
    const horizontal = face < 2;
    const negative = face % 2 === 0;
    const delta = horizontal ? dx : dy;
    const sign = negative ? -1 : 1;
    if (delta * sign >= -EPSILON) continue;
    const coordinate = horizontal
      ? negative
        ? x0 - radius
        : x1 + radius
      : negative
        ? y0 - radius
        : y1 + radius;
    const time = (coordinate - (horizontal ? start.x : start.y)) / delta;
    const other = horizontal ? start.y + dy * time : start.x + dx * time;
    const low = horizontal ? y0 + r : x0 + r;
    const high = horizontal ? y1 - r : x1 - r;
    if (other >= low && other <= high)
      consider(
        time,
        start.x + dx * time,
        start.y + dy * time,
        horizontal ? sign : 0,
        horizontal ? 0 : sign,
      );
  }
  const a = dx * dx + dy * dy;
  if (r > 0 && a > EPSILON)
    for (let q = 0; q < 4; q++) {
      const sx = q % 2 === 0 ? -1 : 1,
        sy = q < 2 ? -1 : 1;
      const cx = sx < 0 ? x0 + r : x1 - r,
        cy = sy < 0 ? y0 + r : y1 - r;
      const ox = start.x - cx,
        oy = start.y - cy;
      const b = 2 * (ox * dx + oy * dy),
        c = ox * ox + oy * oy - (r + radius) ** 2;
      const discriminant = b * b - 4 * a * c;
      if (discriminant < 0) continue;
      const time = (-b - Math.sqrt(discriminant)) / (2 * a);
      const x = start.x + dx * time,
        y = start.y + dy * time;
      if ((x - cx) * sx >= 0 && (y - cy) * sy >= 0)
        consider(time, x, y, (x - cx) / (r + radius), (y - cy) / (r + radius));
    }
  return hit;
}

function contact(start, end, old, next, radius) {
  const dx = next.x - old.x,
    dy = next.y - old.y;
  if (
    Math.abs(next.width - old.width) < 0.001 &&
    Math.abs(next.height - old.height) < 0.001
  ) {
    const hit = rayBody(start, { x: end.x - dx, y: end.y - dy }, old, radius);
    return (
      hit && {
        ...hit,
        x: hit.x + dx + hit.nx * 0.05,
        y: hit.y + dy + hit.ny * 0.05,
        body: next,
      }
    );
  }
  // Bounded changing-face interval, then rounded-entry refinement for a resize.
  const travelX = end.x - start.x,
    travelY = end.y - start.y;
  const nextRelative = { ...next, x: next.x - travelX, y: next.y - travelY };
  const before = [
    old.x - radius,
    old.x + old.width + radius,
    old.y - radius,
    old.y + old.height + radius,
  ];
  const after = [
    nextRelative.x - radius,
    nextRelative.x + nextRelative.width + radius,
    nextRelative.y - radius,
    nextRelative.y + nextRelative.height + radius,
  ];
  let enter = 0,
    exit = 1,
    normal = [0, 0];
  for (let face = 0; face < 4; face++) {
    const lower = face % 2 === 0,
      point = face < 2 ? start.x : start.y;
    const a = lower ? after[face] - before[face] : before[face] - after[face];
    const b = lower ? point - before[face] : before[face] - point;
    if (Math.abs(a) < EPSILON) {
      if (b < 0) return null;
    } else if (a < 0) {
      const t = b / a;
      if (t >= enter) {
        enter = t;
        normal = [
          [-1, 0],
          [1, 0],
          [0, -1],
          [0, 1],
        ][face];
      }
    } else exit = Math.min(exit, b / a);
  }
  if (enter > exit || exit < 0 || enter > 1) return null;
  const oldInside = contains(old, start.x, start.y, radius);
  if (oldInside && !contains(nextRelative, start.x, start.y, radius))
    return null;
  let low = clamp(enter, 0, 1),
    high = null;
  const interpolate = (t) => ({
    ...old,
    x: lerp(old.x, nextRelative.x, t),
    y: lerp(old.y, nextRelative.y, t),
    width: lerp(old.width, nextRelative.width, t),
    height: lerp(old.height, nextRelative.height, t),
    radius: lerp(old.radius, nextRelative.radius, t),
  });
  for (let sample = 0; sample <= 8; sample++) {
    const t = lerp(clamp(enter, 0, 1), clamp(exit, 0, 1), sample / 8);
    if (contains(interpolate(t), start.x, start.y, radius)) {
      high = t;
      break;
    }
    low = t;
  }
  if (high === null) return null;
  for (let i = 0; i < 8; i++) {
    const mid = (low + high) / 2;
    if (contains(interpolate(mid), start.x, start.y, radius)) high = mid;
    else low = mid;
  }
  if (!normal[0] && !normal[1]) {
    const distances = [
      Math.abs(start.x - after[0]),
      Math.abs(start.x - after[1]),
      Math.abs(start.y - after[2]),
      Math.abs(start.y - after[3]),
    ];
    normal = [
      [-1, 0],
      [1, 0],
      [0, -1],
      [0, 1],
    ][distances.indexOf(Math.min(...distances))];
  }
  const x = start.x + travelX * high,
    y = start.y + travelY * high;
  return {
    time: high,
    ...outside(next, { x, y }, normal[0], normal[1], radius),
    nx: normal[0],
    ny: normal[1],
    body: next,
  };
}

function outside(body, point, nx, ny, padding) {
  const r = body.radius,
    expanded = r + padding;
  let { x, y } = point;
  if (Math.abs(nx) >= Math.abs(ny)) {
    const cy = clamp(y, body.y + r, body.y + body.height - r);
    const arc = Math.sqrt(Math.max(0, expanded * expanded - (y - cy) ** 2));
    x = nx < 0 ? body.x + r - arc - 0.05 : body.x + body.width - r + arc + 0.05;
  } else {
    const cx = clamp(x, body.x + r, body.x + body.width - r);
    const arc = Math.sqrt(Math.max(0, expanded * expanded - (x - cx) ** 2));
    y =
      ny < 0 ? body.y + r - arc - 0.05 : body.y + body.height - r + arc + 0.05;
  }
  return { x, y };
}

class Profile {
  constructor(body, count, phase) {
    this.body = body;
    this.count = count;
    this.spacing = body.width / (count - 1);
    this.heights = new Float64Array(count);
    this.capacity = new Float64Array(count);
    this.snowCapacity = new Float64Array(count);
    this.deposition = new Float64Array(count);
    this.exposed = new Uint8Array(count);
    this.sky = new Uint8Array(count);
    this.shadow = new Uint8Array(count);
    this.lobe = new Float64Array(count);
    const limit = body.id === FLOOR ? 28 : body.kind === "dock" ? 13 : 18;
    for (let i = 0; i < count; i++) {
      const x = i * this.spacing;
      const taper =
        body.id === FLOOR
          ? 1
          : smooth(Math.min(1, Math.min(x, body.width - x) / 13));
      const lobe =
        0.68 +
        Math.sin(x * 0.027 + phase) * 0.18 +
        Math.sin(x * 0.071 + phase * 2) * 0.09 +
        Math.sin(x * 0.13 + phase) * 0.05;
      this.capacity[i] = limit * taper;
      this.lobe[i] = lobe;
      this.snowCapacity[i] = this.capacity[i] * lobe;
      this.deposition[i] = (0.18 + lobe * 0.17) * taper;
    }
  }
  base(local) {
    const b = this.body,
      edge = Math.max(0, Math.min(local, b.width - local)),
      r = b.radius;
    return (
      b.y + (edge < r ? r - Math.sqrt(Math.max(0, r * r - (r - edge) ** 2)) : 0)
    );
  }
  height(local) {
    if (local < 0 || local > this.body.width) return 0;
    const coordinate = local / this.spacing,
      i = Math.min(this.count - 2, Math.floor(coordinate));
    return lerp(this.heights[i], this.heights[i + 1], coordinate - i);
  }
  visible(local) {
    return (
      local >= 0 &&
      local <= this.body.width &&
      !!this.exposed[clamp(Math.round(local / this.spacing), 0, this.count - 1)]
    );
  }
  get area() {
    let sum = 0;
    for (const height of this.heights) sum += height * this.spacing;
    return sum;
  }
  deposit(local, amount, snowfall = false, direction = 0) {
    if (local < 0 || local > this.body.width || amount <= 0) return amount;
    const center = clamp(
      direction > 0
        ? Math.ceil(local / this.spacing)
        : direction < 0
          ? Math.floor(local / this.spacing)
          : Math.round(local / this.spacing),
      0,
      this.count - 1,
    );
    if (snowfall && (!this.sky[center] || this.shadow[center])) return amount;
    for (let distance = 0; distance <= 24 && amount > EPSILON; distance++) {
      for (let side = 0; side < (distance === 0 || direction ? 1 : 2); side++) {
        const i =
          center + (direction < 0 ? -distance : side ? -distance : distance);
        if (
          i < 0 ||
          i >= this.count ||
          !this.exposed[i] ||
          (snowfall && (!this.sky[i] || this.shadow[i]))
        )
          continue;
        const limit = snowfall ? this.snowCapacity[i] : this.capacity[i];
        const accepted = Math.min(
          amount,
          Math.max(0, limit - this.heights[i]) * this.spacing,
        );
        this.heights[i] += accepted / this.spacing;
        amount -= accepted;
      }
    }
    return amount < EPSILON ? 0 : amount;
  }
  settle() {
    for (let i = 0; i < this.count - 1; i++) {
      if (!this.exposed[i] || !this.exposed[i + 1]) continue;
      const from = this.heights[i] > this.heights[i + 1] ? i : i + 1,
        to = from === i ? i + 1 : i;
      const amount = Math.min(
        Math.abs(this.heights[i] - this.heights[i + 1]) * 0.12,
        this.heights[from],
        Math.max(0, this.capacity[to] - this.heights[to]),
      );
      this.heights[from] -= amount;
      this.heights[to] += amount;
    }
  }
}

class MaterialField {
  constructor(width, height, mobile) {
    this.width = width;
    this.height = height;
    const budget = mobile ? 16384 : 32768;
    let pitch = Math.max(3, Math.sqrt((width * height) / budget));
    while (Math.ceil(width / pitch) * Math.ceil(height / pitch) > budget)
      pitch *= 1.005;
    this.pitch = pitch;
    this.columns = Math.ceil(width / pitch);
    this.rows = Math.ceil(height / pitch);
    this.maximumActive = mobile ? 2500 : 6000;
    const length = this.columns * this.rows;
    this.mass = new Float64Array(length);
    this.output = new Float64Array(length);
    this.incoming = new Float64Array(length);
    this.solid = new Uint8Array(length);
    this.slots = new Int32Array(length).fill(-1);
    this.marks = new Uint32Array(length);
    this.difference = new Int16Array(this.rows * (this.columns + 1));
    this.queue = new Int32Array(Math.min(length, 768));
    this.active = [];
    this.next = [];
    this.visits = 32768;
    this.generation = 0;
    this.tick = 0;
  }
  begin() {
    this.visits = 32768;
  }
  index(x, y) {
    return x >= 0 && x < this.width && y >= 0 && y < this.height
      ? Math.min(this.rows - 1, Math.floor(y / this.pitch)) * this.columns +
          Math.min(this.columns - 1, Math.floor(x / this.pitch))
      : -1;
  }
  point(index) {
    const x = (index % this.columns) * this.pitch,
      y = Math.floor(index / this.columns) * this.pitch;
    return {
      x: (x + Math.min(this.width, x + this.pitch)) / 2,
      y: (y + Math.min(this.height, y + this.pitch)) / 2,
    };
  }
  capacity(index) {
    return (
      Math.min(this.pitch, this.width - (index % this.columns) * this.pitch) *
      Math.min(
        this.pitch,
        this.height - Math.floor(index / this.columns) * this.pitch,
      )
    );
  }
  get area() {
    let area = 0;
    for (const i of this.active) area += this.mass[i];
    return area;
  }
  remove(index) {
    const slot = this.slots[index];
    if (slot < 0) return;
    const last = this.active.pop();
    if (slot < this.active.length) {
      this.active[slot] = last;
      this.slots[last] = slot;
    }
    this.slots[index] = -1;
    this.mass[index] = 0;
  }
  clear() {
    for (const i of this.active) {
      this.mass[i] = 0;
      this.slots[i] = -1;
    }
    this.active.length = 0;
  }
  raster(bodies) {
    this.difference.fill(0);
    const stride = this.columns + 1;
    for (const body of bodies) {
      const first = Math.max(0, Math.ceil(body.y / this.pitch - 0.5));
      const last = Math.min(
        this.rows - 1,
        Math.floor((body.y + body.height) / this.pitch - 0.5),
      );
      for (let row = first; row <= last; row++) {
        const y = this.point(row * this.columns).y;
        const edge = Math.min(y - body.y, body.y + body.height - y),
          r = body.radius;
        const inset =
          edge < r ? r - Math.sqrt(Math.max(0, r * r - (r - edge) ** 2)) : 0;
        const left = Math.max(
          0,
          Math.ceil((body.x + inset) / this.pitch - 0.5),
        );
        const right = Math.min(
          this.columns - 1,
          Math.floor((body.x + body.width - inset) / this.pitch - 0.5),
        );
        if (left <= right) {
          this.difference[row * stride + left]++;
          this.difference[row * stride + right + 1]--;
        }
      }
    }
    for (let row = 0; row < this.rows; row++) {
      let coverage = 0;
      for (let col = 0; col < this.columns; col++) {
        coverage += this.difference[row * stride + col];
        this.solid[row * this.columns + col] = coverage > 0 ? 1 : 0;
      }
    }
  }
  add(amount, x, y, dx = 0, dy = -1, exclusion = null) {
    x = clamp(
      x,
      Math.min(this.pitch / 2, this.width / 2),
      this.width - Math.min(this.pitch / 2, this.width / 2),
    );
    y = clamp(
      y,
      Math.min(this.pitch / 2, this.height / 2),
      this.height - Math.min(this.pitch / 2, this.height / 2),
    );
    const origin = this.index(x, y);
    if (origin < 0 || this.solid[origin] || amount <= EPSILON) return amount;
    this.generation = (this.generation + 1) >>> 0;
    if (!this.generation) {
      this.marks.fill(0);
      this.generation = 1;
    }
    let head = 0,
      tail = 1;
    this.queue[0] = origin;
    this.marks[origin] = this.generation;
    const horizontal = Math.abs(dx) >= Math.abs(dy);
    const primaryX = horizontal ? Math.sign(dx) || 1 : 0,
      primaryY = horizontal ? 0 : Math.sign(dy) || -1;
    while (head < tail && this.visits-- > 0 && amount > EPSILON) {
      const index = this.queue[head++],
        point = this.point(index);
      const outside =
        !exclusion ||
        Math.hypot(point.x - exclusion.x, point.y - exclusion.y) >=
          exclusion.radius + this.pitch * 0.55;
      if (outside) {
        const available = this.capacity(index) - this.mass[index],
          accepted = Math.min(amount, Math.max(0, available));
        if (
          accepted > EPSILON &&
          (this.slots[index] >= 0 || this.active.length < this.maximumActive)
        ) {
          if (this.slots[index] < 0) {
            this.slots[index] = this.active.length;
            this.active.push(index);
          }
          this.mass[index] += accepted;
          amount -= accepted;
        }
      }
      const col = index % this.columns,
        row = Math.floor(index / this.columns);
      const neighbors = [
        [primaryX, primaryY],
        [horizontal ? 0 : 1, horizontal ? -1 : 0],
        [horizontal ? 0 : -1, horizontal ? 1 : 0],
        [-primaryX, -primaryY],
      ];
      for (const [ox, oy] of neighbors) {
        const cx = col + ox,
          cy = row + oy,
          next = cy * this.columns + cx;
        if (
          cx < 0 ||
          cx >= this.columns ||
          cy < 0 ||
          cy >= this.rows ||
          this.solid[next] ||
          this.marks[next] === this.generation ||
          tail >= this.queue.length
        )
          continue;
        this.marks[next] = this.generation;
        this.queue[tail++] = next;
      }
    }
    return amount < EPSILON ? 0 : amount;
  }
  step(windSide, land) {
    this.output.fill(0);
    this.incoming.fill(0);
    this.next.length = 0;
    const write = (index, amount) => {
      if (this.output[index] <= EPSILON) this.next.push(index);
      this.output[index] += amount;
    };
    for (let offset = 0; offset < this.active.length; offset++) {
      const index = this.active[offset],
        start = this.point(index),
        column = index % this.columns;
      const row = Math.floor(index / this.columns),
        side = windSide || ((column + this.tick) % 2 ? 1 : -1);
      let amount = this.mass[index];
      const choices = windSide ? [side, 0, -side] : [0, side, -side];
      for (const dx of choices) {
        if (amount <= EPSILON) break;
        const col = column + dx;
        if (col < 0 || col >= this.columns) continue;
        if (
          dx &&
          (this.solid[row * this.columns + col] ||
            this.mass[row * this.columns + col] >
              this.capacity(row * this.columns + col) * 0.9)
        )
          continue;
        const target =
          row + 1 < this.rows ? (row + 1) * this.columns + col : -1;
        const end =
          target < 0
            ? { x: start.x + dx * this.pitch, y: this.height + this.pitch }
            : this.point(target);
        const contact = land(start, end, amount);
        amount = contact.remaining;
        if (
          amount <= EPSILON ||
          contact.blocked ||
          target < 0 ||
          this.solid[target]
        )
          continue;
        const room =
          this.capacity(target) - this.mass[target] - this.incoming[target];
        const moved = Math.min(amount, Math.max(0, room));
        const unprocessed = this.active.length - offset - 1;
        if (
          moved <= EPSILON ||
          (this.output[target] <= EPSILON &&
            this.next.length +
              unprocessed +
              (moved < amount - EPSILON ? 1 : 0) >=
              this.maximumActive)
        )
          continue;
        write(target, moved);
        this.incoming[target] += moved;
        amount -= moved;
      }
      if (amount > EPSILON) write(index, amount);
    }
    for (const index of this.active) {
      this.mass[index] = 0;
      this.slots[index] = -1;
    }
    [this.mass, this.output] = [this.output, this.mass];
    [this.active, this.next] = [this.next, this.active];
    for (let i = 0; i < this.active.length; i++) this.slots[this.active[i]] = i;
    this.tick++;
  }
}

export class SnowEngine {
  constructor({
    width = 1000,
    height = 800,
    mobile = false,
    reducedMotion = false,
    seed = 1,
  } = {}) {
    this.mobile = !!mobile;
    this.reducedMotion = !!reducedMotion;
    this.seed = seed >>> 0 || 1;
    this.wind = { x: 0, y: 0 };
    this.tool = "glove";
    this.intensity = 1;
    this.obstacles = [];
    this.profiles = new Map();
    this.flakes = [];
    this.reserve = [];
    this._pointer = null;
    this._accumulator = 0;
    this._settle = 0;
    this._windDistance = 0;
    this.elapsed = 0;
    this._meshMarks = null;
    this._meshGeneration = 0;
    this.resize(width, height);
  }
  random() {
    this.seed = (Math.imul(this.seed, 1664525) + 1013904223) >>> 0;
    return this.seed / 4294967296;
  }
  resize(width, height) {
    width = clamp(finite(width, 1000), 1, 8192);
    height = clamp(finite(height, 800), 1, 8192);
    if (this.width === width && this.height === height) return;
    this.width = width;
    this.height = height;
    this.field = new MaterialField(width, height, this.mobile);
    this._meshMarks = new Uint32Array(this.field.mass.length);
    this.profiles.clear();
    this.flakes.length = 0;
    this.reserve.length = 0;
    this._pointer = null;
    this._accumulator = 0;
    const obstacles = this.obstacles;
    this.obstacles = [];
    this.setObstacles(obstacles);
  }
  setWind(x, y = 0) {
    this.wind = { x: clamp(finite(x), -1, 1), y: clamp(finite(y), -1, 1) };
    this._exposure();
  }
  setTool(tool) {
    this.tool = tool === "shovel" ? "shovel" : "glove";
  }
  resetPointer() {
    this._pointer = null;
  }
  setIntensity(value) {
    this.intensity = clamp(finite(value, 1), 0, 3);
  }
  /** A light initial dusting makes the browser playground usable on its first frame. */
  prime(depth = 6) {
    depth = clamp(finite(depth, 0), 0, 6);
    for (const p of this.profiles.values()) {
      const limit = p.body.id === FLOOR ? 28 : p.body.kind === "dock" ? 13 : 18;
      for (let i = 0; i < p.count; i++)
        if (p.sky[i] && !p.shadow[i]) {
          p.heights[i] = Math.max(
            p.heights[i],
            Math.min(
              p.capacity[i],
              (depth * p.lobe[i] * p.capacity[i]) / limit,
            ),
          );
        }
    }
  }
  profile(id) {
    return this.profiles.get(id);
  }
  deposit(id, localX, mass) {
    const profile = this.profiles.get(id);
    return profile ? profile.deposit(localX, Math.max(0, finite(mass))) : mass;
  }
  addLoose(mass, x, y) {
    this.field.begin();
    const remaining = this.field.add(Math.max(0, finite(mass)), x, y);
    return remaining;
  }
  clear() {
    for (const p of this.profiles.values()) p.heights.fill(0);
    this.field.clear();
    this.reserve.length = 0;
    this._pointer = null;
  }
  get stats() {
    let settled = 0,
      pending = 0;
    for (const p of this.profiles.values()) settled += p.area;
    for (const p of this.reserve) pending += p.mass;
    const loose = this.field.area;
    return {
      settled,
      loose,
      pending,
      totalMass: settled + loose + pending,
      falling: this.flakes.length,
      activeCells: this.field.active.length,
      allocatedCells: this.field.mass.length,
      profileSamples: [...this.profiles.values()].reduce(
        (n, p) => n + p.count,
        0,
      ),
    };
  }
  _retain(chunk) {
    if (chunk.mass <= EPSILON) return;
    if (this.reserve.length < (this.mobile ? 1024 : 2048))
      this.reserve.push(chunk);
    else {
      const i = clamp(
          Math.floor((chunk.x / this.width) * this.reserve.length),
          0,
          this.reserve.length - 1,
        ),
        previous = this.reserve[i];
      const total = previous.mass + chunk.mass,
        fraction = chunk.mass / total;
      previous.x = lerp(previous.x, chunk.x, fraction);
      previous.y = lerp(previous.y, chunk.y, fraction);
      previous.height = Math.max(previous.height, chunk.height);
      previous.mass = total;
    }
  }
  _placeReserve() {
    let keep = 0;
    for (const chunk of this.reserve) {
      chunk.mass = this.field.add(
        chunk.mass,
        chunk.x,
        chunk.y,
        chunk.dx || 0,
        chunk.dy ?? 1,
        chunk.exclusion || null,
      );
      if (chunk.mass > EPSILON) this.reserve[keep++] = chunk;
    }
    this.reserve.length = keep;
  }
  _clipChunk(chunk, bodies) {
    let intervals = [[chunk.y - chunk.height / 2, chunk.y + chunk.height / 2]];
    for (const body of bodies) {
      const span = verticalSpan(body, chunk.x);
      if (!span) continue;
      const next = [];
      for (const [top, bottom] of intervals) {
        if (span[0] >= bottom || span[1] <= top) next.push([top, bottom]);
        else {
          if (span[0] > top) next.push([top, span[0]]);
          if (span[1] < bottom) next.push([span[1], bottom]);
        }
      }
      intervals = next;
      if (!intervals.length) break;
    }
    for (const [top, bottom] of intervals)
      this._retain({
        ...chunk,
        y: (top + bottom) / 2,
        height: bottom - top,
        mass: (chunk.mass * (bottom - top)) / chunk.height,
      });
  }
  setObstacles(input = []) {
    const nextBodies = [],
      seen = new Set();
    for (const raw of input.slice(0, 24)) {
      if (
        raw.id === undefined ||
        seen.has(raw.id) ||
        raw.id === FLOOR ||
        ![raw.x, raw.y, raw.width, raw.height].every(Number.isFinite) ||
        raw.width < 16 ||
        raw.height < 16 ||
        raw.width > 20000 ||
        raw.height > 20000
      )
        continue;
      seen.add(raw.id);
      nextBodies.push({
        id: raw.id,
        x: clamp(raw.x, -raw.width + 8, this.width - 8),
        y: clamp(raw.y, -raw.height + 8, this.height - 8),
        width: raw.width,
        height: raw.height,
        radius: clamp(
          finite(raw.radius, 12),
          0,
          Math.min(raw.width, raw.height) / 2,
        ),
        kind: raw.kind === "dock" ? "dock" : "window",
      });
    }
    const signature = nextBodies
      .map(
        (b) =>
          `${b.id}:${b.x},${b.y},${b.width},${b.height},${b.radius},${b.kind}`,
      )
      .join("|");
    if (signature === this._signature && this.profiles.size) return;
    this._signature = signature;
    this.field.begin();
    const oldMap = new Map(this.obstacles.map((b) => [b.id, b])),
      nextMap = new Map(nextBodies.map((b) => [b.id, b]));
    const appeared = nextBodies.filter((b) => !oldMap.has(b.id));
    const motions = nextBodies
      .filter((b) => oldMap.has(b.id))
      .map((next) => ({ old: oldMap.get(next.id), next }));
    const contacts = [],
      handoffs = [];
    // Capture carried material before attachment changes. The first relative contact wins.
    for (const p of this.profiles.values()) {
      const next = nextMap.get(p.body.id);
      if (
        !next ||
        p.body.id === FLOOR ||
        (next.x === p.body.x &&
          next.y === p.body.y &&
          next.width === p.body.width &&
          next.radius === p.body.radius)
      )
        continue;
      for (let i = 0; i < p.count; i++) {
        const local = i * p.spacing,
          height = p.heights[i];
        if (height <= EPSILON || local > next.width) continue;
        const oldBase = p.base(local);
        const edge = Math.max(0, Math.min(local, next.width - local));
        const newBase =
          next.y +
          (edge < next.radius
            ? next.radius -
              Math.sqrt(
                Math.max(0, next.radius ** 2 - (next.radius - edge) ** 2),
              )
            : 0);
        const layers = Math.max(1, Math.ceil(Math.min(28, height) / 3)),
          thickness = height / layers;
        const radius = Math.max(this.field.pitch * 0.65, thickness / 2);
        let removed = 0;
        for (let layer = 0; layer < layers; layer++) {
          const offset = (layer + 0.5) * thickness;
          const start = { x: p.body.x + local, y: oldBase - offset },
            end = { x: next.x + local, y: newBase - offset };
          let first = null;
          for (const motion of motions) {
            if (motion.old.id === p.body.id) continue;
            const boundX = Math.min(motion.old.x, motion.next.x) - radius;
            const boundRight =
              Math.max(
                motion.old.x + motion.old.width,
                motion.next.x + motion.next.width,
              ) + radius;
            if (
              Math.max(start.x, end.x) < boundX ||
              Math.min(start.x, end.x) > boundRight
            )
              continue;
            const hit = contact(start, end, motion.old, motion.next, radius);
            if (hit && (!first || hit.time < first.time)) first = hit;
          }
          if (!first) continue;
          const chunk = {
            x: first.x,
            y: first.y,
            height: thickness,
            mass: thickness * p.spacing,
          };
          if (first.ny < -0.6 && nextMap.has(first.body.id))
            handoffs.push({ ...chunk, target: first.body.id });
          else contacts.push(chunk);
          removed += thickness;
        }
        p.heights[i] = Math.max(0, height - removed);
      }
    }
    const nextProfiles = new Map(),
      bodiesWithFloor = [
        ...nextBodies,
        {
          id: FLOOR,
          x: 0,
          y: this.height,
          width: this.width,
          height: 0,
          radius: 0,
          kind: "floor",
        },
      ];
    const sampleBudget = this.mobile ? 1024 : 2048;
    const demand = bodiesWithFloor.reduce(
      (n, b) => n + Math.min(512, Math.max(5, Math.ceil(b.width / 4) + 1)),
      0,
    );
    for (const body of bodiesWithFloor) {
      const previous = this.profiles.get(body.id);
      const wanted = Math.min(512, Math.max(5, Math.ceil(body.width / 4) + 1));
      const count = Math.max(
        5,
        Math.floor(wanted * Math.min(1, sampleBudget / demand)),
      );
      let p;
      if (
        previous &&
        previous.count === count &&
        previous.body.width === body.width
      ) {
        previous.body = body;
        p = previous;
      } else {
        p = new Profile(
          body,
          count,
          typeof body.id === "number"
            ? body.id * 0.17
            : String(body.id)
                .split("")
                .reduce((v, c) => v + c.charCodeAt(0), 0) * 0.17,
        );
        if (previous) {
          const oldArea = previous.area;
          for (let i = 0; i < count; i++)
            p.heights[i] = Math.min(
              p.capacity[i],
              previous.height(i * p.spacing),
            );
          const area = p.area;
          if (area > oldArea + EPSILON && area)
            for (let i = 0; i < count; i++) p.heights[i] *= oldArea / area;
          const lost = oldArea - p.area;
          if (lost > EPSILON)
            contacts.push({
              x:
                previous.body.x + Math.min(body.width, previous.body.width) - 2,
              y:
                previous.body.y -
                Math.max(
                  2,
                  previous.height(Math.min(body.width, previous.body.width)),
                ) /
                  2,
              mass: lost,
              height: Math.max(
                2,
                previous.height(Math.min(body.width, previous.body.width)),
              ),
            });
        }
      }
      nextProfiles.set(body.id, p);
    }
    for (const [id, p] of this.profiles)
      if (!nextProfiles.has(id)) {
        for (let i = 0; i < p.count; i++)
          if (p.heights[i] > EPSILON)
            this._clipChunk(
              {
                x: p.body.x + i * p.spacing,
                y: p.base(i * p.spacing) - p.heights[i] / 2,
                height: p.heights[i],
                mass: p.heights[i] * p.spacing,
              },
              nextBodies,
            );
      }
    this.profiles = nextProfiles;
    this.obstacles = nextBodies;
    this._exposure();
    // A persistent body entering another support's material pushes it; it is not a
    // newly appearing eraser. This includes snow resting on the screen floor.
    for (const motion of motions) {
      if (
        motion.old.x === motion.next.x &&
        motion.old.y === motion.next.y &&
        motion.old.width === motion.next.width &&
        motion.old.height === motion.next.height
      )
        continue;
      for (const p of this.profiles.values()) {
        if (p.body.id === motion.next.id) continue;
        if (
          p.body.x >
            Math.max(
              motion.old.x + motion.old.width,
              motion.next.x + motion.next.width,
            ) +
              this.field.pitch ||
          p.body.x + p.body.width <
            Math.min(motion.old.x, motion.next.x) - this.field.pitch
        )
          continue;
        for (let i = 0; i < p.count; i++) {
          const height = p.heights[i];
          if (height <= EPSILON) continue;
          const local = i * p.spacing,
            layers = Math.max(1, Math.ceil(Math.min(28, height) / 3)),
            thickness = height / layers;
          let removed = 0;
          for (let layer = 0; layer < layers; layer++) {
            const point = {
              x: p.body.x + local,
              y: p.base(local) - (layer + 0.5) * thickness,
            };
            const hit = contact(
              point,
              point,
              motion.old,
              motion.next,
              this.field.pitch * 0.65,
            );
            if (hit) {
              contacts.push({
                x: hit.x,
                y: hit.y,
                height: thickness,
                mass: thickness * p.spacing,
              });
              removed += thickness;
            }
          }
          p.heights[i] = Math.max(0, height - removed);
        }
      }
    }
    for (const p of this.profiles.values())
      for (let i = 0; i < p.count; i++) {
        if (p.heights[i] <= EPSILON) continue;
        const local = i * p.spacing,
          x = p.body.x + local,
          base = p.base(local),
          top = base - p.heights[i];
        let covered = 0;
        for (const body of appeared) {
          if (body.id === p.body.id) continue;
          const span = verticalSpan(body, x);
          if (!span) continue;
          if (span[0] <= base && span[1] >= base) {
            covered = p.heights[i];
            break;
          }
          covered = Math.max(
            covered,
            Math.max(0, Math.min(base, span[1]) - Math.max(top, span[0])),
          );
        }
        p.heights[i] = Math.max(0, p.heights[i] - covered);
      }
    const moved = [];
    for (const index of [...this.field.active]) {
      const point = this.field.point(index),
        amount = this.field.mass[index];
      if (appeared.some((body) => contains(body, point.x, point.y))) {
        this.field.remove(index);
        continue;
      }
      let target = point,
        touched = false;
      for (const motion of motions) {
        if (
          motion.old.x === motion.next.x &&
          motion.old.y === motion.next.y &&
          motion.old.width === motion.next.width &&
          motion.old.height === motion.next.height
        )
          continue;
        const hit = contact(
          target,
          target,
          motion.old,
          motion.next,
          this.field.pitch * 0.65,
        );
        if (hit) {
          target = hit;
          touched = true;
        }
      }
      if (touched) {
        this.field.remove(index);
        moved.push({
          x: target.x,
          y: target.y,
          mass: amount,
          height: this.field.pitch,
        });
      }
    }
    this.field.raster(nextBodies);
    // Newly discovered surfaces have a small dusting, with the same exposure rules as snow.
    for (const p of this.profiles.values())
      if (!oldMap.has(p.body.id) && p.body.id !== FLOOR) {
        for (let i = 0; i < p.count; i++)
          if (p.sky[i] && !p.shadow[i])
            p.heights[i] = Math.max(
              p.heights[i],
              Math.min(0.65, p.capacity[i]),
            );
      }
    for (const h of handoffs) {
      const p = this.profiles.get(h.target);
      h.mass = p ? p.deposit(h.x - p.body.x, h.mass) : h.mass;
      if (h.mass > EPSILON) this._clipChunk(h, appeared);
    }
    for (const chunk of [...moved, ...contacts])
      this._clipChunk(chunk, appeared);
    if (appeared.length && this.reserve.length) {
      const pending = this.reserve;
      this.reserve = [];
      for (const chunk of pending) this._clipChunk(chunk, appeared);
    }
    this._placeReserve();
  }
  _exposure() {
    if (!this.profiles) return;
    const strength = Math.abs(this.wind.x),
      reach = strength * 96;
    for (const p of this.profiles.values())
      for (let i = 0; i < p.count; i++) {
        const local = i * p.spacing,
          x = p.body.x + local,
          base = p.base(local);
        let exposed = true,
          sky = true,
          suppression = 1,
          boost = 0,
          capacityBoost = 0;
        for (const body of this.obstacles) {
          if (body.id === p.body.id) continue;
          const span = verticalSpan(body, x);
          if (span && span[0] < base - 0.01 && span[1] > base - 20)
            exposed = false;
          if (x >= body.x && x <= body.x + body.width && body.y < base - 0.01)
            sky = false;
          if (
            !strength ||
            body.y >= base - 0.5 ||
            body.y + body.height < base - 28
          )
            continue;
          const contactStrength =
            clamp((body.y + body.height - base + 28) / 28, 0, 1) *
            clamp((base - body.y) / 28, 0, 1);
          const sampleY = clamp(base, body.y, body.y + body.height),
            edge = Math.min(sampleY - body.y, body.y + body.height - sampleY),
            r = body.radius;
          const inset =
            edge < r ? r - Math.sqrt(Math.max(0, r * r - (r - edge) ** 2)) : 0;
          const left = body.x + inset,
            right = body.x + body.width - inset;
          const side = x <= left ? -1 : x >= right ? 1 : 0;
          if (!side) continue;
          const distance = side < 0 ? left - x : x - right,
            radius = reach * contactStrength;
          if (side * this.wind.x > 0) {
            if (distance <= radius) suppression = 0;
            else if (distance < radius + 4)
              suppression = Math.min(
                suppression,
                smooth((distance - radius) / 4),
              );
          } else if (distance < radius) {
            const shape = smooth(1 - distance / Math.max(0.001, radius));
            boost = Math.max(boost, strength * contactStrength * shape * 1.25);
            capacityBoost = Math.max(
              capacityBoost,
              strength * contactStrength * shape * 0.6,
            );
          }
        }
        p.exposed[i] = exposed ? 1 : 0;
        p.sky[i] = sky && exposed ? 1 : 0;
        p.shadow[i] = suppression === 0 ? 1 : 0;
        p.snowCapacity[i] = Math.min(
          p.capacity[i],
          p.capacity[i] * p.lobe[i] * (1 + capacityBoost) * suppression,
        );
        const taper =
          p.capacity[i] /
          (p.body.id === FLOOR ? 28 : p.body.kind === "dock" ? 13 : 18);
        p.deposition[i] =
          (0.18 + p.lobe[i] * 0.17) * taper * (1 + boost) * suppression;
      }
  }
  _profileHit(start, end, radius, allowEmbedded = false) {
    let hit = null;
    for (const p of this.profiles.values()) {
      const minX = Math.min(start.x, end.x),
        maxX = Math.max(start.x, end.x);
      if (
        maxX < p.body.x ||
        minX > p.body.x + p.body.width ||
        Math.max(start.y, end.y) < p.body.y - 30 ||
        start.y > p.body.y + p.body.radius + 1
      )
        continue;
      const local = start.x - p.body.x;
      if (
        allowEmbedded &&
        local >= 0 &&
        local <= p.body.width &&
        p.visible(local)
      ) {
        const base = p.base(local),
          top = base - p.height(local);
        if (start.y <= base + 0.001 && start.y + radius >= top - 0.001) {
          if (!hit || hit.time > 0 || top < hit.top)
            hit = { time: 0, x: start.x, top, p };
          continue;
        }
      }
      for (let sample = 0; sample <= 2; sample++) {
        const t = sample / 2,
          x = lerp(start.x, end.x, t),
          lx = x - p.body.x;
        if (!p.visible(lx)) continue;
        const top = p.base(lx) - p.height(lx),
          delta = end.y - start.y;
        const time = delta > EPSILON ? (top - radius - start.y) / delta : -1;
        if (time >= 0 && time <= 1 && (!hit || time < hit.time))
          hit = { time, x: lerp(start.x, end.x, time), top, p };
      }
    }
    return hit;
  }
  _land(start, end, mass) {
    const hit = this._profileHit(start, end, this.field.pitch * 0.45, true);
    if (!hit) return { remaining: mass, blocked: false };
    return {
      remaining: hit.p.deposit(hit.x - hit.p.body.x, mass),
      blocked: true,
    };
  }
  _sweep(start, end) {
    const dx = end.x - start.x,
      dy = end.y - start.y,
      travel = Math.hypot(dx, dy),
      hard = this.tool === "shovel";
    if (!hard && travel < 0.5) return;
    const radius = hard ? 36 : 24,
      strength = hard ? 1 : Math.min(0.7, travel / (radius * 1.2));
    const nearest = (point) => {
      const t = travel
        ? clamp(
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / travel ** 2,
            0,
            1,
          )
        : 0;
      return { x: start.x + dx * t, y: start.y + dy * t };
    };
    const direction = (point) =>
      travel > 0.5
        ? { x: dx / travel, y: dy / travel }
        : { x: point.x < end.x ? -1 : 1, y: -0.15 };
    const chunks = [];
    for (const p of this.profiles.values()) {
      if (
        Math.max(start.x, end.x) + radius < p.body.x ||
        Math.min(start.x, end.x) - radius > p.body.x + p.body.width
      )
        continue;
      for (let i = 0; i < p.count; i++) {
        const height = p.heights[i];
        if (height <= EPSILON || !p.exposed[i]) continue;
        const local = i * p.spacing,
          base = p.base(local),
          point = { x: p.body.x + local, y: base - height / 2 },
          close = nearest(point);
        const horizontal = point.x - close.x;
        if (Math.abs(horizontal) >= radius) continue;
        const reach = Math.sqrt(radius * radius - horizontal * horizontal);
        const overlap = Math.max(
          0,
          Math.min(base, close.y + reach) -
            Math.max(base - height, close.y - reach),
        );
        const removed =
          hard && overlap > 0 ? height : Math.min(height, overlap * strength);
        if (removed <= EPSILON) continue;
        const d = direction(point);
        p.heights[i] -= removed;
        chunks.push({
          x: end.x + d.x * (radius + this.field.pitch),
          y: Math.min(point.y, end.y + d.y * (radius + this.field.pitch)),
          mass: removed * p.spacing,
          height: removed,
          dx: d.x,
          dy: d.y,
          exclusion: { ...end, radius },
        });
      }
    }
    for (const index of [...this.field.active]) {
      const point = this.field.point(index),
        close = nearest(point);
      if (
        Math.hypot(point.x - close.x, point.y - close.y) >
        radius + this.field.pitch * 0.5
      )
        continue;
      const d = direction(point),
        mass = this.field.mass[index];
      this.field.remove(index);
      chunks.push({
        x: end.x + d.x * (radius + this.field.pitch),
        y: Math.min(point.y, end.y + d.y * (radius + this.field.pitch)),
        mass,
        height: this.field.pitch,
        dx: d.x,
        dy: d.y,
        exclusion: { ...end, radius },
      });
    }
    for (const chunk of chunks) this._retain(chunk);
    this._placeReserve();
  }
  _newFlake(scattered) {
    const depth = this.random(),
      radius = 0.65 + depth * depth * 1.65;
    let x = this.random() * this.width,
      y = scattered ? this.random() * this.height : -5;
    for (
      let attempt = 0;
      attempt < 4 && this.obstacles.some((b) => contains(b, x, y, radius));
      attempt++
    ) {
      x = this.random() * this.width;
      y = -5;
    }
    return {
      x,
      y,
      radius,
      opacity: 0.3 + depth * 0.55,
      speed: 24 + depth * 42,
      drift: this.random() * 12 - 6,
      phase: this.random() * Math.PI * 2,
    };
  }
  step(rawDT, pointer = null) {
    if (!Number.isFinite(rawDT) || rawDT <= 0) return;
    const dt = Math.min(rawDT, 0.05);
    this.elapsed += dt;
    this.field.begin();
    this._placeReserve();
    if (pointer && Number.isFinite(pointer.x) && Number.isFinite(pointer.y)) {
      if (rawDT < 0.2 && (this._pointer || this.tool === "shovel"))
        this._sweep(this._pointer || pointer, pointer);
      this._pointer = { x: pointer.x, y: pointer.y };
    } else this._pointer = null;
    for (const p of this.profiles.values())
      for (let i = 0; i < p.count; i++) {
        if (p.sky[i] && p.heights[i] < p.snowCapacity[i])
          p.heights[i] = Math.min(
            p.snowCapacity[i],
            p.heights[i] + p.deposition[i] * dt * this.intensity,
          );
      }
    this._settle += dt;
    if (this._settle >= 0.1) {
      for (const p of this.profiles.values()) p.settle();
      this._settle = 0;
    }
    const desired = this.reducedMotion
      ? 0
      : Math.round((this.mobile ? 64 : 160) * Math.min(1, this.intensity));
    if (this.flakes.length > desired) this.flakes.length = desired;
    while (this.flakes.length < desired) this.flakes.push(this._newFlake(true));
    for (let i = 0; i < this.flakes.length; i++) {
      const flake = this.flakes[i],
        start = { x: flake.x, y: flake.y };
      const end = {
        x:
          flake.x +
          (flake.drift +
            Math.sin(this.elapsed * 0.3 + flake.phase) * 8 +
            this.wind.x * 80) *
            dt,
        y: flake.y + (flake.speed + this.wind.y * 20) * dt,
      };
      let first = null;
      for (const body of this.obstacles) {
        const hit = rayBody(start, end, body, flake.radius);
        if (hit && (!first || hit.time < first.time)) first = { ...hit, body };
      }
      const cap = this._profileHit(start, end, flake.radius);
      if (cap && (!first || cap.time <= first.time))
        first = { ...cap, ny: -1, profile: cap.p };
      if (first) {
        if (first.ny < -0.5) {
          const p = first.profile || this.profiles.get(first.body.id);
          if (p) p.deposit(first.x - p.body.x, 0.35 * flake.radius ** 2, true);
        }
        this.flakes[i] = this._newFlake(false);
      } else if (end.y > this.height + 5 || end.y < -40) {
        if (end.y > this.height)
          this.profiles
            .get(FLOOR)
            ?.deposit(
              clamp(end.x, 0, this.width),
              0.35 * flake.radius ** 2,
              true,
            );
        this.flakes[i] = this._newFlake(false);
      } else {
        flake.x =
          end.x < -5
            ? end.x + this.width + 10
            : end.x > this.width + 5
              ? end.x - this.width - 10
              : end.x;
        flake.y = end.y;
      }
    }
    this._accumulator += dt * (1 + this.wind.y * 0.25);
    const steps = Math.min(3, Math.floor((this._accumulator + EPSILON) * 60));
    this._accumulator = Math.max(
      0,
      Math.min(1 / 60, this._accumulator - steps / 60),
    );
    for (let tick = 0; tick < steps && this.field.active.length; tick++) {
      this._windDistance += (this.wind.x * 80) / 60 / this.field.pitch;
      const side =
        Math.abs(this._windDistance) >= 1 ? Math.sign(this._windDistance) : 0;
      if (side) this._windDistance -= side;
      this.field.step(side, (a, b, mass) => this._land(a, b, mass));
    }
    if (this.tool === "shovel" && pointer) this._sweep(pointer, pointer);
  }
  draw(ctx) {
    ctx.clearRect(0, 0, this.width, this.height);
    // Every cap uses the same connected profile shading as transported material.
    for (const p of this.profiles.values()) {
      let start = 0;
      while (start < p.count) {
        while (
          start < p.count &&
          (!p.exposed[start] || p.heights[start] < 0.025)
        )
          start++;
        if (start >= p.count) break;
        let end = start;
        while (
          end + 1 < p.count &&
          p.exposed[end + 1] &&
          p.heights[end + 1] >= 0.025
        )
          end++;
        const begin = start > 0 && p.exposed[start - 1] ? start - 1 : start;
        const finish = end + 1 < p.count && p.exposed[end + 1] ? end + 1 : end;
        if (finish > begin) {
          const top = (i) => p.base(i * p.spacing) - p.heights[i],
            base = (i) => p.base(i * p.spacing) + 0.35;
          const minTop = Math.min(
            top(start),
            top(end),
            p.body.y - Math.max(...p.heights),
          );
          const gradient = ctx.createLinearGradient(
            0,
            minTop,
            0,
            p.body.y + p.body.radius + 1,
          );
          gradient.addColorStop(0, "#ffffff");
          gradient.addColorStop(0.45, "#f5fbff");
          gradient.addColorStop(1, "#c7d8e8");
          ctx.beginPath();
          ctx.moveTo(p.body.x + begin * p.spacing, top(begin));
          for (let i = begin + 1; i <= finish; i++) {
            const previousX = p.body.x + (i - 1) * p.spacing,
              x = p.body.x + i * p.spacing;
            ctx.quadraticCurveTo(
              previousX,
              top(i - 1),
              (previousX + x) / 2,
              (top(i - 1) + top(i)) / 2,
            );
          }
          ctx.lineTo(p.body.x + finish * p.spacing, top(finish));
          for (let i = finish; i >= begin; i--)
            ctx.lineTo(p.body.x + i * p.spacing, base(i));
          ctx.closePath();
          ctx.fillStyle = gradient;
          ctx.fill();
        }
        start = end + 1;
      }
    }
    this._drawMaterial(ctx);
    ctx.fillStyle = "#fff";
    for (const flake of this.flakes) {
      ctx.globalAlpha = flake.opacity;
      ctx.beginPath();
      ctx.arc(flake.x, flake.y, flake.radius, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }
  _drawMaterial(ctx) {
    const field = this.field;
    if (!field.active.length) return;
    this._meshGeneration = (this._meshGeneration + 1) >>> 0;
    if (!this._meshGeneration) {
      this._meshMarks.fill(0);
      this._meshGeneration = 1;
    }
    const threshold = 0.14;
    ctx.beginPath();
    const triangle = (vertices) => {
      const polygon = [];
      for (let i = 0; i < 3; i++) {
        const a = vertices[i],
          b = vertices[(i + 1) % 3],
          insideA = a.d >= threshold,
          insideB = b.d >= threshold;
        if (insideA) polygon.push(a);
        if (insideA !== insideB) {
          const t = (threshold - a.d) / (b.d - a.d);
          polygon.push({ x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t) });
        }
      }
      if (polygon.length >= 3) {
        ctx.moveTo(polygon[0].x, polygon[0].y);
        for (let i = 1; i < polygon.length; i++)
          ctx.lineTo(polygon[i].x, polygon[i].y);
        ctx.closePath();
      }
    };
    for (const index of field.active) {
      const column = index % field.columns,
        row = Math.floor(index / field.columns);
      for (let oy = -1; oy <= 0; oy++)
        for (let ox = -1; ox <= 0; ox++) {
          const x = column + ox,
            y = row + oy;
          if (x < 0 || y < 0 || x >= field.columns - 1 || y >= field.rows - 1)
            continue;
          const quad = y * field.columns + x;
          if (this._meshMarks[quad] === this._meshGeneration) continue;
          this._meshMarks[quad] = this._meshGeneration;
          const corners = [
            quad,
            quad + 1,
            quad + field.columns + 1,
            quad + field.columns,
          ].map((i) => ({
            ...field.point(i),
            d: Math.min(1, field.mass[i] / field.capacity(i)),
          }));
          triangle([corners[0], corners[1], corners[2]]);
          triangle([corners[0], corners[2], corners[3]]);
        }
    }
    ctx.fillStyle = "#f5fbff";
    ctx.fill();
  }
}

export { FLOOR as FLOOR_ID };
