#!/usr/bin/env python3
"""Draw the MiNTs-CPU architecture diagrams (SVG) from one shared layout.

  Docs/images/architecture_simulation.svg  Verilator simulator SoC (plain Makefile
                                           defaults; Linux rebuild profile shown separately)
  Docs/images/architecture_fpga.svg        DE0-CV board SoC: the shared CPU RTL plus
                                           board-specific additions and replacements

Conceptual block diagrams: buses, handshakes and arbitration are simplified.

Every block is tagged "both", "sim" (simulation only), "fpga" (board only) or
"simuse" (in both builds but enabled only in simulation, e.g. branch prediction).
In each view, blocks of the other configuration are drawn greyed and dashed.
Size labels that differ between the configurations come from the CONFIG table
(see Docs/CURRENT_STATUS.md, tools/build-de0cv-soc.sh and the Makefile).

Usage: python3 tools/draw-architecture.py
"""
from pathlib import Path
from xml.sax.saxutils import escape

W, H = 1680, 1190
FONT = "Helvetica, Arial, sans-serif"

# per-view text for configuration-dependent blocks
CONFIG = {
    "sim": {
        "title": "MiNTs-CPU architecture: Verilator simulator SoC",
        "subtitle": "Shared CPU RTL with the simulator memory, I/O and verification harness; "
                    "sizes are the plain Makefile defaults",
        "bp": "PHT 128 / BTB 32 / RAS 8",
        "itlb": "8 entries",
        "dtlb": "8 entries",
        "icache": "4 KiB, 32 B lines",
        "dcache": "4 KiB",
        "sb": "store buffer 4",
        "ram": "128 MiB model\n(optional build:\nSDRAM ctrl + model)",
        "uart": "NS16550A\nDPI byte backend",
        "clock": "timebase 50 MHz (legacy DTB)",
    },
    "fpga": {
        "title": "MiNTs-CPU architecture: DE0-CV FPGA board SoC",
        "subtitle": "Cyclone V 5CEBA4F23C7, 20 MHz: the shared CPU RTL plus board-specific additions and "
                    "replacements (SDRAM, JTAG loader, UART PHY, VGA, microSD)",
        "bp": "disabled (BP_ENABLE=0)",
        "itlb": "2 entries",
        "dtlb": "2 entries",
        "icache": "1 KiB, M10K data",
        "dcache": "1 KiB, M10K data",
        "sb": "store buffer 4",
        "ram": "64 MiB SDRAM",
        "uart": "NS16550A + 8N1 PHY\n115200, JP1 pins",
        "clock": "20 MHz CPU / timebase",
    },
}

STYLE = {
    "core":   ("#eef6ee", "#4f8a4f"),
    "fetch":  ("#e9f1fb", "#3d6fb0"),
    "mem":    ("#fdf3e6", "#c47a1c"),
    "mmu":    ("#f3eefb", "#7a55b5"),
    "bus":    ("#f2f2f2", "#666666"),
    "dev":    ("#ffffff", "#666666"),
    "verify": ("#eaf2fb", "#2f5f99"),
    "board":  ("#fff4f0", "#c0532b"),
}
GREY_FILL, GREY_LINE, GREY_TEXT = "#f7f7f7", "#c4c4c4", "#a8a8a8"


