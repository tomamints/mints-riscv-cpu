#!/usr/bin/env bash
# Install the official Linux x86_64 Quartus release into a local Docker volume.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
: "${QUARTUS_DOWNLOAD_DIR:=$HOME/Downloads}"
: "${QUARTUS_IMAGE:=mints-quartus:20.1}"
: "${QUARTUS_VOLUME:=mints-quartus-20.1}"
installer=QuartusLiteSetup-20.1.0.711-linux.run
device=cyclonev-20.1.0.711.qdz
mkdir -p local/quartus-installers build/logs
python3 - "$QUARTUS_DOWNLOAD_DIR" <<'PY'
import hashlib, pathlib, sys
base = pathlib.Path(sys.argv[1])
expected = {
    'QuartusLiteSetup-20.1.0.711-linux.run': '00a2909e7cf0e174a5528d110608348174aac9b3',
    'cyclonev-20.1.0.711.qdz': 'c4ee3fa13f1dfbd3d95c8baa9fece7b864ef5d2c',
}
for name, wanted in expected.items():
    path = base / name
    if not path.is_file():
        raise SystemExit(f'Missing official installer: {path}')
    h = hashlib.sha1()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(chunk)
    if h.hexdigest() != wanted:
        raise SystemExit(f'Incomplete or unexpected download: {path}')
    print(f'Checksum verified: {name}')
PY
cp "$QUARTUS_DOWNLOAD_DIR/$installer" local/quartus-installers/
cp "$QUARTUS_DOWNLOAD_DIR/$device" local/quartus-installers/
chmod +x "local/quartus-installers/$installer"
docker build --platform linux/amd64 -f Dockerfile.quartus -t "$QUARTUS_IMAGE" .
docker_args=(--rm --init --platform linux/amd64
  -v "$PWD/local/quartus-installers:/installers:ro"
  -v "$QUARTUS_VOLUME:/opt/intelFPGA_lite"
  -v "$PWD:/repo")
docker run "${docker_args[@]}" "$QUARTUS_IMAGE" \
  "/installers/$installer" --help > build/logs/quartus-installer-help.log 2>&1
docker run "${docker_args[@]}" "$QUARTUS_IMAGE" \
  "/installers/$installer" --mode unattended --unattendedmodeui none \
  --accept_eula 1 --installdir /opt/intelFPGA_lite/20.1 \
  2>&1 | tee build/logs/quartus-install.log
docker run "${docker_args[@]}" "$QUARTUS_IMAGE" \
  /opt/intelFPGA_lite/20.1/quartus/bin/quartus_sh --version \
  2>&1 | tee build/logs/quartus-version.log
