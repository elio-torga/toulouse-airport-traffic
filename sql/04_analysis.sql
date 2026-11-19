-- =====================================================================
-- 04_analysis.sql — the six questions behind the dashboard
-- Toulouse-Blagnac = ICAO LFBO
-- =====================================================================

-- Helper view: every route touching Toulouse, with the "other" airport on each row
CREATE OR REPLACE VIEW v_tls_routes AS
SELECT r.route_id,
       r.route_code,
       o.icao        AS dest_icao,
       o.name        AS dest_name,
       o.zone        AS dest_zone,
       r.distance_km
FROM dim_route r
JOIN dim_airport t ON t.airport_id IN (r.airport_1_id, r.airport_2_id) AND t.icao = 'LFBO'
JOIN dim_airport o ON o.airport_id IN (r.airport_1_id, r.airport_2_id) AND o.icao <> 'LFBO';


-- ---------------------------------------------------------------------
-- Q1. Yearly scorecard: passengers, growth, national rank, passengers per flight
--     Techniques: CTE, RANK() partitioned by year, LAG() with a named WINDOW
-- ---------------------------------------------------------------------
WITH yearly AS (
    SELECT a.icao, d.year,
           SUM(f.pax_total)     AS pax,
           SUM(f.movements_pax) AS flights
    FROM fact_airport_traffic f
    JOIN dim_date d    USING (date_id)
    JOIN dim_airport a USING (airport_id)
    WHERE a.is_french
    GROUP BY a.icao, d.year
),
ranked AS (
    SELECT *, RANK() OVER (PARTITION BY year ORDER BY pax DESC) AS national_rank
    FROM yearly
)
SELECT year,
       pax,
       ROUND(100.0 * (pax - LAG(pax) OVER w) / NULLIF(LAG(pax) OVER w, 0), 1) AS growth_pct,
       national_rank,
       ROUND(pax::numeric / NULLIF(flights, 0), 1)                             AS pax_per_flight
FROM ranked
WHERE icao = 'LFBO'
WINDOW w AS (ORDER BY year)
ORDER BY year;


-- ---------------------------------------------------------------------
-- Q2. Post-Covid recovery: 2025 vs 2019 for the 10 largest regional airports
--     Techniques: conditional aggregation with FILTER, ranking on a ratio
-- ---------------------------------------------------------------------
WITH by_airport AS (
    SELECT a.icao, a.name,
           SUM(f.pax_total) FILTER (WHERE d.year = 2019) AS pax_2019,
           SUM(f.pax_total) FILTER (WHERE d.year = 2025) AS pax_2025
    FROM fact_airport_traffic f
    JOIN dim_date d    USING (date_id)
    JOIN dim_airport a USING (airport_id)
    WHERE a.zone = 'METRO'
      AND a.icao NOT IN ('LFPG', 'LFPO')          -- Paris hubs play another game
      AND d.year IN (2019, 2025)
    GROUP BY a.icao, a.name
),
top10 AS (
    SELECT * FROM by_airport
    WHERE pax_2019 IS NOT NULL AND pax_2025 IS NOT NULL   -- NULLs would sort first in DESC
    ORDER BY pax_2019 DESC
    LIMIT 10
)
SELECT icao, name, pax_2019, pax_2025,
       ROUND(100.0 * pax_2025 / pax_2019, 1)                        AS recovery_pct,
       RANK() OVER (ORDER BY pax_2025::numeric / pax_2019 DESC)     AS recovery_rank
FROM top10
ORDER BY recovery_rank;


-- ---------------------------------------------------------------------
-- Q3. Seasonality: each month's share of the year, averaged by decade
--     (2020-2021 excluded: Covid distorts the calendar)
--     Techniques: window SUM over a partition, then a second aggregation
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT d.year, d.month, d.month_name,
           f.pax_total::numeric / SUM(f.pax_total) OVER (PARTITION BY d.year) AS share
    FROM fact_airport_traffic f
    JOIN dim_date d    USING (date_id)
    JOIN dim_airport a USING (airport_id)
    WHERE a.icao = 'LFBO'
      AND NOT d.is_covid AND d.year NOT IN (2020, 2021)
)
SELECT (year / 10) * 10 || 's'     AS decade,
       month, month_name,
       ROUND(100 * AVG(share), 2)  AS avg_share_pct
FROM monthly
GROUP BY 1, month, month_name
ORDER BY month, decade;

-- Q3b. Busiest month of each year (DISTINCT ON keeps the first row per year)
SELECT DISTINCT ON (d.year)
       d.year, d.month_name AS peak_month, f.pax_total
FROM fact_airport_traffic f
JOIN dim_date d    USING (date_id)
JOIN dim_airport a USING (airport_id)
WHERE a.icao = 'LFBO'
ORDER BY d.year, f.pax_total DESC;


-- ---------------------------------------------------------------------
-- Q4. Rolling 12-month traffic: removes seasonality, shows the trend
--     Techniques: window frame ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
-- ---------------------------------------------------------------------
SELECT d.month_start,
       f.pax_total,
       SUM(f.pax_total) OVER (ORDER BY d.month_start
                              ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS pax_rolling_12m
FROM fact_airport_traffic f
JOIN dim_date d    USING (date_id)
JOIN dim_airport a USING (airport_id)
WHERE a.icao = 'LFBO'
ORDER BY d.month_start;


-- ---------------------------------------------------------------------
-- Q5. Gaps and islands: continuous periods in which each Toulouse route is published
--     A gap = route not flown, seasonal, OR hidden by the secrecy rule (< 3 operators).
--     Techniques: ROW_NUMBER() offset trick to label consecutive months
-- ---------------------------------------------------------------------
WITH published AS (
    SELECT v.dest_icao, v.dest_name, d.month_start
    FROM fact_route_traffic f
    JOIN v_tls_routes v USING (route_id)
    JOIN dim_date d     USING (date_id)
    WHERE f.pax_local > 0
),
islands AS (
    SELECT dest_icao, dest_name, month_start,
           month_start - (ROW_NUMBER() OVER (PARTITION BY dest_icao ORDER BY month_start)
                          * interval '1 month') AS island_key
    FROM published
)
SELECT dest_icao, dest_name,
       MIN(month_start) AS period_start,
       MAX(month_start) AS period_end,
       COUNT(*)         AS months
FROM islands
GROUP BY dest_icao, dest_name, island_key
ORDER BY dest_icao, period_start;


-- ---------------------------------------------------------------------
-- Q6. Toulouse - Paris-Orly, like-for-like: only months published in BOTH years
--     Techniques: self-join on the calendar month to compare 2019 with 2025 fairly
-- ---------------------------------------------------------------------
WITH orly AS (
    SELECT d.year, d.month, f.pax_local
    FROM fact_route_traffic f
    JOIN v_tls_routes v USING (route_id)
    JOIN dim_date d     USING (date_id)
    WHERE v.dest_icao = 'LFPO'
)
SELECT COUNT(*)                                       AS common_months,
       SUM(a.pax_local)                               AS pax_2019,
       SUM(b.pax_local)                               AS pax_2025,
       ROUND(100.0 * SUM(b.pax_local) / SUM(a.pax_local) - 100, 1) AS change_pct
FROM orly a
JOIN orly b ON b.month = a.month AND a.year = 2019 AND b.year = 2025;
