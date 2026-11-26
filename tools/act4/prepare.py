"""Prepare the MiNTs DUT configuration from the pinned ACT4 Sail template."""

import json
from pathlib import Path
import re
import shutil
import sys


def main():
    source, output = map(Path, sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    here = Path(__file__).parent
    for name in ("test_config.yaml", "mints-rv64.yaml", "rvmodel_macros.h"):
        shutil.copyfile(here / name, output / name)

    # Preserve quoted strings (including URLs) when removing JSON comments.
    template = source / "config/sail/sail-RVI20U64/sail.json"
    config = json.loads(re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*',
                               lambda match: "" if match[0].startswith("//") else match[0],
                               template.read_text()))
    base = config["base"]
    base["mcountinhibit"]["writable_bits"]["value"] = "0x0"
    for csr in ("mcounteren", "scounteren"):
        base[f"{csr}_writable_bits"]["value"] = "0x7"
    base["stvec"]["direct"]["supported"] = True
    base["stvec"]["vectored"]["supported"] = True
    base["mideleg"]["delegatable_bits"]["value"] = "0x222"
    base["medeleg"]["delegatable_bits"]["value"] = "0xb3ff"
    base["mstatus"]["fs_legal_states"] = "ExtContext_Off"

    memory = config["memory"]
    memory["physaddr_bits"] = 56
    # Sail models a 16-entry CSR bank but only eight entries can be enabled.
    memory["pmp"].update(count=16, usable_count=8)
    exceptions = memory["misaligned"]["exceptions"]
    for access in ("amo", "lrsc"):
        exceptions[access] = {"Some": "AlignmentException"}
    for region in memory["regions"]:
        if int(region["base"]["value"], 16) == 0x80000000:
            region["size"]["value"] = "0x08000000"

    config["platform"].update(impid=1, wfi_is_nop=True, wfi_available_to_user_mode=True)
    extensions = config["extensions"]
    for name in ("F", "D", "Zcd"):
        extensions[name]["supported"] = False
    for name in ("S", "U", "Svbare", "Sv39"):
        extensions[name]["supported"] = True
    (output / "sail.json").write_text(json.dumps(config, indent=2) + "\n")

    link = (source / "config/sail/sail-rv64-max/link.ld").read_text()
    link = link.replace("RAM_LENGTH = 0x80000000;", "RAM_LENGTH = 0x08000000;")
    link = link.replace("  . = ALIGN(16);\n  .bss", "  .tohost : { *(.tohost) } > ram\n\n  . = ALIGN(16);\n  .bss")
    (output / "link.ld").write_text(link)


if __name__ == "__main__":
    main()
