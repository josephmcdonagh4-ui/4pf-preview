-- 2026-09-08 (c) — Booking status and invoice reconciliation
--
-- All updates below are data corrections confirmed by Joe. No client is contacted:
-- trg_zz3_confirm_email and trg_push_booking_confirmed fire on a booking status change
-- and would email/push each client about stays that have already happened, so they are
-- disabled around the booking updates. There are no triggers on public.invoices.

-- ---------------------------------------------------------------------------
-- 1. Bookings paid but left in 'awaiting_payment'
-- ---------------------------------------------------------------------------
-- 4PF-THO811     Celia Niven / Barry Boydell   Thomas    GBP100  11-16 Aug
-- 4PF-MILO-SEP8  Gosia Dorot                   Milo      GBP60   8-9 Sep
-- 4PF-POPON2     Shamim Daniels                Popcorn   GBP50   2-3 Sep
-- (applied in 20260908_fix_upfront_routing.sql)
--
-- 4PF-QVNTYX     Joanna Brecher                Rocco     GBP135  2/7/9 Sep  - Joe: paid
-- 4PF-VV9FVZ     Alastair Woods                Txuri     GBP100  7-8 Sep    - Joe: paid
alter table public.bookings disable trigger trg_zz3_confirm_email;
alter table public.bookings disable trigger trg_push_booking_confirmed;
alter table public.bookings disable trigger trg_booking_to_runsheet;

update public.bookings
   set paid = true, status = 'confirmed'
 where booking_ref in ('4PF-QVNTYX','4PF-VV9FVZ');

alter table public.bookings enable trigger trg_zz3_confirm_email;
alter table public.bookings enable trigger trg_push_booking_confirmed;
alter table public.bookings enable trigger trg_booking_to_runsheet;

-- ---------------------------------------------------------------------------
-- 2. INV-1085 (Joanna Brecher, Aug) — duplicated booking line
-- ---------------------------------------------------------------------------
-- Booking 4PF-QVNTYX was written onto the AUGUST invoice as a single GBP135 line dated
-- 26 Aug (the day it was accepted), but its sessions are 2, 7 and 9 Sep and those days
-- are itemised at GBP45 each on the September invoice INV-1151. The same GBP135 was on
-- two invoices. This is the routing bug fixed in 20260908: the booking was billed to the
-- month it was accepted in rather than the month the service falls in.
--
-- Removing the duplicate leaves ten GBP45 daycare lines = GBP450, matching the GBP450
-- already recorded as paid, so the invoice closes flat. Its stated total of GBP135 was
-- also wrong (line items summed to GBP585), which is what produced the phantom -GBP315
-- credit. Joe: "she is paid and up to date apart from 1 beach ticket".
update public.invoices
   set line_items = (select coalesce(jsonb_agg(l),'[]'::jsonb)
                       from jsonb_array_elements(line_items) l
                      where coalesce(l->>'booking_ref','') <> '4PF-QVNTYX'),
       total = 450,
       bank_paid_applied = 450,
       paid_confirmed = true,
       paid_confirmed_at = now(),
       status = 'paid',
       last_updated = now()
 where invoice_number = 1085;

-- ---------------------------------------------------------------------------
-- 3. INV-1151 (Joanna Brecher, Sep) — GBP65 beach trip outstanding
-- ---------------------------------------------------------------------------
-- GBP200 of lines: 2 Sep GBP45, 5 Sep Beach Trip GBP65, 7 Sep GBP45, 9 Sep GBP45.
-- The GBP135 of daycare is paid; the beach ticket is the only thing still owed.
update public.invoices
   set bank_paid_applied = 135,
       paid_confirmed = false,
       status = 'sent',
       last_updated = now()
 where invoice_number = 1151;

-- ---------------------------------------------------------------------------
-- 4. INV-1159 (Alastair Woods, Sep) — fully paid
-- ---------------------------------------------------------------------------
-- GBP190 = 3 Sep GBP90 (booking 4PF-PPKU3B) + 7 Sep GBP50 + 8 Sep GBP50 (4PF-VV9FVZ).
-- Two bookings, and Joe confirms both are paid.
update public.invoices
   set bank_paid_applied = 190,
       paid_confirmed = true,
       paid_confirmed_at = now(),
       status = 'paid',
       last_updated = now()
 where invoice_number = 1159;

-- ---------------------------------------------------------------------------
-- STILL OUTSTANDING (not addressed here — needs Joe's decisions)
-- ---------------------------------------------------------------------------
-- * 40 invoices where the stated total does not match the sum of their own line items,
--   net GBP8,394 UNDER-stated (i.e. work itemised but not billed). 15 of those have
--   total = 0 despite carrying line items. Root cause not yet identified: something
--   appends to line_items without incrementing total.
-- * Paula Castellino 4PF-JL8VOM, GBP560, 30 Dec - 4 Jan, unpaid and never chased.
-- * Vivi Radway 4PF-P3WEQD, GBP60, 10-11 Sep: she is an invoice (month-end) client and
--   the GBP60 is already on INV-1235, so she should not be in awaiting_payment at all.
--   Some path other than enforce_upfront_payment() put her there - unidentified.
-- * cron job payment-reminders (jobid 9) disabled since 22 Aug; publish-due, ops-watchdog,
--   vps-watchdog, midday-report-a/b also disabled. None re-enabled: all of them send.
