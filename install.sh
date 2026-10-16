#!/usr/bin/env bash
# Installs Kode on macOS (Apple Silicon).
#
# It checks the machine and the release first (preflight), downloads the DMG,
# shows the file's SHA-256 fingerprint next to the digest GitHub lists for it,
# asks before it installs, copies Kode.app into place, and clears macOS's
# quarantine flag so the first launch is not blocked.
#
#   curl -fsSL https://raw.githubusercontent.com/0x01001011/kode/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --check
#   curl -fsSL .../install.sh | bash -s -- --version v0.14.0 --yes
#
# Kode is ad-hoc signed, not notarized: the fingerprint check is the integrity
# check, and the quarantine step is what stands in for notarization.
set -euo pipefail

REPO="0x01001011/kode"
BUNDLE_ID="com.kode.desktop"
DEFAULT_DEST="/Applications"
DEST="$DEFAULT_DEST"
DEST_GIVEN=0
VERSION=""
ASSUME_YES=0
OPEN_AFTER=1
CHECK_ONLY=0
FORCE=0
MIN_MACOS=12

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --check           Run the preflight checks and stop. Nothing is downloaded.
  --version <tag>   Install this release, e.g. v0.14.0 (default: the latest)
  --dir <path>      Install into this folder (default: /Applications, or
                    ~/Applications when /Applications is not writable)
  --force           Reinstall even when this version is already installed
  -y, --yes         Do not ask before installing
  --no-open         Do not offer to open Kode afterwards
  -h, --help        Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --version) [ $# -ge 2 ] || die "--version needs a tag"; VERSION="$2"; shift 2 ;;
    --dir) [ $# -ge 2 ] || die "--dir needs a path"; DEST="$2"; DEST_GIVEN=1; shift 2 ;;
    --force) FORCE=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --no-open) OPEN_AFTER=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

# --- helpers ----------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kode-install.XXXXXX")" \
  || die "cannot create a temporary folder in ${TMPDIR:-/tmp}"
MOUNT="$WORK/mount"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = 1 ]; then hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Asks a yes/no question on the terminal, which is still available when the
# script itself arrives on stdin through a pipe.
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local reply=""
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    die "no terminal to ask on. Run it again with --yes to install without asking."
  fi
  printf '%s [y/N] ' "$1" >&2
  read -r reply <&3 || true
  exec 3<&-
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

FAILED=0
ok() { printf '  \342\234\223 %s\n' "$*"; }
bad() { printf '  \342\234\227 %s\n' "$*"; FAILED=1; }
meh() { printf '  ! %s\n' "$*"; }

# 1 when $1 is newer than $2, -1 when older, 0 when equal. Compares the numeric
# part of a dotted version only.
compare_versions() {
  awk -v a="${1%%-*}" -v b="${2%%-*}" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= (n > m ? n : m); i++) {
      if ((x[i] + 0) > (y[i] + 0)) { print 1; exit }
      if ((x[i] + 0) < (y[i] + 0)) { print -1; exit }
    }
    print 0
  }'
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# Free megabytes on the volume that holds $1, or its nearest existing parent.
free_mb() {
  local dir="$1"
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do dir="$(dirname "$dir")"; done
  df -Pk "$dir" | awk 'NR == 2 { printf "%d", $4 / 1024 }'
}

json() { plutil -extract "$1" raw -o - "$META" 2>/dev/null; }

# --- preflight --------------------------------------------------------------

say "Preflight"

# This Mac.
if [ "$(uname -s)" != "Darwin" ]; then
  bad "Kode releases are macOS only. Build from source on other systems."
  die "preflight failed"
fi
MACOS="$(sw_vers -productVersion 2>/dev/null || echo 0)"
if [ "${MACOS%%.*}" -ge "$MIN_MACOS" ] 2>/dev/null; then
  ok "macOS $MACOS"
