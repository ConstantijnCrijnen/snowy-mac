import { setupDownloadFlow } from "./download-flow.js";
import { SnowEngine } from "./snow-engine.js";
import { readPreferences, savePreferences } from "./preferences.js";
import {
  clampWindowRect,
  reflowWindowRect,
  normalizeWind,
  parseCommand,
} from "./window-geometry.js";

const desktop = document.querySelector("#desktop");
const canvas = document.querySelector("#snow");
const dock = document.querySelector("#dock");
const ctx = canvas.getContext("2d", { alpha: true });
const mobileQuery = matchMedia("(max-width:700px)");
const motionQuery = matchMedia("(prefers-reduced-motion:reduce)");
let mobile = mobileQuery.matches;
let reducedMotion = motionQuery.matches;
let storage;
try {
  storage = window.localStorage;
} catch {
  storage = null;
}
const preferences = readPreferences(storage);
const savedWind = normalizeWind(preferences.windX, preferences.windY);
preferences.windX = savedWind.x;
preferences.windY = savedWind.y;

const models = new Map(
  [...document.querySelectorAll("[data-window]")].map((element) => [
    element.dataset.window,
    {
      id: element.dataset.window,
      element,
      titlebar: element.querySelector(".titlebar"),
      grip: element.querySelector(".resize-grip"),
      visible: !element.hidden,
      initialVisible: !element.hidden,
      touched: false,
      maximized: false,
      restoreRect: null,
      z: 5,
    },
  ]),
);
const intensity = { light: 0.55, steady: 1, flurry: 2.2 };
let stageBounds = { width: 1, height: 1 };
let stageClient = { left: 0, top: 0, width: 1, height: 1 };
let engine;
let primePending = true;
let activeID = "welcome";
let zCounter = 20;
let gesture = null;
let pointer = null;
let touchBrushID = null;
let sweeping = false;
let raf = 0;
let layoutDirty = true;
let geometryDirty = true;
let drawDirty = true;
let lastPhysics = 0;
let lastFrame = 0;
let lastMinute = -1;
let toastUntil = 0;
let clearCount = 0;
const windSpring = {
  length: savedWind.strength * 38,
  target: savedWind.strength * 38,
  velocity: 0,
  active: false,
};
const toastElement = document.querySelector("#toast");
const cursorElement = document.querySelector("#cursor-tool");
const downloadDialog = document.querySelector("#download-dialog");
const betaDialog = document.querySelector("#beta-dialog");
const windPad = document.querySelector("#wind-pad");
const windArrow = document.querySelector("#wind-arrow");
const terminalInput = document.querySelector("#terminal-input");
const terminalOutput = document.querySelector("#terminal-output");
const repositoryURL = "https://github.com/soloiaros/snowy-mac";

function persist() {
  savePreferences(storage, preferences);
}
function wake() {
  if (!raf && !document.hidden) raf = requestAnimationFrame(frame);
}
function requestGeometry() {
  geometryDirty = true;
  drawDirty = true;
  wake();
}
function applyRect(model, rect, touched = false) {
  model.rect = clampWindowRect(rect, stageBounds);
  model.touched ||= touched;
  const { x, y, width, height } = model.rect;
  Object.assign(model.element.style, {
    left: "0px",
    top: "0px",
    right: "auto",
    width: `${width}px`,
    height: `${height}px`,
    transform: `translate3d(${x}px,${y}px,0)`,
  });
}

