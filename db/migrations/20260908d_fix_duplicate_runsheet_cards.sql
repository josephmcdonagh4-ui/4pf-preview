-- 2026-09-08 (d) — Duplicate run sheet cards
--
-- Reported as two "Martha" cards on one day: one showing HALF DAYCARE 09:00-14:00, one blank.
--
-- CAUSE
-- A job reaches run_sheet_jobs by two routes:
--   fn_ledger_to_runsheet   - from the Finance Tracker row
--   fn_booking_to_runsheet  - from the booking
-- The booking trigger checks for an existing card before adding one, but only matches
-- cards of the SAME job class (f_job_class).
--
-- Martha's tracker row was filed under section 'group1' (walks) while the charges on it
-- were half-daycare (GBP35). So the tracker built a class 'walk' card with no times, the
-- booking built a class 'daycare' card, the classes did not match, and both survived.
-- Which one appeared first was down to trigger order, which is why 8 Sep had one card and
-- the 9th and 14th had two.
--
-- Same fault previously recorded against Lola on 7 Aug: "the row existed but was EMPTY and
-- filed under group1 (walks)".
--
-- The money was never affected - the ledger holds the GBP35 once. Only the run sheet
-- duplicated, which overstates the day's work and could send a walker to a job twice.

-- ---------------------------------------------------------------------------
-- 1. Remove blank placeholder cards that have a real sibling on the same day.
--    Backed up first, following the existing *_phantom_backup_* convention.
--    Restricted to future-dated, uncollected work so no history or wages shift.
-- ---------------------------------------------------------------------------
create table if not exists public.run_sheet_jobs_phantom_backup_20260908 as
select r.* from public.run_sheet_jobs r
where nullif(r.pickup_time,'') is null
  and nullif(r.dropoff_time,'') is null
  and r.source_booking_id is null
  and nullif(r.notes,'') is null
  and coalesce(r.collected,false) = false
  and coalesce(r.dropped_off,false) = false
  and r.job_date >= current_date
  and exists (
    select 1 from public.run_sheet_jobs x
    where x.id <> r.id
      and x.job_date = r.job_date
      and f_dogkey(x.dog_name) = f_dogkey(r.dog_name)
      and coalesce(lower(trim(x.client_email)),'') = coalesce(lower(trim(r.client_email)),'')
  );

delete from public.run_sheet_jobs r
where r.id in (select id from public.run_sheet_jobs_phantom_backup_20260908);

-- 15 rows: Martha (9 + 14 Sep), Buxton, Lilah, Blake x6, Polly & 00 x4, Betsy.

-- ---------------------------------------------------------------------------
-- 2. Martha's tracker row was in the wrong section.
-- ---------------------------------------------------------------------------
update public.ledger_dogs
   set section = 'daycare'
 where id = 581 and client_email = 'sophie_hogg@talk21.com' and section = 'group1';

-- ---------------------------------------------------------------------------
-- 3. Stop it recurring: treat a blank placeholder as a match regardless of class.
--    A card with no pickup time, no dropoff time, no notes and no source booking is a
--    Finance Tracker placeholder, not a genuine second job. Claim and fill it in - and
--    correct its class - rather than adding a second card beside it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_booking_to_runsheet()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare ds text; d date; is_da boolean; dname text; em text;
        pt text; dt2 text; v_daycare boolean; v_overnight boolean; v_notes text; v_key text;
        v_class text;
        existing_id bigint;
        v_time_edited boolean;
        v_target_pickup text; v_target_dropoff text;