else
  bad "macOS $MACOS is too old; this installer needs macOS $MIN_MACOS or later"
fi
# A shell running under Rosetta reports x86_64 on an Apple Silicon Mac.
if [ "$(uname -m)" = "arm64" ]; then
  ok "Apple Silicon"
elif [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
  ok "Apple Silicon (this shell runs under Rosetta; the arm64 app is still right)"
else
  bad "Kode releases are Apple Silicon only. Build from source on Intel Macs."
fi
MISSING=""
for tool in curl hdiutil shasum plutil ditto codesign xattr stat df awk; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -z "$MISSING" ]; then ok "Tools present"; else bad "Missing tools:$MISSING"; fi

# GitHub and the release.
if [ "$FAILED" = 1 ]; then echo; die "preflight failed. Nothing was downloaded or installed."; fi
API="https://api.github.com/repos/$REPO/releases"
if [ -n "$VERSION" ]; then API="$API/tags/$VERSION"; else API="$API/latest"; fi
META="$WORK/release.json"
HTTP="$(curl -sS --connect-timeout 10 --max-time 30 -H "Accept: application/vnd.github+json" \
  -o "$META" -w '%{http_code}' "$API" 2>"$WORK/curl.err" || true)"
case "$HTTP" in
  200) ok "Reached GitHub" ;;
  403|429) bad "GitHub is rate limiting this network. Try again later." ;;
  404) bad "No such release${VERSION:+ ($VERSION)}. See https://github.com/$REPO/releases" ;;
  000|"") bad "Cannot reach GitHub: $(head -n 1 "$WORK/curl.err" 2>/dev/null || echo 'no response'). Check your network or proxy." ;;
  *) bad "GitHub answered HTTP $HTTP for $API" ;;
esac

TAG="" NUMBER="" ASSET="" URL="" DIGEST="" ASSET_SIZE=0
if [ "$HTTP" = "200" ]; then
  TAG="$(json tag_name || true)"
  NUMBER="${TAG#v}"
  ASSET="Kode_${NUMBER}_aarch64.dmg"
  COUNT="$(json assets || echo 0)"
  i=0
  while [ "$i" -lt "${COUNT:-0}" ]; do
    if [ "$(json "assets.$i.name" || true)" = "$ASSET" ]; then
      URL="$(json "assets.$i.browser_download_url" || true)"
      DIGEST="$(json "assets.$i.digest" || true)"
      ASSET_SIZE="$(json "assets.$i.size" || echo 0)"
      break
    fi
    i=$((i + 1))
  done
  if [ -z "$TAG" ]; then
    bad "The release has no tag"
  elif [ -z "$URL" ]; then
    bad "Release $TAG has no $ASSET"
  else
    ok "Release $TAG, $((ASSET_SIZE / 1048576)) MB"
    case "$DIGEST" in
      sha256:*) ok "GitHub lists a SHA-256 digest to check the download against" ;;
      *) meh "GitHub lists no digest for this file, so the fingerprint cannot be compared" ;;
    esac
    HOST_HTTP="$(curl -sS -I --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' \
      "https://github.com" 2>/dev/null || true)"
    case "$HOST_HTTP" in
      200|301|302) ok "Download host reachable" ;;
      *) bad "Cannot reach github.com to download (HTTP ${HOST_HTTP:-none})" ;;
    esac
  fi
fi

