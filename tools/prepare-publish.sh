#!/usr/bin/env bash
# Re-stamps this repository's entire history to a GitHub account, then proves it is safe to push.
#
# It never pushes and never adds a remote. It leaves a bundle of the previous history behind, so
# the rewrite is reversible: `git clone <bundle>` gets everything back exactly as it was.
#
#   ./tools/prepare-publish.sh <account>
#
# The account name is the only argument. The email is derived as
# <account>@users.noreply.github.com, which is the address GitHub itself hands out precisely so a
# real one never has to appear in a commit.
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT="${1:-}"
[ -n "$ACCOUNT" ] || { echo "usage: ./tools/prepare-publish.sh <github-account>" >&2; exit 1; }
EMAIL="${PUBLISH_EMAIL:-${ACCOUNT}@users.noreply.github.com}"

ok()   { printf '  \033[32mok  \033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
FAILED=0

# Words that must not appear anywhere: in a file, a commit message, an author, or a path.
#
# Assembled rather than spelled, for the same reason as the key pattern below: written out, this
# file would contain every word it is looking for, and the file scan would report the scanner.
FORBIDDEN="\\b($(printf 'cla%s|cod%s|anthro%s|cop%s|chat%s|open%s' ude ex pic ilot gpt ai))\\b"

step "preconditions"
[ -z "$(git status --porcelain)" ] || { echo "working tree is dirty — commit or stash first" >&2; exit 1; }
if [ -n "$(git remote)" ]; then
  echo "a remote is already configured; this script will not touch it, but check it is the right one:" >&2
  git remote -v >&2
fi
ok "tree clean, $(git rev-list --all --count) commits"

step "backup"
BACKUP="../$(basename "$PWD")-before-$ACCOUNT.bundle"
git bundle create "$BACKUP" --all >/dev/null 2>&1
ok "previous history saved to $BACKUP"

step "restamp identity"
# Every commit, author and committer alike. A history that carries a real name or a previous
# account is as unpublishable as one that carries a key.
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter "
  export GIT_AUTHOR_NAME='$ACCOUNT';    export GIT_AUTHOR_EMAIL='$EMAIL'
  export GIT_COMMITTER_NAME='$ACCOUNT'; export GIT_COMMITTER_EMAIL='$EMAIL'
" --tag-name-filter cat -- --all >/dev/null 2>&1

# Not optional: the pre-rewrite commits survive in the backup ref and the reflog otherwise, and
# `git log --all` will still find them.
git for-each-ref --format='%(refname)' refs/original | xargs -r -n1 git update-ref -d
git reflog expire --expire=now --all
git gc --prune=now --quiet
git config user.name "$ACCOUNT"
git config user.email "$EMAIL"
ok "history restamped to $ACCOUNT <$EMAIL>"

step "scans"

IDS=$(git log --all --format='%an <%ae>%n%cn <%ce>' | sort -u)
if [ "$(echo "$IDS" | wc -l | tr -d ' ')" = "1" ] && [ "$IDS" = "$ACCOUNT <$EMAIL>" ]; then
  ok "one identity in history, and it is the account"
else
  bad "more than one identity in history:"; echo "$IDS" | sed 's/^/       /'
fi

# Captured rather than tested with `grep -q`. Under `pipefail`, a quiet grep closes the pipe the
# instant it matches, the upstream git dies of SIGPIPE, and the pipeline reports failure — so the
# check announced "clean" exactly when it had found something. It passed a history that said the
# word outright, twice, before this was noticed.
MSG_HITS=$(git log --all --format='%an%n%ae%n%cn%n%ce%n%B' | grep -inE "$FORBIDDEN" || true)
if [ -n "$MSG_HITS" ]; then
  bad "history mentions a forbidden word:"; echo "$MSG_HITS" | head -5 | sed 's/^/       /'
else
  ok "no forbidden word in any commit message or author"
fi

PATH_HITS=$(git log --all --name-only --format='' | sort -u | grep -iE "$FORBIDDEN" || true)
if [ -n "$PATH_HITS" ]; then
  bad "a path in history contains a forbidden word:"; echo "$PATH_HITS" | sed 's/^/       /'
else
  ok "no forbidden word in any path, past or present"
fi

# `git grep -E` does not honour \b — it silently matches nothing, so this scan reported clean on
# a file that said the word outright. Its -P engine does honour it, and is verified present below.
git grep -lniP 'a' -- README.md >/dev/null 2>&1 \
  || { echo "git grep has no -P engine; the file scan cannot run" >&2; exit 1; }
TRACKED_HITS=$(git grep -lniP "$FORBIDDEN" -- . ':!lib' || true)
if [ -n "$TRACKED_HITS" ]; then
  bad "tracked files mention a forbidden word:"; echo "$TRACKED_HITS" | sed 's/^/       /'
else
  ok "no forbidden word in any tracked file"
fi

# Historical file *contents*, not just paths. The scan above reads tracked files at HEAD and
# commit messages; neither sees an old version of a file whose current version is clean. This
# scanner's own word list used to be spelled out literally, and three historical blobs of this
# very file carried it for a while — the checks passed the whole time.
BLOB_HITS=""
for obj in $(git rev-list --objects --all | awk '{print $1}' | sort -u); do
  [ "$(git cat-file -t "$obj" 2>/dev/null)" = "blob" ] || continue
  if git cat-file blob "$obj" 2>/dev/null | grep -qiE "$FORBIDDEN"; then
    BLOB_HITS="$BLOB_HITS$(git rev-list --objects --all | awk -v o="$obj" '$1==o {print $2}')
"
  fi
done
if [ -n "$(printf '%s' "$BLOB_HITS" | tr -d '[:space:]')" ]; then
  bad "a forbidden word survives in historical file contents:"
  printf '%s' "$BLOB_HITS" | sort -u | sed 's/^/       /'
else
  ok "no forbidden word in any historical file content"
fi

# A key is the one mistake that cannot be undone by rewriting anything.
#
# The pattern is assembled from pieces rather than written out: spelled literally, this file
# would contain the very string it is looking for, and the first run of this scan duly reported
# itself as a leaked key. Excluding this path instead would have left a hole in the only check
# that matters most.
# Both halves require real content after the "=", not just the name of the variable. Without
# that, the scan matched the previous version of this very line in history, where the word was
# followed by a close paren rather than a secret.
KEYPAT="PRIVATE""_KEY=0x[0-9a-f]{64}|MNEM""ONIC=[\"']?[a-z]{3,}"
KEYS=$(git log --all -p --unified=0 2>/dev/null \
  | grep -E "^\+.*($KEYPAT)" | head -5 || true)
if [ -n "$KEYS" ]; then
  bad "history contains something shaped like a key:"; echo "$KEYS" | sed 's/^/       /'
else
  ok "no private key or mnemonic in history"
fi

# The vault is what Flap and the public read. It must not point at anything of ours: not the
# protocol site, not a social handle, not this repository. The contracts carry no URL at all and
# the submitted UI package must not either — a comment naming the site is still the site, and it
# ships inside the source Flap reviews.
OUTWARD=$(grep -rniE 'https?://|assaymine|twitter\.com|(^|[^a-z])x\.com|t\.me/|discord\.(gg|com)|github\.com' \
  src/AssayFlapVault.sol src/AssayFlapFactory.sol flap-ui/Component.tsx flap-ui/i18n.json \
  flap-ui/manifest.json flap-ui/VaultABI.ts 2>/dev/null || true)
if [ -n "$OUTWARD" ]; then
  bad "the vault surface points outward:"; echo "$OUTWARD" | head -5 | sed 's/^/       /'
else
  ok "nothing in the vault surface points back at us"
fi

if git ls-files --error-unmatch .env >/dev/null 2>&1 || git ls-files --error-unmatch app/.env.local >/dev/null 2>&1; then
  bad "an env file is tracked"
else
  ok "no env file is tracked"
fi

step "build and tests"
export PATH="$HOME/.foundry/bin:$PATH"
if forge test >/dev/null 2>&1; then ok "forge test passes"; else bad "forge test fails"; fi
if node tools/sync-flap-ui-abi.mjs --check >/dev/null 2>&1; then ok "flap ui abi in sync"; else bad "flap ui abi drifted"; fi
if (cd app && npm run --silent check-abi >/dev/null 2>&1); then ok "site abi in sync"; else bad "site abi drifted"; fi
if (cd miner && npm run --silent check-abi >/dev/null 2>&1); then ok "miner abi in sync"; else bad "miner abi drifted"; fi

if [ "$FAILED" = "1" ]; then
  printf '\n\033[31mnot ready to publish — fix the above, then run this again\033[0m\n'
  exit 1
fi

cat <<EOF

$(printf '\033[32mready\033[0m') — history is $ACCOUNT's, and nothing in it says otherwise.

Nothing has been pushed. When the account exists:

    git remote add origin git@github.com:$ACCOUNT/<repo>.git
    git push -u origin main

To undo the rewrite instead:

    git clone $BACKUP restored
EOF
