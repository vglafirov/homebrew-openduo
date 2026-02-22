#!/usr/bin/env bash
# release.sh — Called by CI after a Renovate merge to main.
#
# This script:
#   1. Reads the opencode-ai version from package.json
#   2. Syncs package.json "version" field to match
#   3. Regenerates the restricted models catalog
#   4. Commits and creates a git tag (without formula SHA update)
#   5. Computes SHA256 from the now-existing tag archive
#   6. Updates the Homebrew formula with correct URL + SHA
#   7. Commits the formula update to main
#
# The tag archive is stable (tag points to step 4's commit).
# The formula on main always points to the latest tag.
#
# Requirements:
#   - bun, curl, shasum, git with push permissions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# --- 1. Read versions ---
OPENCODE_VERSION=$(bun -e "
  const pkg = await Bun.file('package.json').json();
  console.log(pkg.dependencies['opencode-ai']);
")
CURRENT_VERSION=$(bun -e "
  const pkg = await Bun.file('package.json').json();
  console.log(pkg.version);
")

echo "opencode-ai version: ${OPENCODE_VERSION}"
echo "Current openduo version: ${CURRENT_VERSION}"

if [ "$OPENCODE_VERSION" = "$CURRENT_VERSION" ]; then
  echo "Version already in sync, nothing to do."
  exit 0
fi

TAG="v${OPENCODE_VERSION}"
echo "Releasing OpenDuo ${TAG}..."

# --- 2. Sync package.json version ---
bun -e "
  const pkg = await Bun.file('package.json').json();
  pkg.version = '${OPENCODE_VERSION}';
  await Bun.write('package.json', JSON.stringify(pkg, null, 2) + '\n');
"

# --- 3. Regenerate models catalog ---
echo "Regenerating models catalog..."
bun run generate:models

# --- 4. Commit and tag (formula not updated yet — that's intentional) ---
# Set git identity if not already set (CI sets these in before_script)
git config user.email 2>/dev/null || git config user.email "ci@gitlab.com"
git config user.name 2>/dev/null || git config user.name "OpenDuo CI"

git add package.json models/models.json
git commit -m "release: bump to opencode-ai ${OPENCODE_VERSION}"
git tag -a "$TAG" -m "OpenDuo ${TAG} (opencode-ai ${OPENCODE_VERSION})"
git push origin main --tags

# --- 5. Compute SHA256 from the tag archive ---
PROJECT_PATH="${CI_PROJECT_PATH:-vglafirov/openduo}"
PROJECT_NAME="${CI_PROJECT_NAME:-openduo}"
ARCHIVE_URL="https://gitlab.com/${PROJECT_PATH}/-/archive/${TAG}/${PROJECT_NAME}-${TAG}.tar.gz"

echo "Fetching archive: ${ARCHIVE_URL}"
sleep 3  # Give GitLab a moment to generate the archive
SHA256=$(curl -sL "$ARCHIVE_URL" | shasum -a 256 | awk '{print $1}')
echo "SHA256: ${SHA256}"

# --- 6. Update Homebrew formula ---
FORMULA="Formula/openduo.rb"
sed -i.bak "s|url \".*\"|url \"${ARCHIVE_URL}\"|" "$FORMULA"
sed -i.bak "s|sha256 \".*\"|sha256 \"${SHA256}\"|" "$FORMULA"
rm -f "${FORMULA}.bak"

# --- 7. Commit formula update to main ---
git add "$FORMULA"
git commit -m "formula: update to ${TAG} (sha256: ${SHA256:0:12}...)"
git push origin main

echo ""
echo "=== Released OpenDuo ${TAG} ==="
echo "Tag:     ${TAG}"
echo "Archive: ${ARCHIVE_URL}"
echo "SHA256:  ${SHA256}"
echo ""
echo "Users can upgrade via:"
echo "  brew upgrade openduo"