# Where it goes, and room for it.
if [ "$DEST_GIVEN" = 0 ] && [ -d "$DEST" ] && [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  meh "$DEFAULT_DEST is not writable for this user, so Kode goes to $DEST"
fi
APP_DEST="$DEST/Kode.app"
if [ -d "$DEST" ] && [ ! -w "$DEST" ]; then
  bad "$DEST is not writable. Pick another folder with --dir, or run with sudo."
elif [ ! -d "$DEST" ] && [ "$DEST" != "$HOME/Applications" ]; then
  bad "$DEST does not exist"
else
  ok "Install folder $DEST"
fi
if [ "$ASSET_SIZE" -gt 0 ]; then
  NEED_TMP=$((ASSET_SIZE / 1048576 + 50))
  NEED_DEST=$((ASSET_SIZE * 4 / 1048576 + 100))
  HAVE_TMP="$(free_mb "$WORK")"
  HAVE_DEST="$(free_mb "$DEST")"
  if [ "$HAVE_TMP" -ge "$NEED_TMP" ]; then
    ok "Room to download (${HAVE_TMP} MB free, ${NEED_TMP} MB needed)"
  else
    bad "Only ${HAVE_TMP} MB free for the download; ${NEED_TMP} MB needed"
  fi
  if [ "$HAVE_DEST" -ge "$NEED_DEST" ]; then
    ok "Room to install (${HAVE_DEST} MB free, ${NEED_DEST} MB needed)"
  else
    bad "Only ${HAVE_DEST} MB free in $DEST; ${NEED_DEST} MB needed"
  fi
fi

# What is installed now.
REPLACING=0
UP_TO_DATE=0
if [ -d "$APP_DEST" ]; then
  EXISTING_ID="$(plist_value "$APP_DEST/Contents/Info.plist" CFBundleIdentifier)"
  EXISTING_VERSION="$(plist_value "$APP_DEST/Contents/Info.plist" CFBundleShortVersionString)"
  if [ "$EXISTING_ID" != "$BUNDLE_ID" ]; then
    bad "$APP_DEST is not Kode (${EXISTING_ID:-unknown app}), so it will not be replaced"
  else
    REPLACING=1
    if [ -n "$NUMBER" ]; then
      case "$(compare_versions "$NUMBER" "${EXISTING_VERSION:-0}")" in
        1) ok "Kode $EXISTING_VERSION is installed; this upgrades it to $NUMBER" ;;
        0) UP_TO_DATE=1; meh "Kode $EXISTING_VERSION is already installed" ;;
        *) meh "Kode $EXISTING_VERSION is installed; $NUMBER is older, so this is a downgrade" ;;
      esac
    else
      ok "Kode ${EXISTING_VERSION:-?} is installed"
    fi
    if pgrep -f "$APP_DEST/Contents/MacOS" >/dev/null 2>&1; then
      meh "Kode is running; it will be asked to quit before it is replaced"
    fi
  fi
else
  ok "No Kode in $DEST yet"
fi
for other in "$DEFAULT_DEST" "$HOME/Applications"; do
  [ "$other" = "$DEST" ] && continue
  [ -d "$other/Kode.app" ] && meh "Another copy is in $other; it will be left alone"
done

echo
if [ "$FAILED" = 1 ]; then die "preflight failed. Nothing was downloaded or installed."; fi
if [ "$CHECK_ONLY" = 1 ]; then say "Preflight passed. Run again without --check to install."; exit 0; fi
if [ "$UP_TO_DATE" = 1 ] && [ "$FORCE" = 0 ]; then
  say "Kode $NUMBER is already installed in $DEST. Use --force to reinstall it."
  exit 0
fi

# --- download and verify ----------------------------------------------------

say "Kode $NUMBER"
say "  from  $URL"
DMG="$WORK/$ASSET"
if [ -t 2 ]; then PROGRESS="--progress-bar"; else PROGRESS="-sS"; fi
curl -fL "$PROGRESS" -o "$DMG" "$URL" || die "download failed"

SIZE="$(stat -f %z "$DMG")"
SUM="$(shasum -a 256 "$DMG" | awk '{print $1}')"
say ""
say "Fingerprint (SHA-256) of $ASSET"
say "  $SUM"
say "  $((SIZE / 1048576)) MB"
case "$DIGEST" in
  sha256:*)
    if [ "${DIGEST#sha256:}" = "$SUM" ]; then
      say "  Matches the digest GitHub lists for this release asset."
    else
      die "the download does not match the digest GitHub lists (${DIGEST#sha256:}). Nothing was installed."
    fi
    ;;
  *) warn "GitHub lists no digest for this asset, so the fingerprint above was not compared with anything." ;;
