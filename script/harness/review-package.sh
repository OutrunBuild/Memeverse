#!/usr/bin/env bash
# Generate a review package from a fixed tracked snapshot and optional
# authoritative --files scope. This script never changes the shared Git index.
#
# Usage: review-package.sh BASE [HEAD] [OUTFILE] [--files FILE...]
# BASE and HEAD must resolve to commits, and HEAD must be the current HEAD.
# With --files, its sorted paths are the scope and unrelated changes are
# ignored. Without --files, all tracked snapshot changes and current untracked
# files are included.
set -euo pipefail

_usage() {
  printf '%s\n' 'usage: review-package.sh BASE [HEAD] [OUTFILE] [--files FILE...]' >&2
}

_canonical_path() {
  local path=$1
  local part
  local -a parts

  case "$path" in
    ''|/*|*/|*//*|*\\*|*:*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac

  IFS=/ read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [ -n "$part" ] && [ "$part" != '.' ] && [ "$part" != '..' ] || return 1
  done
}

_positionals=()
_requested_files=()
_files_mode=0
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--files' ]; then
    _files_mode=1
    shift
    _requested_files=("$@")
    break
  fi
  _positionals+=("$1")
  shift
done

if [ "${#_positionals[@]}" -lt 1 ] || [ "${#_positionals[@]}" -gt 3 ]; then
  _usage
  exit 2
fi

if [ "$_files_mode" -eq 1 ] && [ "${#_requested_files[@]}" -eq 0 ]; then
  printf '%s\n' 'review-package: --files requires at least one path' >&2
  exit 2
fi

root=$(git rev-parse --show-toplevel) || {
  printf '%s\n' 'review-package: unable to locate repository root' >&2
  exit 2
}
cd "$root"

if ! base=$(git rev-parse --verify --quiet "${_positionals[0]}^{commit}"); then
  printf 'review-package: bad BASE: %s\n' "${_positionals[0]}" >&2
  exit 2
fi

head_ref=${_positionals[1]:-HEAD}
if ! head=$(git rev-parse --verify --quiet "${head_ref}^{commit}"); then
  printf 'review-package: bad HEAD: %s\n' "$head_ref" >&2
  exit 2
fi

current_head=$(git rev-parse --verify HEAD^{commit})
if [ "$head" != "$current_head" ]; then
  printf 'review-package: HEAD must resolve to current HEAD (%s), got %s\n' "$current_head" "$head" >&2
  exit 2
fi

if ! git merge-base --is-ancestor "$base" "$head"; then
  printf 'review-package: BASE (%s) must be an ancestor of HEAD (%s)\n' "$base" "$head" >&2
  exit 2
fi

if [ "${#_positionals[@]}" -eq 3 ]; then
  out=${_positionals[2]}
else
  out="$root/.harness/tmp/review-$(git rev-parse --short "$base")..$(git rev-parse --short "$head").diff"
fi

tmp_dir=$(mktemp -d /tmp/review-package.XXXXXX) || {
  printf '%s\n' 'review-package: cannot create /tmp workspace' >&2
  exit 1
}
trap 'rm -rf -- "$tmp_dir"' EXIT

requested_files=()
if [ "$_files_mode" -eq 1 ]; then
  for file in "${_requested_files[@]}"; do
    if ! _canonical_path "$file"; then
      printf 'review-package: --files path is not canonical: %s\n' "$file" >&2
      exit 2
    fi
  done
  printf '%s\n' "${_requested_files[@]}" | LC_ALL=C sort -u > "$tmp_dir/requested-files"
  mapfile -t requested_files < "$tmp_dir/requested-files"
  if [ "${#requested_files[@]}" -ne "${#_requested_files[@]}" ]; then
    printf '%s\n' 'review-package: --files must not contain duplicate paths' >&2
    exit 2
  fi
fi

# git stash create writes no ref and leaves both the index and working tree
# untouched. Its commit tree freezes all tracked content for this package.
if ! snapshot=$(git stash create); then
  printf '%s\n' 'review-package: git stash create failed' >&2
  exit 1
fi
snapshot=${snapshot:-$head}

if ! git cat-file -e "${snapshot}^{commit}"; then
  printf 'review-package: snapshot is not a commit: %s\n' "$snapshot" >&2
  exit 1
fi

