-- 2026-09-08 — Booking acceptance / invoice routing fix
--
-- BACKGROUND
-- Michael Triola (payment_type = 'upfront') had booking 4PF-4GOORE auto-routed onto
-- INV-1141, an August month-end invoice, even though the stay was 2-6 Sep. Tracing it
-- showed enforce_upfront_payment() had two defects:
--
--   (a) It decided prepayment from users.client_type alone and never consulted any
--       billing preference, so a client explicitly marked end_of_month could still be
--       forced to prepay.
--   (b) It attached the booking to the invoice for the CURRENT month rather than the
--       month the service actually falls in.
--
-- DELIBERATELY NOT CHANGED
-- The routing is NOT switched over to users.payment_type. That column is the schema
-- default on 108 of 112 users ('upfront') and does not represent a decision anyone made.
-- Keying off it would have forced 52 established month-end clients into awaiting_payment
-- simultaneously — the same failure that hit Maria Hundsnes-Shevtsova (4PF-UPIW0Q) in
-- August, at scale. Instead a curated billing_mode column is introduced, defaulting to
-- NULL so behaviour is unchanged until each client is explicitly set.
--
-- MEASURED EFFECT: of 112 users, exactly 1 resolves differently — Amrou Al-Kadhi, who is
-- marked end_of_month and was previously being forced to prepay. The change only ever
-- relaxes a demand for prepayment; it never adds one.

-- 1. Curated billing decision. NULL = undecided -> legacy client_type rule applies.
alter table public.users
  add column if not exists billing_mode text;

comment on column public.users.billing_mode is
  'Curated billing decision: ''upfront'' (must pay before the booking confirms) or ''end_of_month''. NULL means undecided - the legacy client_type rule applies. This, not payment_type, is what enforce_upfront_payment() reads.';

alter table public.users
  drop constraint if exists users_billing_mode_chk;
alter table public.users
  add constraint users_billing_mode_chk
  check (billing_mode is null or billing_mode in ('upfront','end_of_month'));

-- 2. Booking acceptance router.
create or replace function public.enforce_upfront_payment()
returns trigger
language plpgsql
security definer
as $function$
declare
  u record;
  mode text;
  inv record;
  svc_first date;
  mk_start date;
  mk_end date;
  nextnum int;
  has_line boolean;
  was_confirmed boolean;
begin
  was_confirmed := (TG_OP = 'UPDATE' and coalesce(old.status,'') = 'confirmed');

  if new.status = 'confirmed' and not was_confirmed and coalesce(new.paid,false) = false then

    select client_type, payment_type, billing_mode
      into u
      from users
     where email = new.email;

    -- Curated billing_mode wins. Failing that, an explicit end_of_month payment_type
    -- is honoured (this only ever RELAXES a demand for prepayment, never adds one).
    -- Otherwise the original client_type rule, unchanged.
    mode := coalesce(
      nullif(u.billing_mode, ''),
      case
        when u.payment_type = 'end_of_month' then 'end_of_month'
        when coalesce(u.client_type, 'new') = 'new' then 'upfront'
        else 'end_of_month'
      end);

    if mode = 'upfront' then
      new.status := 'awaiting_payment';

      -- Bill against the month the service falls in, not the month it was booked.
      select min(case
                   when d.val ~ '^\d{4}-\d{2}-\d{2}$' then d.val::date
                   when d.val ~ '^[0-9]{1,2} [A-Za-z]{3} [0-9]{4}$' then to_date(d.val,'DD Mon YYYY')
                 end)
        into svc_first
        from jsonb_array_elements_text(coalesce(new.dates,'[]'::jsonb)) d(val);

      mk_start := date_trunc('month',
                    coalesce(svc_first, (now() at time zone 'Europe/London')::date))::date;
      mk_end   := (mk_start + interval '1 month - 1 day')::date;

      select * into inv
        from invoices
       where client_email = new.email
         and billing_period_start = mk_start
         and invoice_number < 9000
       order by invoice_number
       limit 1;

      if inv.id is null then
        select coalesce(max(invoice_number),1000) + 1 into nextnum
          from invoices where invoice_number < 9000;
        insert into invoices (invoice_number, client_email, client_name,
                              billing_period_start, billing_period_end,
                              line_items, total, status, email_sent, paid_confirmed)
        values (nextnum, new.email, new.client_name, mk_start, mk_end,
                '[]'::jsonb, 0, 'sent', false, false)
        returning * into inv;
      end if;

      select exists (
        select 1 from jsonb_array_elements(coalesce(inv.line_items,'[]'::jsonb)) l
         where l->>'booking_ref' = new.booking_ref
      ) into has_line;

      if not has_line then
        update invoices set
          line_items = coalesce(line_items,'[]'::jsonb) || jsonb_build_array(jsonb_build_object(
            'service', coalesce(new.summary,'Booking'),
            'dog', new.dog_name,
            'date', to_char(coalesce(svc_first, (now() at time zone 'Europe/London')::date),'YYYY-MM-DD'),
            'amount', new.total,
            'booking_ref', new.booking_ref)),
          total = coalesce(total,0) + coalesce(new.total,0),
          paid_confirmed = false
        where id = inv.id;

        insert into activity_log (type, description, user_email) values (
          'booking_held_unpaid',
          '⏳ ' || coalesce(new.booking_ref,'?') || ' (' || coalesce(new.dog_name,'') || ' — ' ||
          coalesce(new.client_name, new.email) || ') accepted → AWAITING PAYMENT. £' ||
          coalesce(new.total,0)::text || ' added to INV-' || inv.invoice_number ||
          ' (period ' || to_char(mk_start,'Mon YYYY') || '). Confirms automatically on payment.',
          new.email);
      end if;
    end if;
  end if;

  return new;
end $function$;

-- 3. Data correction: three bookings were paid but left stuck in 'awaiting_payment',
--    so they read as unpaid on reports and would be re-chased if the reminder cron
--    is re-enabled.
--
--      4PF-THO811     Celia Niven / Barry Boydell   Thomas    £100   11-16 Aug
--      4PF-MILO-SEP8  Gosia Dorot                   Milo      £60    8-9 Sep
--      4PF-POPON2     Shamim Daniels                Popcorn   £50    2-3 Sep
--
--    trg_zz3_confirm_email and trg_push_booking_confirmed both fire on a status change
--    and would have emailed / pushed each client about a booking that has already
--    happened. All three had confirmation_email_sent_at = null, so the function's own
--    guard would not have suppressed it. Triggers are therefore disabled around the
--    update. trg_booking_to_runsheet is disabled too, to avoid re-posting run sheet
--    jobs for dates already served.
alter table public.bookings disable trigger trg_zz3_confirm_email;
alter table public.bookings disable trigger trg_push_booking_confirmed;
alter table public.bookings disable trigger trg_booking_to_runsheet;

update public.bookings
   set status = 'confirmed'
 where booking_ref in ('4PF-THO811','4PF-MILO-SEP8','4PF-POPON2')
   and paid = true
   and status = 'awaiting_payment';

alter table public.bookings enable trigger trg_zz3_confirm_email;
alter table public.bookings enable trigger trg_push_booking_confirmed;
alter table public.bookings enable trigger trg_booking_to_runsheet;
