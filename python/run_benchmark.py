"""Run the optimisation stages of sql/06_optimizations.sql and time the benchmark queries.

For every stage, each relevant query is run once to warm the cache, then 5 times with
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON). We keep the median execution time and the scan
nodes PostgreSQL chose. Results go to results/benchmark.json and results/benchmark.md.

Usage:  python python/run_benchmark.py   (after sql/05_performance_setup.sql)
"""
from __future__ import annotations

import json
import os
import platform
import re
import statistics
from pathlib import Path

import psycopg

DB_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/tls_traffic")
ROOT = Path(__file__).resolve().parents[1]
RUNS = 5

# Which queries are timed at which stage, and against which table
PLAN = {
    "baseline":    [("A_daily_month", "bench.flights"), ("B_year_ranking", "bench.flights"), ("C_monthly_trend", "bench.flights")],
    "btree":       [("A_daily_month", "bench.flights"), ("B_year_ranking", "bench.flights"), ("C_monthly_trend", "bench.flights")],
    "brin":        [("A_daily_month", "bench.flights"), ("B_year_ranking", "bench.flights"), ("C_monthly_trend", "bench.flights")],
    "partitioned": [("A_daily_month", "bench.flights_part"), ("B_year_ranking", "bench.flights_part"), ("C_monthly_trend", "bench.flights_part")],
    "matview":     [("B_year_ranking_mv", None), ("C_monthly_trend_mv", None)],
}


def parse_blocks(sql: str, tag: str) -> dict[str, str]:
    parts = re.split(rf"^-- @{tag} (\S+).*$", sql, flags=re.M)
    blocks = {}
    for name, body in zip(parts[1::2], parts[2::2]):
        body = body.split("-- ====")[0]          # stop at the next section banner
        blocks[name] = body.strip()
    return blocks


def split_statements(block: str) -> list[str]:
    """Split on ';' at end of line, but never inside a $$ ... $$ body (DO blocks)."""
    statements, current = [], ""
    for piece in re.split(r"(;\s*\n)", block + "\n"):
        current += piece
        if piece.strip() == ";" and current.count("$$") % 2 == 0:
            if re.sub(r"--.*", "", current).strip(" ;\n"):
                statements.append(current.strip())
            current = ""
    if re.sub(r"--.*", "", current).strip(" ;\n"):
        statements.append(current.strip())
    return statements


def scan_nodes(plan: dict) -> list[str]:
    nodes, stack = [], [plan]
    while stack:
        node = stack.pop()
        if "Scan" in node["Node Type"]:
            nodes.append(node["Node Type"])
        stack.extend(node.get("Plans", []))
    return sorted(set(nodes))


def time_query(conn: psycopg.Connection, sql: str) -> dict:
    conn.execute(sql).fetchall()  # warm-up
    times, plan = [], None
    for _ in range(RUNS):
        result = conn.execute(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql}").fetchone()[0][0]
        times.append(result["Execution Time"])
        plan = result["Plan"]
    return {"median_ms": round(statistics.median(times), 3), "runs_ms": [round(t, 3) for t in times],
            "scan_nodes": scan_nodes(plan),
            "buffers_hit": plan.get("Shared Hit Blocks", 0), "buffers_read": plan.get("Shared Read Blocks", 0)}


def technique(stage: str, nodes: list[str]) -> str:
    """Name the optimisation that actually served the query, read from the plan (stages are cumulative)."""
    if stage == "matview":
        return "materialized view"
    if "Index Only Scan" in nodes:
        return "B-tree index (index-only scan)"
    if "Bitmap Index Scan" in nodes:
        return "BRIN index"
    if stage == "partitioned":
        return "partition pruning"
    return stage


def main() -> None:
    sql = (ROOT / "sql" / "06_optimizations.sql").read_text()
    stages, queries = parse_blocks(sql, "stage"), parse_blocks(sql, "query")
    results = {"environment": {}, "stages": {}, "sizes": {}}

    with psycopg.connect(DB_URL, autocommit=True) as conn:   # autocommit: VACUUM can't run in a transaction
        tls = conn.execute("SELECT airport_id FROM dim_airport WHERE icao = 'LFBO'").fetchone()[0]
        results["environment"] = {
            "postgres": conn.execute("SHOW server_version").fetchone()[0],
            "cpu_count": os.cpu_count(), "machine": platform.machine(),
            "rows": conn.execute("SELECT count(*) FROM bench.flights").fetchone()[0],
        }
        for stage, plan in PLAN.items():
            print(f"== stage {stage}")
            for statement in split_statements(stages[stage]):
                conn.execute(statement)
            results["stages"][stage] = {}
            for name, table in plan:
                query = queries[name].format(table=table, tls=tls).rstrip(";")
                results["stages"][stage][name] = timing = time_query(conn, query)
                print(f"   {name:22s} {timing['median_ms']:>10.2f} ms  {', '.join(timing['scan_nodes'])}")

        results["sizes"] = {
            name: conn.execute(f"SELECT pg_size_pretty(pg_relation_size('{rel}')), pg_relation_size('{rel}')").fetchone()
            for name, rel in [("table", "bench.flights"),
                              ("btree_index", "bench.idx_flights_airport_date"),
                              ("brin_index", "bench.idx_flights_date_brin"),
                              ("matview", "bench.mv_monthly_airport")]
        }

    (ROOT / "results").mkdir(exist_ok=True)
    (ROOT / "results" / "benchmark.json").write_text(json.dumps(results, indent=2))

    # Markdown summary: best stage per question vs baseline
    lines = ["| Query | No index (ms) | Best technique | Best (ms) | Speed-up |", "|---|---:|---|---:|---:|"]
    for base_name in ["A_daily_month", "B_year_ranking", "C_monthly_trend"]:
        base = results["stages"]["baseline"][base_name]["median_ms"]
        candidates = [(technique(stage, q["scan_nodes"]), q["median_ms"]) for stage, qs in results["stages"].items()
                      for name, q in qs.items() if name.startswith(base_name) and stage != "baseline"]
        how, best = min(candidates, key=lambda c: c[1])
        lines.append(f"| {base_name} | {base:,.1f} | {how} | {best:,.2f} | x{base / best:,.0f} |")
    (ROOT / "results" / "benchmark.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
