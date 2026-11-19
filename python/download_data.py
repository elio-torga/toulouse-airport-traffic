"""Download the DGAC monthly air traffic series (APT and PAP) from data.gouv.fr.

Resource URLs change with every yearly update, so they are resolved through the
data.gouv.fr API by title instead of being hard-coded.

Usage:  python python/download_data.py
Output: data/raw/apt/ASP_APT_YYYY.csv and data/raw/pap/ASP_PAP_YYYY.csv
"""
from __future__ import annotations

import io
import json
import urllib.request
import zipfile
from pathlib import Path

DATASET_ID = "64808a5811da153f1439914c"  # "Trafic aérien commercial mensuel français"
API_URL = f"https://www.data.gouv.fr/api/1/datasets/{DATASET_ID}/"
RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"
SERIES = {"apt": "ASP_APT_", "pap": "ASP_PAP_"}


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def main() -> None:
    resources = json.loads(fetch(API_URL))["resources"]
    for folder, prefix in SERIES.items():
        zips = [r for r in resources if r["title"].startswith(prefix) and r["format"] == "zip"]
        if not zips:
            raise SystemExit(f"No zip resource starting with {prefix} found on data.gouv.fr")
        resource = max(zips, key=lambda r: r["last_modified"])
        print(f"Downloading {resource['title']} ({resource['filesize'] / 1e6:.1f} MB)")
        target = RAW_DIR / folder
        target.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(fetch(resource["url"]))) as archive:
            archive.extractall(target)
        print(f"  -> {len(list(target.glob('*.csv')))} CSV files in {target}")


if __name__ == "__main__":
    main()
