#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_ENV_FILE="$PROJECT_DIR/.env"
ENV_FILE="${PUBLISH_ENV_FILE:-$DEFAULT_ENV_FILE}"

usage() {
    cat <<'EOF'
Usage: ./scripts/publish-release.sh [options]

Builds the latest DMG (unless --skip-build is used) and uploads it to a GitHub Release.
If the release does not exist yet, it is created.

Options:
  --skip-build         Skip running scripts/build-release.sh
  --asset <path>       Explicit DMG path to upload
  --tag <tag>          Release tag (default: v<CFBundleShortVersionString>)
  --title <title>      Release title (default: SoundMaxx <tag> [build n])
  --notes <text>       Release notes text for newly created releases
    --repo <owner/repo>  GitHub repository slug (default: autodetect)
    --env-file <path>    Load release settings from this .env file (default: ./.env)
  --prerelease         Mark newly created release as prerelease
  -h, --help           Show this help message

Environment alternatives:
    GITHUB_REPOSITORY, RELEASE_REPO, RELEASE_TAG, RELEASE_TITLE, RELEASE_NOTES,
    RELEASE_NOTES_FILE, ASSET_PATH, RELEASE_ASSET_PATH, RELEASE_SKIP_BUILD,
    RELEASE_PRERELEASE, PUBLISH_ENV_FILE

Authentication:
    gh auth login OR set GH_TOKEN/GITHUB_TOKEN in your environment/.env
EOF
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' is not installed." >&2
        exit 1
    fi
}

load_env_file() {
    local env_file="$1"

    if [[ ! -f "$env_file" ]]; then
        return 0
    fi

    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}

is_truthy() {
    local value
    local normalized
    value="${1:-}"
    normalized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

    case "$normalized" in
        1|true|yes|y|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ARGS=("$@")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]}" in
        --env-file)
            i=$((i + 1))
            if [[ $i -ge ${#ARGS[@]} ]]; then
                echo "Error: --env-file requires a value." >&2
                exit 1
            fi
            ENV_FILE="${ARGS[$i]}"
            ;;
    esac
    i=$((i + 1))
done

load_env_file "$ENV_FILE"

SKIP_BUILD=0
IS_PRERELEASE=0
ASSET_PATH="${ASSET_PATH:-${RELEASE_ASSET_PATH:-}}"
RELEASE_TAG="${RELEASE_TAG:-}"
RELEASE_TITLE="${RELEASE_TITLE:-}"
RELEASE_NOTES="${RELEASE_NOTES:-}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"
REPO="${GITHUB_REPOSITORY:-${RELEASE_REPO:-}}"

if is_truthy "${RELEASE_SKIP_BUILD:-0}"; then
    SKIP_BUILD=1
fi

if is_truthy "${RELEASE_PRERELEASE:-0}"; then
    IS_PRERELEASE=1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --asset)
            ASSET_PATH="$2"
            shift 2
            ;;
        --tag)
            RELEASE_TAG="$2"
            shift 2
            ;;
        --title)
            RELEASE_TITLE="$2"
            shift 2
            ;;
        --notes)
            RELEASE_NOTES="$2"
            shift 2
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --prerelease)
            IS_PRERELEASE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

require_command gh
require_command /usr/libexec/PlistBuddy

if ! gh auth status >/dev/null 2>&1 && [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
    echo "Error: GitHub CLI is not authenticated. Run: gh auth login" >&2
    exit 1
fi

BUILD_SCRIPT="$SCRIPT_DIR/build-release.sh"
BUILD_DIR="$PROJECT_DIR/build"
INFO_PLIST="$PROJECT_DIR/SoundMaxx/Info.plist"
DEFAULT_DMG="$BUILD_DIR/SoundMaxx-Installer.dmg"

if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi

if [[ -z "$REPO" ]]; then
    echo "Error: Could not determine repository slug. Use --repo <owner/repo>." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"

if [[ -z "$RELEASE_TAG" ]]; then
    RELEASE_TAG="v${VERSION}"
fi

if [[ -z "$RELEASE_TITLE" ]]; then
    RELEASE_TITLE="SoundMaxx ${RELEASE_TAG}"
    if [[ -n "$BUILD_NUMBER" ]]; then
        RELEASE_TITLE+=" (build ${BUILD_NUMBER})"
    fi
fi

if [[ -z "$RELEASE_NOTES" ]]; then
    RELEASE_NOTES="Automated release for ${RELEASE_TAG}."
fi

if [[ -n "$RELEASE_NOTES_FILE" ]]; then
    if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
        echo "Error: RELEASE_NOTES_FILE does not exist: $RELEASE_NOTES_FILE" >&2
        exit 1
    fi
    RELEASE_NOTES="$(<"$RELEASE_NOTES_FILE")"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "Building release DMG..."
    "$BUILD_SCRIPT"
else
    echo "Skipping build step."
fi

if [[ -z "$ASSET_PATH" ]]; then
    ASSET_PATH="$DEFAULT_DMG"
fi

if [[ ! -f "$ASSET_PATH" ]]; then
    # If a custom path was not generated, fall back to the newest DMG in build/.
    LATEST_DMG="$(ls -t "$BUILD_DIR"/*.dmg 2>/dev/null | head -n 1 || true)"
    if [[ -z "$LATEST_DMG" ]]; then
        echo "Error: No DMG found to upload. Expected '$ASSET_PATH'." >&2
        exit 1
    fi
    ASSET_PATH="$LATEST_DMG"
fi

echo "Repository: $REPO"
echo "Release tag: $RELEASE_TAG"
echo "Asset: $ASSET_PATH"

if gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release exists. Uploading asset (replace if already present)..."
    gh release upload "$RELEASE_TAG" "$ASSET_PATH" --repo "$REPO" --clobber
else
    echo "Release does not exist. Creating release and uploading asset..."
    CREATE_ARGS=(
        release create "$RELEASE_TAG" "$ASSET_PATH"
        --repo "$REPO"
        --title "$RELEASE_TITLE"
        --notes "$RELEASE_NOTES"
    )
    if [[ "$IS_PRERELEASE" -eq 1 ]]; then
        CREATE_ARGS+=(--prerelease)
    fi
    gh "${CREATE_ARGS[@]}"
fi

RELEASE_URL="$(gh release view "$RELEASE_TAG" --repo "$REPO" --json url --jq .url)"
echo ""
echo "Release upload complete: $RELEASE_URL"
