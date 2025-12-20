#!/bin/bash
#
# fake-battery-nut - AUR Publishing Script
#
# Automates the process of publishing updates to the AUR package.
# Usage: ./publish-aur.sh [-y|--yes] [commit-message]
#
# Options:
#   -y, --yes    Skip all confirmation prompts (non-interactive mode)
#

set -e

# Parse flags
AUTO_CONFIRM=false
COMMIT_MSG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        *)
            COMMIT_MSG="$1"
            shift
            ;;
    esac
done

# Helper for confirmations
confirm() {
    local prompt="$1"
    local default="${2:-N}"
    if [ "$AUTO_CONFIRM" = true ]; then
        return 0
    fi
    read -p "$prompt " -n 1 -r
    echo ""
    if [ "$default" = "Y" ]; then
        [[ ! $REPLY =~ ^[Nn]$ ]]
    else
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# Colors for output
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

print_msg() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

print_msg "$GREEN" "═══════════════════════════════════════════════════════"
print_msg "$GREEN" "  fake-battery-nut - AUR Publishing"
print_msg "$GREEN" "═══════════════════════════════════════════════════════"
echo ""

# Check we're in the right directory
if [ ! -f "PKGBUILD" ]; then
    print_msg "$RED" "❌ Error: PKGBUILD not found in current directory"
    exit 1
fi

# Get version from PKGBUILD
PKGNAME=$(grep '^pkgname=' PKGBUILD | cut -d'=' -f2)
PKGVER=$(grep '^pkgver=' PKGBUILD | cut -d'=' -f2)
PKGREL=$(grep '^pkgrel=' PKGBUILD | cut -d'=' -f2)
print_msg "$BLUE" "📦 Package: ${PKGNAME} ${PKGVER}-${PKGREL}"
echo ""

# Check if we're on a clean git state
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    print_msg "$YELLOW" "⚠️  Warning: You have uncommitted changes"
    git status --short
    echo ""
    if ! confirm "Continue anyway? [y/N]" "N"; then
        print_msg "$YELLOW" "Publish cancelled. Commit your changes first."
        exit 0
    fi
fi

# Check if local main/master is in sync with remote
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
print_msg "$BLUE" "🔍 Checking if $CURRENT_BRANCH is in sync with remote..."

# Fetch latest from remote
git fetch origin "$CURRENT_BRANCH" 2>/dev/null

# Check if we're behind
BEHIND=$(git rev-list HEAD..origin/"$CURRENT_BRANCH" --count 2>/dev/null || echo "0")
if [ "$BEHIND" -gt 0 ]; then
    print_msg "$RED" "❌ Error: Your local branch is $BEHIND commit(s) behind origin/$CURRENT_BRANCH"
    print_msg "$YELLOW" "Run: git pull origin $CURRENT_BRANCH"
    exit 1
fi

# Check if we're ahead
AHEAD=$(git rev-list origin/"$CURRENT_BRANCH"..HEAD --count 2>/dev/null || echo "0")
if [ "$AHEAD" -gt 0 ]; then
    print_msg "$YELLOW" "⚠️  Warning: Your local branch is $AHEAD commit(s) ahead of origin/$CURRENT_BRANCH"
    print_msg "$YELLOW" "You need to push to GitHub before publishing to AUR!"
    echo ""
    if confirm "Push to origin/$CURRENT_BRANCH now? [Y/n]" "Y"; then
        git push origin "$CURRENT_BRANCH"
        print_msg "$GREEN" "✓ Pushed to origin/$CURRENT_BRANCH"
    else
        print_msg "$RED" "❌ Cannot publish to AUR without pushing to GitHub first"
        print_msg "$YELLOW" "The PKGBUILD sources from GitHub, so changes must be there!"
        exit 1
    fi
else
    print_msg "$GREEN" "✓ Local branch in sync with origin/$CURRENT_BRANCH"
fi
echo ""

# Check if tag exists for this version
TAG_NAME="v${PKGVER}"
if ! git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    print_msg "$YELLOW" "⚠️  Warning: Git tag $TAG_NAME does not exist"
    if confirm "Create tag $TAG_NAME now? [y/N]" "N"; then
        git tag -a "$TAG_NAME" -m "Release version ${PKGVER}"
        print_msg "$GREEN" "✓ Created tag $TAG_NAME"
        echo ""
    else
        print_msg "$RED" "❌ Tag required for AUR package. Aborting."
        exit 1
    fi
else
    # Tag exists, check if it's pushed to remote
    print_msg "$GREEN" "✓ Tag $TAG_NAME exists locally"

    # Check if tag is on remote
    if git ls-remote --tags origin | grep -q "refs/tags/$TAG_NAME"; then
        print_msg "$GREEN" "✓ Tag $TAG_NAME is pushed to remote"
    else
        print_msg "$YELLOW" "⚠️  Warning: Tag $TAG_NAME exists locally but not on remote"
        if confirm "Push tag to remote now? [Y/n]" "Y"; then
            git push origin "$TAG_NAME"
            print_msg "$GREEN" "✓ Pushed tag $TAG_NAME to remote"
        else
            print_msg "$YELLOW" "⚠️  Tag not pushed - users may not be able to install from AUR!"
        fi
    fi
    echo ""
fi

# Regenerate .SRCINFO
print_msg "$BLUE" "🔄 Regenerating .SRCINFO..."
makepkg --printsrcinfo > .SRCINFO
print_msg "$GREEN" "✓ .SRCINFO updated"
echo ""

# Commit .SRCINFO to main repo if changed
if ! git diff --quiet .SRCINFO 2>/dev/null; then
    print_msg "$BLUE" "💾 Committing .SRCINFO to main repository..."
    git add .SRCINFO
    git commit -m "Update .SRCINFO for version ${PKGVER}-${PKGREL}"
    print_msg "$GREEN" "✓ Committed to main repository"
    echo ""
fi

# Setup AUR repository
AUR_DIR="/tmp/${PKGNAME}-aur"
if [ -d "$AUR_DIR" ]; then
    print_msg "$BLUE" "🔄 Updating existing AUR repository..."
    cd "$AUR_DIR"
    # Ensure we're on master branch (AUR requirement)
    git checkout master 2>/dev/null || git checkout -b master
    git pull origin master 2>/dev/null || true
    cd - > /dev/null
else
    print_msg "$BLUE" "📥 Cloning AUR repository..."
    if ! git clone ssh://aur@aur.archlinux.org/${PKGNAME}.git "$AUR_DIR" 2>/dev/null; then
        print_msg "$YELLOW" "⚠️  AUR package doesn't exist yet. Creating new package..."
        mkdir -p "$AUR_DIR"
        cd "$AUR_DIR"
        git init
        git remote add origin ssh://aur@aur.archlinux.org/${PKGNAME}.git
        cd - > /dev/null
    else
        cd "$AUR_DIR"
        # Ensure we're on master branch (AUR uses master, not main)
        git checkout master 2>/dev/null || git checkout -b master
        cd - > /dev/null
    fi
fi
print_msg "$GREEN" "✓ AUR repository ready"
echo ""

# Copy files to AUR repo
print_msg "$BLUE" "📋 Copying PKGBUILD and .SRCINFO..."
cp PKGBUILD .SRCINFO "$AUR_DIR/"
print_msg "$GREEN" "✓ Files copied"
echo ""

# Commit to AUR
cd "$AUR_DIR"
git add PKGBUILD .SRCINFO

# Check if there are changes
if git diff --cached --quiet; then
    print_msg "$YELLOW" "ℹ️  No changes to publish to AUR"
    exit 0
fi

# Get commit message (use default if not provided)
if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="Update to version ${PKGVER}-${PKGREL}"
fi

print_msg "$BLUE" "💾 Committing to AUR..."
git commit -m "$COMMIT_MSG"
print_msg "$GREEN" "✓ Committed: $COMMIT_MSG"
echo ""

# Show what will be pushed
print_msg "$YELLOW" "📤 Ready to push to AUR:"
git log --oneline -1
echo ""

if ! confirm "Push to AUR now? [Y/n]" "Y"; then
    print_msg "$YELLOW" "Publish cancelled. Changes are committed locally in $AUR_DIR"
    exit 0
fi

# Push to AUR
print_msg "$BLUE" "📤 Pushing to AUR..."
git push origin master
cd - > /dev/null

print_msg "$GREEN" "═══════════════════════════════════════════════════════"
print_msg "$GREEN" "✓ Successfully published to AUR!"
print_msg "$GREEN" "═══════════════════════════════════════════════════════"
echo ""
print_msg "$BLUE" "Package URL: https://aur.archlinux.org/packages/${PKGNAME}"
echo ""
print_msg "$YELLOW" "Don't forget to push your main repository changes:"
print_msg "$NC" "  git push origin main"
print_msg "$NC" "  git push --tags"
echo ""