function layout() {
  const before = stageBounds;
  const nextMobile = mobileQuery.matches,
    breakpointChanged = nextMobile !== mobile;
  mobile = nextMobile;
  stageClient = desktop.getBoundingClientRect();
  stageBounds = { width: desktop.clientWidth, height: desktop.clientHeight };
  for (const model of models.values()) {
    const hidden = model.element.hidden;
    const previous = model.rect;
    model.element.hidden = false;
    model.element.style.visibility = "hidden";
    for (const property of [
      "left",
      "top",
      "right",
      "width",
      "height",
      "transform",
    ])
      model.element.style[property] = "";
    const rect = model.element.getBoundingClientRect();
    model.initial = clampWindowRect(
      {
        x: rect.left - stageClient.left,
        y: rect.top - stageClient.top,
        width: rect.width,
        height: rect.height,
      },
      stageBounds,
    );
    const target =
      previous && model.touched && !breakpointChanged
        ? reflowWindowRect(previous, before, stageBounds)
        : model.initial;
    if (breakpointChanged) {
      model.touched = false;
      model.maximized = false;
      model.restoreRect = null;
    }
    applyRect(model, target);
    model.element.style.visibility = "";
    model.element.hidden = hidden;
  }
  if (!engine || engine.mobile !== mobile) {
    engine = new SnowEngine({
      ...stageBounds,
      mobile,
      reducedMotion,
      seed: 1225,
    });
    primePending = true;
  } else engine.resize(stageBounds.width, stageBounds.height);
  applyWeather();
  const ratio = Math.max(
    0.25,
    Math.min(
      devicePixelRatio || 1,
      1.5,
      Math.sqrt(6_000_000 / (stageBounds.width * stageBounds.height)),
    ),
  );
  canvas.width = Math.max(1, Math.floor(stageBounds.width * ratio));
  canvas.height = Math.max(1, Math.floor(stageBounds.height * ratio));
  ctx?.setTransform(
    canvas.width / stageBounds.width,
    0,
    0,
    canvas.height / stageBounds.height,
    0,
    0,
  );
  layoutDirty = false;
  geometryDirty = true;
  drawDirty = true;
  lastPhysics = 0;
}

function syncGeometry() {
  stageClient = desktop.getBoundingClientRect();
  const obstacles = [];
  for (const model of models.values())
    if (model.visible)
      obstacles.push({
        id: model.id,
        ...model.rect,
        radius: 11,
        kind: "window",
      });
  const rect = dock.getBoundingClientRect();
  obstacles.push({
    id: "dock",
    x: rect.left - stageClient.left,
    y: rect.top - stageClient.top,
    width: rect.width,
    height: rect.height,
    radius: 15,
    kind: "dock",
  });
  engine.setObstacles(obstacles);
  if (primePending) {
    engine.prime();
    primePending = false;
  }
  geometryDirty = false;
  drawDirty = true;
}

function activate(model) {
  if (!model?.visible) return;
  activeID = model.id;
  for (const item of models.values())
    item.element.dataset.active = String(item === model);
  model.z = ++zCounter;
  model.element.style.zIndex = model.z;
}
function updateDock() {
  for (const button of dock.querySelectorAll("[data-open]")) {
    const visible = !!models.get(button.dataset.open)?.visible;
    button.classList.toggle("is-open", visible);
    button.setAttribute("aria-expanded", String(visible));
    button.setAttribute("aria-controls", `window-${button.dataset.open}`);
    const indicator = button.querySelector("i");
    if (indicator) indicator.hidden = !visible;
  }
}
function openWindow(id, focus = true) {
  const model = models.get(id);
  if (!model) return;
  const wasHidden = !model.visible;
  model.visible = true;
  model.element.hidden = false;
  activate(model);
  updateDock();
  requestGeometry();
  if (wasHidden && !reducedMotion)
    model.element.animate?.([{ opacity: 0 }, { opacity: 1 }], {
      duration: 150,
      easing: "ease-out",
    });
  if (focus)
    (id === "terminal" ? terminalInput : model.titlebar)?.focus({
      preventScroll: true,
    });
  if (mobile && focus)
    model.element.scrollIntoView({
      block: "nearest",
      behavior: reducedMotion ? "instant" : "smooth",
    });
}
function closeWindow(id) {
  const model = models.get(id);
  if (!model?.visible) return;
  endGesture();
  model.visible = false;
  model.element.hidden = true;
  model.element.dataset.active = "false";
  const next = [...models.values()]
    .filter((item) => item.visible)
    .sort((a, b) => b.z - a.z)[0];
  activeID = next?.id || null;
  if (next) activate(next);
  updateDock();
  requestGeometry();
  dock.querySelector(`[data-open="${id}"]`)?.focus({ preventScroll: true });
}
function maximizeWindow(id) {
  const model = models.get(id);
  if (!model?.visible) return;
  activate(model);
  if (model.maximized && model.restoreRect) {
    applyRect(model, model.restoreRect, true);
    model.restoreRect = null;
    model.maximized = false;
  } else {
    model.restoreRect = { ...model.rect };
    model.maximized = true;
    const top = Math.max(12, 44 - stageClient.top);
    const bottom = Math.min(
      stageBounds.height - 12,
      innerHeight - stageClient.top - (mobile ? 102 : 114),
    );
    applyRect(
      model,
      {
        x: 12,
        y: top,
        width: stageBounds.width - 24,
        height: Math.max(130, bottom - top),
      },
      true,
    );
  }
  model.element
    .querySelector("[data-maximize]")
    ?.setAttribute(
      "aria-label",
      `${model.maximized ? "Restore" : "Resize"} ${model.element.getAttribute("aria-label")}`,
    );
  requestGeometry();
}
function tidy() {
  endGesture();
  pointer = null;
  engine.resetPointer();
  for (const model of models.values()) {
    model.visible = model.initialVisible;
    model.element.hidden = !model.visible;
    model.maximized = false;
    model.restoreRect = null;
    model.touched = false;
    applyRect(model, model.initial);
  }
  activate(models.get("welcome"));
  updateDock();
  requestGeometry();
  toast("Everything in its slightly snowy place.");
}

