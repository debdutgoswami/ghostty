#!/usr/bin/env bash
# Cut a personal-fork release of Ghostty: build, sign, package, tag, publish,
# and bump the corresponding cask in the homebrew tap. Tailored to the
# debdutgoswami/ghostty + debdutgoswami/homebrew-tap workflow.
#
# Usage:  dist/release-fork.sh <version>          e.g. 1.3.2-osc1337.2
# Env:    TAP_DIR    path to the homebrew-tap repo   (default ~/GitHub/homebrew-tap)
#         FORK_REPO  GitHub repo owning the release  (default debdutgoswami/ghostty)
#         CASK_NAME  cask file basename (no .rb)     (default ghostty-osc1337)
#
# Requires:  zig, codesign, ditto, gh (authed), git, sed.

set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>" >&2; exit 2; }

TAP_DIR="${TAP_DIR:-$HOME/GitHub/homebrew-tap}"
FORK_REPO="${FORK_REPO:-debdutgoswami/ghostty}"
CASK_NAME="${CASK_NAME:-ghostty-osc1337}"

REPO_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_DIR"

ZIP="Ghostty-${VERSION}.zip"
TAG="v${VERSION}"

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
say "preflight"
git diff --quiet                   || die "repo has uncommitted changes"
git diff --quiet --cached          || die "repo has staged-but-uncommitted changes"
git rev-parse "$TAG" >/dev/null 2>&1 \
    && die "tag $TAG already exists locally — bump the version"
# Not `gh auth status`: it exits nonzero on mere scope warnings.
gh api user >/dev/null 2>&1        || die "gh is not authenticated (run: gh auth login)"
[ -d "$TAP_DIR/.git" ]             || die "tap repo not found at $TAP_DIR"
[ -f "$TAP_DIR/Casks/${CASK_NAME}.rb" ] \
    || die "cask not found at $TAP_DIR/Casks/${CASK_NAME}.rb"

# --- build -------------------------------------------------------------------
# App version = the upstream version this branch is based on (from build.zig.zon),
# NOT the fork tag: MDM reads CFBundleShortVersionString and wants plain numbers.
APP_VERSION="$(sed -n 's/^ *\.version = "\([^"]*\)".*/\1/p' build.zig.zon)"
[ -n "$APP_VERSION" ] || die "could not read .version from build.zig.zon"
BUILD_NUM="$(git rev-list --count HEAD)"

say "building ($VERSION, app version $APP_VERSION, build $BUILD_NUM)"
zig build -Doptimize=ReleaseFast -Dversion-string="$APP_VERSION"
[ -d zig-out/Ghostty.app ] || die "build did not produce zig-out/Ghostty.app"

# Stamp real version info into the bundle (must happen before codesign).
PLIST="zig-out/Ghostty.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$PLIST" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$PLIST" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUM" "$PLIST"

# --- sign (ad-hoc) -----------------------------------------------------------
say "signing (ad-hoc)"
codesign --force --deep --sign - zig-out/Ghostty.app
codesign --verify --deep --strict zig-out/Ghostty.app
spctl --assess --type execute zig-out/Ghostty.app 2>&1 \
    | grep -v 'rejected' >/dev/null \
    || echo "  (Gatekeeper will warn on first launch — cask postflight strips quarantine)"

# --- package -----------------------------------------------------------------
say "packaging → zig-out/$ZIP"
rm -f "zig-out/$ZIP"
( cd zig-out && ditto -c -k --keepParent Ghostty.app "$ZIP" )
SHA="$(shasum -a 256 "zig-out/$ZIP" | awk '{print $1}')"
SIZE="$(stat -f%z "zig-out/$ZIP")"
printf '  size: %s bytes\n  sha256: %s\n' "$SIZE" "$SHA"

# --- tag + push --------------------------------------------------------------
say "tagging + pushing"
git tag -m "Ghostty fork release ${VERSION}" "$TAG"
git push origin "$TAG"

# --- github release ----------------------------------------------------------
say "creating GitHub release"
gh release create "$TAG" "zig-out/$ZIP" \
    --repo "$FORK_REPO" \
    --title "$VERSION" \
    --notes "Patched Ghostty fork release $VERSION."

# --- cask bump ---------------------------------------------------------------
say "bumping cask in $TAP_DIR"
CASK="$TAP_DIR/Casks/${CASK_NAME}.rb"
sed -i '' -E "s|version \"[^\"]+\"|version \"${VERSION}\"|" "$CASK"
sed -i '' -E "s|sha256 \"[a-f0-9]+\"|sha256 \"${SHA}\"|"   "$CASK"

# Sanity check: did the substitutions actually land?
grep -q "version \"${VERSION}\"" "$CASK" || die "cask version bump failed"
grep -q "sha256 \"${SHA}\""      "$CASK" || die "cask sha256 bump failed"

git -C "$TAP_DIR" add "Casks/${CASK_NAME}.rb"
git -C "$TAP_DIR" commit -m "${CASK_NAME}: ${VERSION}"
git -C "$TAP_DIR" push

# --- done --------------------------------------------------------------------
say "released ${VERSION}"
cat <<EOF

  Tag:        $TAG
  Release:    https://github.com/${FORK_REPO}/releases/tag/${TAG}
  Asset:      zig-out/$ZIP ($SIZE bytes)
  Cask:       $TAP_DIR/Casks/${CASK_NAME}.rb
  Install:    brew upgrade --cask ${CASK_NAME}
              (or: brew install --cask debdutgoswami/tap/${CASK_NAME})

EOF
