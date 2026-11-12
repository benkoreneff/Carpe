#!/bin/bash
# Fails if something that looks like a credential is in the repository's files,
# in any commit, or in an app bundle.
#
#   scripts/check-secrets.sh                 the working tree and the git history
#   scripts/check-secrets.sh path/to/X.app   the same, plus that bundle
#
# Matches are printed cut short, so running this never puts a whole secret on
# screen or in a log.
set -uo pipefail
cd "$(dirname "$0")/.."

# What a real credential looks like. The placeholders in the code ("sk-ant-…",
# "GOCSPX-…") and the fake values in the tests are too short to match.
PATTERNS=(
    'sk-ant-[A-Za-z0-9_-]{20,}'                               # Anthropic API key
    'GOCSPX-[A-Za-z0-9_-]{20,}'                               # Google OAuth client secret
    '[0-9]{6,}-[a-z0-9]{32}\.apps\.googleusercontent\.com'    # Google OAuth client ID
    '1//0[A-Za-z0-9_-]{30,}'                                  # Google refresh token
    'ya29\.[A-Za-z0-9_-]{30,}'                                # Google access token
    'AIza[0-9A-Za-z_-]{35}'                                   # Google API key
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'                      # private key
    'gh[pousr]_[A-Za-z0-9]{36,}'                              # GitHub token
    'github_pat_[A-Za-z0-9_]{40,}'                            # GitHub fine-grained token
    'AKIA[0-9A-Z]{16}'                                        # AWS access key ID
    'xox[baprs]-[A-Za-z0-9-]{20,}'                            # Slack token
)
REGEX=$(IFS='|'; echo "${PATTERNS[*]}")

# Files that hold credentials by their nature, whatever is inside.
SECRET_FILES='(^|/)(client_secret[^/]*\.json|\.env(\.[^/]*)?|[^/]*\.(p8|p12|pem|key|keystore|mobileprovision))$'

found=0

# Reads grep's "where:match" lines and prints "where: first characters…".
# No pattern above can match a colon, so the last colon ends the "where".
redact() {
    awk '{
        cut = 0
        for (i = length($0); i > 0; i--) if (substr($0, i, 1) == ":") { cut = i; break }
        printf "    %s %s…\n", substr($0, 1, cut), substr($0, cut + 1, 10)
    }' | sort -u
}

report() {
    local title=$1 matches=$2
    if [ -n "$matches" ]; then
        echo "FOUND  $title"
        echo "$matches"
        found=1
    else
        echo "ok     $title"
    fi
}

# 1. Every file git tracks or would track: committed, staged, modified and new.
files=$(git ls-files -z --cached --others --exclude-standard \
    | xargs -0 grep -nIoE -e "$REGEX" -- 2>/dev/null | redact)
report "working tree: file contents" "$files"

names=$(git ls-files --cached --others --exclude-standard | grep -E "$SECRET_FILES" | sed 's/^/    /')
report "working tree: credential files" "$names"

# 2. Every commit reachable from any branch, tag or stash.
commits=$(git rev-list --all)
history=""
if [ -n "$commits" ]; then
    history=$(echo "$commits" | xargs -n 100 git grep -nIoE -e "$REGEX" 2>/dev/null | redact)
fi
report "git history: file contents ($(echo "$commits" | grep -c .) commits)" "$history"

everNamed=$(git log --all --format= --name-only --diff-filter=A | sort -u | grep -E "$SECRET_FILES" | sed 's/^/    /')
report "git history: credential files" "$everNamed"

# 3. The app bundle: every file, the executable included.
for app in "$@"; do
    if [ ! -d "$app" ]; then
        echo "error: no bundle at $app"
        exit 2
    fi
    bundle=$(LC_ALL=C grep -raoE -e "$REGEX" -- "$app" 2>/dev/null | redact)
    report "bundle contents: $app" "$bundle"
    bundleNames=$(cd "$app" && find . -type f | sed 's|^\./||' | grep -E "$SECRET_FILES" | sed 's/^/    /')
    report "bundle credential files: $app" "$bundleNames"
done

# Not a failure: files git ignores never leave this Mac through the repository
# or the app. Worth knowing they are in the folder, though.
ignored=$(git ls-files --others --ignored --exclude-standard \
    | grep -vE '^(build\.noindex|dist\.noindex|Carpe\.xcodeproj)/' | grep -E "$SECRET_FILES" | sed -E 's/[0-9]{6,}-[a-z0-9]{32}/<client ID>/; s/^/    /')
if [ -n "$ignored" ]; then
    echo "note   ignored by git, so not in the repository, but in this folder:"
    echo "$ignored"
fi

if [ "$found" -ne 0 ]; then
    echo
    echo "error: credentials found. Remove them (and rotate them if they were ever committed or shared) before releasing."
    exit 1
fi
