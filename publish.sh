#!/usr/bin/env bash
# Molly4Watch F-Droid repo publisher.
#   ./publish.sh [--dry-run] [new.apk ...]
# 1. Copies any new APKs into repo/.
# 2. Prunes: keeps only the newest $KEEP versions (by versionCode) of each package.
# 3. Rebuilds and signs the F-Droid index.
# 4. Publishes as ONE fresh commit (orphan branch, force-push), so git history never accumulates
#    old APKs and the GitHub Pages site stays small (~2 versions).
# Secrets (keystore.p12, config.yml) are git-ignored and never published.
set -euo pipefail
cd "$(dirname "$0")"

KEEP=${KEEP:-2}
DRY=0
if [[ ${1:-} == --dry-run ]]; then DRY=1; shift; fi

. "$HOME/.android-env.sh"
FDROID=$HOME/.local/opt/fdroidserver/bin/fdroid
AAPT2=$ANDROID_HOME/build-tools/36.0.0/aapt2

for apk in "$@"; do
  [[ -f $apk ]] || { echo "missing: $apk" >&2; exit 1; }
  echo "add   $(basename "$apk")"
  ((DRY)) || cp "$apk" repo/
done

# Prune: group APKs by package, sort by versionCode (newest first), drop all but $KEEP.
declare -A seen=()
while read -r vc pkg file; do
  seen[$pkg]=$(( ${seen[$pkg]:-0} + 1 ))
  if (( seen[$pkg] > KEEP )); then
    echo "prune $file ($pkg vc $vc)"
    ((DRY)) || rm -f "repo/$file"
  else
    echo "keep  $file ($pkg vc $vc)"
  fi
done < <(
  for f in repo/*.apk; do
    [[ -e $f ]] || continue
    line=$("$AAPT2" dump badging "$f" | sed -n 1p)
    pkg=$(sed -E "s/^package: name='([^']+)'.*/\1/" <<<"$line")
    vc=$(sed -E "s/.*versionCode='([0-9]+)'.*/\1/" <<<"$line")
    echo "$vc $pkg $(basename "$f")"
  done | sort -k2,2 -k1,1nr
)

if ((DRY)); then echo "dry run: nothing changed"; exit 0; fi

# Old archive/ copies would defeat the purpose.
rm -rf archive
"$FDROID" update --pretty >/dev/null
"$FDROID" signindex >/dev/null
echo "index rebuilt and signed"

# Publish a single-commit snapshot.
git checkout -q --orphan publish-tmp
git add -A
git commit -q -m "Molly4Watch F-Droid repo ($(date -u +%Y-%m-%d))"
git branch -D main -q 2>/dev/null || true
git branch -m main
git push -q --force origin main
git gc -q --prune=now
echo "published: $(git ls-files repo | grep -c '\.apk$') APK(s), site size $(du -sh --exclude=.git . | cut -f1)"
