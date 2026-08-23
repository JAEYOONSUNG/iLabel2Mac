#!/usr/bin/env python3

from __future__ import annotations

import html
import json
import math
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parent.parent
OUTPUT_JSON = ROOT / "Resources" / "official_formats.json"
USER_AGENT = "iLabel Studio format sync/0.1 (+local build)"


LIST_SOURCES = [
    {
        "family": "a4Label",
        "familyLabel": "A4 Label",
        "pageWidthMM": 210.0,
        "pageHeightMM": 297.0,
        "continuous": False,
        "url": "https://www.label.kr/Goods/A4Label/ByCuts",
    },
    {
        "family": "a3Label",
        "familyLabel": "A3 Label",
        "pageWidthMM": 297.0,
        "pageHeightMM": 420.0,
        "continuous": False,
        "url": "https://www.label.kr/Goods/iLabel/A3Label",
    },
    {
        "family": "zLabel",
        "familyLabel": "Jet Label",
        "pageWidthMM": None,
        "pageHeightMM": None,
        "continuous": True,
        "url": "https://www.label.kr/Goods/ZLabel/ByPrinter/Direct-Thermal",
    },
    {
        "family": "zLabel",
        "familyLabel": "Jet Label",
        "pageWidthMM": None,
        "pageHeightMM": None,
        "continuous": True,
        "url": "https://www.label.kr/Goods/ZLabel/ByPrinter/Thermal-Transfer",
    },
    {
        "family": "zLabel",
        "familyLabel": "Jet Label",
        "pageWidthMM": None,
        "pageHeightMM": None,
        "continuous": True,
        "url": "https://www.label.kr/Goods/ZLabel/ByPrinter/Inkjet-Labelprinter",
    },
    {
        "family": "rollLabel",
        "familyLabel": "Roll Label",
        "pageWidthMM": None,
        "pageHeightMM": None,
        "continuous": True,
        "url": "https://www.label.kr/Goods/RollLabel/ByPrinter/Direct-Thermal",
    },
    {
        "family": "rollLabel",
        "familyLabel": "Roll Label",
        "pageWidthMM": None,
        "pageHeightMM": None,
        "continuous": True,
        "url": "https://www.label.kr/Goods/RollLabel/ByPrinter/Thermal-Transfer",
    },
    {
        "family": "rollLabel",
        "familyLabel": "Roll Label",
        "pageWidthMM": None,
        "pageHeightMM": None,
        "continuous": True,
        "url": "https://www.label.kr/Goods/RollLabel/ByPrinter/Inkjet-Labelprinter",
    },
    {
        "family": "a4Tag",
        "familyLabel": "A4 Tag",
        "pageWidthMM": 210.0,
        "pageHeightMM": 297.0,
        "continuous": False,
        "url": "https://www.label.kr/Goods/A4Tag/ByTypes/All",
    },
    {
        "family": "zTag",
        "familyLabel": "Jet Tag",
        "pageWidthMM": None,
        "pageHeightMM": None,
        "continuous": True,
        "url": "https://www.label.kr/Goods/ZTag/ByTypes/All",
    },
    {
        "family": "rollTag",
        "familyLabel": "Roll Tag",
        "pageWidthMM": None,
        "pageHeightMM": None,
        "continuous": True,
        "url": "https://www.label.kr/Goods/RollTag/ByTypes/All",
    },
]


@dataclass
class FormatRecord:
    code: str
    name: str
    family: str
    familyLabel: str
    sourceURL: str
    detailURL: str
    pdfTemplateURL: Optional[str]
    pageWidthMM: float
    pageHeightMM: float
    columns: int
    rows: int
    labelWidthMM: float
    labelHeightMM: float
    horizontalGapMM: float
    verticalGapMM: float
    marginLeftMM: float
    marginTopMM: float
    marginRightMM: float
    marginBottomMM: float
    labelsPerPage: int
    cornerRadiusMM: float
    shape: str
    officialType: str
    continuous: bool


