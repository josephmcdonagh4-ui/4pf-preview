-- 2026-09-08 (b) — Simplify the billing rule to what Joe actually stated
--
-- "Whoever is on invoice pays at the end of the month, whoever is not pays up front."
--
-- That is users.client_type and nothing else:
--     client_type = 'invoice'  -> end_of_month   (55 users)
--     anything else            -> upfront        (58 users, all 'new')
--
-- users.payment_type is deliberately NOT consulted. It is the schema default
-- ('upfront') on 108 of 112 users, and where it has been hand-edited it contradicts
-- the rule — Amrou Al-Kadhi is client_type='new' (so pays upfront) but was carrying
-- payment_type='end_of_month'. Migration 20260908 honoured that flag; this migration
-- removes it, because the rule says otherwise.
--
-- billing_mode (added in 20260908) is kept ONLY as a manual per-client override for
-- genuine one-offs. It is NULL for every user, so the rule governs everyone. It can be
-- dropped entirely if no override is ever wanted.
--
-- The service-month invoice fix from 20260908 is retained: a booking is billed against
-- the month the service falls in, not the month it happened to be accepted in.

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

    select client_type, billing_mode
      into u
      from users
     where email = new.email;

    -- On invoice -> month end. Anything else -> upfront.
    -- billing_mode overrides, for explicit one-offs only.
    mode := coalesce(
      nullif(u.billing_mode, ''),
      case when u.client_type = 'invoice' then 'end_of_month' else 'upfront' end);

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

-- Override: Michael Triola is client_type='invoice' (so the rule would bill him at month
-- end) but he only ever books boarding, which is paid upfront. Set explicitly rather than
-- bending the rule for everyone.
update public.users set billing_mode = 'upfront' where email = 'triola_michael@icloud.com';
