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
    await windowsCheckoutReturnCheck();
    results.push({
      run,
      desktop: "passed",
      mobile: "passed",
      reducedMotion: "passed",
      storage: "passed",
      download: "passed",
      support: "passed",
      audio: "passed",
    });
    console.log(
      `Browser check ${run}/${runs}: desktop, mobile, reduced motion, storage, download, support and audio passed.`,
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

async function page(width, height, mobile = false, path = "") {
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
  await send("Network.enable");
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
  await send("Page.navigate", { url: new URL(path, baseURL).href });
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
    assert.ok(
      await p.evaluate('!document.querySelector("#pause-button, #forecast-label")'),
      "The menu has no stop button or snowfall state label",
    );
    // Hold only the simulation clock while testing geometry transport; there is
    // no user-facing pause state or stored preference in the website anymore.
    await p.evaluate(
      "window.__snowyOriginalStep = SnowyDesktop.engine.step; SnowyDesktop.engine.step = () => {}; true",
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
    await p.evaluate(
      "SnowyDesktop.engine.step = window.__snowyOriginalStep; delete window.__snowyOriginalStep; true",
    );
    await p.wait("SnowyDesktop.engine.stats.totalMass > 0");
    await downloadCheck(p, run);
    await supportCheck(p);
    await p.evaluate(`(() => {
      window.__snowyAudioPlays = [];
      HTMLMediaElement.prototype.play = function () {
        window.__snowyAudioPlays.push(this.id);
        return Promise.resolve();
      };
      return true;
    })()`);
    const snowfallBeforeAudio = await p.evaluate(
      'document.querySelector("[data-intensity][aria-pressed=true]").dataset.intensity',
    );
    await p.click('#dock [data-open="terminal"]');
    await p.send("Input.insertText", { text: "mariah" });
    await p.key("Enter", "Enter", 13);
    assert.deepEqual(
      await p.evaluate("window.__snowyAudioPlays"),
      ["mariah-audio"],
      "The Mariah terminal command plays the supplied sound",
    );
    assert.equal(
      await p.evaluate(
        'document.querySelector("[data-intensity][aria-pressed=true]").dataset.intensity',
      ),
      snowfallBeforeAudio,
      "The sound does not change snowfall",
    );
    assert.ok(
      await p.evaluate('!document.body.classList.contains("defrosted")'),
      "The Mariah command no longer starts a weather effect",
    );
    assert.equal(
      await p.evaluate('document.querySelector("#mariah-audio").preload'),
      "none",
      "Audio is not fetched speculatively",
    );
    const media = await p.evaluate(`new Promise(resolve => {
      const audio = new Audio(document.querySelector("#mariah-audio").src);
      audio.preload = "metadata";
      const timeout = setTimeout(() => resolve({ error: "metadata timeout" }), 8000);
      audio.addEventListener("loadedmetadata", () => {
        clearTimeout(timeout);
        resolve({ duration: audio.duration });
      }, { once: true });
      audio.addEventListener("error", () => {
        clearTimeout(timeout);
        resolve({ error: audio.error?.code || "media error" });
      }, { once: true });
    })`);
    assert.ok(Number.isFinite(media.duration) && media.duration > 0,
      "The supplied MP3 is served and decodes successfully: " + JSON.stringify(media));
    await p.click("[data-play-mariah]");
    assert.deepEqual(
      await p.evaluate("window.__snowyAudioPlays"),
      ["mariah-audio", "mariah-audio"],
      "The desktop Mariah interaction plays the same supplied sound",
    );
    await p.evaluate('document.querySelector("#terminal-input").focus()');
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

async function setAmount(p, selector, value) {
  await p.evaluate(
    `document.querySelector(${JSON.stringify(selector)}).focus(); document.querySelector(${JSON.stringify(selector)}).select(); true`,
  );
  await p.send("Input.insertText", { text: value });
  await p.frame();
}

async function downloadCheck(p, run, mobile = false) {
  await p.evaluate(`(() => {
    window.__snowyDownloads = [];
    window.__snowyCheckoutRequests = [];
    const originalFetch = window.fetch.bind(window);
    window.fetch = async (url, options) => {
      if (url === '/api/checkout') {
        window.__snowyCheckoutRequests.push(JSON.parse(options.body));
        return Response.json({error:'Payments are temporarily unavailable. You can still download for $0.'}, {status:503});
      }
      return originalFetch(url, options);
    };
    const click = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () {
      if (this.href.includes("/releases/") && [".dmg", ".exe"].some(extension => this.href.endsWith(extension))) {
        window.__snowyDownloads.push(this.href);
        return;
      }
      return click.call(this);
    };
    return true;
  })()`);
  const windowsBefore = await p.evaluate("SnowyDesktop.visibleWindowIDs");
  await p.click("#windows-download");
  assert.ok(await p.evaluate('document.querySelector("#download-dialog").open && !document.querySelector("#windows-download-options").hidden'));
  assert.equal(await p.evaluate('document.activeElement?.id'), "download-amount");
  assert.equal(await p.evaluate('document.querySelector("#download-amount").value'), "2.99");
  assert.deepEqual(
    await p.evaluate('[...document.querySelectorAll("#windows-download-options button[data-build]")].map(button => [button.dataset.build, button.textContent.trim()])'),
    [["windows-x64", "Download x64"], ["windows-arm64", "Download ARM"]],
  );
  await p.key("Enter", "Enter", 13);
  assert.equal(await p.evaluate("document.activeElement?.dataset.build"), "windows-x64");
  assert.equal(await p.evaluate("window.__snowyCheckoutRequests.length"), 0);
  await p.click('[data-build="windows-x64"]');
  assert.equal(await p.evaluate("window.__snowyCheckoutRequests.at(-1).context"), "windows-x64");
  assert.equal(await p.evaluate("window.__snowyCheckoutRequests.at(-1).amountCents"), 299);
  await p.click("#download-free");
  const windowsBetaOpen = 'document.querySelector("#beta-dialog").open && !document.querySelector("#download-dialog").open && !document.querySelector("#windows-beta-description").hidden && document.querySelector("#mac-beta-description").hidden';
  assert.ok(await p.evaluate(windowsBetaOpen));
  await p.key("Escape", "Escape", 27);
  assert.equal(await p.evaluate("document.activeElement?.id"), "windows-download");
  await p.click("#windows-download");
  await p.click('#download-dialog [data-amount="0"]');
  if (run === 1) await p.screenshot(mobile ? "mobile-windows-download" : "desktop-windows-download");
  await p.click('[data-build="windows-arm64"]');
  assert.ok(await p.evaluate(windowsBetaOpen));
  if (run === 1) await p.screenshot(mobile ? "mobile-windows-beta" : "desktop-windows-beta");
  assert.equal(await p.evaluate("window.__snowyCheckoutRequests.length"), 1);
  assert.deepEqual(
    await p.evaluate('window.__snowyDownloads.map(url => url.split("/").at(-1))'),
    ["Snowy-Setup-x64.exe", "Snowy-Setup-arm64.exe"],
    "The free fallback keeps its build and $0 starts the selected installer without checkout",
  );
  await p.evaluate("window.__snowyDownloads = []; window.__snowyCheckoutRequests = [];");
  await p.key("Escape", "Escape", 27);
  assert.equal(await p.evaluate("document.activeElement?.id"), "windows-download");
  await p.evaluate('location.hash = "download-windows"');
  await p.wait('document.querySelector("#download-dialog").open && !document.querySelector("#windows-download-options").hidden');
  await p.key("Escape", "Escape", 27);
  await p.evaluate('history.replaceState(null, "", location.pathname)');
  assert.deepEqual(await p.evaluate("SnowyDesktop.visibleWindowIDs"), windowsBefore);
  await p.click("#download");
  assert.ok(await p.evaluate('document.querySelector("#download-dialog").open && document.querySelector("#windows-download-options").hidden'));
  assert.equal(
    await p.evaluate('document.querySelector("#download-amount").value'),
    "2.99",
    "The download window suggests $2.99",
  );
  assert.ok(
    await p.evaluate('document.querySelector("#download-dialog").contains(document.activeElement)'),
    "Keyboard focus enters the download window",
  );
  const modal = await p.bounds("#download-dialog");
  assert.ok(
    await p.evaluate('(() => { const r=document.querySelector("#download-dialog").getBoundingClientRect(); return r.x>=0 && r.right<=innerWidth && r.y>=0 && r.bottom<=innerHeight; })()'),
    `The ${mobile ? "phone" : "desktop"} download window fits the viewport`,
  );
  assert.ok(modal.width > 200 && modal.height > 200);
  if (run === 1) await p.screenshot(mobile ? "mobile-download" : "desktop-download");
  await p.key("Escape", "Escape", 27);
  assert.ok(!(await p.evaluate('document.querySelector("#download-dialog").open')));
  assert.equal(
    await p.evaluate("document.activeElement?.id"),
    "download",
    "Escape restores focus to the download button",
  );
  assert.deepEqual(
    await p.evaluate("SnowyDesktop.visibleWindowIDs"),
    windowsBefore,
    "Dismissing the dialog does not close a desktop window",
  );

  await p.click("#download");
  await p.click("#download-submit");
  assert.equal(await p.evaluate("window.__snowyCheckoutRequests.at(-1).amountCents"), 299);
  assert.match(
    await p.evaluate('document.querySelector("#download-feedback").textContent'),
    /aren.t available|not available|unavailable|not connected|coming soon/i,
    "Provider failure preserves a free fallback",
  );
  assert.deepEqual(await p.evaluate("window.__snowyDownloads"), []);
  assert.equal(await p.evaluate("location.href"), baseURL);

  await p.evaluate('document.querySelector("#download-feedback").textContent = ""; true');
  await setAmount(p, "#download-amount", "-1");
  await p.click("#download-submit");
  assert.ok(
    await p.evaluate('!document.querySelector("#download-form").checkValidity() || !!document.querySelector("#download-feedback").textContent.trim()'),
    "Invalid amounts show feedback or native validation",
  );
  assert.deepEqual(await p.evaluate("window.__snowyDownloads"), []);

  await p.click('#download-dialog [data-amount="0"]');
  await p.click("#download-submit");
  assert.deepEqual(
    await p.evaluate("window.__snowyDownloads"),
    ["https://github.com/soloiaros/snowy-mac/releases/latest/download/Snowy-macOS-arm64.dmg"],
    "$0 immediately starts the DMG download without checkout",
  );
  assert.ok(await p.evaluate('document.querySelector("#beta-dialog").open && !document.querySelector("#download-dialog").open && !document.querySelector("#mac-beta-description").hidden && document.querySelector("#windows-beta-description").hidden'),
    "Starting the download replaces the price sheet with the beta notice");
  assert.ok(await p.evaluate('document.querySelector("#beta-actions button") === document.activeElement'),
    "The beta notice focuses its dismiss button");
  await p.key("Escape", "Escape", 27);
  assert.ok(!(await p.evaluate('document.querySelector("#beta-dialog").open')));
  assert.deepEqual(await p.evaluate("SnowyDesktop.visibleWindowIDs"), windowsBefore,
    "Dismissing the beta notice leaves the desktop windows alone");
  assert.equal(await p.evaluate("document.activeElement?.id"), "download");
  await p.click("#download");
  await setAmount(p, "#download-amount", "5");
  await p.click("#download-submit");
  await p.click("#download-free");
  assert.equal(
    (await p.evaluate("window.__snowyDownloads")).length,
    2,
    "The free fallback starts a download even when a positive amount was entered",
  );
  assert.ok(await p.evaluate('document.querySelector("#beta-dialog").open'));
  await p.click("#beta-actions button");
  const checkoutRequests = client.events.filter(
    (event) => event.sessionId === p.sessionId &&
      event.method === "Network.requestWillBeSent" &&
      /(?:^|\.)polar\.sh$/.test(new URL(event.params.request.url).hostname),
  );
  assert.deepEqual(checkoutRequests, [], "The browser calls our API rather than Polar directly");
}

async function supportCheck(p) {
  await p.click('.menu-right [data-open="letter"]');
  await setAmount(p, "#support-amount", "2");
  await p.evaluate('document.querySelector("#support-form").requestSubmit(); true');
  await p.frame();
  assert.match(
    await p.evaluate('document.querySelector("#support-feedback").textContent'),
    /aren.t available|not available|unavailable|not connected|coming soon/i,
    "Support failure never claims a donation succeeded",
  );
  assert.equal(await p.evaluate("location.href"), baseURL);
  await setAmount(p, "#support-amount", "0");
  await p.evaluate('document.querySelector("#support-form").requestSubmit(); true');
  await p.frame();
  assert.equal((await p.evaluate("window.__snowyDownloads")).length, 2,
    "A zero support amount does not initiate another download");
  await p.click('#window-letter [data-close]');

  const requestCount = await p.evaluate("window.__snowyCheckoutRequests.length");
  await p.evaluate('location.hash = "#drop-some-coins"; true');
  await p.wait('!document.querySelector("#support-feedback").hidden && !document.querySelector("#support-amount").disabled');
  const requests = await p.evaluate(`window.__snowyCheckoutRequests.slice(${requestCount})`);
  assert.equal(requests.length, 1, "The menu link starts exactly one checkout");
  assert.equal(requests[0].amountCents, 499);
  assert.equal(requests[0].context, "support");
  assert.equal(await p.evaluate("location.href"), baseURL, "The checkout marker is consumed");
  assert.ok(await p.evaluate('SnowyDesktop.visibleWindowIDs.includes("letter")'));
  assert.equal(await p.evaluate('document.querySelector("#support-amount").value'), "4.99",
    "If checkout is unavailable, the support form keeps the amount");
  await p.click('#window-letter [data-close]');
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
    await downloadCheck(p, run, true);
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

async function windowsCheckoutReturnCheck() {
  const p = await page(390, 844, true, "?payment_cancelled=1&build=windows-arm64");
  try {
    assert.ok(await p.evaluate('document.querySelector("#download-dialog").open && !document.querySelector("#windows-download-options").hidden'));
    assert.equal(await p.evaluate('document.querySelector("#download-amount").value'), "0");
    assert.match(await p.evaluate('document.querySelector("#download-feedback").textContent'), /checkout cancelled/i);
    assert.equal(await p.evaluate("location.href"), baseURL);
  } finally {
    await p.close();
  }
}
