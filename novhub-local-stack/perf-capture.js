// HUB-106: Playwright page capture for the NovAI build. Loads a real page, waits for it to be
// genuinely usable, then saves a HAR (with content) + a Performance trace + a metrics.json
// (request counts per endpoint, total scripting time, longest task - via the Long Tasks API,
// collected from page load, not just after navigation settles).
//
// "Usable" on Analytics is DOM-based (list_usable_ms/detail_usable_ms: QC-status badges filled
// + row count stable - never DOM row COUNT alone, pagination caps visible rows at 10 and
// Analytics' rows are grouped sessions, not 1:1 with runs, confirmed by NOVAPP). QC Report has
// no QC-status badge column, so it falls back to time_to_usable_ms (network-idle), which every
// page also keeps as a secondary, explicitly-labelled proxy - it tracks when the last matching
// request STARTS (+ ~1200ms idle), so it's sensitive to request ordering, not just how much
// work was done, and can rise even when the real page got faster.
//
// Analytics' date range (PERF_RANGE_START/PERF_RANGE_END, YYYY-MM-DD) is set through the
// RangePicker UI itself after the page settles on its default range - there is no URL param,
// so a real BEFORE/AFTER comparison needs this pinned explicitly, the same way the owner's own
// manual DevTools recording does it. range_change_usable_ms measures from right before the
// committing change (network cleared at that moment) to list-usable + network-idle again.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const args = Object.fromEntries(
  process.argv.slice(2).map(a => {
    const [k, v] = a.replace(/^--/, '').split('=');
    return [k, v === undefined ? true : v];
  })
);

const BASE_URL = process.env.NOVAPP_URL || 'http://localhost:5173';
const NOVAPI_URL = process.env.NOVAPI_URL || 'http://localhost:3000';
const SECRET_FILE = process.env.PERF_SECRET_FILE ||
  path.join(__dirname, '.state', 'secrets', 'perf-test-user.secret');
const ROBOT_NAME = args['robot-name']; // always passed explicitly by perf-capture.sh, from perf-targets.env
const PAGE = args.page || 'analytics'; // 'analytics' or 'qc_report'
const OUT_DIR = args.out;
const CLICK_ROW = PAGE === 'analytics'; // Analytics: list-load N+1 already fires; click a row for detail-view N+1 too.
// Analytics has no URL-driven date range - the page always opens on a relative "last 7 days"
// default (WeldRunsByRobotIdAndDateBase's own start/end props), so a real BEFORE/AFTER
// comparison needs an explicit, fixed range set through the picker UI itself, the way the
// owner's own manual DevTools recording does it. Both required together when either is set.
const RANGE_START = process.env.PERF_RANGE_START || null;
const RANGE_END = process.env.PERF_RANGE_END || null;
const SET_DATE_RANGE = CLICK_ROW && !!(RANGE_START && RANGE_END); // Analytics only - see below
const ENDPOINT_PATTERNS = ['weld_run', 'weld_test_reports', 'weld_stats'];
const IDLE_MS = 1200;
const OVERALL_TIMEOUT_MS = 60000;
// DOM-based "usable" signal (Analytics only - confirmed live via DOM inspection, 2026-11-17):
// WeldSessions' own QC Status badge is the 8th cell (index 7) inside #tour-weld-sessions;
// WeldInformation's (the row-click detail view) is the 14th cell (index 13) inside
// #tour-weld-information. QC Report (WeldQualityList) has no equivalent QC-status badge
// column (its "QC Report" column is a link, not a status badge), so it keeps the network-idle
// figure as its only usable signal - not a gap in this tool, there's no DOM signal to key off.
const QC_BADGE_SELECTOR = '.ant-scroll-number.ant-badge-count';
const LIST_TABLE_SELECTOR = '#tour-weld-sessions';
const LIST_QC_COLUMN_INDEX = 7;
const DETAIL_TABLE_SELECTOR = '#tour-weld-information';
const DETAIL_QC_COLUMN_INDEX = 13;
const DOM_STABLE_MS = 300; // row count + QC badges must hold steady this long before "usable"
const DOM_POLL_MS = 100;
const DOM_USABLE_TIMEOUT_MS = 20000;

if (!OUT_DIR || !ROBOT_NAME) {
  console.error('Usage: node perf-capture.js --page=analytics|qc_report --out=<dir> --robot-name=<name>');
  process.exit(1);
}
fs.mkdirSync(OUT_DIR, { recursive: true });