esac
say ""

confirm "Install Kode $NUMBER to $APP_DEST?" || die "cancelled. Nothing was installed."

# --- install ----------------------------------------------------------------

mkdir -p "$DEST" || die "cannot create $DEST"
mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$MOUNT" "$DMG" -quiet \
  || die "could not open the disk image"
MOUNTED=1
SRC="$MOUNT/Kode.app"
[ -d "$SRC" ] || die "the disk image has no Kode.app"
PLIST="$SRC/Contents/Info.plist"
FOUND_ID="$(plist_value "$PLIST" CFBundleIdentifier)"
FOUND_VERSION="$(plist_value "$PLIST" CFBundleShortVersionString)"
[ "$FOUND_ID" = "$BUNDLE_ID" ] || die "the app is $FOUND_ID, not $BUNDLE_ID"
[ "$FOUND_VERSION" = "$NUMBER" ] || die "the app is version $FOUND_VERSION, not $NUMBER"
APP_MIN="$(plist_value "$PLIST" LSMinimumSystemVersion)"
if [ -n "$APP_MIN" ] && [ "$(compare_versions "$MACOS" "$APP_MIN")" = "-1" ]; then
  die "Kode $NUMBER needs macOS $APP_MIN or later; this Mac has $MACOS. Nothing was installed."
fi

if [ "$REPLACING" = 1 ] && pgrep -f "$APP_DEST/Contents/MacOS" >/dev/null 2>&1; then
  confirm "Kode is running from $APP_DEST. Quit it now?" || die "cancelled. Quit Kode and run this again."
  osascript -e 'tell application "Kode" to quit' >/dev/null 2>&1 || true
  waited=0
  while pgrep -f "$APP_DEST/Contents/MacOS" >/dev/null 2>&1; do
    [ "$waited" -lt 15 ] || die "Kode did not quit. Quit it yourself and run this again."
    sleep 1
    waited=$((waited + 1))
  done
fi

STAGED="$DEST/.Kode.app.installing"
rm -rf "$STAGED"
ditto "$SRC" "$STAGED"
codesign --verify --deep --strict "$STAGED" 2>/dev/null \
  || { rm -rf "$STAGED"; die "the copied app failed its signature check. Nothing was installed."; }
rm -rf "$APP_DEST"
mv "$STAGED" "$APP_DEST"

say "Installed $APP_DEST"
codesign -dvv "$APP_DEST" 2>&1 \
  | awk -F= '$1 == "Identifier" || $1 == "Signature" || $1 == "CDHash" { printf "  %-10s %s\n", $1, $2 }'

# macOS blocks the first launch of a quarantined app that is not notarized.
# Clear the flag on the installed copy, then confirm it is gone.
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true
if xattr -p com.apple.quarantine "$APP_DEST" >/dev/null 2>&1; then
  warn "could not clear the quarantine flag, so macOS may block the first launch."
  warn "Run this once:  sudo xattr -dr com.apple.quarantine \"$APP_DEST\""
else
  say "  Quarantine flag cleared, so macOS will not block the first launch."
fi

LEGACY="$HOME/Library/Application Support/com.monocode.desktop"
if [ -d "$LEGACY" ] && [ ! -d "$HOME/Library/Application Support/$BUNDLE_ID" ]; then
  say ""
  say "On first launch Kode copies your MonoCode data from:"
  say "  $LEGACY"
  say "The original stays in place. Back it up first if it matters to you."
fi

if [ "$OPEN_AFTER" = 1 ] && [ "$ASSUME_YES" = 0 ] && confirm "Open Kode now?"; then
  open "$APP_DEST"
fi
