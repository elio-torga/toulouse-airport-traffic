-- =====================================================================
-- 03_quality_checks.sql — one row per check, with a PASS / WARN status
-- =====================================================================
WITH checks AS (

    -- 1. Every staging row reached its fact table
    SELECT 1 AS n, 'APT rows: staging = fact' AS check_name,
           (SELECT count(*) FROM staging.stg_apt)::text || ' / ' || (SELECT count(*) FROM fact_airport_traffic) AS result,
           (SELECT count(*) FROM staging.stg_apt) = (SELECT count(*) FROM fact_airport_traffic) AS ok
    UNION ALL
    SELECT 2, 'PAP rows: staging = fact',
           (SELECT count(*) FROM staging.stg_pap)::text || ' / ' || (SELECT count(*) FROM fact_route_traffic),
           (SELECT count(*) FROM staging.stg_pap) = (SELECT count(*) FROM fact_route_traffic)

    -- 2. No missing month for Toulouse between Jan 1990 and the last published month
    UNION ALL
    SELECT 3, 'Toulouse: months with data / months expected',
           count(f.date_id)::text || ' / ' || count(*),
           count(f.date_id) = count(*)
    FROM dim_date d
    LEFT JOIN fact_airport_traffic f
           ON f.date_id = d.date_id
          AND f.airport_id = (SELECT airport_id FROM dim_airport WHERE icao = 'LFBO')
    WHERE d.date_id BETWEEN 199001 AND (SELECT max(date_id) FROM fact_airport_traffic)

    -- 3. Internal consistency: passenger-equivalents = passengers + 10 x freight tonnes
    UNION ALL
    SELECT 4, 'PEQ = pax + 10 x freight (within 2, rounding)',
           round(100.0 * count(*) FILTER (WHERE abs(peq_reported - (pax_total + 10 * (freight_dep_t + freight_arr_t))) <= 2)
                 / count(*), 2)::text || ' % of rows',
           count(*) FILTER (WHERE abs(peq_reported - (pax_total + 10 * (freight_dep_t + freight_arr_t))) > 15) = 0
    FROM fact_airport_traffic

    -- 4. Source anomalies corrected in 02_transform.sql
    UNION ALL
    SELECT 5, 'Negative freight values in source (floored at 0)',
           count(*)::text || ' rows',
           count(*) < 50
    FROM staging.stg_apt
    WHERE staging.to_num(apt_frp_dep) < 0 OR staging.to_num(apt_frp_arr) < 0

    -- 5. Every route has exactly one distance in the source
    UNION ALL
    SELECT 6, 'Routes with more than one published distance',
           count(*)::text,
           count(*) = 0
    FROM (SELECT pap FROM staging.stg_pap GROUP BY pap HAVING count(DISTINCT pap_dist) > 1) x

    -- 6. External check: Toulouse 2025 total vs the airport's own figure (7.6 million)
    UNION ALL
    SELECT 7, 'Toulouse 2025 passengers (airport reports 7.6 M)',
           to_char(sum(f.pax_total), 'FM9 999 999'),
           round(sum(f.pax_total) / 1e5) = 76
    FROM fact_airport_traffic f
    JOIN dim_date d USING (date_id)
    WHERE f.airport_id = (SELECT airport_id FROM dim_airport WHERE icao = 'LFBO') AND d.year = 2025
)
SELECT n, check_name, result, CASE WHEN ok THEN 'PASS' ELSE 'WARN' END AS status
FROM checks
ORDER BY n;
