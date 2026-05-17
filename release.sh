#!/bin/bash
set -euo pipefail

# ── Znote Release Script ────────────────────────────────────
# Usage:
#   ./release.sh v0.1.0           Create tag and push to trigger GitHub Actions release
#   ./release.sh v0.1.0 -m "msg"  With custom release message in tag
#   ./release.sh --list            List all existing tags
#   ./release.sh --delete v0.1.0   Delete a tag locally and remotely
# ─────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✖${NC} $*" >&2; }

usage() {
    echo "Usage:"
    echo "  ./release.sh <version>              Create tag & trigger release"
    echo "  ./release.sh <version> -m \"message\"  With custom tag message"
    echo "  ./release.sh --list                  List all tags"
    echo "  ./release.sh --delete <version>      Delete tag locally + remotely"
    echo ""
    echo "Examples:"
    echo "  ./release.sh v0.1.0"
    echo "  ./release.sh v1.2.3 -m \"Fix audio recording bug\""
    echo "  ./release.sh --delete v0.1.0"
    exit 1
}

list_tags() {
    info "Existing tags:"
    tags=$(git tag -l --sort=-v:refname)
    if [ -z "$tags" ]; then
        echo "  (none)"
    else
        echo "$tags" | while read -r tag; do
            date=$(git log -1 --format='%ai' "$tag" 2>/dev/null | cut -d' ' -f1)
            subject=$(git tag -l -n1 "$tag" | sed "s/^$tag\s*//")
            printf "  ${GREEN}%-12s${NC} ${YELLOW}%s${NC}  %s\n" "$tag" "$date" "$subject"
        done
    fi
    exit 0
}

delete_tag() {
    local tag="$1"
    if ! git rev-parse "$tag" &>/dev/null; then
        err "Tag '$tag' does not exist"
        exit 1
    fi

    warn "This will delete tag '$tag' locally and remotely."
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }

    git tag -d "$tag"
    ok "Deleted local tag '$tag'"

    if git push origin ":refs/tags/$tag" 2>/dev/null; then
        ok "Deleted remote tag '$tag'"
    else
        warn "Remote tag not found or already deleted"
    fi
    exit 0
}

# ── Parse args ───────────────────────────────────────────────

[ $# -lt 1 ] && usage

case "$1" in
    --list|-l)  list_tags ;;
    --delete|-d)
        [ $# -lt 2 ] && { err "Specify tag to delete"; usage; }
        delete_tag "$2"
        ;;
    --help|-h)  usage ;;
esac

VERSION="$1"
shift

# Validate version format
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "Invalid version format: '$VERSION'"
    echo "  Expected: v<major>.<minor>.<patch>  (e.g. v0.1.0, v1.2.3)"
    exit 1
fi

# Parse optional message
MESSAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -m) MESSAGE="$2"; shift 2 ;;
        *)  err "Unknown option: $1"; usage ;;
    esac
done

# ── Pre-flight checks ───────────────────────────────────────

# Check we're in a git repo
git rev-parse --git-dir &>/dev/null || { err "Not a git repository"; exit 1; }

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    err "You have uncommitted changes. Commit or stash them first."
    git status --short
    exit 1
fi

# Check tag doesn't already exist
if git rev-parse "$VERSION" &>/dev/null 2>&1; then
    err "Tag '$VERSION' already exists"
    echo "  Use './release.sh --delete $VERSION' to remove it first"
    exit 1
fi

# Check we're on main branch
BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "main" ]; then
    warn "You are on branch '$BRANCH', not 'main'."
    read -rp "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
fi

# Check remote is up to date
info "Checking remote sync..."
git fetch origin --quiet
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main 2>/dev/null || echo "")
if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
    warn "Local and remote are out of sync."
    echo "  Local:  $(git log -1 --oneline HEAD)"
    echo "  Remote: $(git log -1 --oneline origin/main)"
    read -rp "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
fi

# ── Create tag & push ───────────────────────────────────────

echo ""
info "Release: ${GREEN}$VERSION${NC}"
info "Commit:  $(git log -1 --oneline HEAD)"
[ -n "$MESSAGE" ] && info "Message: $MESSAGE"
echo ""

read -rp "Create and push tag? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }

if [ -n "$MESSAGE" ]; then
    git tag -a "$VERSION" -m "$MESSAGE"
else
    git tag -a "$VERSION" -m "Release $VERSION"
fi
ok "Created tag '$VERSION'"

git push origin "$VERSION"
ok "Pushed tag to origin"

echo ""
ok "Release triggered! GitHub Actions will build and publish."
echo ""
echo "  📦 Monitor:  https://github.com/nicetooo/Znote/actions"
echo "  🏷  Release:  https://github.com/nicetooo/Znote/releases/tag/$VERSION"
echo ""
