// WrightDisc — page logic.
// Drop audio -> decode (Web Audio, 44.1 kHz) -> arrange into
// groups -> encode each track with the atracdenc Wasm module ->
// author the ISO with the proven core -> download.
import { buildDisc } from "./core/author.js";
import { parseAtracDisc } from "./core/isoread.js";
import { cleanMp3 } from "./core/tagclean.js";
import { makeZip } from "./core/zip.js";
import { writeNdb } from "./core/ndb.js";
import { isoSectorCount } from "./core/iso.js";
import { BLANKS, SESSION_OVERHEAD_SECTORS } from "./core/capacity.js";

const $ = (id) => document.getElementById(id);
const logEl = $("log");
function log(msg, cls) {
  const line = document.createElement("div");
  if (cls) line.className = cls;
  line.textContent = msg;
  logEl.appendChild(line);
  logEl.scrollTop = logEl.scrollHeight;
}
function clearLog() { logEl.textContent = ""; }

// ---------------- the drive stage (v6 choreography) ----------------
const stageEl = $("stage");
const stageStatus = $("stageStatus");

// The disc is drawn on a CANVAS (see drawDisc below): five DOM
// builds of the spinning disc all grew a black bar on GlitchedDot's
// OCLP-patched 2014 MacBook's compositor, whatever CSS trick was
// used. One flat bitmap has nothing to split.
const discCanvas = $("discCanvas");
const dctx = discCanvas ? discCanvas.getContext("2d") : null;
const DISC_PX = 720;
let discLabel = "ATRAC CD";
let burnFrac = 0;
let laserAngleDeg = 90;
let laserOn = false, laserLevel = 1;
let sheenAngle = 0;
let squashY = 0.94, squashYTarget = 0.94;

function setBurn(p) {
  // True CD tracking: the spiral packs a constant amount of data
  // per unit of AREA, so with fraction q of the data written, the
  // laser's radius is sqrt(rIn^2 + q * (rOut^2 - rIn^2)) -- it
  // moves quickly at first and ever more slowly toward the rim,
  // exactly like the real pickup. drawDisc() applies this.
  burnFrac = Math.max(0, Math.min(1, p));
}

// Laser position: 8 stops, 45 degrees apart, remembered per user
// (localStorage) across page loads.
const laserPosEl = $("laserPos");
(function initLaserPos() {
  let deg = 90;
  try {
    const saved = window.localStorage.getItem("atrac-laser-pos");
    if (saved !== null && saved !== "" && !isNaN(parseInt(saved, 10)))
      deg = parseInt(saved, 10);
  } catch (e) { /* storage unavailable: keep the default */ }
  laserAngleDeg = deg;
  if (laserPosEl) laserPosEl.value = String(deg);
  if (laserPosEl) laserPosEl.addEventListener("change", () => {
    laserAngleDeg = parseInt(laserPosEl.value, 10) || 0;
    try {
      window.localStorage.setItem("atrac-laser-pos", laserPosEl.value);
    } catch (e) { /* ignore */ }
    drawDisc();
  });
})();

// Subtle, fully random laser flicker (JS-driven: CSS keyframes are
// periodic, and she asked for random). On the canvas build the
// flicker just re-rolls the laser's alpha; a rAF loop turns the
// sheen and redraws while writing.
let flickerTimer = null;
let flickerDelay = null;
let burnAnim = 0, burnLast = 0;
function flickerStep() {
  if (!stageEl || !stageEl.classList.contains("burning")) {
    flickerTimer = null;
    return;
  }
  laserLevel = 0.88 + Math.random() * 0.12;
  flickerTimer = setTimeout(flickerStep, 50 + Math.random() * 160);
}
function burnStep(ts) {
  if (!burnAnim) return;
  if (burnLast) sheenAngle = (sheenAngle + (ts - burnLast) / 1000 * 150) % 360;
  burnLast = ts;
  drawDisc();
  burnAnim = requestAnimationFrame(burnStep);
}
function startFlicker() {
  laserOn = true;
  if (flickerTimer === null) flickerStep();
  if (!burnAnim) { burnLast = 0; burnAnim = requestAnimationFrame(burnStep); }
}
function stopFlicker() {
  laserOn = false;
  if (flickerDelay !== null) { clearTimeout(flickerDelay); flickerDelay = null; }
  if (flickerTimer !== null) { clearTimeout(flickerTimer); flickerTimer = null; }
  if (burnAnim) { cancelAnimationFrame(burnAnim); burnAnim = 0; }
  drawDisc();
}
// ---------------- stage choreography ----------------
const discYEl = $("discY");
const chipLayerEl = $("chipLayer");
const sceneEl = $("scene");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const discShadowEl = document.querySelector(".discShadow");
const dragLayerEl = $("dragLayer");
const dragShadowEl = $("dragShadow");
let spinAngle = 0, spinRaf = 0, spinLast = 0, spinning = false;
let lifted = false, liftX = 0, liftY = 0, liftSize = 0; // full-screen drag state (below)
let liftVX = 0, liftVY = 0, dragging = false, springRaf = 0, springLast = 0;
const SPIN_DEG_PER_SEC = 80; // one full turn per 4.5 s, as approved

// Paint the whole disc into the canvas: base, rainbow sheen, laser,
// hub and label on the front; plain silver on the back. The spin
// squash, the tilt squash, the hover bob and the spin shading are
// all applied to the drawing, never to the element -- the canvas
// itself is a single flat bitmap with no CSS transform at all.
function drawDisc() {
  if (!dctx || !stageEl) return;
  const S = DISC_PX, C = S / 2, R = S / 2 - 6;
  squashY += (squashYTarget - squashY) * 0.10;
  if (Math.abs(squashYTarget - squashY) < 0.001) squashY = squashYTarget;
  const bob = stageEl.classList.contains("idle")
    ? Math.sin(performance.now() / 2600 * Math.PI * 2) * S * 0.026 : 0;
  const c = Math.cos(spinAngle * Math.PI / 180), a = Math.abs(c);
  const back = c < 0;
  dctx.clearRect(0, 0, S, S);
  dctx.save();
  dctx.translate(C, C + bob);
  dctx.scale(Math.max(a, 0.02), squashY);
  const disc = (fill) => {
    dctx.beginPath(); dctx.arc(0, 0, R, 0, Math.PI * 2);
    dctx.fillStyle = fill; dctx.fill();
  };
  const g = dctx.createRadialGradient(0, 0, 0, 0, 0, R);
  if (back) {
    g.addColorStop(0, "#20242b"); g.addColorStop(0.07, "#20242b");
    g.addColorStop(0.075, "#3a3f49"); g.addColorStop(0.12, "#3a3f49");
    g.addColorStop(0.13, "#c8cedb"); g.addColorStop(0.55, "#dfe4ef");
    g.addColorStop(0.92, "#b9c0cf"); g.addColorStop(1, "#454c5c");
  } else {
    g.addColorStop(0, "#20242b"); g.addColorStop(0.17, "#20242b");
    g.addColorStop(0.175, "#2b3038"); g.addColorStop(0.21, "#2b3038");
    g.addColorStop(0.225, "rgba(215,222,240,0.20)");
    g.addColorStop(0.97, "rgba(215,222,240,0.20)");
    g.addColorStop(0.98, "#3a4150"); g.addColorStop(1, "#3a4150");
  }
  disc(g);
  try {
    const cg = dctx.createConicGradient(
      (back ? 200 : sheenAngle) * Math.PI / 180, 0, 0);
    if (back) {
      cg.addColorStop(0, "rgba(0,0,0,0)");
      cg.addColorStop(0.11, "rgba(255,120,120,0.13)");
      cg.addColorStop(0.31, "rgba(120,255,170,0.11)");
      cg.addColorStop(0.53, "rgba(120,170,255,0.13)");
      cg.addColorStop(0.72, "rgba(0,0,0,0)");
      cg.addColorStop(0.89, "rgba(255,255,255,0.10)");
      cg.addColorStop(1, "rgba(0,0,0,0)");
    } else {
      const stops = [
        [0, "rgba(0,0,0,0)"], [0.07, "rgba(255,90,90,0.20)"],
        [0.15, "rgba(255,200,80,0.20)"], [0.24, "rgba(120,255,140,0.18)"],
        [0.33, "rgba(80,180,255,0.22)"], [0.43, "rgba(190,120,255,0.20)"],
        [0.53, "rgba(0,0,0,0)"], [0.65, "rgba(255,255,255,0.10)"],
        [0.76, "rgba(0,0,0,0)"], [0.89, "rgba(120,220,255,0.14)"],
        [1, "rgba(0,0,0,0)"]];
      for (const [o, col] of stops) cg.addColorStop(o, col);
    }
    disc(cg);
  } catch (e) { /* no conic gradient support: sheen skipped */ }
  if (a < 0.999) disc(`rgba(0,0,0,${((1 - a) * 0.30).toFixed(3)})`);
  if (!back) {
    if (laserOn) {
      // Drawn under the hub, as the DOM original had it.
      const rIn = R * (31 / 111), rOut = R * (105 / 111);
      const rr = Math.sqrt(rIn * rIn + burnFrac * (rOut * rOut - rIn * rIn));
      const th = laserAngleDeg * Math.PI / 180;
      const lx = Math.cos(th) * rr, ly = Math.sin(th) * rr;
      const lr = R * 0.055;
      const lg = dctx.createRadialGradient(lx, ly, 0, lx, ly, lr);
      lg.addColorStop(0, "rgba(255,0,0,0.95)");
      lg.addColorStop(0.28, "rgba(255,64,64,0.90)");
      lg.addColorStop(0.47, "rgba(255,110,50,0.70)");
      lg.addColorStop(0.70, "rgba(255,150,110,0.35)");
      lg.addColorStop(1, "rgba(255,150,110,0)");
      dctx.save();
      dctx.globalAlpha = laserLevel;
      dctx.beginPath(); dctx.arc(lx, ly, lr, 0, Math.PI * 2);
      dctx.fillStyle = lg; dctx.fill();
      dctx.restore();
    }
    const hr = R * 0.387;
    const hg = dctx.createRadialGradient(-hr * 0.3, -hr * 0.4, hr * 0.1, 0, 0, hr);
    hg.addColorStop(0, "#2c313b"); hg.addColorStop(0.7, "#191d23");
    hg.addColorStop(1, "#191d23");
    dctx.beginPath(); dctx.arc(0, 0, hr, 0, Math.PI * 2);
    dctx.fillStyle = hg; dctx.fill();
    dctx.lineWidth = 2; dctx.strokeStyle = "rgba(255,255,255,0.14)";
    dctx.stroke();
    dctx.fillStyle = "#eef1ff";
    dctx.textAlign = "center"; dctx.textBaseline = "middle";
    const fs = S * 0.062;
    dctx.font = `700 ${fs}px system-ui, sans-serif`;
    const maxW = hr * 1.78;
    const words = String(discLabel || "ATRAC CD").split(/\s+/);
    const lines = [];
    let line = "";
    for (const w of words) {
      const t = line ? line + " " + w : w;
      if (dctx.measureText(t).width > maxW && line) { lines.push(line); line = w; }
      else line = t;
    }
    if (line) lines.push(line);
    const shown = lines.slice(0, 3);
    const lh = fs * 1.25, subFs = S * 0.047;
    const totalH = shown.length * lh + subFs * 1.5;
    let ty = -totalH / 2 + lh / 2;
    for (const ln of shown) { dctx.fillText(ln, 0, ty); ty += lh; }
    dctx.font = `${subFs}px system-ui, sans-serif`;
    dctx.fillStyle = "#aab3d6";
    dctx.fillText("ATRAC3+ · 64 kbps", 0, ty + subFs * 0.4);
  }
  dctx.restore();
  if (discShadowEl)
    discShadowEl.style.transform =
      `translate(-50%, -50%) scaleX(${(0.35 + 0.65 * a).toFixed(3)})`;
  if (dragShadowEl && lifted) {
    // The roaming shadow: same geometry as the home shadow --
    // 0.78 of the disc wide, centered 0.66 of a disc below center,
    // narrowing as the disc turns edge-on.
    const swd = liftSize * 0.78;
    dragShadowEl.style.left =
      (liftX + liftSize / 2 - swd / 2).toFixed(1) + "px";
    dragShadowEl.style.top =
      (liftY + liftSize * 1.16 - liftSize * 0.052).toFixed(1) + "px";
    dragShadowEl.style.transform =
      `scaleX(${(0.35 + 0.65 * a).toFixed(3)})`;
  }
}

