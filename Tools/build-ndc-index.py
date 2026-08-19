#!/usr/bin/env python3
"""Build the bundled FDA drug directory from openFDA's public-domain NDC dataset.

The format is specified in NDC-INDEX-FORMAT.md, which is the document to read
first. This script trims, deduplicates and sorts; it deliberately does no
interpretation — dosage forms and strengths are carried through verbatim so the
app reads them with the same tested Swift code that reads a scanned label.

Downloading is the only step that touches the network, it happens here on a
developer's machine, and the file it fetches is public domain (CC0 1.0).
Nothing in the shipped app makes a request.

    python3 Tools/build-ndc-index.py --download --output DailyDose/Resources/ndc-index.ddndc
"""

from __future__ import annotations

import argparse
import io
import json
import struct
import sys
import urllib.request
import zipfile
from pathlib import Path

MANIFEST_URL = "https://api.fda.gov/download.json"

MAGIC = b"DDNDCIDX"
FORMAT_VERSION = 1
HEADER_SIZE = 64
PRODUCT_RECORD_SIZE = 24

# Segment lengths → the Format byte DrugDirectory reads. Must stay in step with
# NationalDrugCode.Format's declaration order in Swift.
SEGMENTATIONS = {(4, 4, 2): 0, (5, 3, 2): 1, (5, 4, 1): 2, (6, 4, 2): 3}

# Product types a person can actually be holding. Everything else is a raw
# material with no consumer package, so a match against one would be a false
# positive on a shelf nobody's medicine came from.
CONSUMER_PRODUCT_TYPES = {
    "HUMAN PRESCRIPTION DRUG",
    "HUMAN OTC DRUG",
    "VACCINE",
    "PLASMA DERIVATIVE",
    "STANDARDIZED ALLERGENIC",
    "NON-STANDARDIZED ALLERGENIC",
}


def fetch_dataset() -> tuple[dict, str]:
    """Download the current NDC bulk export and return it with its export date."""
    with urllib.request.urlopen(MANIFEST_URL, timeout=60) as response:
        manifest = json.load(response)
    ndc = manifest["results"]["drug"]["ndc"]
    partitions = ndc["partitions"]
    if len(partitions) != 1:
        # One partition today. If the FDA ever splits it, concatenating the
        # results is correct — but silently reading only the first would ship a
        # directory missing most of its products, so stop instead.
        raise SystemExit(
            f"expected 1 partition, found {len(partitions)}; teach this script to merge them"
        )

    url = partitions[0]["file"]
    print(f"downloading {url} ({partitions[0]['size_mb']} MB)", file=sys.stderr)
    with urllib.request.urlopen(url, timeout=900) as response:
        payload = response.read()
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        name = archive.namelist()[0]
        with archive.open(name) as member:
            return json.load(member), ndc.get("export_date", "")


def load_dataset(path: Path) -> tuple[dict, str]:
    if path.suffix == ".zip":
        with zipfile.ZipFile(path) as archive:
            with archive.open(archive.namelist()[0]) as member:
                data = json.load(member)
    else:
        data = json.loads(path.read_text())
    return data, data.get("meta", {}).get("last_updated", "")


class StringBlob:
    """Deduplicating UTF-8 pool. 61,348 distinct strings back 115,697 products,
    so this is most of the difference between a 12 MB file and an 8 MB one."""

    def __init__(self) -> None:
        self._offsets: dict[str, tuple[int, int]] = {}
        self._buffer = bytearray()

    def add(self, value: str) -> tuple[int, int]:
        value = (value or "").strip()
        if not value:
            return (0, 0)
        if value in self._offsets:
            return self._offsets[value]
        encoded = value.encode("utf-8")
        if len(encoded) > 0xFFFF:
            encoded = encoded[:0xFFFF]
            # Truncating mid-codepoint would produce invalid UTF-8 on read.
            while encoded and (encoded[-1] & 0xC0) == 0x80:
                encoded = encoded[:-1]
        entry = (len(self._buffer), len(encoded))
        self._buffer.extend(encoded)
        self._offsets[value] = entry
        return entry

    @property
    def data(self) -> bytes:
        return bytes(self._buffer)


