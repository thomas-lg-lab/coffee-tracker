// Captures the README screenshots against a running instance, so they can be
// regenerated when the UI moves instead of being stale hand-grabs nobody dares touch.
//
// Needs a running, seeded instance; see "Regenerating the screenshots" in AGENTS.md.
//   BASE_URL=http://localhost:8080 node scripts/capture-screenshots.mjs
//
// It signs in through the API once and seeds the session into localStorage the way the
// app itself persists it, rather than driving the login form: /api/auth is rate-limited
// to 10/min and every shot would otherwise spend one.

import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';

const BASE = process.env.BASE_URL ?? 'http://localhost:8080';
const EMAIL = process.env.EMAIL ?? 'demo@example.com';
const PASSWORD = process.env.PASSWORD ?? 'D3mo-Passw0rd!';
const OUT = process.env.OUT_DIR ?? 'docs/screenshots';

/** localStorage key AuthStore persists under, keep in step with auth.store.ts. */
const SESSION_KEY = 'ct.session';

// Heights are tuned so each shot ends on a natural boundary rather than slicing a card
// or a form row in half. Re-check them after a layout change.
const SHOTS = [
  { name: 'shelf', path: '/coffees', theme: 'light', height: 930 },
  { name: 'shelf-dark', path: '/coffees', theme: 'dark', height: 930 },
  { name: 'coffee-detail', path: '/coffees/1', theme: 'light', height: 1000 },
];

const res = await fetch(`${BASE}/api/auth/login`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ email: EMAIL, password: PASSWORD }),
});
if (!res.ok) throw new Error(`login failed (${res.status}). Is ${BASE} running and seeded?`);
const auth = await res.json();

await mkdir(OUT, { recursive: true });
const browser = await chromium.launch();

for (const shot of SHOTS) {
  const context = await browser.newContext({
    viewport: { width: 1280, height: shot.height ?? 860 },
    deviceScaleFactor: 2, // retina-density PNGs, so they stay sharp on GitHub
    colorScheme: shot.theme,
  });

  // Before the app boots: AuthStore restores from localStorage in its constructor, so
  // seeding after navigation would race the guard and bounce us to /login.
  await context.addInitScript(
    ([key, value]) => window.localStorage.setItem(key, value),
    [SESSION_KEY, JSON.stringify(auth)],
  );

  const page = await context.newPage();
  await page.goto(`${BASE}${shot.path}`, { waitUntil: 'networkidle' });
  if (shot.wait) await page.waitForSelector(shot.wait, { timeout: 10_000 }).catch(() => {});
  // The shelf animates cards in; capture after they have settled.
  await page.waitForTimeout(1200);

  await page.screenshot({ path: `${OUT}/${shot.name}.png` });
  console.log(`  ${OUT}/${shot.name}.png`);
  await context.close();
}

await browser.close();
