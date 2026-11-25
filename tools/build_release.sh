#!/usr/bin/env bash
# Builds the sideload IPA on GitHub's macOS runners and publishes it.
# Usage (from the master worktree): tools/build_release.sh <version> <notes file>
# - dispatches extra builds on other runner kinds (macOS capacity varies), takes the first that succeeds,
#   cancels the rest;
# - puts the IPA in H:\VLCcustom-iOS as VlcCustomIOS-v<version>.ipa (removing the previous VlcCustomIOS-v*.ipa);
# - creates the GitHub release v<version>, or replaces its IPA when it already exists.
set -u
VER="$1"
NOTES="$2"
REPO=vanhau1303-hub/vlccustom-ios
DROP=/h/VLCcustom-iOS
SHA=${SHA:-$(git rev-parse HEAD)}
WORK=$(mktemp -d)

if [ -z "${SKIP_DISPATCH:-}" ]; then
  gh workflow run build-ipa.yml -R $REPO -f runner=macos-15-intel >/dev/null
  gh workflow run build-ipa.yml -R $REPO -f runner=macos-14 >/dev/null
  sleep 20
fi

IDS=""
for i in $(seq 1 30); do
  IDS=$(gh run list -R $REPO --workflow build-ipa.yml -L 10 --json databaseId,headSha -q ".[] | select(.headSha==\"$SHA\") | .databaseId" | tr '\n' ' ')
  [ "$(echo $IDS | wc -w)" -ge 3 ] && break
  sleep 10
done
echo "builds: $IDS"

WIN=""
while [ -z "$WIN" ]; do
  sleep 30
  ALLDONE=1
  for id in $IDS; do
    read -r status conclusion < <(gh run view $id -R $REPO --json status,conclusion -q '.status + " " + .conclusion')
    if [ "$status" = "completed" ] && [ "$conclusion" = "success" ]; then WIN=$id; break; fi
    [ "$status" != "completed" ] && ALLDONE=0
  done
  if [ -z "$WIN" ] && [ $ALLDONE = 1 ]; then
    for id in $IDS; do
      if [ "$(gh run view $id -R $REPO --json conclusion -q .conclusion)" = "failure" ]; then
        echo "FAILED $id"
        gh run view $id -R $REPO --log-failed | grep -E "error:|\*\* BUILD FAILED" | head -20
        exit 1
      fi
    done
    echo "NO SUCCESS"; exit 1
  fi
done
echo "WIN $WIN"
for id in $IDS; do [ "$id" != "$WIN" ] && gh run cancel $id -R $REPO >/dev/null 2>&1; done

gh run download $WIN -R $REPO -n VlcCustomIOS-unsigned-ipa -D "$WORK" || exit 1
rm -f $DROP/VlcCustomIOS-v*.ipa
cp "$WORK/VlcCustomIOS.ipa" "$DROP/VlcCustomIOS-v$VER.ipa"
ls -l "$DROP/VlcCustomIOS-v$VER.ipa"
for i in 1 2 3 4 5; do
  if gh release view "v$VER" -R $REPO >/dev/null 2>&1; then
    gh release upload "v$VER" "$DROP/VlcCustomIOS-v$VER.ipa" -R $REPO --clobber && break
  else
    gh release create "v$VER" "$DROP/VlcCustomIOS-v$VER.ipa" -R $REPO --target "$SHA" -t "v$VER" -F "$NOTES" && break
  fi
  sleep 10
done
rm -rf "$WORK"
gh release view "v$VER" -R $REPO --json url,assets -q '.url, .assets[].name' && echo RELEASED