function beginGesture(kind, model, event) {
  if (event.button !== 0 && event.pointerType !== "touch") return;
  if (event.pointerType === "touch" && !event.isPrimary) return;
  if (gesture) endGesture();
  if (model) activate(model);
  pointer = null;
  touchBrushID = null;
  engine.resetPointer();
  cursorElement.classList.remove("visible");
  if (kind === "move" && model.maximized && model.restoreRect) {
    const restore = model.restoreRect;
    model.maximized = false;
    model.restoreRect = null;
    applyRect(
      model,
      {
        ...restore,
        x: event.clientX - stageClient.left - restore.width / 2,
        y: event.clientY - stageClient.top - 16,
      },
      true,
    );
  }
  gesture = {
    kind,
    model,
    pointerID: event.pointerId,
    target: event.currentTarget,
    startX: event.clientX,
    startY: event.clientY,
    rect: model ? { ...model.rect } : windPad.getBoundingClientRect(),
  };
  if (model) model.element.classList.add("is-dragging");
  gesture.target.setPointerCapture?.(event.pointerId);
  event.preventDefault();
  if (kind === "wind") windFromPointer(event);
}
function endGesture(event) {
  if (!gesture || (event && gesture.pointerID !== event.pointerId)) return;
  const previous = gesture;
  previous.model?.element.classList.remove("is-dragging");
  try {
    if (previous.target.hasPointerCapture?.(previous.pointerID))
      previous.target.releasePointerCapture(previous.pointerID);
  } catch {
    /* capture may already be released */
  }
  gesture = null;
  pointer = null;
  engine?.resetPointer();
  if (previous.kind === "wind") {
    windSpring.target = Math.hypot(preferences.windX, preferences.windY) * 38;
    windSpring.active =
      !reducedMotion && Math.abs(windSpring.length - windSpring.target) > 0.01;
    if (reducedMotion) windSpring.length = windSpring.target;
    persist();
    drawWind();
  }
  requestGeometry();
}

