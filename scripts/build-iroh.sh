#!/bin/bash
# by zayd/cold @ zayd.wtf
#
# Builds iroh (the transport of Zone Link) from source, for the App Store.
#
# Why not the official prebuilt library: iroh-ffi 1.2.0 imports fifteen SystemConfiguration
# functions that the iOS SDK marks unavailable (SCDynamicStoreCreate, SCPreferencesCreate,
# SCNetworkInterfaceCopyAll and the rest). App Review rejects an app that imports them. They
# come from two crates, and each needs its own fix:
#
#   1. netdev 0.46.3 (interface names, DHCP hints and DNS servers on iOS). Fixed upstream by
#      netdev pull request 195 ("use only public APIs on iOS", merged 2026-10-25). This script
#      replaces netdev with the upstream merge commit of that pull request. That commit still
#      calls itself 0.46.3, so it satisfies netwatch 0.19.3 with no edit to netwatch or iroh.
#      (The released netdev 0.47.0 would need netwatch edited: net-tools pull request 263,
#      still open.)
#   2. n0-dns-resolver 0.1.0 (iroh's DNS resolver) reads the system's DNS servers through
#      SCDynamicStoreCreateWithOptions and SCDynamicStoreCopyValue on every Apple platform.
#      Nothing upstream fixes this yet (checked 2026-11-14: no issue, pull request or branch
#      in n0-computer/n0-dns-resolver, n0-computer/iroh or n0-computer/iroh-ffi). This script
#      applies scripts/iroh-patches/n0-dns-resolver-0.1.0-ios-public-api.patch to the crates.io
#      release: on iOS it reads the servers through libresolv (res_ninit, res_getservers),
#      which is public, the same way the netdev fix does. macOS is unchanged.
#
# Everything else is iroh-ffi at its v1.2.0 tag with its own Cargo.lock, so iroh stays 1.4.1,
# the version the computer side speaks. `--locked` refuses any other difference.
#
# Other differences from the official build script (make_swift.sh), on purpose:
#   - iOS deployment target 17.0 and macOS 14.0 (official: 17.5 and 14.5); Zone supports iOS 17.0
#   - no Mac Catalyst slice (Zone has no Catalyst build)
#   - headers go in Headers/Iroh/ (see scripts/fetch-iroh.sh for why)
#   - a pinned Rust toolchain (official: whatever "stable" was that day)
#
# The generated Swift binding must come out byte for byte the same as the official 1.2.0 one,
# and this script stops if it does not. The app must link libresolv (ZoneLink/Package.swift does).
#
# The result goes to a cache outside the checkout, shared by every checkout on this Mac:
#
#   ~/Library/Caches/zone-iroh/<key>/Iroh.xcframework
#   ~/Library/Caches/zone-iroh/<key>/IrohLib/IrohLib.swift
#   ~/Library/Caches/zone-iroh/<key>/BUILD-INFO.txt
#
# Usage:
#   scripts/build-iroh.sh               build into the cache (does nothing when it is there)
#   scripts/build-iroh.sh --force       build again even when it is there
#   scripts/build-iroh.sh --print-key   print the cache key and stop
#   scripts/build-iroh.sh --print-dir   print the cache folder and stop
#
# Environment: ZONE_IROH_CACHE (cache root), ZONE_IROH_WORK (build folder, kept when set).
# Needs rustup, Xcode and the network. About 2 GB of scratch space, removed afterwards.
set -euo pipefail

