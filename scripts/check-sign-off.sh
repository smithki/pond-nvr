#!/bin/sh
# Whether every commit from BASE to HEAD (merges aside) is signed off by its author, as the Developer Certificate of
# Origin asks: a "Signed-off-by: NAME <EMAIL>" line with the author's own name and email (git commit -s writes it).
# Commits by GitHub Apps (an email ending [bot]@users.noreply.github.com) are skipped. CI runs it on pull requests
# (.github/workflows/sign-off.yml); by hand: scripts/check-sign-off.sh origin/main HEAD
#
#   scripts/check-sign-off.sh BASE HEAD
set -u
[ $# -eq 2 ] || { echo "usage: check-sign-off.sh BASE HEAD" >&2; exit 2; }
missing=0
for commit in $(git rev-list --no-merges "$1..$2"); do
    email=$(git show -s --format=%ae "$commit")
    case $email in *"[bot]@users.noreply.github.com") continue ;; esac
    name=$(git show -s --format=%an "$commit")
    if git show -s --format=%B "$commit" | grep -qiF "Signed-off-by: $name <$email>"; then
        echo "✓ $(git show -s --format='%h %s' "$commit")"
    else
        echo "✗ $(git show -s --format='%h %s' "$commit"): no \"Signed-off-by: $name <$email>\""
        [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::$(git show -s --format=%h "$commit") isn't signed off by its author ($name <$email>)"
        missing=1
    fi
done
if [ $missing -ne 0 ]; then
    echo
    echo "Every commit needs its author's sign-off (CONTRIBUTING.md, Signing off). To add it to the commits here:"
    echo "  git rebase --signoff $1 && git push --force-with-lease"
fi
exit $missing