for (const model of models.values()) {
  model.element.addEventListener("pointerdown", () => activate(model));
  model.titlebar.addEventListener("pointerdown", (event) => {
    if (event.target.closest("button, a, input")) return;
    beginGesture("move", model, event);
  });
  model.titlebar.addEventListener("dblclick", (event) => {
    if (!event.target.closest("button")) maximizeWindow(model.id);
  });
  model.titlebar.addEventListener("keydown", (event) => {
    if (
      event.target !== model.titlebar ||
      !["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)
    )
      return;
    event.preventDefault();
    activate(model);
    model.maximized = false;
    model.restoreRect = null;
    const step = event.shiftKey ? 30 : 10;
    applyRect(
      model,
      {
        ...model.rect,
        x:
          model.rect.x +
          (event.key === "ArrowRight"
            ? step
            : event.key === "ArrowLeft"
              ? -step
              : 0),
        y:
          model.rect.y +
          (event.key === "ArrowDown"
            ? step
            : event.key === "ArrowUp"
              ? -step
              : 0),
      },
      true,
    );
    engine.resetPointer();
    requestGeometry();
  });
  model.grip?.addEventListener("pointerdown", (event) =>
    beginGesture("resize", model, event),
  );
  model.grip?.setAttribute(
    "title",
    "Drag to resize, or use arrow keys when focused.",
  );
  model.grip?.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      maximizeWindow(model.id);
      return;
    }
    if (
      !["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)
    )
      return;
    event.preventDefault();
    activate(model);
    model.maximized = false;
    model.restoreRect = null;
    const step = event.shiftKey ? 30 : 10;
    applyRect(
      model,
      {
        ...model.rect,
        width:
          model.rect.width +
          (event.key === "ArrowRight"
            ? step
            : event.key === "ArrowLeft"
              ? -step
              : 0),
        height:
          model.rect.height +
          (event.key === "ArrowDown"
            ? step
            : event.key === "ArrowUp"
              ? -step
              : 0),
      },
      true,
    );
    requestGeometry();
  });
}
document.addEventListener("click", (event) => {
  const open = event.target.closest("[data-open]");
  if (open) {
    openWindow(open.dataset.open);
    return;
  }
  const close = event.target.closest("[data-close]");
  if (close) {
    closeWindow(close.dataset.close);
    return;
  }
  const maximize = event.target.closest("[data-maximize]");
  if (maximize) maximizeWindow(maximize.dataset.maximize);
});
document.addEventListener(
  "pointermove",
  (event) => {
    if (downloadDialog.open || betaDialog.open) return;
    if (gesture?.pointerID === event.pointerId) {
      if (gesture.kind === "wind") windFromPointer(event);
      else {
        const { rect, model } = gesture;
        const dx = event.clientX - gesture.startX,
          dy = event.clientY - gesture.startY;
        model.maximized = false;
        model.restoreRect = null;
        applyRect(
          model,
          gesture.kind === "move"
            ? { ...rect, x: rect.x + dx, y: rect.y + dy }
            : { ...rect, width: rect.width + dx, height: rect.height + dy },
          true,
        );
        requestGeometry();
      }
      event.preventDefault();
      return;
    }
    const touch = event.pointerType === "touch";
    if (touch && (touchBrushID !== event.pointerId || !sweeping)) return;
    const inside =
      event.clientX >= stageClient.left &&
      event.clientX <= stageClient.left + stageBounds.width &&
      event.clientY >= Math.max(31, stageClient.top) &&
      event.clientY <= innerHeight;
    pointer = inside
      ? { clientX: event.clientX, clientY: event.clientY, touch }
      : null;
    updateCursor();
    if (touch && inside) event.preventDefault();
    wake();
  },
  { passive: false },
);
desktop.addEventListener("pointerdown", (event) => {
  if (
    event.pointerType !== "touch" ||
    !event.isPrimary ||
    !sweeping ||
    event.target.closest(".window, button, a, input, .mobile-mode")
  )
    return;
  touchBrushID = event.pointerId;
  desktop.setPointerCapture?.(event.pointerId);
  pointer = { clientX: event.clientX, clientY: event.clientY, touch: true };
  engine.resetPointer();
  updateCursor();
  event.preventDefault();
  wake();
});
for (const name of ["pointerup", "pointercancel"])
  document.addEventListener(name, (event) => {
    endGesture(event);
    if (event.pointerId === touchBrushID) {
      touchBrushID = null;
      pointer = null;
      engine.resetPointer();
      updateCursor();
    }
  });
document.addEventListener("pointerout", (event) => {
  if (!event.relatedTarget && !gesture) {
    pointer = null;
    engine?.resetPointer();
    updateCursor();
  }
});
function updateCursor() {
  const visible =
    !!pointer &&
    !gesture &&
    (preferences.tool === "shovel" || (mobile && sweeping && pointer.touch));
  cursorElement.classList.toggle("visible", visible);
  if (!pointer) return;
  const diameter = preferences.tool === "shovel" ? 72 : 48;
  Object.assign(cursorElement.style, {
    left: `${pointer.clientX}px`,
    top: `${pointer.clientY}px`,
    width: `${diameter}px`,
    height: `${diameter}px`,
  });
}

