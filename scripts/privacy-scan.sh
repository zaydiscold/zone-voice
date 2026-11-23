#!/bin/zsh
# Lists the required-reason API categories each built binary references, so they can be
# checked against Zone/PrivacyInfo.xcprivacy and ZoneKeyboard/PrivacyInfo.xcprivacy before an
# App Store upload (missing categories are refused at upload, ITMS-91053).
#
# usage: scripts/privacy-scan.sh <path to Zone.app>
# Build first, for example a Release device build without signing:
#   xcodebuild -project Zone.xcodeproj -scheme Zone -configuration Release \
#     -destination 'generic/platform=iOS' -derivedDataPath /tmp/zone-dd CODE_SIGNING_ALLOWED=NO build
#   scripts/privacy-scan.sh /tmp/zone-dd/Build/Products/Release-iphoneos/Zone.app
#
# The five categories are Apple's NSPrivacyAccessedAPIType values (checked 2026-10-30). A hit
# marked (sym) is an imported C or Foundation symbol; (str) is an Objective-C selector or
# constant name in the binary's strings. A hit says the category is used, not which reason
# applies: read the call sites to pick the reason code.
set -u
app="${1:?usage: privacy-scan.sh <Zone.app>}"

scan() {
  local bin="$1"
  local syms strs
  syms=$(nm -u "$bin" 2>/dev/null | sed 's/^_//' | sort -u)
  strs=$(strings -a "$bin" 2>/dev/null | sort -u)
  hit() {
    local cat="$1"; shift
    local found=""
    for s in "$@"; do
      print -r -- "$syms" | grep -qx -- "$s" && found="$found $s(sym)"
      print -r -- "$strs" | grep -qx -- "$s" && found="$found $s(str)"
    done
    [ -n "$found" ] && echo "  $cat:$found"
  }
  hit FileTimestamp stat fstat fstatat lstat getattrlist getattrlistbulk fgetattrlist getattrlistat \
    creationDate modificationDate fileModificationDate contentModificationDateKey creationDateKey \
    NSFileCreationDate NSFileModificationDate NSURLContentModificationDateKey NSURLCreationDateKey
  hit SystemBootTime systemUptime mach_absolute_time
  hit DiskSpace statfs statvfs fstatfs fstatvfs volumeAvailableCapacityKey \
    volumeAvailableCapacityForImportantUsageKey volumeAvailableCapacityForOpportunisticUsageKey \
    volumeTotalCapacityKey systemFreeSize systemSize NSFileSystemFreeSize NSFileSystemSize \
    NSURLVolumeAvailableCapacityKey NSURLVolumeAvailableCapacityForImportantUsageKey \
    NSURLVolumeAvailableCapacityForOpportunisticUsageKey NSURLVolumeTotalCapacityKey
  hit ActiveKeyboards activeInputModes
  hit UserDefaults NSUserDefaults standardUserDefaults
}

# Every Mach-O executable in the bundle: the app, extensions, embedded frameworks and dylibs.
find "$app" -type f \( -perm -u+x -o -name "*.dylib" \) | while read -r f; do
  file "$f" | grep -q "Mach-O" || continue
  echo "${f#$app/}"
  scan "$f"
  dir=$(dirname "$f")
  [ -f "$dir/PrivacyInfo.xcprivacy" ] && echo "  manifest: ${dir#$app}/PrivacyInfo.xcprivacy" \
    || echo "  manifest: none next to this binary"
done
