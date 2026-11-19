| Query | No index (ms) | Best technique | Best (ms) | Speed-up |
|---|---:|---|---:|---:|
| A_daily_month | 400.3 | B-tree index (index-only scan) | 0.80 | x500 |
| B_year_ranking | 552.6 | materialized view | 0.67 | x825 |
| C_monthly_trend | 528.2 | materialized view | 0.06 | x9,432 |
