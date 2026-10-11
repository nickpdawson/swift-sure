#!/bin/bash
# Sure (ShiftHuman) TestFlight build: archive, export, verify, upload. Runs on chamonix.
# Modelled on TurnPro's release runner: refuses on the wrong toolchain, a dirty or wrong
# source tree, a concurrent xcodebuild, or a booted simulator. Evidence lands in
# /private/tmp/sure-release-<build>/run.log. The ASC key is referenced by path only.
#
#   BUILD=<n>        build number (default: UTC yyyymmddHHMM)
#   EXPECT_SHA=<sha> refuse unless HEAD matches
#   UPLOAD=0         archive + export + verify, no upload
#   FINANCEKIT=1     expect the financekit entitlement in the signed app
set -euo pipefail
export LC_ALL=C
refuse() { echo "REFUSING: $*" >&2; exit 1; }

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
EXPECT_XCODE_BUILD=${EXPECT_XCODE_BUILD:-27A266a}
TEAM_ID=3ELWNV29J2
KEY_ID=3LGR8HYV5P
ISSUER_ID=69a6de7c-da83-47e3-e053-5b8c7c11a4d1
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
BUNDLE_ID=com.shifthuman.sure
XCODEGEN=${XCODEGEN:-$HOME/bin/xcodegen}
SRC=$(python3 -c 'import os,sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$0")
BUILD=${BUILD:-$(date -u +%Y%m%d%H%M)}
EXPECT_SHA=${EXPECT_SHA:-}
UPLOAD=${UPLOAD:-1}
FINANCEKIT=${FINANCEKIT:-0}
EV=/private/tmp/sure-release-$BUILD
DD=$EV/DerivedData
ARCHIVE=$EV/Sure-$BUILD.xcarchive
EXPORT=$EV/export
LOG=$EV/run.log

[ -d "$DEVELOPER_DIR" ] || refuse "no $DEVELOPER_DIR"
[ -f "$KEY_PATH" ] || refuse "no ASC key at $KEY_PATH"
[ -x "$XCODEGEN" ] || refuse "no xcodegen at $XCODEGEN"
[ -e "$EV" ] && refuse "$EV exists; move it aside"
mkdir -p "$EV"
echo "log: $LOG"

AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID")

{
echo "START $(date -u +%FT%TZ) build=$BUILD"
TV=$(xcodebuild -version); echo "$TV"
echo "$TV" | grep -q "Build version $EXPECT_XCODE_BUILD" || refuse "expected Xcode build $EXPECT_XCODE_BUILD"
HEAD_SHA=$(git -C "$SRC" rev-parse HEAD); echo "source HEAD: $HEAD_SHA"
if [ -n "$EXPECT_SHA" ] && [ "$HEAD_SHA" != "$EXPECT_SHA" ]; then refuse "HEAD $HEAD_SHA, expected $EXPECT_SHA"; fi
DIRTY=$(git -C "$SRC" status --porcelain); [ -z "$DIRTY" ] || { echo "$DIRTY"; refuse "working tree not clean"; }
if pgrep -x xcodebuild >/dev/null; then refuse "another xcodebuild is active"; fi
if xcrun simctl list devices booted | grep -q "(Booted)"; then refuse "a simulator is booted"; fi
MV=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["targets"]["Sure"]["settings"]["base"]["MARKETING_VERSION"])' "$SRC/Project.json")
echo "marketing version: $MV  build: $BUILD"

echo "--- xcodegen ---"
"$XCODEGEN" generate --spec "$SRC/Project.json" --project "$SRC" --quiet
[ -d "$SRC/Sure.xcodeproj" ] || refuse "xcodegen produced no project"

echo "--- archive ---"
if taskpolicy -b nice -n 10 xcodebuild -project "$SRC/Sure.xcodeproj" -scheme Sure -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD" -archivePath "$ARCHIVE" \
    "${AUTH[@]}" DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD" archive; then
  echo ARCHIVE_EXIT=0
else refuse "archive failed"; fi

cat > "$EV/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

echo "--- export ---"
if taskpolicy -b nice -n 10 xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EV/ExportOptions.plist" -exportPath "$EXPORT" "${AUTH[@]}"; then
  echo EXPORT_EXIT=0
else refuse "export failed"; fi
shopt -s nullglob; IPAS=("$EXPORT"/*.ipa); [ "${#IPAS[@]}" -eq 1 ] || refuse "expected one IPA"
IPA=${IPAS[0]}; echo "ipa: $IPA ($(stat -f%z "$IPA") bytes) sha256 $(shasum -a 256 "$IPA" | cut -d' ' -f1)"

echo "--- verify ---"
WORK="$EV/verify"; mkdir -p "$WORK"; unzip -qo "$IPA" -d "$WORK"
APP="$WORK/Payload/Sure.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2> "$EV/ipa-signature.txt"
grep -Fx "TeamIdentifier=$TEAM_ID" "$EV/ipa-signature.txt"
grep -F 'Authority=Apple Distribution:' "$EV/ipa-signature.txt"
codesign -d --entitlements - --xml "$APP" > "$EV/ipa-entitlements.plist"
security cms -D -i "$APP/embedded.mobileprovision" > "$EV/ipa-profile.plist"
python3 - "$APP/Info.plist" "$EV/ipa-entitlements.plist" "$EV/ipa-profile.plist" "$BUNDLE_ID" "$TEAM_ID" "$MV" "$BUILD" "$FINANCEKIT" <<'VERIFY'
import datetime, plistlib, sys
info, ent, profile = [plistlib.load(open(p, 'rb')) for p in sys.argv[1:4]]
bundle, team, mv, build, fk = sys.argv[4:9]
def need(ok, why):
    if not ok: raise SystemExit('REFUSING: ' + why)
for k, v in {'CFBundleIdentifier': bundle, 'CFBundleShortVersionString': mv, 'CFBundleVersion': build,
             'MinimumOSVersion': '18.0', 'CFBundleExecutable': 'Sure'}.items():
    need(info.get(k) == v, f'Info.plist {k}={info.get(k)!r}, expected {v!r}')
need(info.get('ITSAppUsesNonExemptEncryption') is False, 'ITSAppUsesNonExemptEncryption missing')
need(profile.get('TeamIdentifier') == [team], 'profile team mismatch')
need(profile.get('ExpirationDate', datetime.datetime.min) > datetime.datetime.utcnow(), 'expired profile')
need(not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices', False), 'not an App Store profile')
for k, v in {'application-identifier': team + '.' + bundle, 'com.apple.developer.team-identifier': team,
             'get-task-allow': False, 'beta-reports-active': True, 'aps-environment': 'production'}.items():
    need(ent.get(k) == v, f'signed entitlement {k}={ent.get(k)!r}, expected {v!r}')
has_fk = 'com.apple.developer.financekit' in ent
need(has_fk == (fk == '1'), f'financekit entitlement present={has_fk}, FINANCEKIT={fk}')
print(f"Artifact PASS: {bundle} {mv} ({build}); profile '{profile.get('Name')}' {profile.get('UUID')}; "
      f"app groups {ent.get('com.apple.security.application-groups')}; financekit={has_fk}")
VERIFY
dwarfdump --uuid "$APP/Sure" > "$EV/ipa-uuids.txt"
dwarfdump --uuid "$ARCHIVE/dSYMs/Sure.app.dSYM" > "$EV/dsym-uuids.txt"
python3 - "$EV/ipa-uuids.txt" "$EV/dsym-uuids.txt" <<'UUIDS'
import re, sys
def uuids(p):
    r = set(re.findall(r'^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', open(p).read(), re.M))
    if not r: raise SystemExit('REFUSING: no UUIDs in ' + p)
    return r
a, b = uuids(sys.argv[1]), uuids(sys.argv[2])
if a != b: raise SystemExit('REFUSING: IPA/dSYM UUID mismatch')
print('IPA/dSYM UUID parity PASS: ' + str(sorted(a)))
UUIDS

if [ "$UPLOAD" = "1" ]; then
  echo "--- upload ---"
  sed 's|<string>export</string>|<string>upload</string>|' "$EV/ExportOptions.plist" > "$EV/ExportOptions-upload.plist"
  if taskpolicy -b nice -n 10 xcodebuild -exportArchive -archivePath "$ARCHIVE" \
      -exportOptionsPlist "$EV/ExportOptions-upload.plist" -exportPath "$EV/upload" "${AUTH[@]}"; then
    echo UPLOAD_EXIT=0
  else refuse "upload failed"; fi
else
  echo "UPLOAD skipped (UPLOAD=$UPLOAD)"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$HEAD_SHA" ] || refuse "source HEAD moved during build"
rm -rf "$DD"
echo "DONE $(date -u +%FT%TZ) build=$BUILD"
} 2>&1 | tee "$LOG"
