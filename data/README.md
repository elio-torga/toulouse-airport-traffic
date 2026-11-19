# Data

`python python/download_data.py` downloads the two DGAC series into `data/raw/` (ignored by git):

| Folder | Series | Content | Rows (1990-2025) |
|---|---|---|---|
| `raw/apt/` | ASP_APT | Monthly commercial traffic of every French airport | 38,821 |
| `raw/pap/` | ASP_PAP | Monthly traffic per airport pair (published only if >= 3 operators, none > 85%) | 45,787 |

Source: DGAC, [Trafic aérien commercial mensuel français](https://www.data.gouv.fr/datasets/64808a5811da153f1439914c), Licence Ouverte 2.0.
Field definitions: see the official notices published with the dataset (Notice_ASP_serie_APT.pdf, Notice_ASP_serie_PAP.pdf).
