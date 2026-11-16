#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm --init -i -v "$PWD:/repo" -v "${SOURCES_VOLUME:-mints-linux-sources}:/sources:ro" -w /repo \
 "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" python3 - <<'PY'
from pathlib import Path
import hashlib,subprocess,tempfile
out=Path('/repo/build/test/board-linux-source');out.mkdir(parents=True,exist_ok=True)
names=['drivers/spi/spi-altera-core.c','drivers/spi/spi-altera-platform.c','include/linux/spi/altera.h']
with tempfile.TemporaryDirectory(dir=out) as temporary:
 base=Path(temporary);src=base/'upstream';view=base/'view'
 for name in names:
  p=src/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((Path('/sources/linux-6.12')/name).read_bytes())
 (src/'Makefile').write_text('original source marker\n')
 hashes={name:hashlib.sha256((src/name).read_bytes()).digest() for name in names}
 def prepare(target,ok=True):
  r=subprocess.run(['python3','tools/prepare-board-linux.py',str(src),str(target)],capture_output=True,text=True)
  assert (r.returncode==0)==ok,(r.returncode,r.stdout,r.stderr)
 prepare(view);prepare(view)
 assert (view/'Makefile').is_symlink()
 for name in names:
  assert not (view/name).is_symlink()
  assert hashlib.sha256((src/name).read_bytes()).digest()==hashes[name]
 assert 'readl(hw->mmio + ALTERA_SPI_STATUS)' in (view/names[0]).read_text()
 (view/names[0]).write_text('unexpected change\n');prepare(view,False)
 assert hashlib.sha256((src/names[0]).read_bytes()).digest()==hashes[names[0]]
 (src/names[2]).write_text('unsupported upstream header\n');prepare(base/'bad-view',False)
 assert not (base/'bad-view').exists()
print('BOARD_LINUX_SOURCE_PASS: upstream unchanged, private patches, repeatable view, drift rejection')
PY
