-- 2026-09-08 (e) — Stop the tracker wiping hand-typed staff wages
--
-- Joe: "I keep putting staff wages onto the tracker, and they keep going missing."
--
-- CAUSE
-- f_sync_staff_wages() wrote the engine's figure straight over daily_wages[date] with no
-- check for whether a person had put that number there. It fires from three triggers -
-- any insert, update or delete on run_sheet_jobs, daycare_rota or shifts - so a wage typed
-- into the tracker survived only until the next time anything touched that day's jobs.
-- A booking landing, a pickup time edit, even a key number change was enough.
--
-- Only dates from engine_start_date (29 Aug 2026) were affected, and only the seven names
-- the sync loops over: Jefferson, Markos, Jack, Steve, Luke, Austin, Joe. Yvonne, Richard
-- and Kristian were never touched, which matches what Joe had noticed.
--
-- FIX
-- Record what the engine last wrote, in engine_wages. On each sync, if the value sitting in
-- daily_wages differs from the engine's last write, a person changed it, so leave it alone.
-- engine_wages still advances, so the entry stays protected from then on.
--
-- To hand a date back to the engine, drop that key from engine_wages:
--   update ledger_staff set engine_wages = engine_wages - '2026-09-08' where id = ...;

alter table public.ledger_staff
  add column if not exists engine_wages jsonb not null default '{}'::jsonb;

comment on column public.ledger_staff.engine_wages is
  'What f_sync_staff_wages() last computed per date. If daily_wages differs from this for a date, the value was entered by hand and the sync will not overwrite it.';

-- Existing values are treated as engine-written, so protection starts from now.
update public.ledger_staff
   set engine_wages = coalesce(daily_wages, '{}'::jsonb)
 where engine_wages = '{}'::jsonb;

create or replace function public.f_sync_staff_wages(p_date date)
returns void
language plpgsql
security definer
as $function$
declare
  v_start date;
  v_mk text := to_char(p_date,'YYYY-MM');
  v_iso text := to_char(p_date,'YYYY-MM-DD');
  v_name text;
  v_wage numeric;
  v_id bigint;
  v_current text;
  v_last_engine text;
begin
  select value::date into v_start from staff_wage_settings where key = 'engine_start_date';
  if p_date < coalesce(v_start, p_date) then return; end if;

  foreach v_name in array array['Jefferson','Markos','Jack','Steve','Luke','Austin','Joe'] loop
    v_wage := f_staff_day_wage(v_name, p_date);

    select id, daily_wages->>v_iso, engine_wages->>v_iso
      into v_id, v_current, v_last_engine
      from ledger_staff
     where month_key = v_mk and lower(staff_name) = lower(v_name)
     limit 1;

    if v_id is null then
      if v_wage > 0 then
        insert into ledger_staff (month_key, staff_name, daily_wages, engine_wages)
        values (v_mk, v_name,
                jsonb_build_object(v_iso, v_wage),
                jsonb_build_object(v_iso, v_wage));
      end if;
    elsif v_current is not null and v_last_engine is not null
          and v_current::numeric is distinct from v_last_engine::numeric then
      -- Entered by hand. Leave the figure alone; just move the engine's marker on.
      update ledger_staff
         set engine_wages = coalesce(engine_wages,'{}'::jsonb) || jsonb_build_object(v_iso, v_wage)
       where id = v_id;
    else
      update ledger_staff
         set daily_wages  = coalesce(daily_wages,'{}'::jsonb)  || jsonb_build_object(v_iso, v_wage),
             engine_wages = coalesce(engine_wages,'{}'::jsonb) || jsonb_build_object(v_iso, v_wage)
       where id = v_id;
    end if;
  end loop;
end;
$function$;

-- Verified: Jefferson hand-set to 999 for 8 Sep survived a sync that computed 66.

-- ---------------------------------------------------------------------------
-- Rota entries for this week, so the engine produces these wages itself rather
-- than Joe typing them (and having them overwritten).
--   Austin  Thu       = Morning                  = GBP80
--   Luke    Tue, Wed  = Morning                  = GBP80
--   Luke    Thu       = Morning + Evening        = GBP120
-- Shift rates: Morning 80, Evening 40, Saturday 100, Owner 0.
-- ---------------------------------------------------------------------------
insert into public.daycare_rota (rota_date, staff_name, shift_name) values
  (date '2026-09-08','Luke','Morning'),
  (date '2026-09-09','Luke','Morning'),
  (date '2026-09-10','Luke','Morning'),
  (date '2026-09-10','Luke','Evening'),
  (date '2026-09-10','Austin','Morning')
on conflict (rota_date, staff_name, shift_name) do nothing;

-- Jack: GBP80 cash handed over on 8 Sep, recorded as an advance. His earned wage that
-- day is unchanged at GBP120 - the cash is money already paid out, not a lower wage.
update public.ledger_staff
   set advances = coalesce(advances,'[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'id','advsep-jack-cash-20260908','date','2026-09-08','note','Cash advance paid to Jack','amount',80))
 where month_key = '2026-09' and staff_name = 'Jack'
   and not exists (select 1 from jsonb_array_elements(coalesce(advances,'[]'::jsonb)) a
                   where a->>'id' = 'advsep-jack-cash-20260908');
