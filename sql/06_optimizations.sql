-- =====================================================================
-- 06_optimizations.sql — optimisation steps applied one after the other
-- python/run_benchmark.py runs each "@stage" block, then times the three
-- benchmark queries (see the bottom of this file) with EXPLAIN ANALYZE.
-- =====================================================================

-- @stage baseline
-- No index at all: every query has to read the whole 17.6 M-row table.
DROP MATERIALIZED VIEW IF EXISTS bench.mv_monthly_airport;
DROP TABLE IF EXISTS bench.flights_part;
DROP INDEX IF EXISTS bench.idx_flights_airport_date;
DROP INDEX IF EXISTS bench.idx_flights_date_brin;

-- @stage btree
-- Composite B-tree on the filter columns + INCLUDE(pax): "one airport over a period"
-- queries become index-only scans (the table itself is never read).
CREATE INDEX idx_flights_airport_date ON bench.flights (airport_id, flight_date) INCLUDE (pax);
VACUUM ANALYZE bench.flights;

-- @stage brin
-- BRIN on the date: rows are stored in time order, so a block-range index of a few
-- hundred kB is enough to skip every block outside the requested period.
CREATE INDEX idx_flights_date_brin ON bench.flights USING brin (flight_date) WITH (pages_per_range = 32);
ANALYZE bench.flights;

-- @stage partitioned
-- Same data, partitioned by year: a query on 2024 only touches the 2024 partition.
CREATE TABLE bench.flights_part (LIKE bench.flights INCLUDING DEFAULTS) PARTITION BY RANGE (flight_date);
DO $$
BEGIN
    FOR y IN 2015..2025 LOOP
        EXECUTE format('CREATE TABLE bench.flights_part_%s PARTITION OF bench.flights_part
                        FOR VALUES FROM (%L) TO (%L)', y, make_date(y, 1, 1), make_date(y + 1, 1, 1));
    END LOOP;
END $$;
INSERT INTO bench.flights_part SELECT * FROM bench.flights;
CREATE INDEX ON bench.flights_part (airport_id, flight_date) INCLUDE (pax);
VACUUM ANALYZE bench.flights_part;

-- @stage matview
-- Pre-aggregate once per month and airport: 17.6 M rows -> ~11 k rows.
-- Dashboards read this; it is refreshed when new data arrives (REFRESH MATERIALIZED VIEW).
CREATE MATERIALIZED VIEW bench.mv_monthly_airport AS
SELECT airport_id,
       date_trunc('month', flight_date)::date AS month,
       count(*)  AS flights,
       sum(pax)  AS pax
FROM bench.flights
GROUP BY airport_id, date_trunc('month', flight_date);
CREATE INDEX ON bench.mv_monthly_airport (airport_id, month);
ANALYZE bench.mv_monthly_airport;


-- =====================================================================
-- Benchmark queries ({table} = bench.flights or bench.flights_part, {tls} = Toulouse id)
-- =====================================================================

-- @query A_daily_month — Toulouse, daily traffic for July 2025
SELECT flight_date, count(*) AS flights, sum(pax) AS pax
FROM {table}
WHERE airport_id = {tls} AND flight_date >= DATE '2025-07-01' AND flight_date < DATE '2025-08-01'
GROUP BY flight_date
ORDER BY flight_date;

-- @query B_year_ranking — top 10 airports of 2024
SELECT airport_id, sum(pax) AS pax
FROM {table}
WHERE flight_date >= DATE '2024-01-01' AND flight_date < DATE '2025-01-01'
GROUP BY airport_id
ORDER BY pax DESC
LIMIT 10;

-- @query B_year_ranking_mv — same question answered from the materialized view
SELECT airport_id, sum(pax) AS pax
FROM bench.mv_monthly_airport
WHERE month >= DATE '2024-01-01' AND month < DATE '2025-01-01'
GROUP BY airport_id
ORDER BY pax DESC
LIMIT 10;

-- @query C_monthly_trend — Toulouse, monthly passengers over 11 years
SELECT date_trunc('month', flight_date) AS month, sum(pax) AS pax
FROM {table}
WHERE airport_id = {tls}
GROUP BY 1
ORDER BY 1;

-- @query C_monthly_trend_mv — same question answered from the materialized view
SELECT month, pax
FROM bench.mv_monthly_airport
WHERE airport_id = {tls}
ORDER BY month;