IROH_FFI_REPO="https://github.com/n0-computer/iroh-ffi"
IROH_FFI_TAG="v1.2.0"
IROH_FFI_REV="66a8d619a4d791d458d582f312df6e0ab42bc541"
# SHA-256 of iroh-ffi's Cargo.lock at that revision: proves every other crate is the release's.
IROH_FFI_LOCK_SHA256="a0afd6934b8597944f496c83e1381bb64e35b951593eb5ec883eef42668f8b79"
NETDEV_REPO="https://github.com/shellrow/netdev"
# The merge commit of shellrow/netdev pull request 195.
NETDEV_REV="d48084d915bae9e1b97ca4158f509e195523b606"
NETDEV_VERSION="0.46.3"
NETDEV_REGISTRY_CHECKSUM="c3c52c2584961c68f5a6e3356797344061f818c93b8acc9cd6d7e284795e563e"
# iroh's DNS resolver, from crates.io, and the patch applied to it.
DNS_CRATE="n0-dns-resolver"
DNS_VERSION="0.1.0"
DNS_CRATE_SHA256="535c99c9a786bee714155d2ee4fc2477405c2c43536e1bc6a51de09a0d1448f7"
DNS_PATCH_NAME="n0-dns-resolver-0.1.0-ios-public-api.patch"
DNS_PATCH_SHA256="f18c8d6bed7aa95b5cfe3c359e55f40de90095b2e022254dba2f2f9950175682"
# The official generated binding for iroh-ffi 1.2.0. This build must produce the same file.
SWIFT_BINDING_SHA256="63fbfbc1a1761165d192682ca0aff360abdfcad805449017a0c7f508754993ca"
RUST_TOOLCHAIN="1.97.1"
IOS_MIN="17.0"
MACOS_MIN="14.0"
# Bump when this script changes what it produces.
LAYOUT="4"

TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin)

KEY="iroh-ffi-${IROH_FFI_TAG#v}-${IROH_FFI_REV:0:10}_netdev-${NETDEV_REV:0:10}_dns-${DNS_PATCH_SHA256:0:10}_rust-${RUST_TOOLCHAIN}_ios-${IOS_MIN}_layout-${LAYOUT}"
CACHE_ROOT="${ZONE_IROH_CACHE:-$HOME/Library/Caches/zone-iroh}"
OUT="$CACHE_ROOT/$KEY"
HERE="$(cd "$(dirname "$0")" && pwd)"
DNS_PATCH="$HERE/iroh-patches/$DNS_PATCH_NAME"

say() { echo "build-iroh: $*"; }
fail() { echo "build-iroh: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# The only SystemConfiguration functions an iOS library may import: SCNetworkReachability*,
# which SCNetworkReachability.h declares for iOS 2.0 and later. Every other SC function in the
# iOS SDK headers (SCDynamicStore*, SCPreferences*, SCNetworkInterface*, SCNetworkService*,
# SCNetworkSet*, SCNetworkProtocol*, SCNetworkConnection* and the rest) is API_UNAVAILABLE(ios),
# and App Review rejects an app that imports one. Anything not on this list fails the build,
# so a new import from a future iroh is caught here, not in review.
ALLOWED='^_SCNetworkReachability[A-Za-z]*$'

# Every SystemConfiguration function a static library imports, one per line.
sc_imports() {
    { nm -u "$1" 2>/dev/null || true; } | awk '{print $NF}' | { grep -E '^_SC[A-Z]' || true; } | LC_ALL=C sort -u
}

FORCE=0
case "${1:-}" in
    --print-key) echo "$KEY"; exit 0 ;;
    --print-dir) echo "$OUT"; exit 0 ;;
    --force) FORCE=1 ;;
    "") ;;
    *) fail "unknown argument $1" ;;
esac

if [ "$FORCE" = 0 ] && [ -f "$OUT/.stamp" ] && [ "$(cat "$OUT/.stamp")" = "$KEY" ]; then
    say "already built: $OUT"
    exit 0
fi

command -v rustup >/dev/null 2>&1 || fail "rustup is not installed. Install it (https://rustup.rs or 'brew install rustup'), then run this again."
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is not available. Install Xcode."
command -v git >/dev/null 2>&1 || fail "git is not available."
[ -f "$DNS_PATCH" ] || fail "missing $DNS_PATCH"
[ "$(sha "$DNS_PATCH")" = "$DNS_PATCH_SHA256" ] || fail "$DNS_PATCH_NAME changed. Update DNS_PATCH_SHA256 in this script so the cache key follows it."

