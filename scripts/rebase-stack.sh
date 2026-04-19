#!/usr/bin/env bash
#
# rebase-stack.sh - Rebase feature branches onto dev, then reconstruct mycode
#                   by cherry-picking. Feature branches are only modified during
#                   rebase onto dev, never during stacking.
#
# Usage:
#   bash scripts/rebase-stack.sh [OPTIONS]
#
# Options:
#   -c, --config FILE   Branch config file (default: scripts/branches.txt)
#   -n, --dry-run       Show what would be done without making changes
#   --no-push           Skip the force push step
#   --force-push        Use --force instead of --force-with-lease
#   -h, --help          Show this help message
#
# Workflow:
#   1. You manually sync dev with the official repo
#   2. Run this script
#   3. The script:
#      a. Rebases each feature branch onto dev (feature branches ARE modified)
#      b. Pushes each rebased feature branch to origin
#      c. Creates mycode from dev
#      d. Cherry-picks each feature branch's unique commits onto mycode
#      e. Pushes mycode to origin
#   4. Feature branches are only modified by rebase onto dev,
#      never by the stacking process itself
#
# Prerequisites:
#   - dev branch has been manually synced with the official repo
#   - All feature branches listed in config exist locally
#   - Working tree is clean (no uncommitted changes)
#   - RECOMMENDED: enable git rerere for automatic conflict resolution reuse:
#       git config --global rerere.enabled true
#
# Config file format (one branch per line, order = stacking order):
#   # This is a comment
#   feat/x      # inline comments allowed
#   feat/y
#   fix/z
#
set -euo pipefail

# ============================================================
# Configuration
# ============================================================
BASE_BRANCH="dev"
INTEGRATION_BRANCH="mycode"
REMOTE="origin"
BACKUP_PREFIX="refs/backups/pre-rebase"

# ============================================================
# Color helpers (no-op if not a terminal)
# ============================================================
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

info()  { echo -e "${CYAN}INFO${RESET}  $*"; }
ok()    { echo -e "${GREEN}OK${RESET}    $*"; }
warn()  { echo -e "${YELLOW}WARN${RESET}  $*"; }
error() { echo -e "${RED}ERROR${RESET} $*" >&2; }

# ============================================================
# Parse arguments
# ============================================================
CONFIG_FILE=""
DRY_RUN=false
NO_PUSH=false
FORCE_PUSH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)    CONFIG_FILE="$2"; shift 2 ;;
        -n|--dry-run)   DRY_RUN=true; shift ;;
        --no-push)      NO_PUSH=true; shift ;;
        --force-push)   FORCE_PUSH=true; shift ;;
        -h|--help)
            head -32 "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ============================================================
# Resolve paths
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE="$SCRIPT_DIR/branches.txt"
fi

# Make config file path absolute if relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="$REPO_ROOT/$CONFIG_FILE"
fi

cd "$REPO_ROOT"

# ============================================================
# Read branch config
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    error "Config file not found: $CONFIG_FILE"
    echo ""
    echo "Create it with one branch name per line in stacking order:"
    echo "  $CONFIG_FILE"
    echo ""
    echo "Example:"
    echo "  feat/my-feature"
    echo "  fix/my-fix"
    exit 1
fi

BRANCHES=()
while IFS= read -r line; do
    # Strip inline comments and whitespace
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$line" ]] && BRANCHES+=("$line")
done < "$CONFIG_FILE"