function applyWeather() {
  if (!engine) return;
  engine.reducedMotion = reducedMotion;
  engine.setTool(preferences.tool);
  engine.setWind(preferences.windX, preferences.windY);
  engine.setIntensity(intensity[preferences.intensity]);
}
function updateControls() {
  for (const button of document.querySelectorAll("[data-intensity]"))
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.intensity === preferences.intensity),
    );
  for (const button of document.querySelectorAll("[data-tool]"))
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.tool === preferences.tool),
    );
  drawWind();
  updateCursor();
}
for (const button of document.querySelectorAll("[data-intensity]"))
  button.addEventListener("click", () => {
    preferences.intensity = button.dataset.intensity;
    applyWeather();
    persist();
    updateControls();
    wake();
  });
for (const button of document.querySelectorAll("[data-tool]"))
  button.addEventListener("click", () => {
    preferences.tool = button.dataset.tool;
    engine.setTool(preferences.tool);
    engine.resetPointer();
    persist();
    updateControls();
    wake();
  });
function setTouchMode(value) {
  sweeping = value;
  pointer = null;
  touchBrushID = null;
  engine.resetPointer();
  document.body.classList.toggle("sweep-mode", value);
  document
    .querySelector("#explore-mode")
    .setAttribute("aria-pressed", String(!value));
  document
    .querySelector("#sweep-mode")
    .setAttribute("aria-pressed", String(value));
  updateCursor();
  wake();
}
document
  .querySelector("#explore-mode")
  .addEventListener("click", () => setTouchMode(false));
document
  .querySelector("#sweep-mode")
  .addEventListener("click", () => setTouchMode(true));

function setWind(x, y, snap = false, stretch = null) {
  const wind = normalizeWind(x, y, snap);
  preferences.windX = wind.x;
  preferences.windY = wind.y;
  engine.setWind(wind.x, wind.y);
  windSpring.target = wind.strength * 38;
  windSpring.length = stretch === null ? windSpring.target : stretch;
  windSpring.velocity = 0;
  windSpring.active = false;
  drawWind();
  drawDirty = true;
  wake();
}
function windFromPointer(event) {
  const rect = gesture.rect;
  const x = (event.clientX - rect.left - rect.width / 2) / (rect.width * 0.38);
  const y = (event.clientY - rect.top - rect.height / 2) / (rect.height * 0.38);
  const strength = Math.hypot(x, y);
  const stretch =
    strength <= 1
      ? strength * 38
      : (1 + (1 - Math.exp(-(strength - 1) * 0.8)) * 0.16) * 38;
  setWind(
    x,
    y,
    event.shiftKey,
    reducedMotion ? Math.min(1, strength) * 38 : stretch,
  );
}
function drawWind() {
  const strength = Math.min(
    1,
    Math.hypot(preferences.windX, preferences.windY),
  );
  const angle = Math.atan2(preferences.windY, preferences.windX);
  const ux = Math.cos(angle),
    uy = Math.sin(angle),
    length = windSpring.length;
  const x = 50 + ux * length,
    y = 50 + uy * length;
  const head = Math.min(7, length * 0.55),
    backX = x - ux * head,
    backY = y - uy * head;
  windArrow.setAttribute(
    "d",
    length < 0.5
      ? ""
      : `M50 50 L${x} ${y} M${backX - uy * head * 0.7} ${backY + ux * head * 0.7} L${x} ${y} L${backX + uy * head * 0.7} ${backY - ux * head * 0.7}`,
  );
  const stretch = Math.max(0, length - windSpring.target);
  windArrow.style.strokeWidth = String(3.5 / (1 + stretch * 0.035));
  const directions = [
    "east",
    "south-east",
    "south",
    "south-west",
    "west",
    "north-west",
    "north",
    "north-east",
  ];
  const direction = directions[(Math.round(angle / (Math.PI / 4)) + 8) % 8];
  document.querySelector("#wind-label").textContent =
    strength < 0.01
      ? "Perfectly still"
      : `${Math.round(strength * 100)}% ${direction}`;
  windPad.setAttribute("aria-valuenow", String(Math.round(strength * 100)));
  windPad.setAttribute(
    "aria-valuetext",
    strength < 0.01
      ? "Calm"
      : `${Math.round(strength * 100)} percent, moving ${direction}`,
  );
}
windPad.addEventListener("pointerdown", (event) =>
  beginGesture("wind", null, event),
);
windPad.addEventListener("keydown", (event) => {
  let strength = Math.hypot(preferences.windX, preferences.windY),
    angle = Math.atan2(preferences.windY, preferences.windX);
  const fine = event.altKey,
    turn = ((fine ? 1 : event.shiftKey ? 45 : 15) * Math.PI) / 180;
  const amount = fine ? 0.01 : event.shiftKey ? 0.1 : 0.05;
  if (event.key === "ArrowLeft") angle -= turn;
  else if (event.key === "ArrowRight") angle += turn;
  else if (event.key === "ArrowUp") strength = Math.min(1, strength + amount);
  else if (event.key === "ArrowDown") strength = Math.max(0, strength - amount);
  else if (["Home", " "].includes(event.key)) strength = 0;
  else return;
  event.preventDefault();
  setWind(Math.cos(angle) * strength, Math.sin(angle) * strength);
  persist();
});
document.querySelector("#reset-wind").addEventListener("click", () => {
  setWind(0, 0);
  persist();
});