function endpointKey(url) {
  for (const p of ENDPOINT_PATTERNS) {
    if (url.includes(p)) {
      if (url.includes('weld_test_reports/batch')) return 'weld_test_reports_batch';
      if (url.includes('weld_stats/batch')) return 'weld_stats_batch';
      return p;
    }
  }
  return null;
}

// Polls (never a single check) for: at least one row, every visible row's QC-status badge
// filled (has a title attribute), and the row count holding steady for DOM_STABLE_MS - a
// transient re-render (skeleton -> real rows) must not be mistaken for "usable".
async function waitForTableUsable(page, containerSelector, qcColumnIndex) {
  const deadline = Date.now() + DOM_USABLE_TIMEOUT_MS;
  let lastCount = -1;
  let stableSince = null;
  while (Date.now() < deadline) {
    const state = await page.evaluate(({ containerSelector, qcColumnIndex, badgeSelector }) => {
      const container = document.querySelector(containerSelector);
      if (!container) return { rowCount: 0, allFilled: false };
      const rows = Array.from(container.querySelectorAll('tr.ant-table-row[data-row-key]'));
      if (rows.length === 0) return { rowCount: 0, allFilled: false };
      const allFilled = rows.every((row) => {
        const cell = row.children[qcColumnIndex];
        const badge = cell && cell.querySelector(badgeSelector);
        return !!(badge && badge.getAttribute('title'));
      });
      return { rowCount: rows.length, allFilled };
    }, { containerSelector, qcColumnIndex, badgeSelector: QC_BADGE_SELECTOR });

    if (state.rowCount > 0 && state.allFilled) {
      if (state.rowCount === lastCount) {
        if (stableSince !== null && Date.now() - stableSince >= DOM_STABLE_MS) return true;
      } else {
        lastCount = state.rowCount;
        stableSince = Date.now();
      }
    } else {
      lastCount = -1;
      stableSince = null;
    }
    await new Promise((r) => setTimeout(r, DOM_POLL_MS));
  }
  return false;
}

function checkSecretFile() {
  if (!fs.existsSync(SECRET_FILE)) {
    console.error(`[ERROR] PERF_SECRET_FILE not found: ${SECRET_FILE} - refusing`);
    process.exit(1);
  }
  const mode = fs.statSync(SECRET_FILE).mode & 0o777;
  if (mode !== 0o600) {
    console.error(`[ERROR] PERF_SECRET_FILE ${SECRET_FILE} is mode ${mode.toString(8)}, not 0600 - refusing`);
    process.exit(1);
  }
}

async function login() {
  checkSecretFile();
  const [email, password] = fs.readFileSync(SECRET_FILE, 'utf8').trim().split(':');
  const resp = await fetch(`${NOVAPI_URL}/api/v1/auth/signin`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!resp.ok) throw new Error(`signin failed: ${resp.status}`);
  const { token } = await resp.json();
  return token;
}

