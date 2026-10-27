#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Override only isolated generated version.h; do not edit shared QMK code."""
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[3]


def build_timestamp(build):
    if not 0 <= build <= 0xFFFFFFFF:
        raise ValueError("Keyglow build must be a u32")
    # Deterministic release identity, not the wall-clock compilation time.
    return (datetime(2026, 10, 27, tzinfo=timezone.utc) + timedelta(seconds=build)).strftime("%Y-%m-%d-%H:%M:%S")


def main(arguments):
    if not arguments or arguments[0] != "generate-version-h":
        return subprocess.call([str(PROJECT / "build/qmk-venv/bin/qmk")] + arguments)
    output = None
    for index, argument in enumerate(arguments):
        if argument in ("-o", "--output") and index + 1 < len(arguments):
            output = Path(arguments[index + 1]).resolve()
    if output is None or not output.is_relative_to((PROJECT / "build/ota-integration").resolve()):
        raise ValueError("Version header must belong to the isolated OTA output")
    build = int(os.environ.get("KEYGLOW_OTA_BUILD", "8"))
    timestamp = build_timestamp(build)
    text = ("/* SPDX-License-Identifier: GPL-2.0-or-later; generated Keyglow release identity. */\n"
            "#pragma once\n#define QMK_VERSION \"Keyglow\"\n"
            f"#define QMK_BUILDDATE \"{timestamp}\"\n"
            "#define QMK_GIT_HASH \"2b493ff95f2665db719b1e95c91babb5036e72f3\"\n"
            "#define CHIBIOS_VERSION \"pinned\"\n#define CHIBIOS_CONTRIB_VERSION \"pinned\"\n")
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.read_text() != text:
        output.write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