class Svg:
    def __init__(self, view):
        self.view = view
        self.out = []
        self.cfg = CONFIG[view]

    def active(self, tag):
        # "simuse": present in the RTL of both, but only used (enabled) in simulation
        return tag == "both" or tag == self.view or (tag == "simuse" and self.view == "sim")

    def text(self, x, y, s, size=13, weight="normal", color="#222", anchor="middle", italic=False):
        lines = s.split("\n")
        y0 = y - (len(lines) - 1) * size * 0.6
        style = ' font-style="italic"' if italic else ""
        for i, line in enumerate(lines):
            self.out.append(
                f'<text x="{x}" y="{y0 + i * size * 1.2:.1f}" font-family="{FONT}" font-size="{size}" '
                f'font-weight="{weight}" fill="{color}" text-anchor="{anchor}" dominant-baseline="middle"{style}>'
                f"{escape(line)}</text>")

    def group(self, x, y, w, h, label, kind, tag="both", sub=None, right=False):
        on = self.active(tag)
        fill, line = STYLE[kind]
        if not on:
            fill, line = GREY_FILL, GREY_LINE
        dash = "" if on else ' stroke-dasharray="7 5"'
        self.out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{fill}" '
                        f'stroke="{line}" stroke-width="2"{dash}/>')
        if right:
            self.text(x + w - 14, y + 18, label, 15, "bold", line if on else GREY_TEXT, "end")
        else:
            self.text(x + 14, y + 18, label, 15, "bold", line if on else GREY_TEXT, "start")
        if on and tag == self.view and tag != "both":
            self.badge(x + w - 12, y + 18, tag)
        if sub:
            self.text(x + w - 14, y + 18, sub, 12, "normal", line if on else GREY_TEXT, "end", italic=True)

    def badge(self, right, cy, tag):
        text = "SIM ONLY" if tag == "sim" else "FPGA ONLY"
        bw = 62 if tag == "sim" else 70
        color = STYLE["verify"][1] if tag == "sim" else STYLE["board"][1]
        self.out.append(f'<rect x="{right - bw}" y="{cy - 7.5}" width="{bw}" height="15" rx="7" fill="{color}"/>')
        self.text(right - bw / 2, cy + 0.5, text, 9, "bold", "#ffffff")

    def box(self, x, y, w, h, label, kind, tag="both", detail=None, badge=True):
        on = self.active(tag)
        fill, line = STYLE[kind]
        fill = "#ffffff" if on else GREY_FILL
        if not on:
            line = GREY_LINE
        dash = "" if on else ' stroke-dasharray="6 4"'
        width = 2.4 if (on and tag == self.view and tag != "both") else 1.5
        self.out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="{fill}" '
                        f'stroke="{line}" stroke-width="{width}"{dash}/>')
        color = "#222" if on else GREY_TEXT
        rows = [(l, 13, "bold", color) for l in label.split("\n")]
        if detail:
            rows += [(l, 11, "normal", line if on else GREY_TEXT) for l in detail.split("\n")]
        heights = [sz * 1.25 for _, sz, _, _ in rows]
        yy = y + h / 2 - sum(heights) / 2
        for (l, sz, wt, col), hh in zip(rows, heights):
            self.text(x + w / 2, yy + hh / 2, l, sz, wt, col)
            yy += hh
        if badge and on and tag == self.view and tag != "both":
            self.badge(x + w - 4, y - 0.5, tag)

    def arrow(self, pts, tag="both", color="#555", label=None, lpos=None, dashed=False):
        on = self.active(tag)
        c = color if on else GREY_LINE
        d = "M " + " L ".join(f"{x} {y}" for x, y in pts)
        dash = ' stroke-dasharray="6 4"' if (dashed or not on) else ""
        marker = "arrow" if on else "arrowg"
        self.out.append(f'<path d="{d}" fill="none" stroke="{c}" stroke-width="1.8"{dash} '
                        f'marker-end="url(#{marker})"/>')
        if label:
            lx, ly = lpos
            bw = len(label) * 5.9 + 12
            self.out.append(f'<rect x="{lx - bw / 2:.1f}" y="{ly - 8}" width="{bw:.1f}" height="16" rx="3" '
                            f'fill="#ffffff" fill-opacity="0.92"/>')
            self.text(lx, ly, label, 11, "normal", c if on else GREY_TEXT)

    def render(self):
        head = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
                "<defs>",
                '<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
                'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#555"/></marker>',
                '<marker id="arrowg" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
                f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{GREY_LINE}"/></marker>',
                "</defs>",
                f'<rect width="{W}" height="{H}" fill="#ffffff"/>']
        return "\n".join(head + self.out + ["</svg>"]) + "\n"