// Keep redrawing for a while after a phase change, so the tilt
// squash can glide to its new value while nothing else animates.
let kickUntil = 0, kickRunning = false;
function kickDraws(ms = 1300) {
  kickUntil = Math.max(kickUntil, performance.now() + ms);
  if (!kickRunning) { kickRunning = true; requestAnimationFrame(kickStep); }
}
function kickStep() {
  drawDisc();
  if (performance.now() < kickUntil) requestAnimationFrame(kickStep);
  else kickRunning = false;
}
function spinStep(ts) {
  if (!spinning) return;
  if (spinLast) spinAngle = (spinAngle + (ts - spinLast) / 1000 * SPIN_DEG_PER_SEC) % 360;
  spinLast = ts;
  drawDisc();
  spinRaf = requestAnimationFrame(spinStep);
}
function startIdleSpin() {
  if (spinning) return;
  spinning = true; spinLast = 0;
  spinRaf = requestAnimationFrame(spinStep);
}
function stopIdleSpin() {
  spinning = false;
  if (spinRaf) cancelAnimationFrame(spinRaf);
  spinLast = 0;
}
// ---------------- playful drag (GlitchedDot, 2026-11-05) ----------------
// At idle the disc is a toy: grab it and it LIFTS OUT of the scene
// into a full-screen fixed layer, so it can be dragged anywhere on
// the screen; let go and it SPRINGS home on an underdamped spring
// -- a boing, never a snap. The canvas stays one flat bitmap the
// whole time (it is reparented, never rebuilt), and its roaming
// shadow is a plain ellipse div in the same layer, positioned by
// drawDisc() with the home shadow's geometry. Idle only:
// stageLoad() calls resetDrag() so the build choreography always
// starts from an exact, docked home.
const reduceMotion =
  window.matchMedia("(prefers-reduced-motion: reduce)").matches;
function homeRect() {
  // Where the canvas sits when docked, in viewport coordinates:
  // #discY is a 0x0 anchor and the canvas hangs off it by
  // -17.35cqw with a 34.7cqw width (1 cqw = 1% of scene width).
  const yr = discYEl.getBoundingClientRect();
  const sw = sceneEl.getBoundingClientRect().width;
  return { x: yr.left - sw * 0.1735, y: yr.top - sw * 0.1735, s: sw * 0.347 };
}
function applyLift() {
  discCanvas.style.left = liftX.toFixed(1) + "px";
  discCanvas.style.top = liftY.toFixed(1) + "px";
}
function liftDisc() {
  const r = discCanvas.getBoundingClientRect();
  lifted = true;
  liftX = r.left; liftY = r.top; liftSize = r.width;
  liftVX = liftVY = 0;
  dragLayerEl.appendChild(discCanvas);
  discCanvas.classList.add("lifted");
  discCanvas.style.width = r.width.toFixed(1) + "px";
  discCanvas.style.height = r.height.toFixed(1) + "px";
  applyLift();
  if (discShadowEl) discShadowEl.style.opacity = "0";
  if (dragShadowEl) {
    dragShadowEl.style.width = (liftSize * 0.78).toFixed(1) + "px";
    dragShadowEl.style.height = (liftSize * 0.104).toFixed(1) + "px";
    dragShadowEl.style.display = "block";
  }
  drawDisc();
}
function dockDisc() {
  if (!lifted) return;
  lifted = false;
  discYEl.appendChild(discCanvas);
  discCanvas.classList.remove("lifted");
  discCanvas.style.left = ""; discCanvas.style.top = "";
  discCanvas.style.width = ""; discCanvas.style.height = "";
  if (dragShadowEl) dragShadowEl.style.display = "none";
  if (discShadowEl) discShadowEl.style.opacity = "";
  drawDisc();
}
function springStep(ts) {
  if (dragging || !lifted) { springRaf = 0; springLast = 0; return; }
  if (!springLast) springLast = ts;
  const dt = Math.min((ts - springLast) / 1000, 0.05);
  springLast = ts;
  const home = homeRect();
  const K = 110; // spring stiffness
  const C = 2 * Math.sqrt(K) * (reduceMotion ? 1.0 : 0.24); // damping
  for (let i = 0; i < 2; i++) {
    const h = dt / 2;
    liftVX += (-K * (liftX - home.x) - C * liftVX) * h;
    liftVY += (-K * (liftY - home.y) - C * liftVY) * h;
    liftX += liftVX * h;
    liftY += liftVY * h;
  }
  applyLift();
  drawDisc();
  if (Math.abs(liftX - home.x) < 0.5 && Math.abs(liftY - home.y) < 0.5 &&
      Math.abs(liftVX) < 6 && Math.abs(liftVY) < 6) {
    springRaf = 0; springLast = 0;
    dockDisc();
    return;
  }
  springRaf = requestAnimationFrame(springStep);
}
function kickSpring() {
  if (!springRaf && !dragging && lifted) {
    springLast = 0;
    springRaf = requestAnimationFrame(springStep);
  }
}
function resetDrag() {
  dragging = false;
  liftVX = liftVY = 0;
  if (springRaf) { cancelAnimationFrame(springRaf); springRaf = 0; }
  springLast = 0;
  dockDisc();
}
if (discCanvas && discYEl && dragLayerEl) {
  let grabDX = 0, grabDY = 0;
  let lastMX = 0, lastMY = 0, lastMT = 0;
  discCanvas.addEventListener("pointerdown", (e) => {
    if (!stageEl || !stageEl.classList.contains("idle")) return;
    if (!lifted) liftDisc();
    dragging = true;
    if (springRaf) { cancelAnimationFrame(springRaf); springRaf = 0; }
    springLast = 0;
    liftVX = liftVY = 0;
    grabDX = e.clientX - liftX;
    grabDY = e.clientY - liftY;
    lastMX = e.clientX; lastMY = e.clientY;
    lastMT = performance.now();
    try { discCanvas.setPointerCapture(e.pointerId); } catch (err) {}
    discCanvas.style.cursor = "grabbing";
    e.preventDefault();
  });
  discCanvas.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    // Roam the whole screen; always keep a hand-hold of disc
    // on-screen so it can never be lost off an edge mid-drag.
    liftX = Math.max(-liftSize + 48,
      Math.min(window.innerWidth - 48, e.clientX - grabDX));
    liftY = Math.max(-liftSize + 48,
      Math.min(window.innerHeight - 48, e.clientY - grabDY));
    const now = performance.now();
    const dt = Math.max(now - lastMT, 1) / 1000;
    liftVX = liftVX * 0.3 + ((e.clientX - lastMX) / dt) * 0.7;
    liftVY = liftVY * 0.3 + ((e.clientY - lastMY) / dt) * 0.7;
    lastMX = e.clientX; lastMY = e.clientY; lastMT = now;
    applyLift();
    drawDisc();
  });
  const letGo = () => {
    if (!dragging) return;
    dragging = false;
    discCanvas.style.cursor = "";
    if (performance.now() - lastMT > 90) liftVX = liftVY = 0;
    const cap = 1400; // px/s: tame a wild fling
    liftVX = Math.max(-cap, Math.min(cap, liftVX));
    liftVY = Math.max(-cap, Math.min(cap, liftVY));
    kickSpring();
  };
  discCanvas.addEventListener("pointerup", letGo);
  discCanvas.addEventListener("pointercancel", letGo);
  window.addEventListener("resize", () => {
    if (lifted && !dragging) resetDrag();
  });
}
// Ease the spin to a stop, front-facing: keep turning FORWARD the
// rest of the current revolution, decelerating, like the previews.
function globeSettle() {
  return new Promise((resolve) => {
    stopIdleSpin();
    const mod = ((spinAngle % 360) + 360) % 360;
    const remain = (360 - mod) % 360;
    if (remain < 1) { spinAngle = 0; drawDisc(); return resolve(); }
    const dur = Math.max(450, Math.min(1400, 450 + remain / 360 * 950));
    const start = spinAngle, t0 = performance.now();
    (function tick(now) {
      const t = Math.min(1, (now - t0) / dur);
      const e = 1 - Math.pow(1 - t, 3);
      spinAngle = start + remain * e;
      drawDisc();
      if (t < 1) requestAnimationFrame(tick);
      else { spinAngle = 0; drawDisc(); resolve(); }
    })(t0);
  });
}

