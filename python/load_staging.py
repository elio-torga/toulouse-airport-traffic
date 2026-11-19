"""Load the raw DGAC CSV files, untouched, into the PostgreSQL `staging` schema.

Every column is kept as text: typing and cleaning happen in SQL (sql/02_transform.sql),
so the staging layer is an exact, auditable copy of the source files.

Usage:  python python/load_staging.py
"""
from __future__ import annotations

import io
import os
from pathlib import Path

import pandas as pd
import psycopg

DB_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/tls_traffic")
RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"


def read_series(folder: str) -> pd.DataFrame:
    frames = []
    for path in sorted((RAW_DIR / folder).glob("*.csv")):
        # Files are UTF-8 with BOM, ';' separated, decimal comma -> keep everything as text.
        df = pd.read_csv(path, sep=";", dtype=str, encoding="utf-8-sig", keep_default_na=False)
        df.columns = [c.strip().lower() for c in df.columns]
        df["source_file"] = path.name
        frames.append(df)
    if not frames:
        raise SystemExit(f"No CSV in {RAW_DIR / folder}. Run python/download_data.py first.")
    return pd.concat(frames, ignore_index=True)


def copy_to_staging(conn: psycopg.Connection, table: str, df: pd.DataFrame) -> None:
    columns = ", ".join(f'"{c}" text' for c in df.columns)
    with conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS staging.{table}")
        cur.execute(f"CREATE TABLE staging.{table} ({columns})")
        buffer = io.StringIO()
        df.to_csv(buffer, index=False, header=False, sep="\t")
        buffer.seek(0)
        col_list = ", ".join(f'"{c}"' for c in df.columns)
        with cur.copy(f"COPY staging.{table} ({col_list}) FROM STDIN WITH (FORMAT csv, DELIMITER E'\\t')") as copy:
            copy.write(buffer.read())
    print(f"staging.{table}: {len(df):,} rows, {len(df.columns)} columns")


def main() -> None:
    with psycopg.connect(DB_URL) as conn:
        conn.execute("CREATE SCHEMA IF NOT EXISTS staging")
        copy_to_staging(conn, "stg_apt", read_series("apt"))
        copy_to_staging(conn, "stg_pap", read_series("pap"))


if __name__ == "__main__":
    main()