say "building iroh from source. This takes 10 to 20 minutes the first time on this Mac."
say "iroh-ffi $IROH_FFI_TAG ($IROH_FFI_REV), netdev $NETDEV_REV, $DNS_CRATE $DNS_VERSION patched, Rust $RUST_TOOLCHAIN"

if ! rustup toolchain list | grep -q "^${RUST_TOOLCHAIN}-"; then
    say "installing Rust $RUST_TOOLCHAIN"
    rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
fi
rustup target add --toolchain "$RUST_TOOLCHAIN" "${TARGETS[@]}" >/dev/null

if [ -n "${ZONE_IROH_WORK:-}" ]; then
    WORK="$ZONE_IROH_WORK"
    mkdir -p "$WORK"
else
    mkdir -p "$CACHE_ROOT"
    WORK="$(mktemp -d "$CACHE_ROOT/work.XXXXXX")"
    trap 'rm -rf "$WORK"' EXIT
fi
SRC="$WORK/iroh-ffi"

if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git init --quiet "$SRC"
    git -C "$SRC" remote add origin "$IROH_FFI_REPO"
fi
git -C "$SRC" fetch --quiet --depth 1 origin "$IROH_FFI_REV" || fail "could not fetch iroh-ffi $IROH_FFI_REV"
git -C "$SRC" checkout --quiet --force --detach FETCH_HEAD
git -C "$SRC" clean --quiet -fdx -e target
[ "$(git -C "$SRC" rev-parse HEAD)" = "$IROH_FFI_REV" ] || fail "iroh-ffi checkout is not $IROH_FFI_REV"
[ "$(sha "$SRC/Cargo.lock")" = "$IROH_FFI_LOCK_SHA256" ] || fail "iroh-ffi's Cargo.lock is not the pinned one"

# The DNS resolver: the crates.io release, checked, unpacked into a new folder, then patched.
DNS_DIR="$(mktemp -d "$WORK/dns.XXXXXX")"
curl -fL --retry 3 --silent --show-error -A "zone-build-iroh" -o "$DNS_DIR/$DNS_CRATE.crate" \
    "https://static.crates.io/crates/$DNS_CRATE/$DNS_CRATE-$DNS_VERSION.crate" || fail "could not download $DNS_CRATE $DNS_VERSION"
[ "$(sha "$DNS_DIR/$DNS_CRATE.crate")" = "$DNS_CRATE_SHA256" ] || fail "$DNS_CRATE $DNS_VERSION does not match its pinned SHA-256"
tar -xzf "$DNS_DIR/$DNS_CRATE.crate" -C "$DNS_DIR"
DNS_SRC="$DNS_DIR/$DNS_CRATE-$DNS_VERSION"
[ -f "$DNS_SRC/Cargo.toml" ] || fail "$DNS_CRATE did not unpack to $DNS_SRC"
patch -p1 --quiet -d "$DNS_SRC" < "$DNS_PATCH" || fail "$DNS_PATCH_NAME did not apply"

# Replace those two crates, and only those. Each lock entry changes from the registry copy to
# the replacement; --locked below then refuses any other difference.
cat >> "$SRC/Cargo.toml" <<EOF

