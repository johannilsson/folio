#!/usr/bin/env bash
# Shows the self-test pictures on the pull request: they are committed to the `ci-pictures` branch
# (one folder per PR, replaced on every run) and linked from a single comment that is updated in place.
# Run by CI on a pull request from this repository; needs GH_TOKEN, PR and SHA in the environment.
# PICTURES names another folder of pictures and PICTURES_KIND (e.g. "windows") gives them a branch
# (`ci-pictures-<kind>`) and a comment of their own, so two jobs never push over each other.
set -euo pipefail

pictures="${PICTURES:-$RUNNER_TEMP/snapshots}"
kind="${PICTURES_KIND:-}"
branch="ci-pictures${kind:+-$kind}"
shopt -s nullglob
files=("$pictures"/*.png)
if ((${#files[@]} == 0)); then
  echo "no pictures to show"
  exit 0
fi

remote="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
work="$RUNNER_TEMP/ci-pictures"
rm -rf "$work"
if ! git clone --quiet --depth 1 --branch "$branch" "$remote" "$work" 2>/dev/null; then
  git init --quiet "$work"
  git -C "$work" checkout --quiet --orphan "$branch"
  git -C "$work" remote add origin "$remote"
fi

rm -rf "${work:?}/pr-$PR"
mkdir -p "$work/pr-$PR"
for file in "${files[@]}"; do
  cp "$file" "$work/pr-$PR/$(basename "$file" | sed 's/^folio-//')"
done

git -C "$work" config user.name "github-actions[bot]"
git -C "$work" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$work" add -A
git -C "$work" commit --quiet -m "Pictures for PR #$PR at ${SHA:0:7}" || true
git -C "$work" push --quiet origin "HEAD:$branch"
commit=$(git -C "$work" rev-parse HEAD)

marker="<!-- folio-ci-pictures${kind:+-$kind} -->"
body="$marker"$'\n'"### Self-test pictures${kind:+ ($kind)} (\`${SHA:0:7}\`)"$'\n\n'
for file in "$work/pr-$PR"/*.png; do
  name=$(basename "$file")
  body+="**${name%.png}**"$'\n'"![${name%.png}](https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${commit}/pr-${PR}/${name})"$'\n\n'
done

existing=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" --paginate \
  --jq ".[] | select(.body | startswith(\"$marker\")) | .id" | head -n 1)
if [[ -n "$existing" ]]; then
  gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${existing}" -f body="$body" > /dev/null
else
  gh api "repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" -f body="$body" > /dev/null
fi
echo "pictures are on the PR"
