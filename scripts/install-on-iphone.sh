#!/bin/zsh
# by zayd/cold @ zayd.wtf
#
# Builds Zone under your own Apple ID and installs it on the iPhone connected to this Mac.
#
#   scripts/install-on-iphone.sh            # first run writes Config/Local.xcconfig for you
#   scripts/install-on-iphone.sh <device>   # a device name or identifier from `xcrun devicectl list devices`
#   scripts/install-on-iphone.sh --check    # only check the Mac, the team and the phone; build nothing
#
# Needs: Xcode 26 signed in to an Apple ID (Xcode > Settings > Accounts; a free one works), XcodeGen
# (`brew install xcodegen`), and the iPhone unlocked, trusted and in Developer Mode.
# A free Apple ID's install stops opening after 7 days; run this again to renew it.

set -euo pipefail
cd "$(dirname "$0")/.."

check_only=false
if [[ ${1:-} == --check ]]; then check_only=true; shift; fi

say() { print -P "%B==>%b $*"; }
fail() { print -P "%F{red}error:%f $*" >&2; exit 1; }

command -v xcodebuild >/dev/null || fail "Xcode is not installed."
command -v xcodegen >/dev/null || fail "XcodeGen is missing: brew install xcodegen"

# 1. Who signs. Config/Local.xcconfig wins; otherwise the first team Xcode knows, then the team in
#    the Apple Development certificate (its OU; the code in parentheses is the certificate's, not the team's).
local_config=Config/Local.xcconfig
if [[ ! -f $local_config ]]; then
    team=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
        | awk -F' = ' '/teamID/ { gsub(/[ ;"]/, "", $2); print $2; exit }') || true
    if [[ -z ${team:-} ]]; then
        team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p') || true
    fi
    [[ -n ${team:-} ]] || fail "No Apple team found. Open Xcode > Settings > Accounts, add your Apple ID, then run this again."
    default_team=$(sed -n 's/^DEVELOPMENT_TEAM = //p' Config/Signing.xcconfig)
fi
if [[ ! -f $local_config && ${team:-} == "${default_team:-}" ]]; then
    say "Team $team is the project's own; using Config/Signing.xcconfig"
elif $check_only && [[ ! -f $local_config ]]; then
    say "Would write $local_config: team $team, bundle IDs dev.${(L)team}.zone*"
elif [[ ! -f $local_config ]]; then
    # Bundle IDs are global, so the default prefix carries the team ID to stay unique.
    prefix="dev.${(L)team}"
    print "// Written by scripts/install-on-iphone.sh. Edit freely; git ignores this file.\nDEVELOPMENT_TEAM = $team\nZONE_BUNDLE_PREFIX = $prefix" > $local_config
    say "Wrote $local_config (team $team, bundle IDs $prefix.zone*)"
else
    say "Using $local_config"
fi

# 2. Which iPhone.
json=$(mktemp)
xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || fail "devicectl could not list devices."
read -r device_udid device_name dev_mode <<<"$(python3 -I - "$json" "${1:-}" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
wanted = sys.argv[2]
for d in devices:
    hw, props = d["hardwareProperties"], d["deviceProperties"]
    if hw.get("platform") != "iOS":
        continue
    names = {d["identifier"], hw.get("udid"), props.get("name")}
    if wanted and wanted not in names:
        continue
    print(hw.get("udid"), props.get("name", "iPhone").replace(" ", "_"), props.get("developerModeStatus", "unknown"))
    break
PY
)"
rm -f "$json"
[[ -n ${device_udid:-} ]] || fail "No iPhone found. Connect it with a cable, unlock it and tap Trust."
[[ $dev_mode == enabled ]] || fail "Developer Mode is off on $device_name: Settings > Privacy & Security > Developer Mode, then restart the phone."
if $check_only; then
    say "Ready: $device_name ($device_udid), Developer Mode on. Run without --check to build and install."
    exit 0
fi
say "Installing on $device_name ($device_udid)"

# 3. Build and install.
xcodegen generate --quiet
derived=build/device
mkdir -p build
# A unique default prevents different source builds all masquerading as build 1.
build_version=${ZONE_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
say "Source $(git rev-parse --short HEAD), build $build_version, workspace $PWD"
xcodebuild -project Zone.xcodeproj -scheme Zone -configuration Release \
    -destination "id=$device_udid" -derivedDataPath $derived CURRENT_PROJECT_VERSION="$build_version" -allowProvisioningUpdates build \
    | tee build/device-build.log
# set -e + pipefail above must stop here if xcodebuild fails. An older .app is not proof of success.
app=$derived/Build/Products/Release-iphoneos/Zone.app
[[ -d $app ]] || fail "The app bundle is missing; inspect build/device-build.log."

# The app and the keyboard must share one App Group, or every dictation fails in the app.
groups=$(for b in $app $app/PlugIns/ZoneKeyboard.appex; do
    codesign -d --entitlements - --xml $b 2>/dev/null | plutil -extract com\\.apple\\.security\\.application-groups.0 raw - 2>/dev/null
done | sort -u)
[[ $(print -l $groups | wc -l | tr -d ' ') == 1 && -n $groups ]] || fail "The app and the keyboard were signed with different App Groups: $groups"
say "Signed with App Group $groups"

xcrun devicectl device install app --device $device_udid $app >/dev/null || fail "Install failed. Is the phone unlocked?"

cat <<'DONE'

Installed. On the iPhone:
  1. First time on a free Apple ID: Settings > General > VPN & Device Management > your Apple ID > Trust.
  2. Open Zone and follow setup (speech model, microphone, keyboard).
  3. Settings > Apps > Zone > Keyboards: turn on Zone and Allow Full Access.

by zayd/cold @ zayd.wtf
DONE