def fetch_text(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8", errors="ignore")


def strip_tags(value: str) -> str:
    without_tags = re.sub(r"<[^>]+>", "", value)
    return html.unescape(without_tags).strip()


def parse_number(value: str, default: float = 0.0) -> float:
    match = re.search(r"-?\d+(?:\.\d+)?", value.replace(",", ""))
    return float(match.group(0)) if match else default


def parse_int(value: str, default: int = 0) -> int:
    digits = re.sub(r"[^\d]", "", value)
    return int(digits) if digits else default


def official_shape(listing_type: str, width: float, height: float, radius: float) -> tuple[str, float]:
    normalized = listing_type.lower()
    if normalized == "circle":
        return "circle", max(radius, min(width, height) / 2.0)
    if normalized == "oval":
        return "capsule", max(radius, min(width, height) / 2.0)
    if normalized in {"rectangle-sc", "square-sc"}:
        return "rectangle", 0.0
    return "roundedRectangle", max(radius, 2.0 if normalized.endswith("-rc") else radius)


def extract_detail_links(list_html: str) -> dict[str, dict]:
    items: dict[str, dict] = {}
    block_pattern = re.compile(
        r"(<div class=\"p-product-list-item[^>]*>.*?<a class=\"p-product c-card\" href=['\"](?P<href>/Goods/Detail/(?P<code>[A-Za-z0-9]+)[^'\"]*)['\"].*?</a>\s*</div>)",
        re.S,
    )
    for block_match in block_pattern.finditer(list_html):
        block = block_match.group(1)
        code = block_match.group("code")
        href = html.unescape(block_match.group("href"))
        tag_open = re.search(r"<div class=\"p-product-list-item([^>]*)>", block)
        attrs = {}
        if tag_open:
            attrs = dict(re.findall(r"([a-zA-Z0-9-]+)=\"([^\"]+)\"", tag_open.group(1)))

        items[code] = {
            "detailURL": f"https://www.label.kr{href.split('?')[0]}",
            "listingType": attrs.get("data-type", ""),
        }

    for href_match in re.finditer(r"href=['\"](?P<href>/Goods/Detail/(?P<code>[A-Za-z0-9]+)[^'\"]*)['\"]", list_html):
        code = href_match.group("code")
        if code not in items:
            href = html.unescape(href_match.group("href"))
            items[code] = {
                "detailURL": f"https://www.label.kr{href.split('?')[0]}",
                "listingType": "",
            }

    return items


def parse_table(detail_html: str) -> dict[str, str]:
    pairs = re.findall(r"<th>(.*?)</th>\s*<td>(.*?)</td>", detail_html, re.S)
    result: dict[str, str] = {}
    for key_html, value_html in pairs:
        key = strip_tags(key_html)
        value = strip_tags(value_html)
        result[key] = value
    return result


def discover_pdf_template(detail_html: str) -> Optional[str]:
    match = re.search(
        r"<a href=\"(https://images\.label\.kr/pds/template/[^\"]+?_line\.pdf)\"",
        detail_html,
        re.I,
    )
    return html.unescape(match.group(1)) if match else None


def derive_grid(
    labels_per_page: int,
    page_width: float,
    page_height: float,
    label_width: float,
    label_height: float,
    left: float,
    top: float,
    right: float,
    bottom: float,
    h_gap: float,
    v_gap: float,
) -> tuple[int, int]:
    if labels_per_page <= 1:
        return 1, 1

    best: Optional[tuple[float, int, int]] = None
    for cols in range(1, labels_per_page + 1):
        if labels_per_page % cols != 0:
            continue
        rows = labels_per_page // cols
        implied_right = page_width - left - (cols * label_width) - ((cols - 1) * h_gap)
        implied_bottom = page_height - top - (rows * label_height) - ((rows - 1) * v_gap)

        penalty = 0.0
        if implied_right < -1.5 or implied_bottom < -1.5:
            penalty += 1_000_000

        penalty += abs(implied_right - right)
        penalty += abs(implied_bottom - bottom)
        penalty += abs(round(implied_right, 2) - implied_right)
        penalty += abs(round(implied_bottom, 2) - implied_bottom)

        candidate = (penalty, cols, rows)
        if best is None or candidate < best:
            best = candidate

    if best is not None:
        return best[1], best[2]

    guessed_cols = max(1, round((page_width - left + h_gap) / (label_width + h_gap)))
    guessed_rows = max(1, round((page_height - top + v_gap) / (label_height + v_gap)))
    return int(guessed_cols), int(guessed_rows)


def build_record(source: dict, code: str, detail_url: str, listing_type: str, detail_html: str) -> FormatRecord:
    table = parse_table(detail_html)

    label_width = parse_number(table.get("라벨 너비", "0"))
    label_height = parse_number(table.get("라벨 높이", "0"))
    if label_width == 0 or label_height == 0:
        raise ValueError(f"Missing size fields for {code}")

    left = parse_number(table.get("왼쪽 여백", "0"))
    top = parse_number(table.get("위쪽 여백", "0"))
    right = parse_number(table.get("오른쪽 여백", str(left if not source["continuous"] else 0)))
    bottom = parse_number(table.get("아래쪽 여백", str(top if not source["continuous"] else 0)))
    h_gap = parse_number(table.get("좌우 간격", "0"))
    v_gap = parse_number(table.get("상하 간격", "0"))
    labels_per_page = parse_int(table.get("장당 라벨 수", "1"), default=1)
    corner_radius = parse_number(table.get("모서리 R 값", "0"))

    shape, resolved_radius = official_shape(listing_type, label_width, label_height, corner_radius)

    if source["continuous"]:
        page_width = max(label_width + left + right, label_width)
        page_height = max(label_height + top + bottom, label_height)
        columns = 1
        rows = 1
        labels_per_page = 1
    else:
        page_width = float(source["pageWidthMM"])
        page_height = float(source["pageHeightMM"])
        columns, rows = derive_grid(
            labels_per_page=labels_per_page,
            page_width=page_width,
            page_height=page_height,
            label_width=label_width,
            label_height=label_height,
            left=left,
            top=top,
            right=right,
            bottom=bottom,
            h_gap=h_gap,
            v_gap=v_gap,
        )

    return FormatRecord(
        code=code,
        name=f"{code} · {source['familyLabel']}",
        family=source["family"],
        familyLabel=source["familyLabel"],
        sourceURL=source["url"],
        detailURL=detail_url,
        pdfTemplateURL=discover_pdf_template(detail_html),
        pageWidthMM=page_width,
        pageHeightMM=page_height,
        columns=columns,
        rows=rows,
        labelWidthMM=label_width,
        labelHeightMM=label_height,
        horizontalGapMM=h_gap,
        verticalGapMM=v_gap,
        marginLeftMM=left,
        marginTopMM=top,
        marginRightMM=right,
        marginBottomMM=bottom,
        labelsPerPage=labels_per_page,
        cornerRadiusMM=resolved_radius,
        shape=shape,
        officialType=listing_type or "unspecified",
        continuous=source["continuous"],
    )


def sync() -> int:
    OUTPUT_JSON.parent.mkdir(parents=True, exist_ok=True)

    code_index: dict[str, dict] = {}
    for source in LIST_SOURCES:
        print(f"[catalog] fetching list {source['familyLabel']} from {source['url']}", file=sys.stderr)
        list_html = fetch_text(source["url"])
        discovered = extract_detail_links(list_html)
        for code, listing in discovered.items():
            entry = code_index.get(code)
            if entry is None:
                entry = {
                    "source": source,
                    "detailURL": listing["detailURL"],
                    "listingType": listing["listingType"],
                }
                code_index[code] = entry
            else:
                if not entry.get("listingType") and listing.get("listingType"):
                    entry["listingType"] = listing["listingType"]

    records: list[FormatRecord] = []
    total = len(code_index)
    for index, code in enumerate(sorted(code_index), start=1):
        entry = code_index[code]
        print(f"[detail] {index}/{total} {code}", file=sys.stderr)
        detail_html = fetch_text(entry["detailURL"])
        try:
            record = build_record(
                source=entry["source"],
                code=code,
                detail_url=entry["detailURL"],
                listing_type=entry.get("listingType", ""),
                detail_html=detail_html,
            )
            records.append(record)
        except Exception as error:  # noqa: BLE001
            print(f"[warn] failed to parse {code}: {error}", file=sys.stderr)
        time.sleep(0.04)

    payload = {
        "generatedAt": time.strftime("%Y-%m-%d"),
        "source": "https://www.label.kr",
        "count": len(records),
        "formats": [asdict(record) for record in sorted(records, key=lambda item: (item.family, item.code))],
    }
    OUTPUT_JSON.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {len(records)} formats to {OUTPUT_JSON}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(sync())
    except urllib.error.URLError as error:
        print(f"Network error: {error}", file=sys.stderr)
        raise SystemExit(2)