def draw(view):
    s = Svg(view)
    c = s.cfg
    s.text(W / 2, 32, c["title"], 26, "bold")
    s.text(W / 2, 60, c["subtitle"], 14, "normal", "#555")

    # ---------------- CPU core pipeline (y 85..430) ----------------
    s.group(30, 85, 1230, 345, "CPU core: in-order 5-stage pipeline, RV64IMAC, M/S/U privilege", "core",
            sub="IF → ID → EX → MEM → WB")
    for x, w, label, kind in [(50, 225, "IF  instruction fetch", "fetch"), (290, 200, "ID  decode", "core"),
                              (505, 220, "EX  execute", "core"), (740, 300, "MEM  memory access", "mem"),
                              (1055, 190, "WB  write back", "core")]:
        s.group(x, 120, w, 295, label, kind)
    s.box(65, 155, 195, 46, "Instruction fetcher", "fetch", detail="fetch / issue FIFOs, RVC expand")
    s.box(65, 209, 195, 46, "Branch predictor", "fetch", tag="simuse", detail=c["bp"])
    s.box(65, 263, 195, 46, "ITLB (Sv39)", "fetch", detail=c["itlb"])
    s.box(65, 317, 195, 46, "I-cache", "fetch", detail=c["icache"])
    s.box(65, 371, 195, 32, "PMP fetch / issue checks", "mmu")
    s.box(305, 160, 170, 52, "Instruction decoder", "core")
    s.box(305, 225, 170, 52, "Register file", "core", detail="32 × 64 bit, 2R1W")
    s.box(305, 290, 170, 52, "Control / hazards", "core", detail="forwarding, stalls")
    s.box(520, 155, 190, 46, "ALU", "core")
    s.box(520, 209, 190, 46, "Branch unit", "core", detail="early JAL / JALR / branch redirect")
    s.box(520, 263, 190, 46, "Mul / Div unit", "core", detail="M extension")
    s.box(520, 317, 190, 46, "CSR unit", "core", detail="traps, interrupts, counters")
    s.box(755, 155, 130, 46, "memunit", "mem", detail="align / split")
    s.box(755, 209, 130, 46, "DTLB (Sv39)", "mem", detail=c["dtlb"])
    s.box(755, 263, 130, 46, "PMP data check", "mmu")
    s.box(900, 155, 125, 100, "D-cache", "mem", detail=c["dcache"] + "\nwrite-through\n" + c["sb"])
    s.box(900, 263, 125, 46, "AMO unit", "mem", detail="LR/SC, AMO*")
    s.box(755, 317, 270, 46, "fence.i drain", "mem", detail="store buffer + AMO idle before re-fetch")
    s.box(1070, 160, 160, 52, "Register writeback", "core")
    s.box(1070, 225, 160, 52, "Retire", "core", detail="minstret, retire port")
    s.box(1070, 290, 160, 52, "Performance counters", "core", detail="cycle / instret CSRs")
    for x0, x1 in [(275, 290), (490, 505), (725, 740), (1040, 1055)]:
        s.arrow([(x0, 268), (x1, 268)])

    # ---------------- channel (y 430..495): miss and page-table traffic ----------------
    # RTL: the I-side PTW shares the fetcher memory port with I-cache refills (PTW
    # first); the D-side PTW issues its PTE reads through memunit -> D-cache.
    s.arrow([(110, 415), (110, 526)], color="#7a55b5", label="ITLB miss", lpos=(66, 470))
    s.arrow([(800, 415), (800, 444), (215, 444), (215, 526)], color="#7a55b5",
            label="DTLB miss → page-table walk", lpos=(560, 444))
    s.arrow([(140, 415), (140, 466), (830, 466), (830, 520)], color="#3d6fb0",
            label="fetch memory port: I-cache refill + I-side PTE reads", lpos=(500, 466))
    s.arrow([(180, 526), (180, 469)], color="#7a55b5")
    s.arrow([(245, 526), (245, 486), (870, 486), (870, 415)], color="#7a55b5",
            label="D-side PTE reads → memunit → D-cache", lpos=(560, 486))
    s.arrow([(962, 415), (962, 520)], color="#c47a1c", label="D-cache miss / uncached / stores",
            lpos=(1060, 466))

    # ---------------- MMU / protection (y 495..650) ----------------
    s.group(30, 495, 710, 155, "MMU / protection", "mmu", right=True)
    s.box(50, 526, 215, 56, "Sv39 page-table walkers", "mmu", detail="I: fetch memory port\nD: memunit → D-cache")
    s.box(280, 526, 210, 56, "PMP region decode", "mmu", detail="8 entries, decoded once, shared")
    s.box(505, 526, 215, 56, "PMP checkers", "mmu", detail="fetch, issue, data, 2 × PTW")
    s.box(50, 592, 670, 44, "satp / ASID, sfence.vma, SUM / MXR", "mmu",
          detail="M-mode bypass; access fault on PMP violation")

    # ---------------- SoC interconnect (y 495..650) ----------------
    s.group(760, 495, 500, 155, "SoC interconnect", "bus")
    s.box(780, 520, 220, 56, "I/D memory arbiter", "bus", detail="I-side, D-high, D-low")
    s.box(1020, 520, 220, 56, "MMIO controller", "bus", detail="address decode → devices / RAM")
    s.box(780, 588, 460, 46, "DMA engine  @ 0x3000_0000", "bus", detail="RAM master, MMIO-programmed")
    s.arrow([(1000, 548), (1020, 548)])
    s.arrow([(1130, 650), (1130, 690)])

    # ---------------- devices / memory map (y 670..850) ----------------
    s.group(30, 670, 1230, 180, "Devices and memory map", "bus")
    devs = [
        ("Boot ROM", "0x0000_1000\nreset vector", "both"),
        ("ACLINT", "0x0200_0000\nMSWI / MTIMER", "both"),
        ("PLIC", "0x0C00_0000\nexternal IRQs", "both"),
        ("UART", "0x1000_0000\n" + c["uart"], "both"),
        ("Debug / exit MMIO", "0x4000_0000\nprintf, test exit", "sim"),
        ("Board I/O", "0x4000_0000\nLED / SW / KEY,\nVGA text, microSD", "fpga"),
        ("RAM", "0x8000_0000\n" + c["ram"], "both"),
    ]
    for i, (name, detail, tag) in enumerate(devs):
        s.box(45 + i * 175, 712, 165, 120, name, "dev", tag=tag, detail=detail)

    # ---------------- simulation-only column ----------------
    s.group(1280, 85, 370, 345, "Verification (simulation)", "verify", tag="sim")
    for k, (name, detail) in enumerate([
            ("riscv-tests ISA suite", "rv64 ui / um / ua / uc / mi / si"),
            ("Whisper lockstep (optional)", "PC, register, memory, trap compare"),
            ("RAM latency shim (optional)", "variable memory latency injection"),
            ("Traces and PERF_SUMMARY", "fetch / cache / TLB / predictor statistics"),
            ("Linux boot (Linux rebuild profile)", "OpenSBI → Linux 6.12 → BusyBox autotest")]):
        s.box(1300, 122 + k * 60, 330, 50, name, "verify", tag="sim", detail=detail, badge=False)

    # ---------------- board-only column ----------------
    s.group(1280, 495, 370, 355, "DE0-CV board integration", "board", tag="fpga")
    s.box(1300, 530, 330, 46, "PLL", "board", tag="fpga", badge=False, detail="20 MHz CPU, phase-shifted SDRAM clock")
    s.box(1300, 586, 330, 56, "SDRAM path", "board", tag="fpga", badge=False,
          detail="membus_sdram_adapter → bridge64 →\nsdram_native16 (x16 SDR, 64 MiB)")
    s.box(1300, 652, 330, 56, "JTAG boot loader", "board", tag="fpga", badge=False,
          detail="virtual JTAG mailbox → loader: clear,\nwrite, read-back verify, then release CPU")
    s.box(1300, 716, 160, 70, "VGA text", "board", tag="fpga", badge=False,
          detail="80 × 30, 640 × 480\ncommand/ack verified;\nmonitor image not observed")
    s.box(1470, 716, 160, 70, "microSD (SPI)", "board", tag="fpga", badge=False,
          detail="polled; FAT32 read +\nnew-file write/readback\nverified on board")
    s.box(1300, 794, 330, 46, "JTAG CPU snapshots", "board", tag="fpga", badge=False, detail="read-only debug (SVCPU_FPGA_DEBUG)")
    s.arrow([(1252, 772), (1288, 772), (1288, 614), (1300, 614)], tag="fpga", color="#c0532b")

    # ---------------- software stack, configuration, legend (y 870..) ----------------
    y = 870
    s.group(30, y, 1620, 300, "Software stack and configuration", "bus")
    for i, name in enumerate(["Boot ROM", "OpenSBI v1.3.1", "Linux 6.12", "BusyBox 1.36.1", "UART shell"]):
        x = 55 + i * 170
        s.box(x, y + 40, 145, 40, name, "core")
        if i:
            s.arrow([(x - 25, y + 60), (x, y + 60)])
    if view == "sim":
        heads = ["", "plain Makefile defaults", "Linux rebuild profile"]
        rows = [("Branch prediction", "PHT 128 / BTB 32 / RAS 8", "PHT 128 / BTB 32 / RAS 8"),
                ("ITLB / DTLB", "8 entries each", "8 entries each"),
                ("I-cache", "4 KiB", "4 KiB"),
                ("D-cache", "4 KiB, write-through", "16 KiB, write-through"),
                ("Store buffer", "4 entries", "8 entries"),
                ("RAM", "128 MiB model", "128 MiB model"),
                ("DTB timebase", "50 MHz", "50 MHz")]
    else:
        heads = ["", "DE0-CV build defaults"]
        rows = [("Branch prediction", "disabled (BP_ENABLE=0)"),
                ("ITLB / DTLB", "2 entries each"),
                ("I-cache", "1 KiB, M10K data"),
                ("D-cache", "1 KiB, M10K data, write-through"),
                ("Store buffer", "4 entries"),
                ("RAM", "64 MiB SDRAM"),
                ("CPU clock / timebase", "20 MHz / 20 MHz")]
    s.text(55, y + 106, "Configuration (Docs/CURRENT_STATUS.md):", 13, "bold", "#333", "start")
    cols = [55, 215, 470]
    for ci, h in enumerate(heads):
        s.text(cols[ci], y + 130, h, 12, "bold", "#2f5f99" if view == "sim" else "#c0532b", "start")
    for ri, row in enumerate(rows):
        yy = y + 150 + ri * 18
        for ci, v in enumerate(row):
            s.text(cols[ci], yy, v, 12, "bold" if ci == 0 else "normal", "#444", "start")
    lx, ly = 940, y + 40
    s.text(lx, ly, "Legend", 14, "bold", "#333", "start")
    s.out.append(f'<rect x="{lx}" y="{ly + 18}" width="34" height="20" rx="4" fill="#fff" stroke="#666" stroke-width="1.5"/>')
    s.text(lx + 45, ly + 28, "used in this configuration", 12, "normal", "#333", "start")
    s.out.append(f'<rect x="{lx}" y="{ly + 48}" width="34" height="20" rx="4" fill="{GREY_FILL}" '
                 f'stroke="{GREY_LINE}" stroke-width="1.5" stroke-dasharray="6 4"/>')
    other = "FPGA board only (not in this view)" if view == "sim" else "simulation only (not on the board)"
    s.text(lx + 45, ly + 58, other, 12, "normal", "#333", "start")
    s.badge(lx + 70, ly + 88, view)
    s.text(lx + 80, ly + 88, "present only in this configuration", 12, "normal", "#333", "start")
    if view == "fpga":
        notes = ["Same CPU RTL as the simulator. The board adds the PLL, SDRAM path, JTAG loader,",
                 "UART PHY, VGA and microSD, and replaces the RAM model, the DPI UART backend",
                 "and the 0x4000_0000 window. Fit 17,269 / 18,480 ALM (93 %); timing passes at 20 MHz."]
    else:
        notes = ["Blocks show the plain Makefile defaults; the Linux rebuild profile differs only in",
                 "D-cache size and store-buffer depth. \"optional\" items are separate build options.",
                 "The DE0-CV board SoC is shown in architecture_fpga.svg."]
    notes.append("Conceptual block diagram: buses, handshakes and arbitration are simplified.")
    for k, n in enumerate(notes):
        s.text(lx, ly + 122 + k * 18, n, 11, "normal", "#666", "start", italic=True)
    return s.render()


def main():
    out = Path(__file__).resolve().parent.parent / "Docs" / "images"
    out.mkdir(parents=True, exist_ok=True)
    for view, name in [("sim", "architecture_simulation.svg"), ("fpga", "architecture_fpga.svg")]:
        (out / name).write_text(draw(view))
        print(out / name)


if __name__ == "__main__":
    main()