def build(dataset: dict, export_date: str) -> bytes:
    results = dataset["results"]
    blob = StringBlob()
    products = bytearray()
    packages: dict[int, tuple[int, int]] = {}   # key → (product index, format byte)

    owners: dict[int, str] = {}                 # key → the product_ndc that claimed it
    product_index = 0
    skipped_type = 0
    skipped_package = 0
    duplicate_rows = 0
    collisions: list[tuple[int, str, str]] = []

    for record in results:
        if record.get("product_type") not in CONSUMER_PRODUCT_TYPES:
            skipped_type += 1
            continue

        product_ndc = record.get("product_ndc") or ""
        rows = record.get("packaging") or []
        usable: list[tuple[int, int]] = []
        for package in rows:
            code = (package.get("package_ndc") or "").split("-")
            shape = tuple(len(segment) for segment in code)
            if len(code) != 3 or shape not in SEGMENTATIONS or not all(s.isdigit() for s in code):
                skipped_package += 1
                continue
            key = int("".join(code))
            owner = owners.get(key)
            if owner is not None:
                # The same package listed twice. Harmless when it is the same
                # product both times — openFDA carries a handful of exact
                # duplicate rows — and a genuine ambiguity when it is not.
                if owner == product_ndc:
                    duplicate_rows += 1
                else:
                    collisions.append((key, owner, product_ndc))
                continue
            owners[key] = product_ndc
            usable.append((key, SEGMENTATIONS[shape]))

        # A record whose packages were all duplicates or all malformed gets no
        # product entry: an entry nothing points at is dead weight in the file.
        if not usable:
            continue

        brand = (record.get("brand_name") or "").strip()
        generic = (record.get("generic_name") or "").strip()
        ingredients = record.get("active_ingredients") or []
        # Only a single-ingredient product has *a* strength. A combination
        # tablet has two, and neither one of them is the truth on its own.
        strength = ingredients[0].get("strength", "") if len(ingredients) == 1 else ""

        name_offset, name_length = blob.add(brand or generic)
        generic_offset, generic_length = blob.add(generic)
        strength_offset, strength_length = blob.add(strength)
        form_offset, form_length = blob.add(record.get("dosage_form") or "")

        products.extend(struct.pack(
            "<IHHIIHHI",
            name_offset, name_length,
            generic_length, generic_offset,
            strength_offset, strength_length,
            form_length, form_offset,
        ))

        for key, segmentation in usable:
            packages[key] = (product_index, segmentation)

        product_index += 1

    if collisions:
        # Two *different* products sharing a ten-digit form would make
        # GTIN → NDC resolution ambiguous, which is the assumption the whole
        # feature rests on. It has never happened across the full directory; if
        # it starts, this must be a loud failure rather than a silent overwrite
        # that hands somebody the wrong medicine's name.
        for key, first, second in collisions[:10]:
            print(f"  {key:010d}: {first} and {second}", file=sys.stderr)
        raise SystemExit(
            f"{len(collisions)} package NDCs are claimed by two different products — "
            "GTIN resolution is no longer unique; see NDC-INDEX-FORMAT.md"
        )

    keys = sorted(packages)
    package_count = len(keys)
    print(
        f"{product_index} products, {package_count} packages "
        f"({skipped_type} non-consumer products, {skipped_package} malformed packages "
        f"and {duplicate_rows} duplicate listings skipped)",
        file=sys.stderr,
    )

    keys_blob = b"".join(struct.pack("<Q", key) for key in keys)
    index_blob = b"".join(struct.pack("<I", packages[key][0]) for key in keys)
    formats_blob = bytes(packages[key][1] for key in keys)
    strings_blob = blob.data

    keys_offset = HEADER_SIZE
    packages_offset = keys_offset + len(keys_blob)
    formats_offset = packages_offset + len(index_blob)
    products_offset = formats_offset + len(formats_blob)
    strings_offset = products_offset + len(products)

    header = bytearray(HEADER_SIZE)
    header[0:8] = MAGIC
    struct.pack_into(
        "<IIIIIIIIII", header, 8,
        FORMAT_VERSION,
        int(export_date.replace("-", "")[:8] or 0),
        package_count,
        product_index,
        keys_offset,
        packages_offset,
        formats_offset,
        products_offset,
        strings_offset,
        len(strings_blob),
    )

    return bytes(header) + keys_blob + index_blob + formats_blob + bytes(products) + strings_blob


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--download", action="store_true", help="fetch the current dataset from openFDA")
    source.add_argument("--input", type=Path, help="a previously downloaded .json or .json.zip")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    if arguments.download:
        dataset, export_date = fetch_dataset()
    else:
        dataset, export_date = load_dataset(arguments.input)

    index = build(dataset, export_date)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_bytes(index)
    print(f"wrote {arguments.output} ({len(index) / 1e6:.2f} MB, export {export_date})", file=sys.stderr)


if __name__ == "__main__":
    main()
