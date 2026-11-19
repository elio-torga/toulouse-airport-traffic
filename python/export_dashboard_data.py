"""Export everything the dashboard shows into dashboard/data.json (one SQL query per block).

Usage:  python python/export_dashboard_data.py
"""
from __future__ import annotations

import json
import os
from datetime import date
from decimal import Decimal
from pathlib import Path

import psycopg
from psycopg.rows import dict_row

DB_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/tls_traffic")
ROOT = Path(__file__).resolve().parents[1]

QUERIES = {
    # Q1 — yearly scorecard
    "annual": """
        WITH yearly AS (
            SELECT a.icao, d.year, SUM(f.pax_total) AS pax, SUM(f.movements_pax) AS flights,
                   SUM(f.freight_dep_t + f.freight_arr_t) AS freight_t
            FROM fact_airport_traffic f JOIN dim_date d USING (date_id) JOIN dim_airport a USING (airport_id)
            WHERE a.is_french GROUP BY a.icao, d.year)
        SELECT year, pax, flights, round(freight_t) AS freight_t,
               RANK() OVER (PARTITION BY year ORDER BY pax DESC) AS rank,
               round(pax::numeric / NULLIF(flights, 0), 1) AS pax_per_flight
        FROM yearly ORDER BY icao = 'LFBO' DESC, year""",
    # Q4 — monthly series + rolling 12 months
    "monthly": """
        SELECT to_char(d.month_start, 'YYYY-MM') AS month, f.pax_total AS pax,
               SUM(f.pax_total) OVER (ORDER BY d.month_start ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS rolling_12m
        FROM fact_airport_traffic f JOIN dim_date d USING (date_id) JOIN dim_airport a USING (airport_id)
        WHERE a.icao = 'LFBO' ORDER BY d.month_start""",
    "forecast": """
        SELECT to_char(d.month_start, 'YYYY-MM') AS month, model, pax_forecast AS pax, lo80, hi80, lo95, hi95
        FROM fact_forecast JOIN dim_date d USING (date_id) ORDER BY model, d.month_start""",
    # Q2 — recovery among the 10 largest regional airports
    "recovery": """
        WITH by_airport AS (
            SELECT a.icao, a.name,
                   SUM(f.pax_total) FILTER (WHERE d.year = 2019) AS pax_2019,
                   SUM(f.pax_total) FILTER (WHERE d.year = 2025) AS pax_2025
            FROM fact_airport_traffic f JOIN dim_date d USING (date_id) JOIN dim_airport a USING (airport_id)
            WHERE a.zone = 'METRO' AND a.icao NOT IN ('LFPG', 'LFPO') AND d.year IN (2019, 2025)
            GROUP BY a.icao, a.name),
        top10 AS (SELECT * FROM by_airport WHERE pax_2019 IS NOT NULL AND pax_2025 IS NOT NULL
                  ORDER BY pax_2019 DESC LIMIT 10)
        SELECT icao, name, pax_2019, pax_2025, round(100.0 * pax_2025 / pax_2019, 1) AS recovery_pct
        FROM top10 ORDER BY recovery_pct DESC""",
    # Q3 — seasonality by decade
    "seasonality": """
        WITH monthly AS (
            SELECT d.year, d.month, f.pax_total::numeric / SUM(f.pax_total) OVER (PARTITION BY d.year) AS share
            FROM fact_airport_traffic f JOIN dim_date d USING (date_id) JOIN dim_airport a USING (airport_id)
            WHERE a.icao = 'LFBO' AND d.year NOT IN (2020, 2021))
        SELECT (year / 10) * 10 AS decade, month, round(100 * AVG(share), 2) AS share_pct
        FROM monthly GROUP BY 1, 2 ORDER BY 1, 2""",
    # Q5 — gaps and islands for every Toulouse route
    "route_islands": """
        WITH tls AS (
            SELECT r.route_id, o.icao AS dest_icao, o.name AS dest_name, o.zone AS dest_zone
            FROM dim_route r
            JOIN dim_airport t ON t.airport_id IN (r.airport_1_id, r.airport_2_id) AND t.icao = 'LFBO'
            JOIN dim_airport o ON o.airport_id IN (r.airport_1_id, r.airport_2_id) AND o.icao <> 'LFBO'),
        published AS (
            SELECT tls.dest_icao, tls.dest_name, tls.dest_zone, d.month_start, f.pax_local
            FROM fact_route_traffic f JOIN tls USING (route_id) JOIN dim_date d USING (date_id)
            WHERE f.pax_local > 0),
        islands AS (
            SELECT *, month_start - (ROW_NUMBER() OVER (PARTITION BY dest_icao ORDER BY month_start)
                                     * interval '1 month') AS island_key
            FROM published)
        SELECT dest_icao, dest_name, dest_zone,
               to_char(MIN(month_start), 'YYYY-MM') AS start, to_char(MAX(month_start), 'YYYY-MM') AS "end",
               COUNT(*) AS months, SUM(pax_local) AS pax
        FROM islands GROUP BY dest_icao, dest_name, dest_zone, island_key ORDER BY dest_icao, start""",
    # Q6 — Toulouse - Orly like-for-like
    "orly": """
        WITH orly AS (
            SELECT d.year, d.month, f.pax_local
            FROM fact_route_traffic f JOIN dim_route r USING (route_id) JOIN dim_date d USING (date_id)
            WHERE r.route_code = 'LFPO_LFBO')
        SELECT COUNT(*) AS common_months, SUM(a.pax_local) AS pax_2019, SUM(b.pax_local) AS pax_2025,
               round(100.0 * SUM(b.pax_local) / SUM(a.pax_local) - 100, 1) AS change_pct
        FROM orly a JOIN orly b ON b.month = a.month AND a.year = 2019 AND b.year = 2025""",
    "quality": open(ROOT / "sql" / "03_quality_checks.sql").read(),
}


def to_json(value):
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, date):
        return value.isoformat()
    raise TypeError(type(value))


def main() -> None:
    data = {}
    with psycopg.connect(DB_URL, row_factory=dict_row) as conn:
        for name, sql in QUERIES.items():
            data[name] = conn.execute(sql).fetchall()
    # annual: keep Toulouse rows only (the query ranks all airports first)
    n_years = len({r["year"] for r in data["annual"]})
    data["annual"] = sorted(data["annual"][:n_years], key=lambda r: r["year"])
    data["orly"] = data["orly"][0]
    for extra in ["forecast_metrics.json", "benchmark.json"]:
        path = ROOT / "results" / extra
        if path.exists():
            data[extra.removesuffix(".json")] = json.loads(path.read_text())
    out = ROOT / "dashboard" / "data.json"
    out.write_text(json.dumps(data, default=to_json, separators=(",", ":")))
    print(f"{out} ({out.stat().st_size / 1024:.0f} kB): " + ", ".join(f"{k}={len(v)}" for k, v in data.items()))


if __name__ == "__main__":
    main()
