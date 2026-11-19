"""Forecast Toulouse-Blagnac monthly passengers for 2026-2027 and write the result to PostgreSQL.

Method
------
1. Backtest from two origins (Dec 2023 -> 24 months ahead, Dec 2024 -> 12 months ahead):
   - seasonal naive: the last observed year repeated (the benchmark to beat)
   - SARIMA(0,1,1)(0,1,1,12), the classic "airline model" (Box & Jenkins), on log passengers
     since 2014, with one impulse dummy per Covid month
   - ensemble: the average of both
   The model with the lowest mean MAPE across both origins is selected.
2. Refit every model on data up to Dec 2025, forecast 2026-2027, store in fact_forecast.
3. Reality check: compare 2026 quarters with the figures already published by the airport.

Usage:  python python/forecast.py
"""
from __future__ import annotations

import json
import os
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
import psycopg
from statsmodels.tsa.statespace.sarimax import SARIMAX

warnings.filterwarnings("ignore")

DB_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/tls_traffic")
RESULTS = Path(__file__).resolve().parents[1] / "results"
HORIZON = 24
TRAIN_START = "2014-01"

# Quarterly totals published by the airport after the DGAC data ends (press releases).
AIRPORT_2026 = {
    "2026Q1": (1_689_291, "https://www.air-journal.fr/?p=275367"),
    "2026Q2": (2_132_814, "https://www.toulouse.aeroport.fr/sites/default/files/2026-08/CP_Trafic_T2_2026.pdf"),
    "2026Q3": (2_015_286, "https://www.air-journal.fr/?p=278869"),
}


def load_series(conn: psycopg.Connection) -> pd.Series:
    rows = conn.execute("""
        SELECT d.month_start, f.pax_total
        FROM fact_airport_traffic f
        JOIN dim_date d    USING (date_id)
        JOIN dim_airport a USING (airport_id)
        WHERE a.icao = 'LFBO'
        ORDER BY d.month_start
    """).fetchall()
    idx = pd.DatetimeIndex([r[0] for r in rows], freq="MS")
    return pd.Series([float(r[1]) for r in rows], index=idx, name="pax")


COVID_MONTHS = pd.date_range("2020-03-01", "2022-06-01", freq="MS")


def covid_dummies(idx: pd.DatetimeIndex) -> pd.DataFrame:
    """One impulse dummy per Covid month (Mar 2020 - Jun 2022).

    Each crisis month gets its own coefficient, so those 28 months are absorbed exactly
    and do not inflate the residual variance -> realistic prediction intervals.
    In the future all dummies are 0.
    """
    return pd.DataFrame({f"covid_{m:%Y%m}": (idx == m).astype(float) for m in COVID_MONTHS}, index=idx)


def future_index(last: pd.Timestamp, n: int) -> pd.DatetimeIndex:
    return pd.date_range(last + pd.offsets.MonthBegin(1), periods=n, freq="MS")


def fit_predict(train: pd.Series, n: int) -> dict[str, pd.DataFrame]:
    idx = future_index(train.index[-1], n)

    # Seasonal naive: the last 12 observed months, repeated
    naive = pd.Series(np.tile(train.iloc[-12:].values, n // 12 + 1)[:n], index=idx)

    # SARIMAX on log passengers -> multiplicative seasonality, intervals stay positive
    history = train[TRAIN_START:]
    model = SARIMAX(np.log(history), exog=covid_dummies(history.index),
                    order=(0, 1, 1), seasonal_order=(0, 1, 1, 12)).fit(disp=False)
    fc = model.get_forecast(n, exog=covid_dummies(idx))
    ci80, ci95 = fc.conf_int(alpha=0.20), fc.conf_int(alpha=0.05)
    sarima = pd.DataFrame({
        "pax": np.exp(fc.predicted_mean),
        "lo80": np.exp(ci80.iloc[:, 0]), "hi80": np.exp(ci80.iloc[:, 1]),
        "lo95": np.exp(ci95.iloc[:, 0]), "hi95": np.exp(ci95.iloc[:, 1]),
    }, index=idx)

    # Ensemble: average of both point forecasts; SARIMA intervals re-centred on it (ratio shift)
    ens_pax = (sarima["pax"] + naive) / 2
    ratio = ens_pax / sarima["pax"]
    ensemble = sarima.mul(ratio, axis=0)
    ensemble["pax"] = ens_pax

    naive_df = pd.DataFrame({"pax": naive, "lo80": naive, "hi80": naive, "lo95": naive, "hi95": naive})
    return {"seasonal_naive": naive_df, "sarima": sarima, "ensemble": ensemble}


def mape(actual: pd.Series, forecast: pd.Series) -> float:
    return float(np.mean(np.abs(actual - forecast) / actual) * 100)


def main() -> None:
    RESULTS.mkdir(exist_ok=True)
    with psycopg.connect(DB_URL) as conn:
        series = load_series(conn)

        # 1. Backtest from two origins
        metrics: dict = {}
        for train_end, horizon in [("2023-12-01", 24), ("2024-12-01", 12)]:
            train = series[:train_end]
            test = series[pd.Timestamp(train_end) + pd.offsets.MonthBegin(1):][:horizon]
            for name, df in fit_predict(train, horizon).items():
                metrics.setdefault(name, {})[f"mape_{horizon}m_from_{train_end[:7]}"] = round(mape(test, df["pax"]), 2)
        for name in list(metrics):
            metrics[name]["mean_mape_pct"] = round(float(np.mean(list(metrics[name].values()))), 2)
        best = min(metrics, key=lambda k: metrics[k]["mean_mape_pct"])
        metrics["_selected_model"] = best

        # 2. Final forecast from all the data
        final = fit_predict(series, HORIZON)
        airport_id = conn.execute("SELECT airport_id FROM dim_airport WHERE icao = 'LFBO'").fetchone()[0]
        conn.execute("DELETE FROM fact_forecast WHERE airport_id = %s", (airport_id,))
        with conn.cursor() as cur:
            for name, df in final.items():
                cur.executemany(
                    """INSERT INTO fact_forecast (date_id, airport_id, model, pax_forecast, lo80, hi80, lo95, hi95)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""",
                    [(int(ts.strftime("%Y%m")), airport_id, name, *[int(round(v)) for v in row])
                     for ts, row in df[["pax", "lo80", "hi80", "lo95", "hi95"]].iterrows()],
                )

        # 3. Reality check against the airport's own 2026 quarterly figures
        chosen = final[best]
        quarterly = chosen.groupby(chosen.index.to_period("Q")).sum()
        check = []
        for quarter, (actual, source) in AIRPORT_2026.items():
            row = quarterly.loc[pd.Period(quarter)]
            check.append({"quarter": quarter, "actual_airport": actual, "forecast": int(row["pax"]),
                          "error_pct": round((row["pax"] - actual) / actual * 100, 2), "source": source})
        metrics["_reality_check_2026"] = check

    (RESULTS / "forecast_metrics.json").write_text(json.dumps(metrics, indent=2))
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
