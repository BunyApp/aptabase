#!/usr/bin/env bash
#
# Re-sync this fork onto upstream/main by replaying the fork's patch series.
# See FORK.md for what the patches are and how deployment picks them up.
#
set -euo pipefail

BRANCH="${FORK_BRANCH:-changes}"
REMOTE="${FORK_UPSTREAM:-upstream}"
REMOTE_BRANCH="${FORK_UPSTREAM_BRANCH:-main}"
TARGET="${REMOTE}/${REMOTE_BRANCH}"

cd "$(git rev-parse --show-toplevel)"

die() { printf '\nerror: %s\n' "$1" >&2; exit 1; }

# A rebase rewrites the working tree; refuse to run with anything uncommitted.
if [ -n "$(git status --porcelain)" ]; then
    git status --short
    die "working tree is not clean. Commit or stash first."
fi

current="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current" != "$BRANCH" ]; then
    die "on branch '$current', expected '$BRANCH'. Switch with: git switch $BRANCH"
fi

git remote get-url "$REMOTE" >/dev/null 2>&1 \
    || die "no '$REMOTE' remote. Add it with: git remote add $REMOTE https://github.com/aptabase/aptabase.git"

echo "==> fetching $REMOTE"
git fetch "$REMOTE" --prune --tags

before="$(git rev-parse HEAD)"

# Already replayed on top of the current upstream tip: nothing to do. Exiting
# here keeps repeat runs a no-op and avoids piling up restore-point tags.
if git merge-base --is-ancestor "$TARGET" HEAD; then
    echo "==> already up to date with $TARGET ($(git rev-parse --short "$TARGET"))"
    echo
    echo "fork patches:"
    git log --oneline "$TARGET..$BRANCH" | sed 's/^/  /'
    exit 0
fi

incoming="$(git rev-list --count "HEAD..$TARGET")"
echo "==> $incoming new upstream commit(s):"
git log --oneline "HEAD..$TARGET" | sed 's/^/  /'

tag="fork-sync-$(date +%Y%m%d-%H%M%S)"
git tag "$tag" "$BRANCH"
echo "==> restore point tagged: $tag"

echo "==> rebasing $BRANCH onto $TARGET"
if ! git rebase "$TARGET"; then
    cat <<EOF

Rebase stopped on a conflict. Either:

  resolve, then:   git add <files> && git rebase --continue
  give up, then:   git rebase --abort

If things go sideways entirely:  git reset --hard $tag

Conflict resolutions are remembered (rerere), so a conflict you have
already settled once will not be asked about again.
EOF
    exit 1
fi

cat <<EOF

==> synced: $(git rev-parse --short "$before") -> $(git rev-parse --short HEAD)

fork patches now replayed on $TARGET:
$(git log --oneline "$TARGET..$BRANCH" | sed 's/^/  /')

fork surface:
$(git diff "$TARGET..$BRANCH" --stat | sed 's/^/  /')

Next:
  dotnet build src/Aptabase.csproj          # verify it still compiles
  git push --force-with-lease origin $BRANCH  # history was rewritten

Then on the deploy host, see FORK.md (use reset --hard, not pull).
Restore point if needed: $tag
EOF