if [ ${#BRANCHES[@]} -eq 0 ]; then
    error "No branches found in $CONFIG_FILE"
    exit 1
fi

# ============================================================
# Display plan
# ============================================================
echo -e "${BOLD}=== Rebase Stack Plan ===${RESET}"
echo ""
echo "  Base:         $BASE_BRANCH"
echo "  Integration:  $INTEGRATION_BRANCH"
echo "  Remote:       $REMOTE"
echo "  Dry run:      $DRY_RUN"
echo ""
echo -e "  ${BOLD}Branch order (bottom to top):${RESET}"
for i in "${!BRANCHES[@]}"; do
    marker="├──"
    if [ "$i" -eq $(( ${#BRANCHES[@]} - 1 )) ]; then
        marker="└──"
    fi
    echo "  $marker [${BRANCHES[$i]}]"
done
echo ""

# ============================================================
# Pre-flight checks
# ============================================================
info "Running pre-flight checks..."

# Working tree clean
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    error "Working tree has uncommitted changes."
    echo "  Commit or stash before running this script."
    exit 1
fi
ok "Working tree is clean"

# Base branch exists
if ! git show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
    error "Base branch '$BASE_BRANCH' does not exist locally."
    exit 1
fi
ok "Base branch '$BASE_BRANCH' exists"

# All feature branches exist
for branch in "${BRANCHES[@]}"; do
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
        error "Branch '$branch' does not exist locally."
        echo "  Create it first: git checkout -b $branch $BASE_BRANCH"
        exit 1
    fi
done
ok "All ${#BRANCHES[@]} feature branches exist"

# Check if integration branch exists (for backup)
INTEGRATION_EXISTS=false
if git show-ref --verify --quiet "refs/heads/$INTEGRATION_BRANCH"; then
    INTEGRATION_EXISTS=true
fi

# Save current branch
CURRENT_BRANCH=$(git branch --show-current)
ok "Current branch: $CURRENT_BRANCH"

echo ""

# ============================================================
# Helper: run git command (respects dry-run)
# ============================================================
git_run() {
    local desc="$1"
    shift
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}[DRY]${RESET} git $*"
        return 0
    else
        echo -e "  ${CYAN}RUN${RESET}   git $*"
        git "$@"
    fi
}

# ============================================================
# Helper: save backup refs for rollback
# ============================================================
save_backups() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    info "Saving backup refs under $BACKUP_PREFIX/$timestamp/"

    for branch in "${BRANCHES[@]}"; do
        local sha
        sha=$(git rev-parse "$branch")
        git_run "backup $branch" update-ref "${BACKUP_PREFIX}/${timestamp}/${branch}" "$sha"
    done

    if [ "$INTEGRATION_EXISTS" = true ]; then
        local sha
        sha=$(git rev-parse "$INTEGRATION_BRANCH")
        git_run "backup $INTEGRATION_BRANCH" update-ref "${BACKUP_PREFIX}/${timestamp}/${INTEGRATION_BRANCH}" "$sha"
    fi
}

# ============================================================
# Helper: check if all conflicted files are auto-resolved (no conflict markers)
# Returns 0 if all resolved, 1 if any file still has markers
# ============================================================
all_conflicts_auto_resolved() {
    local unmerged
    unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null)
    if [ -z "$unmerged" ]; then
        return 1
    fi
    for file in $unmerged; do
        if grep -q "^<<<<<<< " "$file" 2>/dev/null; then
            return 1
        fi
    done
    return 0
}

# ============================================================
# Helper: retry cherry-pick/rebase continuation after rerere
# Tries to auto-continue when rerere has resolved all conflicts
# Returns 0 if fully resolved, 1 if manual intervention needed
# ============================================================
try_rerere_continue() {
    local subcmd="$1"  # "cherry-pick" or "rebase"
    local max_attempts=50  # safety limit for multi-commit ranges
    local attempt=0

    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))

        if ! all_conflicts_auto_resolved; then
            # Still has real conflict markers - needs manual resolution
            return 1
        fi

        # rerere resolved all markers, stage the files
        local unmerged
        unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null)
        if [ -z "$unmerged" ]; then
            return 1
        fi

        info "rerere auto-resolved conflicts, staging: $unmerged"
        git add $unmerged

        # Continue the operation
        if [ "$subcmd" = "cherry-pick" ]; then
            if git cherry-pick --continue --no-edit; then
                return 0
            fi
        else
            if git rebase --continue; then
                return 0
            fi
        fi
        # If continue failed (another conflict), loop to try rerere again
    done

    return 1
}

# ============================================================
# Cleanup trap
# ============================================================
on_exit() {
    if [ "$DRY_RUN" = false ]; then
        echo ""
        info "Restoring to branch: $CURRENT_BRANCH"
        git checkout "$CURRENT_BRANCH" 2>/dev/null || true
    fi
}
trap on_exit EXIT

# ============================================================
# Phase 1: Rebase all feature branches onto dev
# ============================================================
save_backups
echo ""

echo -e "${BOLD}=== Phase 1: Rebase feature branches onto $BASE_BRANCH ===${RESET}"
echo ""

