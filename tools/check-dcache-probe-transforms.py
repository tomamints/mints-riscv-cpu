#!/usr/bin/env python3
"""Verify the copy-only synthesis transforms of tools/build-dcache-probe.sh.

For every configuration directory under build/fpga/dcache-probe/:
  * eei.sv: the CsrCause enum has the same element names, order and numeric
    values before (eei.sv.orig) and after (rtl/eei.sv); all other lines identical.
  * dcache.sv: the only difference is the added translate_off/translate_on pair.
Writes transform_check.txt (with SHA-256 of all four files) per configuration.
Exit status 1 on any mismatch.
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "build/fpga/dcache-probe"


def literal(text):
    t = text.strip().replace("_", "")
    m = re.fullmatch(r"(?:(\d+))?'([dhb])([0-9a-fA-F]+)", t)
    if m:
        return int(m.group(3), {"d": 10, "h": 16, "b": 2}[m.group(2)])
    if re.fullmatch(r"\d+", t):
        return int(t)
    raise ValueError(f"unsupported literal {text!r}")


def csr_cause(path):
    lines = path.read_text().splitlines()
    start = next(i for i, l in enumerate(lines) if re.search(r"typedef enum UIntX\s*\{", l))
    end = next(i for i in range(start, len(lines)) if re.search(r"\}\s*CsrCause", lines[i]))
    elems = []
    for l in lines[start + 1:end]:
        m = re.match(r"\s*([A-Z_0-9]+)\s*=\s*([^,]+?)\s*,?\s*$", l)
        if m:
            elems.append((m.group(1), literal(m.group(2))))
    return lines, start, end, elems


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ok = True
    cfgs = sorted(p for p in ROOT.iterdir() if (p / "eei.sv.orig").exists())
    if not cfgs:
        print("no configurations found")
        return 1
    for cfg in cfgs:
        report = []
        bad = False
        o_lines, o_s, o_e, o_el = csr_cause(cfg / "eei.sv.orig")
        n_lines, n_s, n_e, n_el = csr_cause(cfg / "rtl/eei.sv")
        if len(o_el) != 19 or o_el != n_el:
            bad = True
            report.append(f"CsrCause mismatch: {o_el} vs {n_el}")
        else:
            report.append("CsrCause: 19 elements, names/order/values identical: "
                          + ", ".join(f"{k}=0x{v:x}" for k, v in n_el))
        if (o_s, o_e) != (n_s, n_e) or len(o_lines) != len(n_lines) or \
           o_lines[:o_s + 1] != n_lines[:n_s + 1] or o_lines[o_e:] != n_lines[n_e:]:
            bad = True
            report.append("eei.sv: lines outside the CsrCause enum differ")
        d_o = (cfg / "dcache.sv.orig").read_text().splitlines()
        d_n = (cfg / "rtl/dcache.sv").read_text().splitlines()
        added = [l for l in d_n if l.strip() in ("// synthesis translate_off", "// synthesis translate_on")]
        added_o = [l for l in d_o if l.strip() in ("// synthesis translate_off", "// synthesis translate_on")]
        stripped = list(d_n)
        # remove exactly the two inserted pragma lines around "final begin"
        i = next(k for k, l in enumerate(stripped) if l == "\tfinal begin")
        if stripped[i - 1] != "\t// synthesis translate_off":
            bad = True
            report.append("dcache.sv: translate_off not directly before final")
        else:
            del stripped[i - 1]
            j = next(k for k in range(i - 1, len(stripped)) if stripped[k] == "\t// synthesis translate_on")
            del stripped[j]
        if stripped != d_o or len(added) - len(added_o) != 2:
            bad = True
            report.append("dcache.sv: differs beyond the final-block pragma pair")
        else:
            report.append("dcache.sv: only the final-block translate_off/on pair added")
        for f in ("eei.sv.orig", "rtl/eei.sv", "dcache.sv.orig", "rtl/dcache.sv"):
            report.append(f"sha256 {sha(cfg / f)}  {f}")
        report.insert(0, f"{cfg.name}: {'FAIL' if bad else 'OK'}")
        (cfg / "transform_check.txt").write_text("\n".join(report) + "\n")
        print(report[0])
        ok &= not bad
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
