#!/bin/bash
# Lager utgivelsespakken Foreldrekontroll-<versjon>.zip fra det som er committet (ikke arbeidskopien).
# Rydder byggemappen først, og stopper hvis noe ikke stemmer. Kjør:  bash tools/lag-utgivelse.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ver=$(grep -oP "^\\\$AppVersion\s*=\s*'\K[0-9]+\.[0-9]+\.[0-9]+" Setup-Foreldrekontroll.ps1)
[ -n "$ver" ] || { echo "FEIL: fant ikke \$AppVersion i Setup-Foreldrekontroll.ps1"; exit 1; }
if [ -n "$(git status --porcelain -- . ':!scratchpad')" ]; then
    echo "FEIL: det finnes endringer som ikke er committet:"; git status --short -- . ':!scratchpad'; exit 1
fi

name="Foreldrekontroll-$ver"
out="scratchpad/release"
rm -rf "$out"                      # rydd gamle utdata for denne pakken
mkdir -p "$out/$name"
files=(Setup-Foreldrekontroll.ps1 Haandhever.ps1 Start-Foreldrekontroll.cmd lang README.md README.uk.md LICENSE)
git archive HEAD "${files[@]}" | tar -x -C "$out/$name"

# Kontroller innholdet
fail=0
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -qE 'ELF|PE32|executable'; then echo "FEIL: binærfil i pakken: $f"; fail=1; fi
    if grep -qP '[\x{2012}-\x{2015}]' "$f"; then echo "FEIL: lang strek i $f"; fail=1; fi
done < <(find "$out/$name" -type f -print0)
for f in "$out/$name"/*.ps1 "$out/$name"/lang/*.psd1; do
    [ "$(head -c3 "$f" | xxd -p)" = "efbbbf" ] || { echo "FEIL: mangler UTF-8 BOM: $f"; fail=1; }
done
cmd="$out/$name/Start-Foreldrekontroll.cmd"
if LC_ALL=C grep -qP '[^\x00-\x7F]' "$cmd"; then echo "FEIL: .cmd er ikke ren ASCII"; fail=1; fi
if ! grep -q $'\r$' "$cmd"; then echo "FEIL: .cmd mangler CRLF"; fail=1; fi
grep -q "\$AppVersion  = '$ver'" "$out/$name/Setup-Foreldrekontroll.ps1" || { echo "FEIL: versjon stemmer ikke"; fail=1; }
[ "$fail" -eq 0 ] || exit 1

(cd "$out" && zip -qrX "$name.zip" "$name")
(cd "$out" && sha256sum "$name.zip" > "$name.zip.sha256")
echo "Laget $out/$name.zip (versjon $ver, commit $(git rev-parse --short HEAD))"
unzip -l "$out/$name.zip"
cat "$out/$name.zip.sha256"
