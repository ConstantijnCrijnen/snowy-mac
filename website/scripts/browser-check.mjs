import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { access, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const out = resolve(root, ".local-artifacts/browser-qa/functional");
const baseURL = "http://127.0.0.1:4173/";
const runs = process.argv.includes("--runs=3") ? 3 : 1;
const candidates = [
  process.env.CHROME_BIN,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome",
].filter(Boolean);
let executable;
for (const candidate of candidates) {
  try {
    await access(candidate);
    executable = candidate;
    break;
  } catch {}
}
if (!executable)
  throw new Error(
    "Set CHROME_BIN to Chrome or Chromium. This check always uses a new temporary headless profile.",
  );
if (!(await fetch(baseURL)).ok)
  throw new Error("Start npm --prefix website run dev first.");
await mkdir(out, { recursive: true });
const profile = await mkdtemp(resolve(tmpdir(), "snowy-browser-check-"));
const child = spawn(
  executable,
  [
    "--headless=new",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-default-apps",
    "--disable-sync",
    "--disable-gpu",
    "--mute-audio",
    "about:blank",
  ],
  { stdio: ["ignore", "ignore", "pipe"] },
);
let client;
const results = [];
try {
  const address = await new Promise((resolveAddress, reject) => {
    let buffer = "";
    const timeout = setTimeout(
      () => reject(new Error("Headless Chrome did not start.")),
      15000,
    );
    child.once("error", reject);
    child.stderr.on("data", (chunk) => {
      buffer = (buffer + chunk.toString()).slice(-16000);
      const match = buffer.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) {
        clearTimeout(timeout);
        resolveAddress(match[1]);
      }
    });
  });
  client = await connect(address);
  for (let run = 1; run <= runs; run++) {
    await desktopCheck(run);
    await mobileCheck(run);
    results.push({
      run,
      desktop: "passed",
      mobile: "passed",
      reducedMotion: "passed",
      storage: "passed",
    });
    console.log(
      `Browser check ${run}/${runs}: desktop, mobile, reduced motion and storage passed.`,
    );
  }
  await writeFile(
    resolve(out, "results.json"),
    JSON.stringify(results, null, 2) + "\n",
  );
} finally {
  if (client) {
    try {
      await client.send("Browser.close");
    } catch {}
    client.socket.close();
  }
  child.kill("SIGTERM");
  await new Promise((resolveExit) => {
    if (child.exitCode !== null) resolveExit();
    else {
      child.once("exit", resolveExit);
      setTimeout(resolveExit, 3000);
    }
  });
  // This exact temporary profile was created above; no user browser data is accessed.
  await rm(profile, { recursive: true, force: true });
}

async function connect(address) {
  const socket = new WebSocket(address),
    pending = new Map(),
    events = [];
  let sequence = 0;
  await new Promise((yes, no) => {
    socket.addEventListener("open", yes, { once: true });
    socket.addEventListener("error", no, { once: true });
  });
  socket.addEventListener("message", (event) => {
    const value = JSON.parse(event.data);
    if (value.id) {
      const task = pending.get(value.id);
      if (!task) return;
      clearTimeout(task.timeout);
      pending.delete(value.id);
      value.error
        ? task.reject(new Error(value.error.message))
        : task.resolve(value.result);
    } else events.push(value);
  });
  return {
    socket,
    events,
    send(method, params = {}, sessionId) {
      const id = ++sequence;
      return new Promise((resolveMessage, reject) => {
        const timeout = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }, 15000);
        pending.set(id, { resolve: resolveMessage, reject, timeout });
        socket.send(
          JSON.stringify({
            id,
            method,
            params,
            ...(sessionId ? { sessionId } : {}),
          }),
        );
      });
    },
  };
}