function toast(message) {
  toastElement.textContent = message;
  toastElement.classList.add("visible");
  toastUntil = performance.now() + 3600;
  wake();
}
function clearSnow() {
  engine.clear();
  drawDirty = true;
  clearCount++;
  toast(
    clearCount >= 3
      ? "You do know it’s still snowing, right?"
      : clearCount === 2
        ? "All clear. For approximately one snowflake."
        : "Fresh start. The forecast is still yours.",
  );
}
document.querySelector("#clear-snow").addEventListener("click", clearSnow);
document.querySelector("#tidy-desktop").addEventListener("click", tidy);
const mariahAudio = document.querySelector("#mariah-audio");
function playMariah() {
  mariahAudio.pause();
  mariahAudio.currentTime = 0;
  mariahAudio.play()?.catch(() => toast("The sound couldn’t play. Give it another try."));
}
for (const button of document.querySelectorAll("[data-play-mariah]"))
  button.addEventListener("click", playMariah);

function terminalLine(text, className = "response") {
  const line = document.createElement("p");
  line.className = className;
  line.textContent = text;
  terminalOutput.append(line);
  while (terminalOutput.childElementCount > 40)
    terminalOutput.firstElementChild.remove();
  const body = models.get("terminal").element.querySelector(".window-body");
  body.scrollTop = body.scrollHeight;
}
document.querySelector("#terminal-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const command = parseCommand(terminalInput.value);
  terminalInput.value = "";
  if (!command.raw) return;
  terminalLine(`snowy ~ % ${command.raw}`, "command");
  if (!command.known) {
    terminalLine("Unknown forecast. Try “help”.");
    return;
  }
  switch (command.name) {
    case "help":
      terminalLine("help     A small map of the place.");
      terminalLine("clear    Clear this terminal.");
      terminalLine("snow     Make it a flurry.");
      terminalLine("calm     Put the wind down.");
      terminalLine("about    About Snowy.");
      terminalLine("github   Open the source code.");
      terminalLine("defrost  Check the seasonal freezer.");
      break;
    case "clear":
      terminalOutput.replaceChildren();
      break;
    case "snow":
      preferences.intensity = "flurry";
      applyWeather();
      persist();
      updateControls();
      terminalLine("Flurry selected. Your desktop knew the risks.");
      break;
    case "calm":
      setWind(0, 0);
      persist();
      terminalLine("Wind: calm. Snow: still very much snow.");
      break;
    case "about":
      terminalLine(
        "Snowy is a little winter for your Mac. Free, open source, and entirely unnecessary.",
      );
      terminalLine("macOS 14+ · Apple silicon");
      break;
    case "github":
      window.open(repositoryURL, "_blank", "noopener,noreferrer");
      terminalLine(repositoryURL);
      break;
    case "defrost":
    case "mariah":
      playMariah();
      break;
  }
  wake();
});