async function main() {
  const token = await login();
  const browser = await chromium.launch();
  const harPath = path.join(OUT_DIR, `${PAGE}.har`);
  const context = await browser.newContext({
    recordHar: { path: harPath, content: 'embed' },
    // Sets localStorage before any page script runs - avoids driving the login form just to
    // get an authenticated session for measuring dashboard pages, not the login flow itself.
    storageState: { cookies: [], origins: [{ origin: BASE_URL, localStorage: [{ name: 'jwt_token', value: token }] }] },
  });
  const page = await context.newPage();

  // Long Tasks API - collected from the very start of navigation, not polled after the fact.
  await page.addInitScript(() => {
    window.__longTasks = [];
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) window.__longTasks.push(entry.duration);
      }).observe({ entryTypes: ['longtask'] });
    } catch (e) { /* Long Tasks API unavailable - scripting-time metrics will read 0 */ }
  });

  const requestCounts = {};
  let lastRequestAt = Date.now();
  page.on('request', (req) => {
    const key = endpointKey(req.url());
    if (key) {
      requestCounts[key] = (requestCounts[key] || 0) + 1;
      lastRequestAt = Date.now();
    }
  });

  await context.tracing.start({ screenshots: true, snapshots: true });

  const navStart = Date.now();
  const url = `${BASE_URL}/${ROBOT_NAME}/${PAGE}`;
  console.error(`[INFO] navigating to ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: OVERALL_TIMEOUT_MS });

  let listUsableMs = null;
  let detailUsableMs = null;
  let rangeChangeUsableMs = null;
  let dateRangeApplied = false;

  // Sets the date-range filter through the RangePicker UI, the way a user does - there is no
  // URL param. Confirmed live against the local stack: fill+Enter on each of the picker's two
  // <input> elements (format YYYY-MM-DD) commits the range and closes the dropdown. Network is
  // "cleared" (lastRequestAt reset) and the clock starts right before the committing action
  // (the end-date Enter), matching the owner's own DevTools recording (Network cleared +
  // Performance recording started right before the change) - not before the picker is opened.
  async function setDateRangeViaUI() {
    const rangePicker = page.locator('.ant-picker-range').first();
    if (await rangePicker.count() === 0) {
      console.error('[WARN] no .ant-picker-range found on this page - cannot pin the date range here');
      return { ok: false, usable_ms: null };
    }
    await rangePicker.click();
    const inputs = rangePicker.locator('input');
    if (await inputs.count() < 2) {
      console.error('[WARN] range picker found but has fewer than 2 inputs - cannot pin the date range');
      return { ok: false, usable_ms: null };
    }
    await inputs.nth(0).fill(RANGE_START);
    await inputs.nth(0).press('Enter');

    lastRequestAt = Date.now(); // "Network cleared" - count idle time from here, not from navStart
    const changeStart = Date.now();
    await inputs.nth(1).fill(RANGE_END);
    await inputs.nth(1).press('Enter');

    const settled = await waitForTableUsable(page, LIST_TABLE_SELECTOR, LIST_QC_COLUMN_INDEX);
    const deadline = Date.now() + OVERALL_TIMEOUT_MS;
    while (Date.now() - lastRequestAt < IDLE_MS) {
      if (Date.now() > deadline) break;
      await new Promise((r) => setTimeout(r, 200));
    }
    const usableMs = settled ? Date.now() - changeStart : null;
    console.error(settled
      ? `[INFO] date range applied (${RANGE_START} to ${RANGE_END}) - list usable + network idle ${usableMs}ms after the change`
      : `[WARN] date range applied (${RANGE_START} to ${RANGE_END}) but list never reached "usable" within ${DOM_USABLE_TIMEOUT_MS}ms`);
    return { ok: true, usable_ms: usableMs };
  }

  if (CLICK_ROW) {
    const rowSelector = 'tr.ant-table-row[data-row-key]';
    // A first-visit "What's New in NovHub" tour prompt (.ant-modal-wrap, Skip/Take the Tour)
    // intercepts the click. Antd's close animation leaves the (now-empty) wrap in the DOM for
    // a beat, still intercepting pointer events, so wait for it to actually detach rather than
    // a flat sleep - and re-check right before the row click in case it reappears.
    async function dismissTourModal(label) {
      const wrap = page.locator('.ant-modal-wrap').first();
      const stillThere = await wrap.isVisible({ timeout: 2000 }).catch(() => false);
      if (!stillThere) return;
      console.error(`[INFO] (${label}) tour modal visible - dismissing`);
      const skipBtn = page.locator('.ant-modal-wrap button:has-text("Skip")').first();
      const closeBtn = page.locator('.ant-modal-close').first();
      let clicked = false;
      if (await skipBtn.isVisible({ timeout: 1000 }).catch(() => false)) {
        await skipBtn.click({ timeout: 2000 }).catch((e) => console.error(`[WARN] Skip click failed: ${e.message}`));
        clicked = true;
      } else if (await closeBtn.isVisible({ timeout: 1000 }).catch(() => false)) {
        await closeBtn.click({ timeout: 2000 }).catch((e) => console.error(`[WARN] close-icon click failed: ${e.message}`));
        clicked = true;
      } else {
        console.error('[WARN] modal visible but neither Skip nor close-icon matched - dumping modal text');
        console.error(await wrap.innerText().catch(() => '(innerText failed)'));
      }
      if (clicked) {
        const detached = await wrap.waitFor({ state: 'hidden', timeout: 5000 }).then(() => true).catch(() => false);
        console.error(detached ? `[INFO] (${label}) modal gone` : `[WARN] (${label}) modal still present after dismiss click`);
      }
    }
    try {
      await page.waitForTimeout(1000); // the tour prompt mounts shortly after the page, not instantly
      await dismissTourModal('pre-click');
      await page.waitForSelector(rowSelector, { timeout: 15000 });
      await dismissTourModal('right-before-click'); // in case it (re)appeared while waiting for rows

      const listSettled = await waitForTableUsable(page, LIST_TABLE_SELECTOR, LIST_QC_COLUMN_INDEX);
      listUsableMs = listSettled ? Date.now() - navStart : null;
      console.error(listSettled
        ? `[INFO] LIST usable (QC Status filled, row count stable) at ${listUsableMs}ms`
        : `[WARN] LIST never reached "QC Status filled + stable" within ${DOM_USABLE_TIMEOUT_MS}ms - list_usable_ms will be null`);

      if (SET_DATE_RANGE) {
        const applied = await setDateRangeViaUI();
        dateRangeApplied = applied.ok;
        rangeChangeUsableMs = applied.usable_ms;
      }

      const clickStart = Date.now();
      await page.click(rowSelector, { timeout: 8000 });
      console.error(`[INFO] clicked first row (now at ${page.url()}) - detail view (WeldInformation) should now fire its own N+1`);
      await page.screenshot({ path: path.join(OUT_DIR, `${PAGE}-post-click.png`) }).catch(() => {});

      const detailSettled = await waitForTableUsable(page, DETAIL_TABLE_SELECTOR, DETAIL_QC_COLUMN_INDEX);
      detailUsableMs = detailSettled ? Date.now() - clickStart : null;
      console.error(detailSettled
        ? `[INFO] DETAIL usable (QC Status filled, row count stable) ${detailUsableMs}ms after the click`
        : `[WARN] DETAIL never reached "QC Status filled + stable" within ${DOM_USABLE_TIMEOUT_MS}ms - detail_usable_ms will be null`);
    } catch (e) {
      console.error(`[WARN] could not find/click a row (${rowSelector}) - continuing with list-view traffic only: ${e.message}`);
      await page.screenshot({ path: path.join(OUT_DIR, `${PAGE}-row-click-failure.png`) }).catch(() => {});
    }
  }

  // Network-idle on the endpoints we care about, bounded by an overall timeout.
  const deadline = Date.now() + OVERALL_TIMEOUT_MS;
  while (Date.now() - lastRequestAt < IDLE_MS) {
    if (Date.now() > deadline) {
      console.error('[WARN] overall timeout reached before network went idle - metrics may be incomplete');
      break;
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  const usableAt = Date.now();

  const longTasks = await page.evaluate(() => window.__longTasks || []);
  await context.tracing.stop({ path: path.join(OUT_DIR, `${PAGE}-trace.zip`) });
  await context.close(); // flushes the HAR
  await browser.close();

  const metrics = {
    page: PAGE, robot_name: ROBOT_NAME, url,
    list_usable_ms: listUsableMs,
    detail_usable_ms: detailUsableMs,
    dom_usable_note: CLICK_ROW
      ? 'DOM-based: list_usable_ms = QC Status badges filled + row count stable (navigation -> settle, under the DEFAULT date range); detail_usable_ms = same, measured from the row click (under the pinned range, if one was set - the click happens after the range change). Primary metric for this page.'
      : 'No DOM-based signal: this page has no QC-status badge column to key off (its "QC Report" column is a link, not a status badge) - time_to_usable_ms (network-idle) is the only metric available here.',
    time_to_usable_ms: usableAt - navStart,
    time_to_usable_note: 'Network-idle proxy, not a render-complete signal: navigation -> (last matching request start + ~1200ms of no further matching requests). Secondary number - exposed to request-ordering/waterfall timing, not just work volume. Use list_usable_ms/detail_usable_ms where available.',
    date_range_used: SET_DATE_RANGE ? { start: RANGE_START, end: RANGE_END, applied: dateRangeApplied } : null,
    range_change_usable_ms: rangeChangeUsableMs,
    range_change_note: SET_DATE_RANGE
      ? 'Measured from right before the change that commits the new range (the end-date Enter, network cleared at that same moment) until the list is usable again AND the network is idle - matches the owner\'s own DevTools BEFORE recording methodology. detail_usable_ms (if present) is measured after this, so it reflects the pinned range, not the default one.'
      : 'No PERF_RANGE_START/PERF_RANGE_END configured for this run - the page kept its default relative date range throughout.',
    request_counts: requestCounts,
    total_scripting_ms: longTasks.reduce((a, b) => a + b, 0),
    longest_task_ms: longTasks.length ? Math.max(...longTasks) : 0,
    long_task_count: longTasks.length,
  };
  fs.writeFileSync(path.join(OUT_DIR, `${PAGE}-metrics.json`), JSON.stringify(metrics, null, 2));
  console.log(JSON.stringify(metrics, null, 2));
  console.error(`[INFO] saved: ${harPath}, ${path.join(OUT_DIR, PAGE + '-trace.zip')}, ${path.join(OUT_DIR, PAGE + '-metrics.json')}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