async function page(width, height, mobile = false) {
  const { browserContextId } = await client.send("Target.createBrowserContext");
  const { targetId } = await client.send("Target.createTarget", {
    url: "about:blank",
    browserContextId,
  });
  const { sessionId } = await client.send("Target.attachToTarget", {
    targetId,
    flatten: true,
  });
  const send = (method, params = {}) => client.send(method, params, sessionId);
  const evaluate = async (expression) => {
    const result = await send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails)
      throw new Error(
        result.exceptionDetails.text +
          ": " +
          result.exceptionDetails.exception?.description,
      );
    return result.result.value;
  };
  const wait = async (expression) => {
    const until = Date.now() + 10000;
    while (Date.now() < until) {
      if (await evaluate(expression)) return;
      await new Promise((resolveWait) => setTimeout(resolveWait, 40));
    }
    throw new Error(`Condition did not become true: ${expression}`);
  };
  await send("Page.enable");
  await send("Runtime.enable");
  await send("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 1,
    mobile,
  });
  if (mobile)
    await send("Emulation.setTouchEmulationEnabled", {
      enabled: true,
      maxTouchPoints: 1,
    });
  await send("Page.navigate", { url: baseURL });
  await wait(
    '!!window.SnowyDesktop?.engine && document.readyState === "complete"',
  );
  const frame = () =>
    evaluate(
      "new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))))",
    );
  const bounds = (selector) =>
    evaluate(
      `(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height,bottom:r.bottom,right:r.right}; })()`,
    );
  const click = async (selector) => {
    const b = await bounds(selector),
      x = b.x + b.width / 2,
      y = b.y + b.height / 2;
    await send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
    await send("Input.dispatchMouseEvent", {
      type: "mousePressed",
      x,
      y,
      button: "left",
      clickCount: 1,
    });
    await send("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x,
      y,
      button: "left",
      clickCount: 1,
    });
    await frame();
  };
  const key = async (key, code = key, virtualKey = 0) => {
    await send("Input.dispatchKeyEvent", {
      type: "keyDown",
      key,
      code,
      windowsVirtualKeyCode: virtualKey,
      nativeVirtualKeyCode: virtualKey,
      ...(key === "Enter" ? { text: "\r", unmodifiedText: "\r" } : {}),
    });
    await send("Input.dispatchKeyEvent", {
      type: "keyUp",
      key,
      code,
      windowsVirtualKeyCode: virtualKey,
    });
    await frame();
  };
  const screenshot = async (name) => {
    const result = await send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      resolve(out, name + ".png"),
      Buffer.from(result.data, "base64"),
    );
  };
  return {
    send,
    evaluate,
    wait,
    frame,
    bounds,
    click,
    key,
    screenshot,
    close: () =>
      client.send("Target.disposeBrowserContext", { browserContextId }),
    sessionId,
  };
}