selected_tracked=()
selected_untracked=()
if [ "$_files_mode" -eq 1 ]; then
  for file in "${requested_files[@]}"; do
    if GIT_LITERAL_PATHSPECS=1 git -c core.quotePath=false diff --quiet "$base" "$snapshot" -- "$file"; then
      if [ -d "$file" ] || { [ ! -e "$file" ] && [ ! -L "$file" ]; }; then
        printf 'review-package: --files path is absent or unchanged: %s\n' "$file" >&2
        exit 1
      fi
      if ! GIT_LITERAL_PATHSPECS=1 git ls-files --others --exclude-standard -- "$file" > "$tmp_dir/untracked-candidate"; then
        printf 'review-package: cannot inspect untracked path: %s\n' "$file" >&2
        exit 1
      fi
      mapfile -t untracked_candidate < "$tmp_dir/untracked-candidate"
      if [ "${#untracked_candidate[@]}" -ne 1 ] || [ "${untracked_candidate[0]}" != "$file" ]; then
        printf 'review-package: --files path is absent or unchanged: %s\n' "$file" >&2
        exit 1
      fi
      selected_untracked+=("$file")
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        printf 'review-package: cannot inspect tracked path: %s\n' "$file" >&2
        exit "$status"
      fi
      selected_tracked+=("$file")
    fi
  done
  manifest_files=("${requested_files[@]}")
else
  if ! git -c core.quotePath=false diff --name-only "$base" "$snapshot" -- > "$tmp_dir/tracked-files.raw"; then
    printf '%s\n' 'review-package: cannot list tracked snapshot changes' >&2
    exit 1
  fi
  LC_ALL=C sort -u "$tmp_dir/tracked-files.raw" > "$tmp_dir/tracked-files"
  mapfile -t selected_tracked < "$tmp_dir/tracked-files"

  if ! git ls-files --others --exclude-standard > "$tmp_dir/untracked-files.raw"; then
    printf '%s\n' 'review-package: cannot list untracked files' >&2
    exit 1
  fi
  LC_ALL=C sort -u "$tmp_dir/untracked-files.raw" > "$tmp_dir/untracked-files"
  mapfile -t selected_untracked < "$tmp_dir/untracked-files"

  for file in "${selected_tracked[@]}" "${selected_untracked[@]}"; do
    if ! _canonical_path "$file"; then
      printf 'review-package: discovered path is not canonical: %s\n' "$file" >&2
      exit 1
    fi
  done

  : > "$tmp_dir/manifest-files.raw"
  if [ "${#selected_tracked[@]}" -gt 0 ]; then
    printf '%s\n' "${selected_tracked[@]}" >> "$tmp_dir/manifest-files.raw"
  fi
  if [ "${#selected_untracked[@]}" -gt 0 ]; then
    printf '%s\n' "${selected_untracked[@]}" >> "$tmp_dir/manifest-files.raw"
  fi
  LC_ALL=C sort -u "$tmp_dir/manifest-files.raw" > "$tmp_dir/manifest-files"
  mapfile -t manifest_files < "$tmp_dir/manifest-files"
fi

payload="$tmp_dir/payload"
{
  printf 'Base: %s\n' "$base"
  printf 'Head: %s\n' "$head"
  printf 'Snapshot: %s\n' "$snapshot"
  printf '\n## Scope Manifest\nAuthority: authoritative\n'
  if [ "${#manifest_files[@]}" -gt 0 ]; then
    printf '%s\n' "${manifest_files[@]}"
  fi
  printf '\n## Diff\n'
  if [ "${#selected_tracked[@]}" -gt 0 ]; then
    GIT_LITERAL_PATHSPECS=1 git -c core.quotePath=false diff --no-ext-diff -U10 "$base" "$snapshot" -- "${selected_tracked[@]}"
  fi
  for file in "${selected_untracked[@]}"; do
    if git -c core.quotePath=false diff --no-index --no-ext-diff -U10 -- /dev/null "$file"; then
      :
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        printf 'review-package: cannot diff untracked file: %s\n' "$file" >&2
        exit "$status"
      fi
    fi
  done
} > "$payload"

if ! hash_output=$(sha256sum "$payload"); then
  printf '%s\n' 'review-package: cannot hash payload' >&2
  exit 1
fi
review_id=${hash_output%% *}
case "$review_id" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) printf '%s\n' 'review-package: invalid SHA-256 output' >&2; exit 1 ;;
esac

package="$tmp_dir/package"
{
  printf '# Review package\nReview-ID: %s\n\n' "$review_id"
  cat "$payload"
} > "$package"

mkdir -p "$(dirname -- "$out")"
mv "$package" "$out"
printf 'wrote %s: Review-ID %s, %s file(s)\n' "$out" "$review_id" "${#manifest_files[@]}"
