import { createClient } from 'jsr:@supabase/supabase-js@2';

// Morning Report (07:00) and Daily Close (21:00), rebuilt in Supabase after the VPS
// that used to send them was retired. Both go to info@4pawfriend.co.uk.
//   ?kind=morning  -> today's run sheet, money, staff, month-to-date, alerts
//   ?kind=close    -> the day just traded: sales, staff split, 8-week like-for-like
// Gated by the same shared secret the other cron-driven functions use.

const SECRET = 'afaf9bfa64a31c2bee35a183e09c5a2c6d49';
const TO = ['info@4pawfriend.co.uk'];
const FROM = 'bookings@4pawfriend.co.uk';

const money = (n: number) => '£' + (Math.round(n * 100) / 100).toFixed(2);
const money0 = (n: number) => '£' + Math.round(n).toLocaleString('en-GB');
const pct = (n: number) => (Math.round(n * 10) / 10).toFixed(1) + '%';

function londonToday(): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date());
}
function longDate(iso: string): string {
  return new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
  }).format(new Date(iso + 'T12:00:00Z'));
}
function shortDate(iso: string): string {
  const d = new Date(iso + 'T12:00:00Z');
  return new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London', weekday: 'long' }).format(d) +
    ' ' + iso.slice(8, 10) + '/' + iso.slice(5, 7);
}
const addDays = (iso: string, n: number) => {
  const d = new Date(iso + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const monthKey = (iso: string) => iso.slice(0, 7);

type Row = Record<string, any>;

// ---------------------------------------------------------------------------
// Sales for a single day, per client, straight out of the Finance Tracker.
// ---------------------------------------------------------------------------
async function daySales(sb: any, iso: string) {
  const mk = monthKey(iso);
  const { data } = await sb.from('ledger_dogs')
    .select('dog_name,client_name,client_email,daily_amounts,daily_services,is_internal,section')
    .eq('month_key', mk);
  let total = 0;
  const services: Record<string, { n: number; sales: number }> = {};
  const dogs: Row[] = [];
  for (const r of (data ?? []) as Row[]) {
    if (r.is_internal) continue;
    const amt = Number(r.daily_amounts?.[iso] ?? 0);
    if (!(amt > 0)) continue;
    total += amt;
    dogs.push({ dog: r.dog_name, client: r.client_name, email: r.client_email, amount: amt, section: r.section });
    const svcs = r.daily_services?.[iso];
    if (Array.isArray(svcs)) {
      for (const s of svcs) {
        if (!s || typeof s !== 'object') continue;
        const name = String(s.service || 'Other').trim() || 'Other';
        services[name] = services[name] || { n: 0, sales: 0 };
        services[name].n += 1;
        services[name].sales += Number(s.amount || 0);
      }
    }
  }
  return { total, services, dogs };
}

// Month-to-date service mix, 1st of month up to and including iso.
async function monthServices(sb: any, iso: string) {
  const mk = monthKey(iso);
  const { data } = await sb.from('ledger_dogs').select('daily_services,is_internal').eq('month_key', mk);
  const out: Record<string, { n: number; sales: number }> = {};
  for (const r of (data ?? []) as Row[]) {
    if (r.is_internal) continue;
    for (const [day, svcs] of Object.entries(r.daily_services ?? {})) {
      if (day < mk + '-01' || day > iso) continue;
      if (!Array.isArray(svcs)) continue;
      for (const s of svcs as Row[]) {
        if (!s || typeof s !== 'object') continue;
        const name = String(s.service || 'Other').trim() || 'Other';
        out[name] = out[name] || { n: 0, sales: 0 };
        out[name].n += 1;
        out[name].sales += Number(s.amount || 0);
      }
    }
  }
  return out;
}

async function dayWages(sb: any, iso: string) {
  const { data } = await sb.from('ledger_staff').select('staff_name,daily_wages').eq('month_key', monthKey(iso));
  const per: Record<string, number> = {};
  let total = 0;
  for (const r of (data ?? []) as Row[]) {
    const w = Number(r.daily_wages?.[iso] ?? 0);
    if (!(w > 0)) continue;
    per[r.staff_name] = (per[r.staff_name] ?? 0) + w;
    total += w;
  }
  return { per, total };
}

async function dayCompanyCost(sb: any, iso: string) {
  const { data } = await sb.from('ledger_company_costs').select('daily_costs').eq('month_key', monthKey(iso)).maybeSingle();
  return Number(data?.daily_costs?.[iso] ?? 0);
}

// Distinct dog-days, so duplicated tracker rows can't inflate the count.
async function dayJobs(sb: any, iso: string) {
  const { data } = await sb.from('run_sheet_jobs')
    .select('dog_name,client_email,staff_email,collected,dropped_off,is_daycare,overnight,notes,pickup_time')
    .eq('job_date', iso);
  const seen = new Set<string>();
  const rows: Row[] = [];
  for (const r of (data ?? []) as Row[]) {
    const key = (r.dog_name || '').toLowerCase().trim() + '|' + (r.client_email || '').toLowerCase().trim() +
      '|' + (r.pickup_time || '') + '|' + (r.notes || '');
    if (seen.has(key)) continue;
    seen.add(key);
    rows.push(r);
  }
  return rows;
}

// public.staff is empty, so run sheet emails are mapped to the names the wage ledger
// uses. Without this the reports would show "jackanicholson8" instead of "Jack", and
// staff pay would never line up with sales. Add a line here when someone joins.
const STAFF_NAMES: Record<string, string> = {
  'josephmcdonagh4@googlemail.com': 'Joe',
  'jeffgoncalves22@icloud.com': 'Jefferson',
  'jackanicholson8@yahoo.com': 'Jack',
  'mahrcosgoncalves@gmail.com': 'Markos',
  'austinshaw564@gmail.com': 'Austin',
  'stephenkle@hotmail.com': 'Steve',
  'luketoner1239@gmail.com': 'Luke',
  'mysticyvonne@gmail.com': 'Yvonne',
};

async function staffNames(sb: any) {
  const map: Record<string, string> = { ...STAFF_NAMES };
  try {
    const { data } = await sb.from('staff').select('email,name');
    for (const r of (data ?? []) as Row[]) if (r.email && r.name) map[r.email.toLowerCase()] = r.name;
  } catch { /* staff table optional */ }
  return map;
}

// ---------------------------------------------------------------------------
const css = {
  wrap: 'max-width:680px;margin:0 auto;font-family:Arial,Helvetica,sans-serif;border:1px solid #e8e8f0;border-radius:14px;overflow:hidden',
  head: 'background:#0000FF;padding:22px;text-align:center',
  h1: 'font-size:22px;font-weight:900;color:#FFFF00;letter-spacing:1px;margin:0',
  sub: 'font-size:12px;color:#fff;letter-spacing:2px;margin-top:4px',
  body: 'padding:24px 26px;background:#fff',
  h2: 'font-size:15px;font-weight:900;color:#0000BB;margin:26px 0 10px;padding-bottom:6px;border-bottom:2px solid #FFFF00',
  table: 'width:100%;border-collapse:collapse;font-size:13.5px',
  th: 'text-align:left;padding:8px 10px;background:#f4f4ff;color:#0000BB;font-weight:700;border-bottom:1px solid #e0e0ff',
  td: 'padding:8px 10px;border-bottom:1px solid #f0f0f8;color:#222',
  note: 'font-size:11.5px;color:#888;line-height:1.6;margin:8px 0 0',
};

function tiles(items: { label: string; value: string; sub?: string }[]) {
  return `<table style="width:100%;border-collapse:separate;border-spacing:8px 0;margin-bottom:6px"><tr>` +
    items.map((t) => `<td style="background:#f4f4ff;border-radius:10px;padding:14px 10px;text-align:center;width:${Math.floor(100 / items.length)}%">
      <div style="font-size:10.5px;color:#7a7a95;text-transform:uppercase;letter-spacing:1px;font-weight:700">${t.label}</div>
      <div style="font-size:23px;font-weight:900;color:#0000BB;margin-top:4px">${t.value}</div>
      ${t.sub ? `<div style="font-size:11px;color:#888;margin-top:2px">${t.sub}</div>` : ''}
    </td>`).join('') + `</tr></table>`;
}

function table(headers: string[], rows: string[][], align: string[] = []) {
  return `<table style="${css.table}"><tr>` +
    headers.map((h, i) => `<th style="${css.th};text-align:${align[i] || 'left'}">${h}</th>`).join('') + '</tr>' +
    rows.map((r) => '<tr>' + r.map((c, i) => `<td style="${css.td};text-align:${align[i] || 'left'}">${c}</td>`).join('') + '</tr>').join('') +
    '</table>';
}

function shell(title: string, dateLine: string, inner: string) {
  return `<div style="${css.wrap}">
    <div style="${css.head}"><div style="${css.h1}">🐾 4 PAW FRIEND</div><div style="${css.sub}">${title.toUpperCase()}</div></div>
    <div style="${css.body}">
      <div style="font-size:13px;color:#666;margin-bottom:16px">${dateLine}</div>
      ${inner}
      <p style="${css.note}">Net Contribution = Sales − Staff Pay. This is not net profit: the Finance Tracker does not hold every business overhead (insurance, vehicles, fuel, subscriptions, rent, accountancy). Figures come from the same tracker tables as the admin portal, so they always agree with what you see on screen. Staff pay is recorded per person per day, not per job.</p>
    </div></div>`;
}

// ---------------------------------------------------------------------------
async function morning(sb: any, iso: string) {
  const [sales, wages, cost, jobs, mSvc, names] = await Promise.all([
    daySales(sb, iso), dayWages(sb, iso), dayCompanyCost(sb, iso), dayJobs(sb, iso), monthServices(sb, iso), staffNames(sb),
  ]);

  const { data: split } = await sb.rpc('f_day_sales_split', { p_date: iso });
  const s = (Array.isArray(split) ? split[0] : split) ?? {};
  const received = Number(s.received ?? 0);
  const outstanding = Number(s.outstanding ?? sales.total);

  const lastWeekIso = addDays(iso, -7);
  const lastWeek = await daySales(sb, lastWeekIso);
  const diff = sales.total - lastWeek.total;
  const growth = lastWeek.total > 0 ? (diff / lastWeek.total) * 100 : 0;

  const totalCost = wages.total + cost;
  const profit = sales.total - totalCost;

  // Sales per staff, from the run sheet.
  const perStaff: Record<string, { jobs: number; sales: number }> = {};
  const dogSale: Record<string, number> = {};
  for (const d of sales.dogs) dogSale[(d.dog || '').toLowerCase().trim()] = (dogSale[(d.dog || '').toLowerCase().trim()] ?? 0) + d.amount;
  let attributed = 0;
  for (const j of jobs) {
    const nm = names[(j.staff_email || '').toLowerCase()] || (j.staff_email || '').split('@')[0];
    const v = dogSale[(j.dog_name || '').toLowerCase().trim()] ?? 0;
    perStaff[nm] = perStaff[nm] || { jobs: 0, sales: 0 };
    perStaff[nm].jobs += 1;
    perStaff[nm].sales += v;
    attributed += v;
  }
  const unattributed = Math.max(0, sales.total - attributed);

  // Yesterday's ops.
  const yIso = addDays(iso, -1);
  const { data: yJobs } = await sb.from('run_sheet_jobs')
    .select('dog_name,staff_email,collected,airtag,airtag_reason').eq('job_date', yIso);
  const collected = (yJobs ?? []).filter((j: Row) => j.collected).length;
  const noTag = (yJobs ?? []).filter((j: Row) => j.collected && !j.airtag);
  const { count: vChecks } = await sb.from('vehicle_checks').select('*', { count: 'exact', head: true })
    .gte('created_at', yIso + 'T00:00:00Z').lte('created_at', yIso + 'T23:59:59Z');

  // Last 24h customer activity.
  const since = new Date(Date.now() - 86400000).toISOString();
  const { data: newBookings } = await sb.from('bookings')
    .select('client_name,dog_name,total,created_at').gte('created_at', since).order('created_at', { ascending: false });

  const alerts: string[] = [];
  if (outstanding > received) alerts.push(`Most of today is unpaid — ${money0(outstanding)} of ${money0(sales.total)} has not been collected.`);
  if (totalCost > received) alerts.push(`Costs exceed money received today — ${money0(totalCost)} of costs against ${money0(received)} received.`);
  if (noTag.length) alerts.push(`AirTags missing — ${noTag.length} dog(s) walked yesterday without one: ${noTag.map((j: Row) => j.dog_name).join(', ')}.`);
  if (!vChecks) alerts.push('No vehicle check yesterday — Nobody completed a daily vehicle check.');

  const inner = `
    ${tiles([
      { label: "Today's Sales", value: money0(sales.total) },
      { label: "Today's Costs", value: money0(cost) },
      { label: 'Staff Wages', value: money0(wages.total) },
      { label: "Today's Profit", value: money0(profit) },
      { label: 'Jobs', value: String(jobs.length) },
    ])}

    <div style="${css.h2}">Like-for-Like — same weekday last week</div>
    ${table(['Day', 'Net Sales'], [
      [`<strong>Today — ${shortDate(iso)}</strong>`, `<strong>${money0(sales.total)}</strong>`],
      [shortDate(lastWeekIso), money0(lastWeek.total)],
      [`<em>${diff >= 0 ? 'Increase' : 'Decrease'}</em>`, `<em>${diff >= 0 ? '+' : '−'}${money0(Math.abs(diff))} (${growth >= 0 ? '+' : ''}${pct(growth)})</em>`],
    ], ['left', 'right'])}
    <p style="${css.note}">Strictly this weekday against the same weekday one week ago. Nothing here is a month total or a forecast.</p>

    <div style="${css.h2}">💰 Money — ${longDate(iso)}</div>
    ${table(['Measure', 'Value'], [
      ["Today's total sales", money(sales.total)],
      ['Number of jobs today', String(jobs.length)],
      ['Prepaid &amp; settled today', money(received)],
      ['Outstanding today', money(outstanding)],
      ['Staff costs', '−' + money(wages.total)],
      ['Company costs', '−' + money(cost)],
      ['Total costs', '−' + money(totalCost)],
      ['Net profit — paid / settled', money(received - totalCost)],
      ['Net profit — still outstanding', money(outstanding)],
    ], ['left', 'right'])}
    <p style="${css.note}">Costs are charged in full against the settled figure, because wages and the company cost are payable whether or not the client has paid yet. The outstanding line is profit still to come — it is never counted as money you have.</p>

    <div style="${css.h2}">👥 Staff — Today</div>
    ${table(['Staff', 'Jobs', 'Sales', 'Paid', 'Left for Business'],
      Object.entries(perStaff).sort((a, b) => b[1].sales - a[1].sales).map(([nm, v]) =>
        [nm, String(v.jobs), money(v.sales), money(wages.per[nm] ?? 0), money(v.sales - (wages.per[nm] ?? 0))]),
      ['left', 'right', 'right', 'right', 'right'])}
    ${unattributed > 0 ? `<p style="${css.note}">${money(unattributed)} of today's sales has no run-sheet job attached, so it is not against anyone above.</p>` : ''}

    <div style="${css.h2}">🏆 Top Services — Month to Date</div>
    ${table(['Service', 'Jobs', 'Sales'],
      Object.entries(mSvc).sort((a, b) => b[1].sales - a[1].sales).map(([n, v]) => [n, String(v.n), money(v.sales)]),
      ['left', 'right', 'right'])}
    <p style="${css.note}">From the 1st of the month up to today. Each day simply adds to the running total.</p>

    <div style="${css.h2}">👤 Customers — Last 24 Hours</div>
    ${table(['Measure', 'Value'], [['Bookings made', String((newBookings ?? []).length)]], ['left', 'right'])}
    ${(newBookings ?? []).length ? '<p style="' + css.note + '">Who booked<br>' +
      (newBookings ?? []).map((b: Row) => `• ${b.client_name ?? ''} — ${b.dog_name ?? ''} ${money(Number(b.total ?? 0))}`).join('<br>') + '</p>' : ''}

    <div style="${css.h2}">🚐 Operations &amp; Safety — ${longDate(yIso)}</div>
    ${table(['Measure', 'Value'], [
      ['Vehicle checks completed', String(vChecks ?? 0)],
      ['Dogs collected', String(collected)],
      ['Dogs walked without an AirTag', String(noTag.length)],
    ], ['left', 'right'])}
    ${noTag.length ? `<p style="${css.note}">⚠️ ${noTag.length} dog(s) walked without an AirTag<br>` +
      noTag.map((j: Row) => `• ${j.dog_name} — ${names[(j.staff_email || '').toLowerCase()] || ''} — ${j.airtag_reason || 'not recorded'}`).join('<br>') + '</p>' : ''}

    ${alerts.length ? `<div style="${css.h2}">Owner Alerts</div>
      <div style="background:#FFFCE0;border:1px solid #F5EBA0;border-radius:10px;padding:14px 16px;font-size:13.5px;color:#8A7000;line-height:1.8">
        ${alerts.map((a) => '• ' + a).join('<br>')}
      </div>` : ''}

    <div style="${css.h2}">What This Means</div>
    <p style="font-size:13.5px;color:#444;line-height:1.7;margin:0">Today's run sheet carries ${money0(sales.total)} across ${jobs.length} jobs. ${money0(received)} of that is already settled and ${money0(outstanding)} still has to be collected. After ${money0(wages.total)} of wages and the ${money0(cost)} company cost, the business keeps ${money0(received - totalCost)} of money actually in, with a further ${money0(outstanding)} due once the outstanding work is paid for.${alerts.length ? ` Worth your attention: ${alerts.length} item(s) flagged above.` : ''}</p>`;

  return {
    subject: `4 Paw Friend — Morning Report — ${shortDate(iso)} — ${money0(sales.total)}`,
    html: shell('Morning Report', longDate(iso), inner),
    log: { dateIso: iso, jobs: jobs.length, sales: sales.total },
  };
}

// ---------------------------------------------------------------------------
async function close(sb: any, iso: string) {
  const [sales, wages, cost, jobs, names] = await Promise.all([
    daySales(sb, iso), dayWages(sb, iso), dayCompanyCost(sb, iso), dayJobs(sb, iso), staffNames(sb),
  ]);

  const contribution = sales.total - wages.total;
  const margin = sales.total > 0 ? (contribution / sales.total) * 100 : 0;
  const staffPctSales = sales.total > 0 ? (wages.total / sales.total) * 100 : 0;
  const avg = jobs.length ? sales.total / jobs.length : 0;

  const dogSale: Record<string, number> = {};
  for (const d of sales.dogs) dogSale[(d.dog || '').toLowerCase().trim()] = (dogSale[(d.dog || '').toLowerCase().trim()] ?? 0) + d.amount;
  const perStaff: Record<string, number> = {};
  let attributed = 0;
  for (const j of jobs) {
    const nm = names[(j.staff_email || '').toLowerCase()] || (j.staff_email || '').split('@')[0];
    const v = dogSale[(j.dog_name || '').toLowerCase().trim()] ?? 0;
    perStaff[nm] = (perStaff[nm] ?? 0) + v;
    attributed += v;
  }
  const unattributed = Math.max(0, sales.total - attributed);

  // Same weekday, previous 8 weeks.
  const hist: { iso: string; total: number }[] = [];
  for (let i = 1; i <= 8; i++) {
    const d = addDays(iso, -7 * i);
    hist.push({ iso: d, total: (await daySales(sb, d)).total });
  }
  const traded = hist.filter((h) => h.total > 0);
  const avgWeek = traded.length ? traded.reduce((a, b) => a + b.total, 0) / traded.length : 0;
  const vsAvg = avgWeek > 0 ? ((sales.total - avgWeek) / avgWeek) * 100 : 0;
  const best = traded.slice().sort((a, b) => b.total - a.total)[0];
  const quiet = traded.slice().sort((a, b) => a.total - b.total)[0];

  const staffRows = Object.entries(perStaff).sort((a, b) => b[1] - a[1]).map(([nm, sv]) => {
    const paid = wages.per[nm] ?? 0;
    return [nm, money0(sv), money0(paid), money0(sv - paid), sales.total ? pct((sv / sales.total) * 100) : '0.0%'];
  });
  const topSales = Object.entries(perStaff).sort((a, b) => b[1] - a[1])[0];

  const inner = `
    ${tiles([
      { label: 'Net Sales', value: money0(sales.total) },
      { label: 'Jobs', value: String(jobs.length), sub: 'avg ' + money0(avg) },
      { label: 'Staff Pay', value: money0(wages.total), sub: pct(staffPctSales) + ' of sales' },
      { label: 'Contribution', value: money0(contribution), sub: pct(margin) + ' margin' },
    ])}

    <div style="${css.h2}">Day Summary</div>
    ${table(['Measure', 'Value'], [
      ['Total net sales', money(sales.total)],
      ['Jobs completed', String(jobs.length)],
      ['Average sale per job', money(avg)],
      ['Total staff pay', money(wages.total)],
      ['Staff cost as % of sales', pct(staffPctSales)],
      ['Net contribution after staff costs', money(contribution)],
      ['Net contribution margin', pct(margin)],
      ['Company costs logged today', money(cost)],
      ['Contribution after staff + logged costs', money(contribution - cost)],
    ], ['left', 'right'])}
    <p style="${css.note}">Jobs are counted as distinct dog-days, not raw run-sheet rows — duplicate rows created by the tracker trigger would otherwise inflate the count.</p>

    <div style="${css.h2}">Staff Breakdown</div>
    ${table(['Staff', 'Sales', 'Paid', 'Contribution', '% of Sales'], staffRows, ['left', 'right', 'right', 'right', 'right'])}
    <p style="${css.note}">${unattributed > 0 ? money(unattributed) + " of today's sales had no run-sheet job attached, so it is not attributed to anyone above. " : ''}${topSales ? 'Highest sales: ' + topSales[0] + ' (' + money0(topSales[1]) + ').' : ''}</p>

    <div style="${css.h2}">Like-for-Like — Last 8 ${new Intl.DateTimeFormat('en-GB', { weekday: 'long', timeZone: 'Europe/London' }).format(new Date(iso + 'T12:00:00Z'))}s</div>
    ${table(['Day', 'Net Sales', 'Change'], [
      [`<strong>▶ TODAY — ${shortDate(iso)}</strong>`, `<strong>${money0(sales.total)}</strong>`, `${vsAvg >= 0 ? '+' : ''}${pct(vsAvg)} vs average`],
      ...hist.map((h) => [shortDate(h.iso), money0(h.total),
        h.total > 0 ? `${sales.total >= h.total ? '+' : ''}${pct(((sales.total - h.total) / h.total) * 100)} vs today` : '—']),
    ], ['left', 'right', 'right'])}
    <p style="${css.note}">Today: ${money(sales.total)} · Average over 8 weeks: ${money(avgWeek)} · Today vs that average: ${vsAvg >= 0 ? '+' : ''}${pct(vsAvg)}${best ? ' · Best: ' + shortDate(best.iso) + ' ' + money0(best.total) : ''}${quiet ? ' · Quietest: ' + shortDate(quiet.iso) + ' ' + money0(quiet.total) : ''}<br>Compared against the same weekday only — different weekdays trade too differently to be meaningful. Weeks with no trading are left out of the average rather than counted as zero.</p>

    <div style="${css.h2}">Services Today</div>
    ${table(['Service', 'Count', 'Sales'],
      Object.entries(sales.services).sort((a, b) => b[1].sales - a[1].sales).map(([n, v]) => [n, String(v.n), money0(v.sales)]),
      ['left', 'right', 'right'])}`;

  return {
    subject: `4 Paw Friend — Daily Close — ${shortDate(iso)} — ${money0(sales.total)}`,
    html: shell('Daily Close', longDate(iso), inner),
    log: { dateIso: iso, jobsCompleted: jobs.length, sales: sales.total, staffPay: wages.total, contribution },
  };
}

// ---------------------------------------------------------------------------
Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  if (url.searchParams.get('secret') !== SECRET) return new Response('forbidden', { status: 403 });

  const kind = (url.searchParams.get('kind') ?? 'morning').toLowerCase();
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  try {
    const { data: sec } = await sb.from('app_secrets').select('value').eq('key', 'resend_api_key').maybeSingle();
    const resendKey = sec?.value;
    if (!resendKey) return json({ error: 'no resend key' }, 500);

    // Morning reports on today; the close reports on the day that just traded.
    const iso = url.searchParams.get('date') ?? londonToday();

    const built = kind === 'close' ? await close(sb, iso) : await morning(sb, iso);

    if (url.searchParams.get('dry') === '1') {
      return new Response(built.html, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    }

    const rs = await (await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + resendKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM, to: TO, subject: built.subject, html: built.html }),
    })).json();

    await sb.from('activity_log').insert({
      type: kind === 'close' ? 'daily_close_sent' : 'daily_morning_sent',
      description: JSON.stringify({ ...built.log, resendId: rs?.id ?? null, error: rs?.message ?? null }),
      user_email: TO[0],
    });

    return json({ ok: !!rs?.id, kind, date: iso, resend: rs?.id ?? rs });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(b: unknown, s = 200) {
  return new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } });
}