[patch.crates-io]
netdev = { git = "$NETDEV_REPO", rev = "$NETDEV_REV" }
$DNS_CRATE = { path = "$DNS_SRC" }
EOF
NETDEV_REPO="$NETDEV_REPO" NETDEV_REV="$NETDEV_REV" NETDEV_VERSION="$NETDEV_VERSION" \
NETDEV_REGISTRY_CHECKSUM="$NETDEV_REGISTRY_CHECKSUM" DNS_CRATE="$DNS_CRATE" DNS_VERSION="$DNS_VERSION" \
DNS_CRATE_SHA256="$DNS_CRATE_SHA256" perl -0pi -e '
    my $registry = "source = \"registry+https://github.com/rust-lang/crates.io-index\"\n";
    my $from = "name = \"netdev\"\nversion = \"$ENV{NETDEV_VERSION}\"\n${registry}checksum = \"$ENV{NETDEV_REGISTRY_CHECKSUM}\"\n";
    my $to = "name = \"netdev\"\nversion = \"$ENV{NETDEV_VERSION}\"\nsource = \"git+$ENV{NETDEV_REPO}?rev=$ENV{NETDEV_REV}#$ENV{NETDEV_REV}\"\n";
    my $n = (s/\Q$from\E/$to/);
    die "netdev $ENV{NETDEV_VERSION} from the registry is not in Cargo.lock\n" unless $n == 1;
    # A crate replaced by a folder has no source and no checksum in the lock.
    $from = "name = \"$ENV{DNS_CRATE}\"\nversion = \"$ENV{DNS_VERSION}\"\n${registry}checksum = \"$ENV{DNS_CRATE_SHA256}\"\n";
    $to = "name = \"$ENV{DNS_CRATE}\"\nversion = \"$ENV{DNS_VERSION}\"\n";
    $n = (s/\Q$from\E/$to/);
    die "$ENV{DNS_CRATE} $ENV{DNS_VERSION} from the registry is not in Cargo.lock\n" unless $n == 1;
' "$SRC/Cargo.lock"

cd "$SRC"
CARGO=(cargo "+$RUST_TOOLCHAIN")

# The same path normalization as the official script, so the libraries do not embed this Mac's
# paths. The resolver's folder has a random name, so it gets a fixed one (a later rule wins).
CARGO_PFX="${CARGO_HOME:-$HOME/.cargo}"
RUSTUP_PFX="${RUSTUP_HOME:-$HOME/.rustup}"
REPO_PFX="$(pwd -P)"
DNS_PFX="$(cd "$DNS_DIR" && pwd -P)"
export RUSTFLAGS="--remap-path-prefix=${CARGO_PFX}/registry=/cargo/registry --remap-path-prefix=${CARGO_PFX}/git=/cargo/git --remap-path-prefix=${RUSTUP_PFX}=/rustup --remap-path-prefix=${REPO_PFX}=/build --remap-path-prefix=${DNS_PFX}=/build-dns"
export CFLAGS="-ffile-prefix-map=${CARGO_PFX}/registry=/cargo/registry -ffile-prefix-map=${CARGO_PFX}/git=/cargo/git -ffile-prefix-map=${REPO_PFX}=/build"
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
export CARGO_TARGET_DIR="$SRC/target"
unset CARGO_BUILD_TARGET CARGO_ENCODED_RUSTFLAGS SDKROOT || true

say "host library, for the binding generator"
"${CARGO[@]}" build --locked --lib -p iroh-ffi
for target in "${TARGETS[@]}"; do
    say "release library for $target"
    "${CARGO[@]}" build --locked --release --lib -p iroh-ffi --target "$target"
done

LIB="libiroh_ffi"
T="$CARGO_TARGET_DIR"
STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/bindgen" "$STAGE/headers" "$STAGE/sim" "$STAGE/out/IrohLib"

say "generating the Swift binding"
"${CARGO[@]}" run --locked --bin uniffi-bindgen -- generate --language swift \
    --out-dir "$STAGE/bindgen" --library "$T/debug/$LIB.dylib" --config uniffi.toml

cp "$STAGE/bindgen/iroh_ffiFFI.h" "$STAGE/headers/iroh_ffiFFI.h"
echo '#include "iroh_ffiFFI.h"' > "$STAGE/headers/Export.h"
cat > "$STAGE/headers/module.modulemap" <<EOF
module Iroh {
    umbrella header "Export.h"
    export *
    module * { export * }
}
EOF

lipo -create "$T/aarch64-apple-ios-sim/release/$LIB.a" "$T/x86_64-apple-ios/release/$LIB.a" -output "$STAGE/sim/$LIB.a"