for branch in "${BRANCHES[@]}"; do
    info "Rebasing $branch onto $BASE_BRANCH"

    git_run "checkout" checkout "$branch"

    if ! git_run "rebase" rebase "$BASE_BRANCH"; then
        # Try to auto-resolve via rerere
        if try_rerere_continue "rebase"; then
            ok "$branch rebased onto $BASE_BRANCH (with rerere)"
        else
            echo ""
            error "CONFLICT while rebasing ${branch} onto ${BASE_BRANCH}!"
            echo ""
            echo "  Resolve the conflict(s), then:"
            echo "    git rebase --continue"
            echo ""
            echo "  To abort this rebase:"
            echo "    git rebase --abort"
            echo ""
            echo "  After resolving, re-run this script to continue."
            exit 1
        fi
    fi

    ok "$branch rebased onto $BASE_BRANCH"
    echo ""
done

# ============================================================
# Phase 2: Reconstruct mycode by cherry-picking
# ============================================================
echo -e "${BOLD}=== Phase 2: Reconstruct $INTEGRATION_BRANCH ===${RESET}"
echo ""

# Create mycode from dev
info "Creating $INTEGRATION_BRANCH from $BASE_BRANCH"
git_run "create mycode" checkout -B "$INTEGRATION_BRANCH" "$BASE_BRANCH"
echo ""

# Cherry-pick each branch's unique commits onto mycode
# After Phase 1 rebase, each branch shares the same base (dev tip),
# so dev..branch correctly identifies only that branch's unique commits.
for branch in "${BRANCHES[@]}"; do
    COMMIT_COUNT=$(git rev-list --count "${BASE_BRANCH}..${branch}")

    if [ "$COMMIT_COUNT" -eq 0 ]; then
        warn "$branch has no unique commits (already in $BASE_BRANCH), skipping"
        echo ""
        continue
    fi

    info "Cherry-picking $branch ($COMMIT_COUNT commit(s)) onto $INTEGRATION_BRANCH"

    if ! git_run "cherry-pick" cherry-pick "${BASE_BRANCH}..${branch}"; then
        # Try to auto-resolve via rerere
        if try_rerere_continue "cherry-pick"; then
            ok "$branch cherry-picked ($COMMIT_COUNT commit(s)) with rerere"
            echo ""
            continue
        fi
        echo ""
        error "CONFLICT while cherry-picking ${branch}!"
        echo ""
        echo "  Resolve the conflict(s), then:"
        echo "    git cherry-pick --continue"
        echo ""
        echo "  To abort:"
        echo "    git cherry-pick --abort"
        echo ""
        echo "  After resolving, re-run this script to continue."
        exit 1
    fi

    ok "$branch cherry-picked ($COMMIT_COUNT commit(s))"
    echo ""
done

# ============================================================
# Show final log
# ============================================================
echo -e "${BOLD}=== Result: $INTEGRATION_BRANCH commit history ===${RESET}"
echo ""
if [ "$DRY_RUN" = false ]; then
    git --no-pager log --oneline --decorate "$BASE_BRANCH..$INTEGRATION_BRANCH"
fi
echo ""

# ============================================================
# Phase 3: Force push
# ============================================================
if [ "$NO_PUSH" = false ]; then
    echo -e "${BOLD}=== Phase 3: Force push to $REMOTE ===${RESET}"
    echo ""

    # Fetch remote refs so --force-with-lease has up-to-date tracking info
    # (rebase rewrites local history, making cached remote refs stale)
    info "Fetching $REMOTE to refresh tracking refs"
    git_run "fetch" fetch --prune "$REMOTE"

    PUSH_FLAG="--force-with-lease"
    if [ "$FORCE_PUSH" = true ]; then
        PUSH_FLAG="--force"
    fi

    # Push feature branches (rebased in Phase 1)
    for branch in "${BRANCHES[@]}"; do
        info "Pushing $branch"
        git_run "push" push $PUSH_FLAG --no-verify "$REMOTE" "$branch"
    done

    # Push integration branch
    info "Pushing $INTEGRATION_BRANCH"
    git_run "push" push $PUSH_FLAG --no-verify "$REMOTE" "$INTEGRATION_BRANCH"

    echo ""
    ok "All branches pushed to $REMOTE"
else
    warn "Push skipped (--no-push)"
fi

# ============================================================
# Done
# ============================================================
echo ""
echo -e "${GREEN}${BOLD}=========================================${RESET}"
echo -e "${GREEN}${BOLD}  Done!${RESET}"
echo -e "  ${BOLD}$INTEGRATION_BRANCH${RESET} = $BASE_BRANCH"
for branch in "${BRANCHES[@]}"; do
    echo -e "  → $branch"
done
echo -e "${GREEN}${BOLD}=========================================${RESET}"
echo ""
echo "Tip: To rollback, use backup refs:"
echo "  git for-each-ref $BACKUP_PREFIX"
