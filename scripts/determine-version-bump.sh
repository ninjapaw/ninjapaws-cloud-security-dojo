#!/usr/bin/env bash

# Determines the SemVer bump (major|minor|patch) for the next release.
#
# A deterministic Conventional Commits heuristic always runs first and never
# requires network access. When a GITHUB_TOKEN is available, GitHub Models is
# asked to classify the same commit range; its result only ever escalates the
# heuristic (e.g. heuristic=patch, AI=minor -> minor), never downgrades it, so
# a missing/failed/unavailable AI call always falls back safely to the
# heuristic result.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SINCE_TAG=""
USE_AI=true
while (($# > 0)); do
    case "$1" in
        --since) SINCE_TAG="$2"; shift 2 ;;
        --no-ai) USE_AI=false; shift ;;
        --help|-h)
            cat <<'EOF'
Usage: scripts/determine-version-bump.sh [--since <tag>] [--no-ai]

Prints (and, inside GitHub Actions, also appends to GITHUB_OUTPUT):
  bump=<major|minor|patch>
  source=<heuristic (Conventional Commits)|GitHub Models (...)>
  reason=<short explanation>
  since=<tag commits were compared against, or <none>>
EOF
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SINCE_TAG" ]]; then
    SINCE_TAG="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname 2>/dev/null | grep -Ev -- '-' | head -n 1 || true)"
fi

if [[ -n "$SINCE_TAG" ]]; then
    commit_log="$(git log "${SINCE_TAG}..HEAD" --pretty='%s%n%b' 2>/dev/null || true)"
else
    commit_log="$(git log --pretty='%s%n%b' 2>/dev/null || true)"
fi

rank() {
    case "$1" in
        major) echo 3 ;;
        minor) echo 2 ;;
        *) echo 1 ;;
    esac
}

heuristic_bump="patch"
if grep -Eiq 'BREAKING[ -]CHANGE|^[a-zA-Z]+(\([^)]*\))?!:' <<<"$commit_log"; then
    heuristic_bump="major"
elif grep -Eq '^feat(\([^)]*\))?:' <<<"$commit_log"; then
    heuristic_bump="minor"
fi

ai_bump=""
ai_reason=""
if [[ "$USE_AI" == true && -n "${GITHUB_TOKEN:-}" && -n "$commit_log" ]] && command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    request_body="$(node -e '
        const commits = require("fs").readFileSync(0, "utf8");
        const payload = {
            model: "openai/gpt-4o-mini",
            temperature: 0,
            messages: [
                {
                    role: "system",
                    content: "You classify software changes into a SemVer release bump: major, minor, or patch, following Conventional Commits. Breaking changes or removed/changed public behavior are major. New backward-compatible features are minor. Everything else (fixes, docs, chores, refactors) is patch. Respond with ONLY a JSON object: {\"bump\":\"major|minor|patch\",\"reason\":\"one short sentence\"}."
                },
                { role: "user", content: "Classify the required release bump for these commit messages:\n\n" + commits }
            ]
        };
        process.stdout.write(JSON.stringify(payload));
    ' <<<"$commit_log" 2>/dev/null || true)"

    if [[ -n "$request_body" ]]; then
        ai_response="$(curl -fsS --max-time 20 \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$request_body" \
            "https://models.github.ai/inference/chat/completions" 2>/dev/null || true)"

        if [[ -n "$ai_response" ]]; then
            ai_bump="$(node -e '
                try {
                    const res = JSON.parse(require("fs").readFileSync(0, "utf8"));
                    const text = res.choices?.[0]?.message?.content ?? "";
                    const match = text.match(/\{[\s\S]*\}/);
                    const parsed = JSON.parse(match ? match[0] : text);
                    const bump = String(parsed.bump || "").toLowerCase();
                    if (["major", "minor", "patch"].includes(bump)) process.stdout.write(bump);
                } catch { /* leave empty: fall back to heuristic */ }
            ' <<<"$ai_response" 2>/dev/null || true)"

            if [[ -n "$ai_bump" ]]; then
                ai_reason="$(node -e '
                    try {
                        const res = JSON.parse(require("fs").readFileSync(0, "utf8"));
                        const text = res.choices?.[0]?.message?.content ?? "";
                        const match = text.match(/\{[\s\S]*\}/);
                        const parsed = JSON.parse(match ? match[0] : text);
                        process.stdout.write(String(parsed.reason || ""));
                    } catch { /* no reason available */ }
                ' <<<"$ai_response" 2>/dev/null || true)"
            fi
        fi
    fi
fi

final_bump="$heuristic_bump"
source="heuristic (Conventional Commits)"
if [[ -n "$ai_bump" && "$(rank "$ai_bump")" -gt "$(rank "$heuristic_bump")" ]]; then
    final_bump="$ai_bump"
    source="GitHub Models (escalated over heuristic: $heuristic_bump)"
fi

reason="${ai_reason:-Derived from commit subjects since ${SINCE_TAG:-the start of history}.}"

echo "bump=$final_bump"
echo "source=$source"
echo "reason=$reason"
echo "since=${SINCE_TAG:-<none>}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "bump=$final_bump"
        echo "source=$source"
        echo "reason=$reason"
    } >> "$GITHUB_OUTPUT"
fi
