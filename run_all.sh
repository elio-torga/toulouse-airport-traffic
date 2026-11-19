#!/usr/bin/env bash
# Rebuild everything from scratch: data -> database -> analysis -> forecast -> benchmark -> dashboard.
# Usage:  ./run_all.sh            (SKIP_DOWNLOAD=1 ./run_all.sh to reuse data/raw)
set -euo pipefail
cd "$(dirname "$0")"

export DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/tls_traffic}"
PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -P pager=off)
mkdir -p results

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$1"; }

if [[ "${SKIP_DOWNLOAD:-0}" != "1" ]]; then
  step "1/8 Download DGAC data from data.gouv.fr"
  python python/download_data.py
fi
step "2/8 Create the schema";               "${PSQL[@]}" -f sql/01_schema.sql 2>&1 | grep -v NOTICE || true
step "3/8 Load raw CSV into staging";       python python/load_staging.py
step "4/8 Transform staging -> star schema"; "${PSQL[@]}" -f sql/02_transform.sql
step "5/8 Quality checks";                  "${PSQL[@]}" -f sql/03_quality_checks.sql | tee results/quality_checks.txt
"${PSQL[@]}" -f sql/04_analysis.sql > results/analysis_output.txt
echo "analysis results -> results/analysis_output.txt"
step "6/8 Forecast 2026-2027";              python python/forecast.py > /dev/null && echo "-> results/forecast_metrics.json"
step "7/8 Performance benchmark (~1 min)";  "${PSQL[@]}" -f sql/05_performance_setup.sql > /dev/null 2>&1
python python/run_benchmark.py
step "8/8 Build the dashboard";             python python/export_dashboard_data.py && python python/build_dashboard.py
echo -e "\nDone. Open dashboard/index.html in a browser."