// Start the idle globe spin (unless the user prefers reduced motion).
if (!window.matchMedia || !matchMedia("(prefers-reduced-motion: reduce)").matches)
  startIdleSpin();
else
  drawDisc();

let writingStarted = false;
function stageStartWriting() {
  if (writingStarted || !stageEl) return;
  writingStarted = true;
  stageEl.classList.add("burning");
  startFlicker();
}

// One Comic Sans title chip per track: flies in from the right and
// is sucked into the drive as the track is buffered, like a real
// drive loading its write buffer. WAAPI on transform/opacity, so it
// stays smooth even while the encoder blocks the main thread.
function stageChip(title, no) {
  stageStartWriting();
  if (!chipLayerEl || !sceneEl) return;
  const chip = document.createElement("div");
  chip.className = "chip";
  chip.textContent = `${String(no).padStart(2, "0")} - ${title}`;
  chipLayerEl.appendChild(chip);
  const W = sceneEl.clientWidth;
  const startX = W * 1.03;
  const dx = W * 0.604 - startX;
  chip.style.left = startX + "px";
  const anim = chip.animate([
    { transform: "translateY(-50%) translateX(0) scale(1)", opacity: 1 },
    { transform: `translateY(-50%) translateX(${(dx * 0.55).toFixed(1)}px) scale(1)`, opacity: 1, offset: 0.6 },
    { transform: `translateY(-50%) translateX(${dx.toFixed(1)}px) scale(0.3)`, opacity: 0 },
  ], { duration: 900, easing: "cubic-bezier(.4,.05,.6,.5)" });
  anim.onfinish = () => chip.remove();
}

async function stageLoad() {
  if (!stageEl) return;
  resetDrag(); // the toy homes itself before the choreography
  writingStarted = false;
  stageEl.classList.remove("done", "driveout", "casein", "casecenter",
    "caseclosed", "incased", "lidclosed", "seated", "burning", "idle");
  discLabel = "ATRAC CD";
  if (stageStatus) stageStatus.textContent = "Loading disc…";
  setBurn(0);
  kickDraws(3600);
  const settle = globeSettle();
  stageEl.classList.add("drivein");
  await settle;
  squashYTarget = 0.80;
  stageEl.classList.add("seated");
  await sleep(1080);
  stageEl.classList.add("lidclosed");
  await sleep(780);
}

async function stageFinish(ok) {
  if (!stageEl) return;
  stopFlicker();
  stageEl.classList.remove("burning");
  if (!ok) {
    stageEl.classList.remove("seated", "lidclosed", "drivein");
    squashYTarget = 0.94;
    spinAngle = 0;
    drawDisc();
    startIdleSpin();
    stageEl.classList.add("idle");
    return;
  }
  kickDraws(4200);
  stageEl.classList.remove("lidclosed");
  await sleep(820);                    // the drive's lid swings open
  stageEl.classList.add("casein");
  await sleep(520);                    // the jewel case slides in
  squashYTarget = 0.97;
  stageEl.classList.remove("seated");
  stageEl.classList.add("incased");
  await sleep(1120);                   // the disc glides into the case
  stageEl.classList.add("caseclosed");
  await sleep(1150);                   // the case lid swings shut
  stageEl.classList.add("driveout");
  stageEl.classList.add("casecenter");
  stageEl.classList.add("done");
}

// ---------------- tags ----------------
const latin1 = (bytes) =>
  [...bytes].map((b) => String.fromCharCode(b)).join("").replace(/[\0 ]+$/, "").trim();

function parseV1(bytes) {
  if (bytes.length < 128) return null;
  const t = bytes.subarray(bytes.length - 128);
  if (String.fromCharCode(t[0], t[1], t[2]) !== "TAG") return null;
  return {
    title: latin1(t.subarray(3, 33)),
    artist: latin1(t.subarray(33, 63)),
    album: latin1(t.subarray(63, 93)),
  };
}

function parseV2(bytes) {
  if (bytes.length < 10 || String.fromCharCode(bytes[0], bytes[1], bytes[2]) !== "ID3")
    return null;
  const ver = bytes[3];
  const size = ((bytes[6] & 0x7f) << 21) | ((bytes[7] & 0x7f) << 14) |
    ((bytes[8] & 0x7f) << 7) | (bytes[9] & 0x7f);
  const out = {};
  const dec = (enc, body) => {
    const names = { 0: "iso-8859-1", 1: "utf-16", 2: "utf-16be", 3: "utf-8" };
    try {
      return new TextDecoder(names[enc] ?? "utf-8").decode(body).replace(/\0+$/, "").trim();
    } catch { return ""; }
  };
  let pos = 10;
  const end = Math.min(bytes.length, 10 + size);
  while (pos + 10 <= end) {
    const id = String.fromCharCode(...bytes.subarray(pos, pos + 4));
    if (!/^[A-Z0-9]{4}$/.test(id)) break;
    const raw = bytes.subarray(pos + 4, pos + 8);
    const fsize = ver === 4
      ? ((raw[0] & 0x7f) << 21) | ((raw[1] & 0x7f) << 14) | ((raw[2] & 0x7f) << 7) | (raw[3] & 0x7f)
      : (raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3];
    const body = bytes.subarray(pos + 10, pos + 10 + fsize);
    if (body.length > 1 && ["TIT2", "TPE1", "TALB"].includes(id)) {
      const key = { TIT2: "title", TPE1: "artist", TALB: "album" }[id];
      out[key] = dec(body[0], body.subarray(1));
    }
    pos += 10 + fsize;
  }
  return out.title !== undefined ? out : null;
}

function tagsFor(bytes, fileName) {
  const tags = parseV2(bytes) ?? parseV1(bytes) ?? {};
  if (!tags.title)
    tags.title = fileName.replace(/\.[^.]+$/, "").replace(/_/g, " ").trim();
  tags.artist ??= "";
  tags.album ??= "";
  return tags;
}

// ---------------- state ----------------
let nextId = 1;
const state = { groups: [{ name: "Group 1", tracks: [] }], imported: null };

function allTracks() {
  return state.groups.flatMap((g) => g.tracks);
}

// ---------------- encoder ----------------
let enc = null;
window.Atrac3p({ locateFile: (p) => "encoder/" + p }).then((mod) => {
  enc = mod;
  $("buildNote").innerHTML = "<small>Encoder ready: 64 kbps ATRAC3+.</small>";
  refresh();
}).catch((e) => {
  $("buildNote").innerHTML = `<small class="err">Encoder failed to load: ${e.message}</small>`;
});

function encodeTrack(pcm, perChannel) {
  const ctx = enc._atrac3p_create(2);
  if (!ctx) throw new Error("encoder create failed");
  const buf = enc._malloc(pcm.length * 2);
  enc.HEAP16.set(pcm, buf / 2);
  const rc = enc._atrac3p_encode(ctx, buf, perChannel);
  if (rc !== 0) { enc._atrac3p_destroy(ctx); enc._free(buf); throw new Error("encode failed"); }
  const outLen = enc._atrac3p_flush(ctx);
  const frames = new Uint8Array(enc.HEAPU8.buffer, enc._atrac3p_output(ctx), outLen).slice();
  enc._atrac3p_destroy(ctx);
  enc._free(buf);
  return frames;
}