async function desktopCheck(run) {
  const p = await page(1440, 960);
  try {
    assert.ok(
      await p.evaluate("document.documentElement.scrollWidth <= innerWidth"),
      "Desktop overflow",
    );
    assert.ok(
      await p.evaluate("SnowyDesktop.engine.stats.totalMass > 0"),
      "Initial snow is real material",
    );
    assert.ok(
      await p.evaluate(
        'document.querySelector("#download").getBoundingClientRect().bottom < document.querySelector("#window-welcome").getBoundingClientRect().bottom',
      ),
      "Download remains visible",
    );
    await p.wait("SnowyDesktop.engine.stats.falling > 0");
    if (run === 1) await p.screenshot("desktop");
    await p.click("#pause-button");
    assert.equal(
      await p.evaluate(
        'document.querySelector("#pause-button").getAttribute("aria-pressed")',
      ),
      "true",
    );
    const before = await p.evaluate("SnowyDesktop.engine.stats.totalMass");
    const bar = await p.bounds("#window-welcome .titlebar");
    const start = { x: bar.x + bar.width / 2, y: bar.y + bar.height / 2 };
    await p.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...start });
    await p.send("Input.dispatchMouseEvent", {
      type: "mousePressed",
      ...start,
      button: "left",
      clickCount: 1,
    });
    for (let i = 1; i <= 8; i++) {
      await p.send("Input.dispatchMouseEvent", {
        type: "mouseMoved",
        x: start.x + i * 60,
        y: start.y,
        button: "left",
        buttons: 1,
      });
      await p.frame();
    }
    await p.send("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x: start.x + 480,
      y: start.y,
      button: "left",
      clickCount: 1,
    });
    await p.frame();
    const moved = await p.bounds("#window-welcome");
    assert.ok(
      moved.x > 800,
      "Window moved through the actual title-bar gesture",
    );
    const stats = await p.evaluate("SnowyDesktop.engine.stats");
    assert.ok(
      stats.loose + stats.pending > 0,
      "Carried cap meets the other window wall",
    );
    assert.ok(
      Math.abs(stats.totalMass - before) < Math.max(1, before * 0.01),
      "Dragging preserves material",
    );
    await p.evaluate("SnowyDesktop.tidy()");
    await p.frame();
    await p.click("#window-weather [data-close]");
    assert.ok(
      !(await p.evaluate('SnowyDesktop.visibleWindowIDs.includes("weather")')),
    );
    await p.click('#dock [data-open="weather"]');
    assert.ok(
      await p.evaluate('SnowyDesktop.visibleWindowIDs.includes("weather")'),
    );
    await p.click("#clear-snow");
    assert.ok(await p.evaluate("SnowyDesktop.engine.stats.totalMass < .001"));
    await p.click("#pause-button");
    await p.wait("SnowyDesktop.engine.stats.totalMass > 0");
    await p.click('#dock [data-open="terminal"]');
    await p.send("Input.insertText", { text: "mariah" });
    await p.key("Enter", "Enter", 13);
    assert.ok(
      await p.evaluate('document.body.classList.contains("defrosted")'),
    );
    await p.send("Input.insertText", {
      text: '<img src=x onerror="window.__snowy_xss=1">',
    });
    await p.key("Enter", "Enter", 13);
    assert.ok(
      await p.evaluate(
        '!window.__snowy_xss && !document.querySelector("#terminal-output img")',
      ),
      "Terminal output remains text",
    );
    await p.click('#window-weather [data-tool="shovel"]');
    await p.click('#window-weather [data-intensity="light"]');
    await p.send("Page.reload", { ignoreCache: true });
    await p.wait(
      '!!window.SnowyDesktop?.engine && document.readyState === "complete"',
    );
    assert.equal(await p.evaluate("SnowyDesktop.engine.tool"), "shovel");
    assert.equal(
      await p.evaluate(
        'document.querySelector("[data-intensity=light]").getAttribute("aria-pressed")',
      ),
      "true",
    );
    await p.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-motion", value: "reduce" }],
    });
    await p.wait(
      "SnowyDesktop.engine.reducedMotion && SnowyDesktop.engine.stats.falling === 0",
    );
    assert.ok(
      await p.evaluate("SnowyDesktop.engine.stats.totalMass > 0"),
      "Reduced motion retains material",
    );
    const errors = client.events.filter(
      (e) =>
        e.sessionId === p.sessionId && e.method === "Runtime.exceptionThrown",
    );
    assert.deepEqual(errors, [], "No desktop runtime exceptions");
  } catch (error) {
    console.error(
      "Desktop check state:",
      await p.evaluate(
        '({active:document.activeElement?.id,value:document.querySelector("#terminal-input").value,output:document.querySelector("#terminal-output").textContent,windows:SnowyDesktop.visibleWindowIDs})',
      ),
    );
    await p.screenshot("desktop-failure");
    throw error;
  } finally {
    await p.close();
  }
}

async function mobileCheck(run) {
  const p = await page(390, 844, true);
  try {
    assert.ok(
      await p.evaluate("document.documentElement.scrollWidth <= innerWidth"),
      "Phone overflow",
    );
    const download = await p.bounds("#download");
    assert.ok(
      download.x >= 0 && download.right <= 390 && download.bottom < 700,
      "Phone download is visible and readable",
    );
    if (run === 1) await p.screenshot("mobile");
    await p.click("#sweep-mode");
    assert.ok(
      await p.evaluate('document.body.classList.contains("sweep-mode")'),
    );
    await p.click("#explore-mode");
    assert.ok(
      !(await p.evaluate('document.body.classList.contains("sweep-mode")')),
    );
    await p.click('#dock [data-open="weather"]');
    await p.wait(
      'document.querySelector("#window-weather").getBoundingClientRect().bottom < innerHeight - 65',
    );
    await p.frame();
    const aligned = await p.evaluate(
      '(() => { const d=document.querySelector("#dock").getBoundingClientRect(), r=document.querySelector("#desktop").getBoundingClientRect(); return Math.abs(SnowyDesktop.engine.profile("dock").body.y-(d.top-r.top)) < 1; })()',
    );
    assert.ok(aligned, "Fixed Dock collider stays aligned after mobile scroll");
    await p.click('#window-weather [data-tool="shovel"]');
    assert.equal(await p.evaluate("SnowyDesktop.engine.tool"), "shovel");
    if (run === 1) await p.screenshot("mobile-weather");
    const errors = client.events.filter(
      (e) =>
        e.sessionId === p.sessionId && e.method === "Runtime.exceptionThrown",
    );
    assert.deepEqual(errors, [], "No phone runtime exceptions");
  } finally {
    await p.close();
  }
}
