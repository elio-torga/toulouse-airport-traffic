-- =====================================================================
-- 05_performance_setup.sql — a realistic large table to benchmark on
--
-- The real fact tables are small (~40k rows), too small for indexes to matter.
-- So we SIMULATE a flight-level table from the real monthly totals:
--   * one row per commercial passenger movement published by the DGAC (2015-2025)
--   * a random day inside the real month
--   * passengers drawn around the real monthly average per flight (+/- 40%)
-- Result: ~17.6 million rows whose monthly sums match the real data's shape.
-- It is clearly labelled SIMULATED and never used for the traffic analysis.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS bench;
DROP TABLE IF EXISTS bench.flights CASCADE;

CREATE TABLE bench.flights (
    flight_id    bigint   GENERATED ALWAYS AS IDENTITY,
    airport_id   integer  NOT NULL,
    flight_date  date     NOT NULL,
    pax          smallint NOT NULL
);

SELECT setseed(0.42);   -- reproducible simulation

INSERT INTO bench.flights (airport_id, flight_date, pax)
SELECT f.airport_id,
       d.month_start + floor(random() * extract(day FROM d.month_start + interval '1 month - 1 day'))::int,
       round(f.pax_total::numeric / f.movements_pax * (0.6 + 0.8 * random()))::smallint
FROM fact_airport_traffic f
JOIN dim_date d USING (date_id)
CROSS JOIN LATERAL generate_series(1, f.movements_pax)
WHERE d.year >= 2015
  AND f.movements_pax > 0
ORDER BY d.date_id;        -- rows stored in time order, as an append-only flight log would be

VACUUM ANALYZE bench.flights;