// ---------------- parallel encoding ----------------
// The build used to decode and encode strictly one track at a
// time on the main thread (GlitchedDot: "Make it use more than just one
// core", 2026-11-04). Now the encodes run in a pool of Web
// Workers -- one Wasm encoder instance each -- sized from the
// machine's thread count (navigator.hardwareConcurrency), and
// decodes run a few at a time (decodeAudioData does its work on
// the browser's own threads). Results are slotted back by track
// index, so the disc that gets authored is the same no matter
// how the work interleaves. If Workers or Wasm-in-a-worker fail
// for any reason, everything falls back to the serial path.
const MAX_WORKERS = 8;
const MAX_DECODE_AHEAD = 2;   // extra runners beyond the workers
const MAX_DECODE_AT_ONCE = 3; // float PCM is the memory spike; cap it
function poolSize() {
  const hc = navigator.hardwareConcurrency || 4;
  return Math.max(1, Math.min(hc - 1, MAX_WORKERS));
}
function makePool(n) {
  const pool = {
    workers: [], idle: [], queue: [], pending: new Map(),
    nextId: 1, dead: false, readyCount: 0,
  };
  pool.ready = new Promise((resolve, reject) => {
    pool._readyResolve = resolve; pool._readyReject = reject;
  });
  for (let i = 0; i < n; i++) {
    const w = new Worker("encoder/encode-worker.js");
    w.onmessage = (e) => {
      const d = e.data;
      if (d && d.type === "ready") {
        pool.readyCount++;
        if (pool.readyCount === n) pool._readyResolve();
        return;
      }
      if (d && d.type === "initError") {
        pool.dead = true;
        pool._readyReject(new Error(d.error || "encoder worker failed to start"));
        return;
      }
      const p = pool.pending.get(d.id);
      if (!p) return;
      pool.pending.delete(d.id);
      pool.idle.push(w);
      if (d.ok) p.resolve(new Uint8Array(d.frames));
      else p.reject(new Error(d.error || "encode failed"));
      pumpPool(pool);
    };
    w.onerror = () => {
      if (pool.dead) return;
      pool.dead = true;
      pool._readyReject(new Error("encoder worker crashed"));
      for (const [, p] of pool.pending) p.reject(new Error("encoder worker crashed"));
      pool.pending.clear();
      for (const job of pool.queue.splice(0)) job.reject(new Error("encoder worker crashed"));
    };
    pool.workers.push(w);
    pool.idle.push(w);
  }
  return pool;
}
function pumpPool(pool) {
  while (pool.idle.length && pool.queue.length) {
    const w = pool.idle.pop();
    const job = pool.queue.shift();
    const id = pool.nextId++;
    pool.pending.set(id, job);
    // The PCM buffer is COPIED to the worker, not transferred, so
    // the main thread still holds it if the job has to fall back.
    w.postMessage({ id, pcm: job.pcmBuf, perChannel: job.perChannel });
  }
}
function poolEncode(pool, pcmBuf, perChannel) {
  return new Promise((resolve, reject) => {
    pool.queue.push({ pcmBuf, perChannel, resolve, reject });
    pumpPool(pool);
  });
}
async function encodeAll(jobs, discTracks, onDone) {
  let pool = null;
  if (jobs.length > 1 && typeof Worker !== "undefined") {
    try {
      pool = makePool(poolSize());
      await Promise.race([
        pool.ready,
        new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), 15000)),
      ]);
      log(`Encoding in parallel: ${pool.workers.length} workers across ${navigator.hardwareConcurrency || "?"} threads.`);
    } catch (e) {
      if (pool) for (const w of pool.workers) w.terminate();
      pool = null;
      log("Parallel encoding unavailable — encoding on the main thread instead.");
    }
  }
  // A small semaphore keeps concurrent decodes (the memory spike)
  // bounded, however many runners there are.
  let decodeSlots = MAX_DECODE_AT_ONCE;
  const decodeWaiters = [];
  const acquireDecode = () => new Promise((res) => {
    if (decodeSlots > 0) { decodeSlots--; res(); }
    else decodeWaiters.push(res);
  });
  const releaseDecode = () => {
    const next = decodeWaiters.shift();
    if (next) next(); else decodeSlots++;
  };
  const encodeOne = async (track) => {
    await acquireDecode();
    let pcm;
    try {
      const tbytes = new Uint8Array(await track.file.arrayBuffer());
      let tbuf;
      try {
        tbuf = await actx.decodeAudioData(tbytes.buffer.slice(0));
      } catch (e2) {
        throw new Error(`Could not decode "${track.title || track.name}"`);
      }
      track.samples = tbuf.length;
      pcm = toInt16(tbuf);
    } finally {
      releaseDecode();
    }
    if (pool && !pool.dead) {
      try { return await poolEncode(pool, pcm.buffer, track.samples); }
      catch (e) { /* fall through: encode this one on the main thread */ }
    }
    return encodeTrack(pcm, track.samples);
  };
  const limit = pool ? pool.workers.length + MAX_DECODE_AHEAD : 1;
  let idx = 0;
  const run = async () => {
    while (true) {
      const i = idx++;
      if (i >= jobs.length) return;
      const track = jobs[i];
      log(`Encoding “${track.title || track.name}”…`);
      discLabel = track.title || track.name;
      drawDisc();
      stageChip(track.title || track.name, i + 1);
      const frames = await encodeOne(track);
      discTracks[i] = {
        frames, title: track.title, artist: track.artist, album: track.album,
      };
      onDone(track, frames);
    }
  };
  try {
    await Promise.all(
      Array.from({ length: Math.min(limit, jobs.length) }, run));
  } finally {
    if (pool) for (const w of pool.workers) w.terminate();
  }
}

// ---------------- audio ----------------
const actx = new OfflineAudioContext(2, 44100, 44100);

// Duration from the media metadata alone -- no PCM decode. The
// build only needs samples for its capacity estimate at this
// point; the real sample count is known when the track is decoded
// during the build itself.
function fileDuration(file) {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const a = new Audio();
    a.preload = "metadata";
    a.onloadedmetadata = () => {
      const d = a.duration;
      URL.revokeObjectURL(url);
      resolve(isFinite(d) ? d : 0);
    };
    a.onerror = () => { URL.revokeObjectURL(url); resolve(0); };
    a.src = url;
  });
}

async function addFile(file, group) {
  group = group || state.groups[state.groups.length - 1];
  const track = {
    id: nextId++, name: file.name, title: "", artist: "", album: "",
    file, samples: 0, error: null,
  };
  group.tracks.push(track);
  render();
  try {
    const bytes = new Uint8Array(await file.arrayBuffer());
    Object.assign(track, tagsFor(bytes, file.name));
    // Do NOT decode the audio here. Decoding a whole folder up
    // front keeps every track's PCM in memory at once -- a 200 MB
    // folder of MP3s is ~2.4 GB of float PCM -- and Safari kills
    // the tab (GlitchedDot's crash report, 2026-11-04). The File handle
    // is nearly free: the bytes stay out of the heap until the
    // build decodes one track at a time.
    const dur = await fileDuration(file);
    if (dur > 0) {
      track.samples = Math.round(dur * 44100);
    } else {
      // No metadata duration (odd format): decode once just to
      // count the samples, then let the PCM go.
      const buf = await actx.decodeAudioData(bytes.buffer.slice(0));
      track.samples = buf.length;
    }
  } catch (e) {
    track.error = "could not decode this file";
  }
  render();
  refresh();
}

function toInt16(buffer) {
  const n = buffer.length;
  const L = buffer.getChannelData(0);
  const R = buffer.numberOfChannels > 1 ? buffer.getChannelData(1) : L;
  const out = new Int16Array(n * 2);
  const clamp = (v) => Math.max(-32768, Math.min(32767, v));
  for (let i = 0; i < n; i++) {
    out[2 * i] = clamp(Math.round(L[i] * 32768));
    out[2 * i + 1] = clamp(Math.round(R[i] * 32768));
  }
  return out;
}