# The whole point: stop here if a phone or simulator library still imports what App Review rejects.
for built in "$T/aarch64-apple-ios/release/$LIB.a" "$STAGE/sim/$LIB.a"; do
    found="$(sc_imports "$built" | { grep -v -E "$ALLOWED" || true; })"
    if [ -n "$found" ]; then
        echo "$found" >&2
        fail "$built still imports SystemConfiguration functions that are unavailable on iOS"
    fi
done

xcodebuild -create-xcframework \
    -library "$T/aarch64-apple-ios/release/$LIB.a" -headers "$STAGE/headers" \
    -library "$STAGE/sim/$LIB.a" -headers "$STAGE/headers" \
    -library "$T/aarch64-apple-darwin/release/$LIB.a" -headers "$STAGE/headers" \
    -output "$STAGE/out/Iroh.xcframework" >/dev/null

# Headers/ becomes Headers/Iroh/ in every slice (scripts/fetch-iroh.sh explains why).
for slice in "$STAGE/out/Iroh.xcframework"/*/; do
    [ -d "$slice/Headers" ] || continue
    mkdir "$slice/Headers-nested"
    mv "$slice/Headers" "$slice/Headers-nested/Iroh"
    mv "$slice/Headers-nested" "$slice/Headers"
    [ -f "$slice/Headers/Iroh/module.modulemap" ] || fail "no module map in $slice"
done

# uniffi names the C module iroh_ffiFFI; the module map above names it Iroh.
sed "s/iroh_ffiFFI/Iroh/g" "$STAGE/bindgen/iroh_ffi.swift" > "$STAGE/out/IrohLib/IrohLib.swift"
[ "$(sha "$STAGE/out/IrohLib/IrohLib.swift")" = "$SWIFT_BINDING_SHA256" ] \
    || fail "the generated Swift binding differs from the official iroh-ffi $IROH_FFI_TAG one: the library's interface changed"

{
    echo "Built by scripts/build-iroh.sh for Zone Link."
    echo "key: $KEY"
    echo "iroh-ffi: $IROH_FFI_REPO $IROH_FFI_TAG $IROH_FFI_REV"
    echo "netdev: $NETDEV_REPO $NETDEV_REV (replaces $NETDEV_VERSION from crates.io)"
    echo "$DNS_CRATE: $DNS_VERSION from crates.io ($DNS_CRATE_SHA256) with $DNS_PATCH_NAME ($DNS_PATCH_SHA256)"
    imports="$(sc_imports "$T/aarch64-apple-ios/release/$LIB.a" | paste -sd' ' -)"
    echo "SystemConfiguration imports, iOS library: ${imports:-none}"
    imports="$(sc_imports "$STAGE/sim/$LIB.a" | paste -sd' ' -)"
    echo "SystemConfiguration imports, simulator library: ${imports:-none}"
    echo "crates: $(grep -A1 -E '^name = "(iroh|iroh-base|iroh-relay|netwatch|portmapper|noq|noq-proto)"$' Cargo.lock | grep -v '^--' | paste -d' ' - - | sed -e 's/name = //' -e 's/version = //' -e 's/"//g' | paste -sd, - | sed 's/,/, /g')"
    echo "rust: $("${CARGO[@]}" --version), $(rustc "+$RUST_TOOLCHAIN" --version)"
    echo "xcode: $(xcodebuild -version | paste -sd' ' -)"
    echo "deployment targets: iOS $IOS_MIN, macOS $MACOS_MIN"
    echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "sha256:"
    (cd "$STAGE/out" && find Iroh.xcframework IrohLib -type f | LC_ALL=C sort | while read -r f; do echo "  $(sha "$f")  $f"; done)
} > "$STAGE/out/BUILD-INFO.txt"
echo "$KEY" > "$STAGE/out/.stamp"

mkdir -p "$CACHE_ROOT"
rm -rf "$OUT"
mv "$STAGE/out" "$OUT"
say "done: $OUT"
