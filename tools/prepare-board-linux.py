#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Private source view: retain upstream sources and add an 8-bit polling path.

The original Linux tree stays untouched. All unchanged files are symlinks;
only the three modified files are replaced by private regular files.
"""
from pathlib import Path
import hashlib,json,subprocess,sys
src,dst=map(Path,sys.argv[1:])
if not src.is_absolute() or not dst.is_absolute():
    raise SystemExit('Expected absolute source and destination directories')
changes={
 'include/linux/spi/altera.h': [('\tstruct regmap *regmap;', '\t/* Direct MMIO is valid only for the standalone platform controller. */\n\tvoid __iomem *mmio;\n\tstruct regmap *regmap;')],
 'drivers/spi/spi-altera-platform.c': [('\t\thw->regmap = devm_regmap_init_mmio', '\t\thw->mmio = res;\n\t\thw->regmap = devm_regmap_init_mmio'),
 ('\tdev_info(&pdev->dev, "regoff %u, irq %d\\n", hw->regoff, hw->irq);', '\tif (hw->mmio && hw->irq < 0)\n\t\tdev_info(&pdev->dev, "MiNTs direct 8-bit MMIO polling enabled\\n");\n\tdev_info(&pdev->dev, "regoff %u, irq %d\\n", hw->regoff, hw->irq);')],
 'drivers/spi/spi-altera-core.c': [('\twhile (hw->count < hw->len) {', '''	/* SPI core serializes transfers. Avoid regmap locks/callbacks for every
	 * byte on the standalone, uncached MMIO, polling-only 8-bit path.
	 * Keep normal readl/writel I/O ordering. IRQ, subdevice and wider-word
	 * transfers retain the original regmap implementation below.
	 */
	if (hw->mmio && hw->bytes_per_word == 1) {
		while (hw->count < hw->len) {
			u8 tx = hw->tx ? hw->tx[hw->count] : 0;

			writel(tx, hw->mmio + ALTERA_SPI_TXDATA);
			do {
				val = readl(hw->mmio + ALTERA_SPI_STATUS);
				if (!(val & ALTERA_SPI_STATUS_RRDY_MSK))
					cpu_relax();
			} while (!(val & ALTERA_SPI_STATUS_RRDY_MSK));
			val = readl(hw->mmio + ALTERA_SPI_RXDATA);
			if (hw->rx)
				hw->rx[hw->count] = val;
			hw->count++;
		}
		spi_finalize_current_transfer(host);
		return 0;
	}

	while (hw->count < hw->len) {''')],
}
# Validate all contexts before creating a view; fail if the upstream API changes.
patched={};manifest={}
for name,replacements in changes.items():
    original=(src/name).read_text();text=original
    for old,new in replacements:
        if text.count(old)!=1:raise SystemExit('Unexpected Linux source context: '+name)
        text=text.replace(old,new)
    patched[name]=text
    manifest[name]={'original':hashlib.sha256(original.encode()).hexdigest(),'patched':hashlib.sha256(text.encode()).hexdigest()}
if dst.exists():
    marker=dst/'mints-spi-source-manifest.json'
    if not marker.is_file() or json.loads(marker.read_text())!=manifest:
        raise SystemExit('Refusing an unknown or outdated source view')
    for name,text in patched.items():
        if (dst/name).is_symlink() or (dst/name).read_text()!=text:
            raise SystemExit('Modified source view: '+name)
    print(dst)
    raise SystemExit(0)
subprocess.run(['cp','-as',str(src),str(dst)],check=True)
for name,text in patched.items():
    target=dst/name
    # Atomic replacement replaces the symlink, never follows it into upstream.
    temporary=target.with_name(target.name+'.mints-new');temporary.write_text(text);temporary.replace(target)
(dst/'mints-spi-source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(dst)