// ---------------- rendering ----------------
let dragSrc = null; // {gi, ti} of the track row being dragged
// Column widths for Title/Artist/Album, in percent of the table
// (GlitchedDot, 2026-11-05: adjustable columns). Shared by every group
// table and remembered between visits.
let colFrac = [36, 25, 21];
try {
  const s = JSON.parse(localStorage.getItem("atrac-col-widths"));
  if (Array.isArray(s) && s.length === 3 && s.every((n) => n > 0)) colFrac = s;
} catch {}
function startColResize(e, fi, table) {
  e.preventDefault();
  const startX = e.clientX;
  const startFrac = colFrac[fi];
  const tw = table.clientWidth || 1;
  const move = (ev) => {
    const nf = Math.max(8, Math.min(70, startFrac + (ev.clientX - startX) / tw * 100));
    colFrac[fi] = nf;
    document.querySelectorAll("#groups table").forEach((t) => {
      const col = t.querySelectorAll("col")[fi + 1];
      if (col) col.style.width = nf + "%";
    });
  };
  const up = () => {
    document.removeEventListener("mousemove", move);
    document.removeEventListener("mouseup", up);
    try { localStorage.setItem("atrac-col-widths", JSON.stringify(colFrac)); } catch {}
  };
  document.addEventListener("mousemove", move);
  document.addEventListener("mouseup", up);
}
function fmtDur(samples) {
  if (!samples) return "…";
  const s = Math.round(samples / 44100);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function render() {
  const wrap = $("groups");
  wrap.innerHTML = "";
  state.groups.forEach((group, gi) => {
    const div = document.createElement("div");
    div.className = "group";
    const h = document.createElement("h3");
    const nameInput = document.createElement("input");
    nameInput.type = "text";
    nameInput.value = group.name;
    nameInput.addEventListener("change", () => { group.name = nameInput.value; refresh(); });
    if (group.imported) nameInput.disabled = true;
    h.append("Group: ", nameInput);
    if (state.groups.length > 1 && !group.imported) {
      const del = document.createElement("button");
      del.textContent = "Remove group";
      del.addEventListener("click", () => {
        const dest = state.groups[gi === 0 ? 1 : gi - 1];
        dest.tracks.push(...group.tracks);
        state.groups.splice(gi, 1);
        render(); refresh();
      });
      h.append(" ", del);
    }
    div.appendChild(h);

    const table = document.createElement("table");
    const colgroup = document.createElement("colgroup");
    ["26px", colFrac[0] + "%", colFrac[1] + "%", colFrac[2] + "%", "54px", "auto"]
      .forEach((w) => {
        const c = document.createElement("col");
        c.style.width = w;
        colgroup.appendChild(c);
      });
    table.appendChild(colgroup);
    const head = document.createElement("tr");
    head.innerHTML = "<th></th><th>Title</th><th>Artist</th><th>Album</th><th></th><th></th>";
    table.appendChild(head);
    head.querySelectorAll("th").forEach((th, ci) => {
      if (ci < 1 || ci > 3) return; // Title/Artist/Album only
      const grip = document.createElement("span");
      grip.className = "colgrip";
      grip.title = "Drag to resize the column";
      grip.addEventListener("mousedown", (e) => startColResize(e, ci - 1, table));
      th.appendChild(grip);
    });
    group.tracks.forEach((track, ti) => {
      const tr = document.createElement("tr");
      const grip = document.createElement("td");
      grip.className = "grip";
      grip.textContent = track.imported ? "" : "⠿";
      grip.title = track.imported ? "" : "Drag to rearrange";
      tr.appendChild(grip);
      for (const key of ["title", "artist", "album"]) {
        const td = document.createElement("td");
        const input = document.createElement("input");
        input.type = "text";
        input.value = track[key];
        if (track.imported) input.disabled = true;
        input.addEventListener("change", () => { track[key] = input.value; refresh(); });
        td.appendChild(input);
        tr.appendChild(td);
      }
      const dur = document.createElement("td");
      dur.className = "dur";
      dur.textContent = track.error ? "⚠ " + track.error : fmtDur(track.samples);
      tr.appendChild(dur);
      const ctl = document.createElement("td");
      ctl.className = "trackbtns";
      const mkBtn = (label, title, fn) => {
        const b = document.createElement("button");
        b.textContent = label;
        b.title = title;
        b.addEventListener("click", fn);
        return b;
      };
      ctl.append(
        mkBtn("↑", "Move up", () => { if (ti > 0) { [group.tracks[ti - 1], group.tracks[ti]] = [group.tracks[ti], group.tracks[ti - 1]]; render(); refresh(); } }),
        mkBtn("↓", "Move down", () => { if (ti < group.tracks.length - 1) { [group.tracks[ti + 1], group.tracks[ti]] = [group.tracks[ti], group.tracks[ti + 1]]; render(); refresh(); } }),
      );
      if (state.groups.length > 1) {
        const sel = document.createElement("select");
        state.groups.forEach((g2, g2i) => {
          const o = document.createElement("option");
          o.value = g2i; o.textContent = g2.name || `Group ${g2i + 1}`;
          if (g2i === gi) o.selected = true;
          sel.appendChild(o);
        });
        sel.addEventListener("change", () => {
          group.tracks.splice(ti, 1);
          state.groups[Number(sel.value)].tracks.push(track);
          render(); refresh();
        });
        ctl.append(sel);
      }
      ctl.append(mkBtn("✕", "Remove track", () => { group.tracks.splice(ti, 1); render(); refresh(); }));
      if (track.imported) ctl.innerHTML = ""; // read-only row: no buttons
      tr.appendChild(ctl);
      // Drag to rearrange within the group (GlitchedDot, 2026-11-05).
      // Only the grip arms dragging, so the text fields stay
      // selectable the rest of the time.
      grip.addEventListener("mousedown", () => { if (!track.imported) tr.draggable = true; });
      tr.addEventListener("dragstart", (e) => {
        dragSrc = { gi, ti };
        tr.classList.add("dragging");
        e.dataTransfer.effectAllowed = "move";
        try { e.dataTransfer.setData("text/plain", "track"); } catch {}
      });
      tr.addEventListener("dragend", () => {
        tr.draggable = false;
        dragSrc = null;
        wrap.querySelectorAll(".dragging, .drop-before, .drop-after")
          .forEach((r) => r.classList.remove("dragging", "drop-before", "drop-after"));
      });
      tr.addEventListener("dragover", (e) => {
        if (!dragSrc || dragSrc.gi !== gi || dragSrc.ti === ti) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
        const r = tr.getBoundingClientRect();
        const after = (e.clientY - r.top) > r.height / 2;
        tr.classList.toggle("drop-after", after);
        tr.classList.toggle("drop-before", !after);
      });
      tr.addEventListener("dragleave", () =>
        tr.classList.remove("drop-before", "drop-after"));
      tr.addEventListener("drop", (e) => {
        if (!dragSrc || dragSrc.gi !== gi) return;
        e.preventDefault();
        const r = tr.getBoundingClientRect();
        const after = (e.clientY - r.top) > r.height / 2;
        const from = dragSrc.ti;
        let to = ti + (after ? 1 : 0);
        const [moved] = group.tracks.splice(from, 1);
        if (from < to) to--;
        group.tracks.splice(to, 0, moved);
        dragSrc = null;
        render(); refresh();
      });
      table.appendChild(tr);
    });
    div.appendChild(table);
    wrap.appendChild(div);
  });
}

// ---------------- capacity meter ----------------
function estimatedSizes() {
  const sizes = new Map();
  const tracks = allTracks();
  tracks.forEach((t, i) => {
    const frames = t.samples ? Math.floor(t.samples / 2048) + 1 : 0;
    sizes.set(`/HIFI/TRK${(i + 1).toString(16).toUpperCase().padStart(5, "0")}.ATP`,
      frames * 376 + 1120);
  });
  sizes.set("/TRACK.NDB", writeNdb(tracks.map((t) => t.title)).length);
  sizes.set("/ALBUM.NDB", writeNdb(tracks.map((t) => t.album)).length);
  sizes.set("/ARTIST.NDB", writeNdb(tracks.map((t) => t.artist)).length);
  sizes.set("/GROUP.NDB", writeNdb(state.groups.filter((g) => g.tracks.length).map((g) => g.name)).length);
  sizes.set("/PLLIST.NDB", 256);
  sizes.set("/TOC00000.STI", 0x900 + 16 * tracks.length);
  sizes.set("/TOC00001.STI", 2176);
  sizes.set("/0001000E.STK", 172);
  return sizes;
}

// ---------------- cleaned-tag export ----------------
// (GlitchedDot, 2026-11-05) One click downloads a .zip of COPIES of the
// current tracks: each MP3 with every trace of ID3v2 removed --
// all frames, album art included -- and a fresh ID3v1.1 tag
// written from the fields as they stand in the app, edits
// included. Files land in folders named for their group. A web
// page cannot modify the originals, and never would: copies only.
$("cleanExport").addEventListener("click", async () => {
  const btn = $("cleanExport");
  btn.disabled = true;
  try {
    const entries = [];
    const usedNames = new Set();
    let cleaned = 0, artGone = 0, passed = 0;
    for (const g of state.groups) {
      const folder = (g.name || "Group").replace(/[\\/:*?"<>|]/g, "_");
      let n = 0;
      for (const t of g.tracks) {
        n++;
        if (!t.file) continue;
        const bytes = new Uint8Array(await t.file.arrayBuffer());
        let data = bytes;
        if (/\.mp3$/i.test(t.name)) {
          const r = cleanMp3(bytes, {
            title: t.title, artist: t.artist, album: t.album, track: n,
          });
          data = r.data;
          cleaned++;
          if (r.hadArt) artGone++;
          log(`${t.name}: ${r.stripped
            ? "ID3v2 stripped" + (r.hadArt ? " (album art removed)" : "")
            : "no ID3v2 found"} — ID3v1.1 written.`);
        } else {
          passed++;
          log(`${t.name}: not an MP3 — copied unchanged.`);
        }
        let arc = `${folder}/${t.name}`;
        if (usedNames.has(arc.toLowerCase()))
          arc = `${folder}/${n}-${t.name}`;
        usedNames.add(arc.toLowerCase());
        entries.push({ name: arc, data });
      }
    }
    const blob = new Blob([makeZip(entries)], { type: "application/zip" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "cleaned-tags.zip";
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 60000);
    log(`Cleaned export done: ${cleaned} MP3${cleaned === 1 ? "" : "s"} retagged to ID3v1.1 only` +
      (artGone ? `, album art removed from ${artGone}` : "") +
      (passed ? `, ${passed} file${passed === 1 ? "" : "s"} copied unchanged` : "") +
      `. Your originals were not touched.`);
  } catch (err) {
    log(`Cleaned export failed: ${err.message}`);
  } finally {
    refresh();
  }
});

// ---------------- import ISO ----------------
// (GlitchedDot, 2026-11-05 — “gravely important”) Open an ISO made
// earlier — by WrightDisc or by SonicStage — and see exactly what
// is on it: its groups and tracks, with the names the player
// shows. An authored disc is finished, so the tracks come in
// read-only: no renaming, no rearranging, no removing. In the
// native apps this same import feeds the burner; here it is how
// you check a disc before it ever meets a blank.
$("importIso").addEventListener("click", () => $("isoPicker").click());
$("isoPicker").addEventListener("change", async (e) => {
  const file = e.target.files[0];
  e.target.value = "";
  if (!file) return;
  try {
    const bytes = new Uint8Array(await file.arrayBuffer());
    const disc = parseAtracDisc(bytes);
    state.groups = disc.groups.map((g) => ({
      name: g.name,
      imported: true,
      tracks: g.tracks.map((t) => ({
        id: nextId++,
        name: t.title || "Track",
        title: t.title, artist: t.artist, album: t.album,
        file: null, samples: t.seconds * 44100, error: null,
        imported: true, size: t.size,
      })),
    }));
    state.imported = { name: file.name, size: file.size };
    render();
    refresh();
    log(`Imported “${file.name}”: ${disc.trackCount} track${disc.trackCount === 1 ? "" : "s"} ` +
      `in ${disc.groups.length} group${disc.groups.length === 1 ? "" : "s"}, ` +
      `${(file.size / 1e6).toFixed(0)} MB.`);
    log("This disc is already authored — its tracks are read-only. " +
      "Clear the imported disc to start a new one.");
  } catch (err) {
    log(`Import failed: ${err.message}`);
  }
});
$("clearImport").addEventListener("click", () => {
  state.imported = null;
  state.groups = [{ name: "Group 1", tracks: [] }];
  render();
  refresh();
  log("Imported disc cleared.");
});

function refresh() {
  const tracks = allTracks();
  const blank = Number($("blank").value || 360000);
  let sectors = 0;
  try { sectors = isoSectorCount(estimatedSizes()); } catch { sectors = 0; }
  const used = sectors + SESSION_OVERHEAD_SECTORS;
  const pct = Math.min(100, (used / blank) * 100);
  $("meter").style.width = pct + "%";
  $("meter").className = used > blank ? "full" : "";
  $("meterText").textContent =
    `${tracks.length} track${tracks.length === 1 ? "" : "s"} · ` +
    `${(used * 2048 / 1e6).toFixed(0)} MB of ${(blank * 2048 / 1e6).toFixed(0)} MB` +
    (used > blank ? " — over capacity!" : "");
  // With a disc imported, the big button means "burn THIS ISO" —
  // possible only where a burn bridge exists (the native apps).
  // In a browser it stays greyed: a browser cannot burn.
  const burnBridge = !!(window.webkit && window.webkit.messageHandlers &&
                        window.webkit.messageHandlers.burnIso);
  $("build").disabled = state.imported
    ? !burnBridge
    : (!enc || tracks.length === 0 || tracks.some((t) => t.error || !t.file));
  const ce = $("cleanExport");
  if (ce) ce.disabled = tracks.length === 0 || tracks.some((t) => t.error || !t.file);
  const nowInfo = $("nowInfo");
  if (nowInfo) {
    if (tracks.length === 0) {
      nowInfo.textContent = "WrightDisc";
    } else {
      const secs = Math.round(tracks.reduce((a, t) => a + t.samples, 0) / 44100);
      const hh = String(Math.floor(secs / 3600)).padStart(2, "0");
      const mm = String(Math.floor((secs % 3600) / 60)).padStart(2, "0");
      const ss = String(secs % 60).padStart(2, "0");
      nowInfo.textContent =
        `${tracks.length} Track${tracks.length === 1 ? "" : "s"} / ${hh}:${mm}:${ss}`;
    }
  }
  const libInfo = $("libInfo");
  if (libInfo) {
    const g = state.groups.filter((x) => x.tracks.length > 0).length;
    libInfo.textContent = tracks.length ? `${g} group${g === 1 ? "" : "s"}` : "";
  }
  const ci = $("clearImport");
  if (ci) ci.hidden = !state.imported;
  if (state.imported) {
    $("meter").style.width = "100%";
    $("meter").className = "";
    $("meterText").textContent =
      `Imported disc “${state.imported.name}” — ${tracks.length} track${tracks.length === 1 ? "" : "s"} · ` +
      `${(state.imported.size / 1e6).toFixed(0)} MB (the ISO itself)`;
  }
}

// ---------------- build ----------------
$("build").addEventListener("click", async () => {
  if (state.imported) {
    // Burn Disc with an imported ISO: burn THAT file. The shell
    // holds its path (it ran the picker); the page just asks.
    if (window.webkit && window.webkit.messageHandlers &&
        window.webkit.messageHandlers.burnIso) {
      window.webkit.messageHandlers.burnIso.postMessage({ action: "burnImported" });
      log("Burning the imported ISO — the app handles the burn from here.");
    }
    return;
  }
  clearLog();
  $("build").disabled = true;
  try {
    await stageLoad();
    const groups = state.groups.filter((g) => g.tracks.length > 0);
    if (groups.length < state.groups.length)
      log("Note: empty groups are left off the disc.");
    const totalTracks = groups.reduce((a, g) => a + g.tracks.length, 0);
    const totalEstFrames = groups.reduce(
      (a, g) => a + g.tracks.reduce(
        (b, t) => b + (Math.floor(t.samples / 2048) + 1), 0), 0);
    const discTracks = [];
    const groupRanges = [];
    let cursor = 1;
    for (const group of groups) {
      groupRanges.push({ name: group.name || "Group", first: cursor, last: cursor + group.tracks.length - 1 });
      cursor += group.tracks.length;
    }
    const jobs = groups.flatMap((g) => g.tracks);
    let doneFrames = 0, doneCount = 0;
    await encodeAll(jobs, discTracks, (track, frames) => {
      doneCount++;
      doneFrames += frames.length / 376;
      setBurn(totalEstFrames ? (doneFrames / totalEstFrames) * 0.97 : 0);
      log(`  ${frames.length / 376} frames — “${track.title || track.name}” (${doneCount} of ${totalTracks})`);
      if (stageStatus)
        stageStatus.textContent = `Writing — ${doneCount} of ${totalTracks} tracks encoded`;
    });
    if (stageStatus) stageStatus.textContent = "Finishing the disc…";
    setBurn(0.99);
    log("Authoring the disc…");
    await new Promise((r) => setTimeout(r, 10));
    const discId = crypto.getRandomValues(new Uint8Array(16));
    const ivs = discTracks.map(() => crypto.getRandomValues(new Uint8Array(8)));
    const { iso, stats } = buildDisc({
      tracks: discTracks,
      groups: groupRanges,
      discId,
      ivs,
      capacitySectors: Number($("blank").value || 360000),
      timestamp: { ms: Date.now(), tzOffsetMinutes: -new Date().getTimezoneOffset() },
    });
    const blob = new Blob([iso], { type: "application/octet-stream" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "atrac-disc.iso";
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 60000);
    log(`Done: ${stats.trackCount} tracks, ${(stats.isoBytes / 1e6).toFixed(1)} MB ISO downloaded.`);
    log("Burn the ISO as a plain single-session disc image.");
    setBurn(1);
    if (stageStatus) stageStatus.textContent = "Your disc is ready — the ISO has downloaded. 💿";
    stageFinish(true);
  } catch (e) {
    log("Build failed: " + e.message, "err");
    if (stageStatus) stageStatus.textContent = "Something went wrong — see the log below.";
    stageFinish(false);
  } finally {
    refresh();
  }
});

// ---------------- wiring ----------------
const blankSel = $("blank");
for (const [sectors, label] of BLANKS) {
  const o = document.createElement("option");
  o.value = sectors;
  o.textContent = label;
  blankSel.appendChild(o);
}
blankSel.value = "360000";
blankSel.addEventListener("change", refresh);

$("addGroup").addEventListener("click", () => {
  if (intakeBlocked()) return;
  state.groups.push({ name: `Group ${state.groups.length + 1}`, tracks: [] });
  render(); refresh();
});

// While a disc is imported the list is that disc, read-only:
// starting a new one means clearing the import first.
function intakeBlocked() {
  if (!state.imported) return false;
  log("A disc is imported — clear it (✕ Clear imported disc) before starting a new one.");
  return true;
}

// Folder intake: audio files are collected recursively, up to 2
// folders deep (the folder itself, its subfolders, and theirs).
// Used by the folder picker and by drag-and-drop, which can carry
// whole folders too. Collected tracks land in path order.
const AUDIO_EXTS = ["mp3", "m4a", "wav", "flac", "ogg", "aif", "aiff"];
function isAudioFile(f) {
  const dot = f.name.lastIndexOf(".");
  const ext = dot >= 0 ? f.name.slice(dot + 1).toLowerCase() : "";
  return AUDIO_EXTS.includes(ext) || (f.type && f.type.startsWith("audio/"));
}
async function addFilesSerial(files) {
  if (intakeBlocked()) return;
  for (const f of files) await addFile(f);
}
async function addCollected(collected, skipped) {
  if (intakeBlocked()) return;
  collected.sort((x, y) => x.path.localeCompare(y.path));
  // One at a time: a folder's files are added (and their bytes
  // read) sequentially, so intake memory stays at one file's
  // worth no matter how big the folder is.
  // A dropped/picked FOLDER becomes a group named after it
  // (GlitchedDot, 2026-11-05): tracks whose path starts with a folder
  // land in that folder's group -- created on first sight, or
  // reused if a group with that name already exists. Bare files
  // (no folder in their path) keep the usual behaviour.
  const folderGroups = new Map();
  const groupFor = (path) => {
    const segs = path.split("/").filter(Boolean);
    if (segs.length < 2) return null;
    const name = segs[0];
    let g = state.groups.find((x) => x.name === name);
    if (!g) {
      g = { name, tracks: [] };
      state.groups.push(g);
    }
    if (!folderGroups.has(name)) folderGroups.set(name, g);
    return g;
  };
  for (const { file, path } of collected)
    await addFile(file, groupFor(path) || undefined);
  if (collected.length || skipped)
    log(`Folder scan: added ${collected.length} audio file${collected.length === 1 ? "" : "s"}` +
      (skipped ? `, skipped ${skipped} (not audio, or deeper than 2 folders)` : "") + ".");
  for (const [name, g] of folderGroups)
    log(`Folder “${name}” became a group (${g.tracks.length} track${g.tracks.length === 1 ? "" : "s"}).`);
}
function readAllEntries(dirEntry) {
  return new Promise((resolve, reject) => {
    const reader = dirEntry.createReader();
    const all = [];
    (function next() {
      reader.readEntries((batch) => {
        if (!batch.length) return resolve(all);
        all.push(...batch);
        next();
      }, reject);
    })();
  });
}
function entryFile(entry) {
  return new Promise((resolve, reject) => entry.file(resolve, reject));
}
async function walkEntry(entry, depth, out, stats) {
  if (entry.isFile) {
    const f = await entryFile(entry).catch(() => null);
    if (!f) return;
    if (isAudioFile(f)) out.push({ file: f, path: entry.fullPath || f.name });
    else stats.skipped++;
  } else if (entry.isDirectory) {
    const children = await readAllEntries(entry).catch(() => []);
    for (const child of children) {
      if (child.isDirectory && depth >= 2) { stats.skipped++; continue; }
      await walkEntry(child, depth + 1, out, stats);
    }
  }
}

const drop = $("drop");
drop.addEventListener("dragover", (e) => { e.preventDefault(); drop.classList.add("over"); });
drop.addEventListener("dragleave", () => drop.classList.remove("over"));
drop.addEventListener("drop", async (e) => {
  e.preventDefault();
  drop.classList.remove("over");
  const items = e.dataTransfer.items;
  let usedEntries = false;
  if (items && items.length && typeof items[0].webkitGetAsEntry === "function") {
    const entries = [...items].map((i) => i.webkitGetAsEntry()).filter(Boolean);
    if (entries.some((en) => en.isDirectory)) {
      usedEntries = true;
      const collected = [], stats = { skipped: 0 };
      for (const en of entries) await walkEntry(en, 0, collected, stats);
      addCollected(collected, stats.skipped);
    }
  }
  if (!usedEntries) await addFilesSerial([...e.dataTransfer.files]);
});
$("picker").addEventListener("change", (e) => {
  addFilesSerial([...e.target.files]);
  e.target.value = "";
});
$("folderPicker").addEventListener("change", async (e) => {
  const collected = [];
  let skipped = 0;
  for (const f of e.target.files) {
    const rel = f.webkitRelativePath || f.name;
    const depth = rel.split("/").length - 2;
    if (depth <= 2 && isAudioFile(f)) collected.push({ file: f, path: rel });
    else skipped++;
  }
  await addCollected(collected, skipped);
  e.target.value = "";
});

render();
refresh();

// ---------------- the Aero window buttons (Claude's wiring) ----------------
const winEl = $("win");
if (winEl) {
  const bMin = $("bMin"), bMax = $("bMax"), bClose = $("bClose");
  if (bMax) bMax.addEventListener("click", () => {
    winEl.classList.remove("rolled");
    winEl.classList.toggle("maxed");
  });
  if (bMin) bMin.addEventListener("click", () =>
    winEl.classList.toggle("rolled"));
  if (bClose) bClose.addEventListener("click", () => {
    winEl.classList.remove("rolled");
    log("Close is disabled in this demo. 😉");
  });
  const tb = winEl.querySelector(".titlebar");
  if (tb) tb.addEventListener("dblclick", (e) => {
    if (!e.target.closest(".wbtn") && bMax) bMax.click();
  });
}

// ---------------- Claude's generated wallpapers (from burn-aero) ----------------
const rng = seed => { let s = seed; return () => (s = (s * 16807) % 2147483647) / 2147483647; };
const PALETTES = [
  { name: 'Blue Ribbons',  seed: 7,  bg: ['#031a4d', '#0a56b8', '#4fc3f0'], glow: '#9fe6ff', rib: ['#7fd4ff', '#2a8cf0', '#ffffff', '#1457c4'] },
  { name: 'Emerald Flow',  seed: 21, bg: ['#022b1f', '#0a7a4a', '#8be28f'], glow: '#d4ffb0', rib: ['#b6ff9a', '#2fcf7a', '#ffffff', '#0b8f55'] },
  { name: 'Sunset Waves',  seed: 33, bg: ['#2a0845', '#b02a6b', '#ffa14a'], glow: '#ffe0a0', rib: ['#ffd27a', '#ff6b8a', '#ffffff', '#7a2fbf'] },
  { name: 'Violet Streams', seed: 48, bg: ['#12063a', '#4b2aa8', '#b78cff'], glow: '#e6d4ff', rib: ['#d9b8ff', '#7a5cff', '#ffffff', '#3a1fa0'] },
  { name: 'Graphite Lines', seed: 59, bg: ['#0d1015', '#2b3440', '#7b8a9c'], glow: '#dbe6f5', rib: ['#c0cddd', '#5f7189', '#ffffff', '#2b3a4e'] },
  { name: 'Golden Beams',   seed: 64, mode: 'beams',   bg: ['#2b1500', '#9a4a08', '#ffc65a'], glow: '#fff0b8', rib: ['#ffe08a', '#ff9a3c', '#ffffff', '#b8530a'] },
  { name: 'Teal Silk',      seed: 71, mode: 'waves',   bg: ['#031f2b', '#0a6a7a', '#6fe0d0'], glow: '#c9fff4', rib: ['#8ff0e0', '#1fb3b8', '#ffffff', '#0b7482'] },
  { name: 'Rose Bokeh',     seed: 82, mode: 'bokeh',   bg: ['#3a0a2a', '#c23a78', '#ffb3c8'], glow: '#ffe3ec', rib: ['#ffc2d6', '#ff6fa0', '#ffffff', '#8a1f58'] },
  { name: 'Twilight Twist', seed: 93, mode: 'swirl',   bg: ['#0a0d33', '#2c3fb0', '#9aa8ff'], glow: '#dfe5ff', rib: ['#c8d2ff', '#6578ff', '#ffffff', '#1c2a8a'] },
  { name: 'Aurora Green',   seed: 17, mode: 'aurora',  bg: ['#02131a', '#0b5a52', '#58e0a8'], glow: '#b8ffe0', rib: ['#9affd0', '#2ed6a0', '#ffffff', '#10806a'] }
];
const f1 = n => n.toFixed(1);
const dots = (r, W, H, n) => {
  let s = '';
  for (let i = 0; i < n; i++) {
    s += `<circle cx='${(r() * W).toFixed(0)}' cy='${(r() * H).toFixed(0)}' r='${(2 + r() * 9).toFixed(1)}' fill='#fff' fill-opacity='${(0.05 + r() * 0.2).toFixed(2)}'/>`;
  }
  return s;
};
const MODES = {
  beams(p, r, W, H) {
    const ox = 1300, oy = -120;
    const defs = `<radialGradient id='bm' cx='${ox}' cy='${oy}' r='1700' gradientUnits='userSpaceOnUse'><stop offset='0' stop-color='#fff' stop-opacity='.7'/><stop offset='.6' stop-color='${p.glow}' stop-opacity='.25'/><stop offset='1' stop-color='${p.glow}' stop-opacity='0'/></radialGradient>`;
    let body = '';
    for (let i = 0; i < 16; i++) {
      const a = 1.7 + i * 0.075 + r() * 0.04, w = 0.012 + r() * 0.05;
      const x1 = ox + 2200 * Math.cos(a - w), y1 = oy + 2200 * Math.sin(a - w);
      const x2 = ox + 2200 * Math.cos(a + w), y2 = oy + 2200 * Math.sin(a + w);
      body += `<polygon points='${ox},${oy} ${f1(x1)},${f1(y1)} ${f1(x2)},${f1(y2)}' fill='url(#bm)' opacity='${(0.25 + r() * 0.6).toFixed(2)}'/>`;
    }
    for (let i = 0; i < 9; i++) {
      const y = 520 + i * 38, a = 60 + r() * 120;
      body += `<path d='M-50 ${y} C 450 ${y - a}, 1000 ${y + a}, 1650 ${y - a * 1.5}' fill='none' stroke='${p.rib[i % 4]}' stroke-opacity='${(0.2 + r() * 0.3).toFixed(2)}' stroke-width='${(0.8 + r() * 1.6).toFixed(1)}'/>`;
    }
    return { defs, body };
  },
  waves(p, r, W, H) {
    let defs = '', body = '';
    for (let k = 0; k < 6; k++) {
      const c = p.rib[k % p.rib.length];
      const y0 = 300 + k * 100, amp = 70 + r() * 100, amp2 = 50 + r() * 90;
      defs += `<linearGradient id='w${k}' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='${c}' stop-opacity='.6'/><stop offset='1' stop-color='${c}' stop-opacity='.04'/></linearGradient>`;
      const top = `M-50 ${y0} C 350 ${f1(y0 - amp)}, 700 ${f1(y0 + amp)}, 1000 ${y0} S 1450 ${f1(y0 - amp2)}, 1700 ${f1(y0 + amp2 * 0.4)}`;
      body += `<path d='${top} L 1700 950 L -50 950 Z' fill='url(#w${k})'/>`;
      body += `<path d='${top}' fill='none' stroke='#fff' stroke-opacity='.4' stroke-width='1.4'/>`;
    }
    return { defs, body };
  },
  bokeh(p, r, W, H) {
    const defs = `<radialGradient id='bkA'><stop offset='0' stop-color='${p.glow}' stop-opacity='.9'/><stop offset='.7' stop-color='${p.glow}' stop-opacity='.35'/><stop offset='1' stop-color='${p.glow}' stop-opacity='0'/></radialGradient><radialGradient id='bkB'><stop offset='0' stop-color='${p.rib[0]}' stop-opacity='.8'/><stop offset='1' stop-color='${p.rib[1]}' stop-opacity='0'/></radialGradient>`;
    let body = '', over = '';
    for (let i = 0; i < 26; i++) {
      const cx = r() * W, cy = r() * H, rad = 40 + r() * 150;
      over += `<circle cx='${cx.toFixed(0)}' cy='${cy.toFixed(0)}' r='${rad.toFixed(0)}' fill='url(#${i % 3 ? 'bkA' : 'bkB'})' opacity='${(0.18 + r() * 0.4).toFixed(2)}'/>`;
      if (i % 4 === 0) over += `<circle cx='${cx.toFixed(0)}' cy='${cy.toFixed(0)}' r='${(rad * 0.55).toFixed(0)}' fill='none' stroke='#fff' stroke-opacity='${(0.15 + r() * 0.2).toFixed(2)}' stroke-width='1.2'/>`;
    }
    for (let i = 0; i < 12; i++) {
      const y = 100 + i * 60, a = 70 + r() * 150;
      body += `<path d='M-50 ${y} C 450 ${y + a}, 1000 ${y - a}, 1650 ${y + a / 2}' fill='none' stroke='#fff' stroke-opacity='${(0.06 + r() * 0.12).toFixed(2)}' stroke-width='1'/>`;
    }
    return { defs, body, over };
  },
  swirl(p, r, W, H) {
    let body = '';
    for (let i = 0; i < 46; i++) {
      const t = i / 45, op = (0.08 + 0.34 * Math.sin(Math.PI * t)).toFixed(2);
      body += `<path d='M-60 700 C 480 ${f1(780 - 760 * t)}, 1080 ${f1(60 + 760 * t)}, 1660 160' fill='none' stroke='${p.rib[i % 4]}' stroke-opacity='${op}' stroke-width='${(0.7 + r() * 0.8).toFixed(1)}'/>`;
    }
    for (let i = 0; i < 30; i++) {
      const t = i / 29, op = (0.06 + 0.26 * Math.sin(Math.PI * t)).toFixed(2);
      body += `<path d='M-60 840 C 520 ${f1(900 - 500 * t)}, 1100 ${f1(480 + 380 * t)}, 1660 560' fill='none' stroke='${p.rib[(i + 1) % 4]}' stroke-opacity='${op}' stroke-width='${(0.6 + r() * 0.7).toFixed(1)}'/>`;
    }
    return { defs: '', body };
  },
  aurora(p, r, W, H) {
    let defs = `<filter id='bl' x='-20%' y='-20%' width='140%' height='140%'><feGaussianBlur stdDeviation='22'/></filter>`;
    let body = `<g filter='url(#bl)'>`;
    for (let k = 0; k < 7; k++) {
      const c = p.rib[k % p.rib.length];
      defs += `<linearGradient id='au${k}' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='${c}' stop-opacity='0'/><stop offset='.5' stop-color='${c}' stop-opacity='.65'/><stop offset='1' stop-color='${c}' stop-opacity='0'/></linearGradient>`;
      const x0 = -100 + k * 240 + r() * 120, w = 90 + r() * 170, a = 80 + r() * 220, b = 80 + r() * 220, dd = 60 + r() * 200;
      body += `<path d='M${f1(x0)} -60 C ${f1(x0 + a)} 260, ${f1(x0 - b)} 560, ${f1(x0 + dd)} 980 L ${f1(x0 + dd + w)} 980 C ${f1(x0 - b + w)} 560, ${f1(x0 + a + w)} 260, ${f1(x0 + w)} -60 Z' fill='url(#au${k})'/>`;
    }
    body += '</g>';
    for (let i = 0; i < 14; i++) {
      const x = 40 + i * 115 + r() * 40, a = 60 + r() * 160;
      body += `<path d='M${f1(x)} -20 C ${f1(x + a)} 280, ${f1(x - a)} 600, ${f1(x + a / 2)} 940' fill='none' stroke='#fff' stroke-opacity='${(0.06 + r() * 0.14).toFixed(2)}' stroke-width='1'/>`;
    }
    return { defs, body };
  }
};
function wallpaperSVG(p, aspect = 16 / 9) {
  const r = rng(p.seed);
  const DW = 1600, H = 900;
  const W = Math.round(H * Math.min(3.6, Math.max(0.45, aspect)));
  const sx = W / DW;
  let defs = `<linearGradient id='bg' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='${p.bg[0]}'/><stop offset='.55' stop-color='${p.bg[1]}'/><stop offset='1' stop-color='${p.bg[2]}'/></linearGradient>`;
  defs += `<radialGradient id='g1'><stop offset='0' stop-color='${p.glow}' stop-opacity='.85'/><stop offset='1' stop-color='${p.glow}' stop-opacity='0'/></radialGradient>`;
  let body = `<rect width='${W}' height='${H}' fill='url(#bg)'/>`;
  body += `<circle cx='${f1(1150 * sx)}' cy='260' r='620' fill='url(#g1)'/><circle cx='${f1(260 * sx)}' cy='760' r='420' fill='url(#g1)' opacity='.5'/>`;
  body += `<g transform='scale(${sx.toFixed(4)} 1)'>`;
  if (p.mode) {
    const m = MODES[p.mode](p, r, W, H, DW);
    return `<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 ${W} ${H}' preserveAspectRatio='xMidYMid slice'><defs>${defs}${m.defs}</defs>${body}${m.body}</g>${m.over || ''}${dots(r, W, H, 22)}</svg>`;
  }
  for (let i = 0; i < 34; i++) {
    const y = 60 + i * 26, a = 80 + r() * 160, b = 60 + r() * 200;
    body += `<path d='M-50 ${y} C 400 ${y - a}, 950 ${y + b}, 1650 ${y - a / 2}' fill='none' stroke='#fff' stroke-opacity='${(0.05 + r() * 0.14).toFixed(2)}' stroke-width='${(0.6 + r() * 1.1).toFixed(1)}'/>`;
  }
  for (let k = 0; k < 6; k++) {
    const c1 = p.rib[k % p.rib.length], c2 = p.rib[(k + 1) % p.rib.length];
    defs += `<linearGradient id='r${k}' x1='0' y1='0' x2='1' y2='0'><stop offset='0' stop-color='${c1}' stop-opacity='0'/><stop offset='.35' stop-color='${c1}' stop-opacity='.55'/><stop offset='.75' stop-color='${c2}' stop-opacity='.45'/><stop offset='1' stop-color='${c2}' stop-opacity='0'/></linearGradient>`;
    const y = 120 + r() * 620, a1 = 120 + r() * 260, a2 = 120 + r() * 260, a3 = 80 + r() * 220;
    const h1 = 26 + r() * 70, h2 = 26 + r() * 110;
    body += `<path d='M-100 ${y} C 420 ${y - a1}, 960 ${y + a2}, 1700 ${y - a3} L 1700 ${y - a3 + h2} C 960 ${y + a2 + h1}, 420 ${y - a1 + h1}, -100 ${y + h2} Z' fill='url(#r${k})'/>`;
    body += `<path d='M-100 ${y} C 420 ${y - a1}, 960 ${y + a2}, 1700 ${y - a3}' fill='none' stroke='#fff' stroke-opacity='.35' stroke-width='1.2'/>`;
  }
  body += '</g>';
  for (let i = 0; i < 28; i++) {
    body += `<circle cx='${(r() * W).toFixed(0)}' cy='${(r() * H).toFixed(0)}' r='${(2 + r() * 9).toFixed(1)}' fill='#fff' fill-opacity='${(0.05 + r() * 0.2).toFixed(2)}'/>`;
  }
  return `<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 ${W} ${H}' preserveAspectRatio='xMidYMid slice'><defs>${defs}</defs>${body}</svg>`;
}

// Wiring: Random by default; the menu can pin one wallpaper, and the
// pin (or Random) is remembered. "Your own picture" works like his.
const wallSel = $("wall");
let wallMode = "random";       // "random" | palette index | "custom"
let curWall = 0, lastAspect = 0, customURL = null;
try {
  wallMode = window.localStorage.getItem("atracWallpaperMode") || "random";
  customURL = window.localStorage.getItem("atracWallpaperCustom") || null;
} catch (e) { /* storage unavailable */ }
if (wallSel) {
  wallSel.add(new Option("Random (surprise me)", "random"));
  PALETTES.forEach((p, i) => wallSel.add(new Option(p.name, i)));
  const customOpt = new Option(customURL ? "Your picture (change…)" : "Your own picture…", "custom");
  customOpt.id = "wallCustomOpt";
  wallSel.add(customOpt);
}
function saveWallMode() {
  try { window.localStorage.setItem("atracWallpaperMode", String(wallMode)); } catch (e) { /* ignore */ }
}
function setWall(i) {
  curWall = i;
  lastAspect = window.innerWidth / Math.max(1, window.innerHeight);
  const svg = wallpaperSVG(PALETTES[i], lastAspect);
  document.body.style.background = `url("data:image/svg+xml,${encodeURIComponent(svg)}") center / cover no-repeat`;
}
function setCustomWall(url) {
  customURL = url;
  document.body.style.background = `url("${url}") center / cover no-repeat`;
  const o = $("wallCustomOpt");
  if (o) o.textContent = "Your picture (change…)";
  try { window.localStorage.setItem("atracWallpaperCustom", url); } catch (e) { /* too big: session only */ }
}
function applyWallpaper() {
  if (wallMode === "custom" && customURL) { setCustomWall(customURL); return; }
  if (wallMode === "random" || isNaN(parseInt(wallMode, 10))) {
    setWall(Math.floor(Math.random() * PALETTES.length));
    return;
  }
  setWall(parseInt(wallMode, 10));
}
if (wallSel) {
  wallSel.value = (wallMode === "custom" && !customURL) ? "random" : String(wallMode);
  applyWallpaper();
  wallSel.addEventListener("change", () => {
    if (wallSel.value === "custom") { const f = $("wallFile"); if (f) f.click(); return; }
    wallMode = wallSel.value;
    saveWallMode();
    applyWallpaper();
  });
}
const wallFileEl = $("wallFile");
if (wallFileEl) wallFileEl.addEventListener("change", (e) => {
  const file = e.target.files && e.target.files[0];
  if (!file) { if (wallSel) wallSel.value = String(wallMode); return; }
  const rd = new FileReader();
  rd.onload = () => {
    wallMode = "custom";
    saveWallMode();
    if (wallSel) wallSel.value = "custom";
    setCustomWall(rd.result);
  };
  rd.readAsDataURL(file);
});
let wallTimer;
window.addEventListener("resize", () => {
  if (wallMode === "custom") return;
  clearTimeout(wallTimer);
  wallTimer = setTimeout(() => {
    const a = window.innerWidth / Math.max(1, window.innerHeight);
    if (lastAspect && Math.abs(a - lastAspect) / lastAspect > 0.01) setWall(curWall);
  }, 150);
});
