"""Inject dashboard/data.json into dashboard/template.html -> dashboard/index.html and docs/index.html.

Usage:  python python/build_dashboard.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "dashboard"


def main() -> None:
    data = (ROOT / "data.json").read_text().replace("</", "<\\/")   # never close the <script> tag early
    html = (ROOT / "template.html").read_text().replace("__DATA__", data)
    (ROOT / "index.html").write_text(html)
    (ROOT.parent / "docs" / "index.html").write_text(html)   # GitHub Pages serves /docs
    print(f"dashboard/index.html and docs/index.html written ({len(html) / 1024:.0f} kB)")


if __name__ == "__main__":
    main()