document.addEventListener("keydown", (event) => {
  if (downloadDialog.open || betaDialog.open) return;
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault();
    openWindow("terminal");
    return;
  }
  if (event.key === "Escape" && !event.defaultPrevented) {
    if (gesture) {
      endGesture();
      return;
    }
    if (activeID) closeWindow(activeID);
  }
});
window.addEventListener(
  "resize",
  () => {
    endGesture();
    layoutDirty = true;
    wake();
  },
  { passive: true },
);
window.addEventListener(
  "scroll",
  () => {
    geometryDirty = true;
    pointer = null;
    engine?.resetPointer();
    updateCursor();
    wake();
  },
  { passive: true },
);
window.addEventListener("blur", () => {
  endGesture();
  pointer = null;
  engine?.resetPointer();
  updateCursor();
});
document.addEventListener("visibilitychange", () => {
  endGesture();
  engine?.resetPointer();
  pointer = null;
  lastPhysics = 0;
  lastFrame = 0;
  updateCursor();
  if (document.hidden) {
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
  } else {
    geometryDirty = true;
    drawDirty = true;
    wake();
  }
});
motionQuery.addEventListener("change", () => {
  reducedMotion = motionQuery.matches;
  engine.reducedMotion = reducedMotion;
  windSpring.active = false;
  windSpring.length = windSpring.target;
  engine.resetPointer();
  drawWind();
  drawDirty = true;
  lastPhysics = 0;
  wake();
});

function updateClock() {
  const minute = Math.floor(Date.now() / 60000);
  if (minute === lastMinute) return;
  lastMinute = minute;
  const date = new Date();
  const clock = document.querySelector("#clock");
  clock.textContent = new Intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
  clock.dateTime = date.toISOString();
}
function frame(timestamp) {
  raf = 0;
  if (document.hidden) return;
  const elapsed = lastFrame
    ? Math.min(0.05, (timestamp - lastFrame) / 1000)
    : 1 / 60;
  lastFrame = timestamp;
  if (layoutDirty) layout();
  if (geometryDirty) syncGeometry();
  if (toastUntil && timestamp >= toastUntil) {
    toastUntil = 0;
    toastElement.classList.remove("visible");
  }
  if (windSpring.active) {
    windSpring.velocity +=
      ((windSpring.target - windSpring.length) * 180 -
        windSpring.velocity * 24) *
      elapsed;
    windSpring.length = Math.max(
      0,
      windSpring.length + windSpring.velocity * elapsed,
    );
    if (
      Math.abs(windSpring.length - windSpring.target) < 0.01 &&
      Math.abs(windSpring.velocity) < 0.03
    ) {
      windSpring.length = windSpring.target;
      windSpring.velocity = 0;
      windSpring.active = false;
    }
    drawWind();
  }
  const fps = reducedMotion ? 15 : mobile ? 20 : 30;
  if (!lastPhysics || timestamp - lastPhysics >= 1000 / fps - 0.5) {
    const dt = lastPhysics ? (timestamp - lastPhysics) / 1000 : 1 / fps;
    lastPhysics = timestamp;
    const position =
      pointer && !gesture && (!pointer.touch || sweeping)
        ? {
            x: pointer.clientX - stageClient.left,
            y: pointer.clientY - stageClient.top,
          }
        : null;
    engine.step(dt, position);
    drawDirty = true;
  }
  if (drawDirty && ctx) {
    engine.draw(ctx);
    drawDirty = false;
  }
  updateClock();
  wake();
}

layout();
syncGeometry();
activate(models.get("welcome"));
updateDock();
updateControls();
updateClock();
function resetDownloadPointer() {
  endGesture();
  pointer = null;
  engine.resetPointer();
  updateCursor();
}
setupDownloadFlow({
  onOpen: resetDownloadPointer,
  onSupportOpen() {
    openWindow("letter");
  },
});
Object.defineProperty(window, "SnowyDesktop", {
  value: Object.freeze({
    get engine() {
      return engine;
    },
    get visibleWindowIDs() {
      return [...models.values()]
        .filter((model) => model.visible)
        .map((model) => model.id);
    },
    tidy,
    reset: tidy,
  }),
  configurable: false,
  writable: false,
});
wake();