begin
  if coalesce(NEW.status,'') in ('cancelled','declined','rejected') or coalesce(NEW.charge_cancelled,false) then return NEW; end if;
  if NEW.dates is null or jsonb_typeof(NEW.dates) <> 'array' then return NEW; end if;
  em := lower(trim(NEW.email));
  is_da := (em = 'butler.jadzia@gmail.com');
  dname := case when is_da then 'Duke & Austin' else NEW.dog_name end;
  if nullif(trim(dname),'') is null then return NEW; end if;

  select p.pickup, p.dropoff into pt, dt2 from public.f_parse_job_times(NEW.opt_label, NEW.service_id) p;

  v_time_edited := (TG_OP = 'UPDATE' and NEW.opt_label is distinct from OLD.opt_label);

  v_daycare  := (NEW.service_id = 'daycare');
  v_overnight := (NEW.service_id = 'overnight');
  v_notes := case
               when v_daycare and NEW.opt_label ilike '%half%' then 'Half Day daycare'
               when NEW.service_id = 'home-visit' then 'Home Visit'
               when NEW.service_id = 'home-feed'  then 'Home Feeding Visit'
               when NEW.service_id = 'pet-taxi'   then 'Pet Taxi'
               when NEW.service_id = 'beach-trip' then 'Beach Trip'
               else null end;
  v_key := coalesce(nullif(NEW.key_number,''), f_client_key(NEW.email));
  v_class := f_svc_class(NEW.service_id);

  for ds in select jsonb_array_elements_text(NEW.dates) loop
    d := null;
    begin
      if ds ~ '^\d{4}-\d{2}-\d{2}$' then d := to_date(ds,'YYYY-MM-DD');
      elsif ds ~ '^\d{1,2} [A-Za-z]{3} \d{4}$' then d := to_date(ds,'DD Mon YYYY');
      end if;
    exception when others then d := null; end;
    if d is null or d < current_date then continue; end if;

    select r.id into existing_id
    from run_sheet_jobs r
    where r.job_date = d
      and (
        r.source_booking_id = NEW.id
        or (
          (lower(trim(coalesce(r.client_email,''))) = em or f_dogkey(r.dog_name) = f_dogkey(dname))
          and coalesce(r.overnight,false) = v_overnight
          and coalesce(r.is_daycare,false) = v_daycare
          and f_job_class(r.is_daycare, r.overnight, r.notes) = v_class
        )
        -- A blank, timeless, unsourced card is a Finance Tracker placeholder. Claim it
        -- whatever class it was filed as, instead of adding a second card beside it.
        or (
          (lower(trim(coalesce(r.client_email,''))) = em or f_dogkey(r.dog_name) = f_dogkey(dname))
          and r.source_booking_id is null
          and nullif(r.pickup_time,'')  is null
          and nullif(r.dropoff_time,'') is null
          and nullif(r.notes,'')        is null
          and coalesce(r.collected,false)   = false
          and coalesce(r.dropped_off,false) = false
        )
      )
    order by (r.source_booking_id = NEW.id) desc, (nullif(r.pickup_time,'') is not null) desc, r.id
    limit 1;

    if existing_id is not null then
      select case when v_time_edited and pt  is not null then pt
                  else coalesce(nullif(r.pickup_time,''),  pt)  end,
             case when v_time_edited and dt2 is not null then dt2
                  else coalesce(nullif(r.dropoff_time,''), dt2) end
        into v_target_pickup, v_target_dropoff
      from run_sheet_jobs r where r.id = existing_id;

      update run_sheet_jobs r
         set source_booking_id = coalesce(r.source_booking_id, NEW.id),
             pickup_time  = v_target_pickup,
             dropoff_time = v_target_dropoff,
             is_daycare   = case when r.source_booking_id is null
                                  and nullif(r.pickup_time,'') is null
                                  and nullif(r.notes,'') is null
                                 then v_daycare else r.is_daycare end,
             overnight    = case when r.source_booking_id is null
                                  and nullif(r.pickup_time,'') is null
                                  and nullif(r.notes,'') is null
                                 then v_overnight else r.overnight end,
             notes        = coalesce(nullif(r.notes,''), v_notes)
       where r.id = existing_id
         and not exists (
           select 1 from run_sheet_jobs x
           where x.id <> r.id
             and x.dog_name = r.dog_name
             and coalesce(x.client_email,'') = coalesce(r.client_email,'')
             and x.job_date = r.job_date
             and nullif(x.pickup_time,'') is not distinct from nullif(v_target_pickup,'')
             and f_job_class(x.is_daycare, x.overnight, x.notes) = f_job_class(r.is_daycare, r.overnight, r.notes)
         );
      continue;
    end if;

    if pt is null and exists (
      select 1 from run_sheet_jobs x
      where x.job_date = d
        and (lower(trim(coalesce(x.client_email,''))) = em or f_dogkey(x.dog_name) = f_dogkey(dname))
        and f_job_class(x.is_daycare, x.overnight, x.notes) = v_class
    ) then
      continue;
    end if;

    if not exists (
      select 1 from run_sheet_jobs x
      where x.dog_name = dname
        and coalesce(x.client_email,'') = coalesce(NEW.email,'')
        and x.job_date = d
        and nullif(x.pickup_time,'') is not distinct from nullif(pt,'')
        and f_job_class(x.is_daycare, x.overnight, x.notes) = v_class
    ) then
      insert into run_sheet_jobs (staff_email, dog_name, client_email, client_name, job_date, is_recurring, source_booking_id,
                                  pickup_time, dropoff_time, is_daycare, overnight, notes, key_number)
      values ('josephmcdonagh4@googlemail.com', dname, NEW.email, NEW.client_name, d, false, NEW.id,
              pt, dt2, v_daycare, v_overnight, v_notes, v_key);
    end if;
  end loop;
  return NEW;
end;
$function$;

-- ---------------------------------------------------------------------------
-- NOT ADDRESSED - both cards carry real times, so which is correct is a judgement call:
--   * Lexi (Layla Adaci) 10, 15, 17, 22 Sep and on: tracker says daycare 11:30-13:00,
--     booking says walk 11:00. Same dog, same day, overlapping.
--   * Bear (Christopher Hutton) 15 Sep: tracker says "Evening care 17:00-23:00" (daycare),
--     booking says overnight 17:30-09:00.
-- Duke & Austin's multiple cards per day are legitimate - morning walk, afternoon walk and
-- sometimes an evening feed are genuinely separate jobs.
