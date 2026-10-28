#!/usr/bin/env bash
# make-bundle.sh -- pack this lab into one self-extracting file: dist/setup.sh
# On the target machine (WSL):  bash setup.sh [target-dir]   (default ~/ozone-lab)
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$LAB_DIR"
mkdir -p dist
payload=$(mktemp)
tar -czf "$payload" --exclude=./state --exclude=./logs --exclude=./exports --exclude=./dist --exclude=./.git \
  --exclude=./replay/data --exclude=./replay/events.log --exclude=./lab.env \
  --transform 's,^\./,,' .
{
  cat <<'HEADER'
#!/usr/bin/env bash
# setup.sh -- self-extracting Ozone 2.0.0 incident lab.
# Run inside WSL (Ubuntu), from your Linux home, not from /mnt/c:
#   bash setup.sh [target-dir]        default target: ~/ozone-lab
# If this file went through Windows and bash complains about $'\r', run first:
#   sed -i 's/\r$//' setup.sh
set -euo pipefail
dest=${1:-$HOME/ozone-lab}
case "$(pwd -P)/" in /mnt/*) echo "warning: you are under /mnt (Windows disk). Docker bind mounts are slow there; use your Linux home." >&2 ;; esac
case "$dest" in /mnt/*) echo "error: do not extract to $dest (Windows disk). Use a Linux path such as ~/ozone-lab." >&2; exit 1 ;; esac
mkdir -p "$dest"
sed -n '/^__PAYLOAD_BELOW__$/,$p' "$0" | tail -n +2 | tr -d '\r' | base64 -d | tar -xzf - -C "$dest"
find "$dest" -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' -o -name '*.conf' -o -name '*.env' \
  -o -name 'docker-config' -o -name '*.btm' -o -name '*.py' -o -name '*.json' -o -name '*.md' \) -exec sed -i 's/\r$//' {} +
chmod +x "$dest"/scenario.sh "$dest"/make-bundle.sh "$dest"/byteman/hold.sh "$dest"/perses/make-dashboard.py
echo "Extracted to $dest"
echo
echo "Checks:"
ok=1
if docker info >/dev/null 2>&1; then echo "  [ok]   docker engine is running"; else
  echo "  [FAIL] docker engine is not running. Try: sudo service docker start   (or: sudo systemctl start docker)"; ok=0; fi
if docker compose version >/dev/null 2>&1; then echo "  [ok]   $(docker compose version | head -1)"; else
  echo "  [FAIL] 'docker compose' (v2 plugin) is missing. Install: sudo apt-get install docker-compose-plugin"; ok=0; fi
if command -v python3 >/dev/null; then echo "  [ok]   python3 $(python3 -c 'import sys; print(sys.version.split()[0])')"; else
  echo "  [FAIL] python3 is missing. Install: sudo apt-get install python3"; ok=0; fi
mem=$(awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo)
if [ "$mem" -ge 11 ]; then echo "  [ok]   memory ${mem} GB"; else
  echo "  [WARN] memory ${mem} GB. The lab needs about 10 GB. Set memory=12GB in %UserProfile%\\.wslconfig, then: wsl --shutdown"; fi
command -v flock >/dev/null || { echo "  [FAIL] flock is missing (util-linux)"; ok=0; }
command -v curl >/dev/null || { echo "  [FAIL] curl is missing"; ok=0; }
echo
echo "Next: read $dest/HANDOFF.md, then:"
echo "  cd $dest && ./scenario.sh up"
[ $ok = 1 ] || exit 1
exit 0
__PAYLOAD_BELOW__
HEADER
  base64 -w 76 "$payload"
} > dist/setup.sh
rm -f "$payload"
chmod +x dist/setup.sh
echo "dist/setup.sh ($(du -h dist/setup.sh | cut -f1))"
