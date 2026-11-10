#!/bin/bash
# Builds the browser replay: one self-contained HTML page showing a simulated
# coaching session with the app's real HUD output and voice clips.
#   tools/make_replay.sh [out.html] [laps]
# Needs luajit, ffmpeg and python3. The game does not need any of this.

set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/replay.html}"
LAPS="${2:-20}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

luajit tools/make_replay.lua "$TMP/replay.json" "$LAPS"

# The voice clips as small MP3s, so the page can speak.
mkdir -p "$TMP/mp3"
for f in sounds/*.wav; do
  ffmpeg -loglevel error -y -i "$f" -ac 1 -ar 22050 -b:a 40k "$TMP/mp3/$(basename "$f" .wav).mp3"
done

python3 - "$TMP" "$OUT" <<'PY'
import base64, json, os, sys
tmp, out = sys.argv[1], sys.argv[2]
data = open(os.path.join(tmp, 'replay.json')).read()
audio = {}
for name in sorted(os.listdir(os.path.join(tmp, 'mp3'))):
    raw = open(os.path.join(tmp, 'mp3', name), 'rb').read()
    audio[name[:-4]] = 'data:audio/mpeg;base64,' + base64.b64encode(raw).decode()
page = open('tools/replay.html').read()
assert '/*REPLAY*/null' in page and '/*AUDIO*/null' in page
page = page.replace('/*REPLAY*/null', data).replace('/*AUDIO*/null', json.dumps(audio))
os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
open(out, 'w').write(page)
print('%s: %.1f MB' % (out, len(page) / 1e6))
PY
