#!/usr/bin/env python3
"""Extract IPv4 CIDRs for a given country ISO code from MaxMind GeoLite2-Country CSVs."""

import csv
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: maxmind-country.py <ISO> <locations.csv> <blocks.csv>", file=sys.stderr)
        return 2

    iso = sys.argv[1].upper()
    locations_path = sys.argv[2]
    blocks_path = sys.argv[3]

    geoname_ids: set[str] = set()
    with open(locations_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row.get("country_iso_code", "").upper() == iso:
                gid = row.get("geoname_id", "").strip()
                if gid:
                    geoname_ids.add(gid)

    if not geoname_ids:
        print(f"ERROR: no geoname_id for ISO={iso}", file=sys.stderr)
        return 1

    with open(blocks_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if (
                row.get("geoname_id") in geoname_ids
                or row.get("registered_country_geoname_id") in geoname_ids
            ):
                network = row.get("network", "").strip()
                if network:
                    print(network)

    return 0


if __name__ == "__main__":
    sys.exit(main())
