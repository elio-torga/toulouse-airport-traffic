-- =====================================================================
-- 02_transform.sql — staging (raw text) -> typed star schema
-- Run after python/load_staging.py. Idempotent: it rebuilds dims and facts.
-- =====================================================================

-- French decimal comma + empty strings -> numeric
CREATE OR REPLACE FUNCTION staging.to_num(v text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(NULLIF(replace(trim(v), ',', '.'), '')::numeric, 0)
$$;

TRUNCATE fact_forecast, fact_route_traffic, fact_airport_traffic, dim_route, dim_airport RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- dim_airport — French airports from APT, keeping each airport's most recent name
-- ---------------------------------------------------------------------
INSERT INTO dim_airport (icao, name, zone)
SELECT DISTINCT ON (apt)
       apt,
       trim(apt_nom),
       CASE WHEN apt LIKE 'ZZ%' THEN 'AGGREGATE'      -- "other airports" rows under 1,000 pax
            WHEN apt_zon = 'MT'  THEN 'METRO'
            ELSE 'OVERSEAS' END
FROM staging.stg_apt
ORDER BY apt, anmois DESC;

-- Airports that only appear in PAP routes are foreign airports
WITH route_ends AS (
    SELECT anmois, split_part(pap, '_', 1) AS icao, trim(pap1_label) AS name FROM staging.stg_pap
    UNION ALL
    SELECT anmois, split_part(pap, '_', 2),         trim(pap2_label)         FROM staging.stg_pap
)
INSERT INTO dim_airport (icao, name, zone)
SELECT DISTINCT ON (icao) icao, name, 'FOREIGN'
FROM route_ends
WHERE icao NOT IN (SELECT icao FROM dim_airport)
ORDER BY icao, anmois DESC;

-- ---------------------------------------------------------------------
-- dim_route — one row per PAP code, latest published distance
-- ---------------------------------------------------------------------
INSERT INTO dim_route (route_code, airport_1_id, airport_2_id, distance_km)
SELECT DISTINCT ON (s.pap)
       s.pap, a1.airport_id, a2.airport_id, staging.to_num(s.pap_dist)::int
FROM staging.stg_pap s
JOIN dim_airport a1 ON a1.icao = split_part(s.pap, '_', 1)
JOIN dim_airport a2 ON a2.icao = split_part(s.pap, '_', 2)
ORDER BY s.pap, s.anmois DESC;

-- ---------------------------------------------------------------------
-- Facts
-- ---------------------------------------------------------------------
INSERT INTO fact_airport_traffic (date_id, airport_id, pax_departing, pax_arriving, pax_transit,
                                  freight_dep_t, freight_arr_t, movements_pax, movements_cargo, peq_reported)
SELECT s.anmois::int,
       a.airport_id,
       staging.to_num(s.apt_pax_dep)::int,
       staging.to_num(s.apt_pax_arr)::int,
       staging.to_num(s.apt_pax_tr)::int,
       -- 19 source rows (small French Polynesia airfields) carry -0.1/-0.2 t of freight:
       -- rounding artefacts of corrections. Floored at 0, counted in 03_quality_checks.sql.
       GREATEST(staging.to_num(s.apt_frp_dep), 0),
       GREATEST(staging.to_num(s.apt_frp_arr), 0),
       staging.to_num(s.apt_nmvt_mxt)::int,
       staging.to_num(s.apt_nmvt_cgo)::int,
       staging.to_num(s.apt_peq)::int
FROM staging.stg_apt s
JOIN dim_airport a ON a.icao = s.apt;

INSERT INTO fact_route_traffic (date_id, route_id, pax_local, pax_onboard, freight_local_t, services, movements)
SELECT s.anmois::int,
       r.route_id,
       staging.to_num(s.pap_pax)::int,
       staging.to_num(s.pap_pax_fs)::int,
       staging.to_num(s.pap_frp),
       staging.to_num(s.pap_drt)::int,
       staging.to_num(s.pap_mvt)::int
FROM staging.stg_pap s
JOIN dim_route r ON r.route_code = s.pap;

ANALYZE dim_airport, dim_route, fact_airport_traffic, fact_route_traffic;
