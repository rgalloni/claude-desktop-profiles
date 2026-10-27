#!/bin/zsh
# `cdp projects` / `cdp transfer` against fake profiles in a throwaway HOME.
# Real profiles are never read: every path cdp uses hangs off $HOME.
set -uo pipefail
cd "${0:A:h:h}"

fails=0
not() { ! "$@" }
check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    print -- "ok   $name"
  else
    print -- "FAIL $name"
    fails=$((fails + 1))
  fi
}

sandbox=${$(mktemp -d):A}
trap 'rm -rf "$sandbox"' EXIT
AS="$sandbox/Library/Application Support"
A="$AS/Claude-Alpha" B="$AS/Claude-Beta"
cdp() { HOME="$sandbox" zsh bin/cdp "$@" }

# Alpha: project /x/proj (one session + one in a worktree, with /rewind
# history and a sidebar entry carrying account-bound fields) and /y/other.
mkdir -p "$A/claude-config/projects/-x-proj/s1" "$A/claude-config/projects/-x-proj--claude-worktrees-w" \
  "$A/claude-config/projects/-y-other" "$A/claude-config/file-history/s1" \
  "$A/claude-code-sessions/acct/org" "$B/claude-code-sessions/acct2/org2" "$sandbox/.Trash"
print -r -- '{"type":"user","cwd":"/x/proj","sessionId":"s1"}' > "$A/claude-config/projects/-x-proj/s1.jsonl"
print -r -- 'sub' > "$A/claude-config/projects/-x-proj/s1/agent.jsonl"
print -r -- '{"type":"user","cwd":"/x/proj/.claude/worktrees/w","sessionId":"s2"}' > "$A/claude-config/projects/-x-proj--claude-worktrees-w/s2.jsonl"
print -r -- '{"type":"user","cwd":"/y/other","sessionId":"s3"}' > "$A/claude-config/projects/-y-other/s3.jsonl"
print -r -- 'v1' > "$A/claude-config/file-history/s1/f@v1"
# Terminal-only sessions date by transcript mtime; keep them older.
touch -t 202001010000 "$A"/claude-config/projects/*/*.jsonl
print -r -- '{"sessionId":"local_a","cliSessionId":"s1","cwd":"/x/proj","lastActivityAt":1700000000000,"title":"Fix\tbug","bridgeSessionIds":["b1"],"enabledMcpTools":{"x":true},"model":"m"}' \
  > "$A/claude-code-sessions/acct/org/local_a.json"
print -r -- '{"sessionId":"local_c","cliSessionId":"s3","cwd":"/y/other","lastActivityAt":1600000000000,"title":"Other"}' \
  > "$A/claude-code-sessions/acct/org/local_c.json"

out=$(cdp projects alpha)
check "projects lists /x/proj with both sessions" grep -qxF $'/x/proj\t2\t1700000000\tFix bug' <<<"$out"
check "projects lists /y/other" grep -q $'^/y/other\t1\t' <<<"$out"
check "projects sorts newest first" test "${${(f)out}[1]%%$'\t'*}" = /x/proj
check "unknown profile fails" not cdp projects nope
check "dry run succeeds" cdp transfer alpha beta /x/proj --dry-run
check "dry run moves nothing" test ! -e "$B/claude-config"
check "unknown project fails" not cdp transfer alpha beta /nope
check "same profile fails" not cdp transfer alpha alpha /x/proj

check "move succeeds" cdp transfer alpha beta /x/proj/
check "transcript arrived" test -f "$B/claude-config/projects/-x-proj/s1.jsonl"
check "subagent transcript arrived" test -f "$B/claude-config/projects/-x-proj/s1/agent.jsonl"
check "worktree session arrived" test -f "$B/claude-config/projects/-x-proj--claude-worktrees-w/s2.jsonl"
check "rewind history arrived" test -f "$B/claude-config/file-history/s1/f@v1"
check "other project not moved" test ! -e "$B/claude-config/projects/-y-other"
meta="$B/claude-code-sessions/acct2/org2/local_a.json"
check "sidebar entry lands in destination account" test -f "$meta"
check "sidebar entry keeps its session" test "$(plutil -extract cliSessionId raw "$meta")" = s1
check "account-bound fields dropped" not grep -qE 'bridgeSessionIds|enabledMcpTools' "$meta"
check "source transcript removed" test ! -e "$A/claude-config/projects/-x-proj"
check "source rewind history removed" test ! -e "$A/claude-config/file-history/s1"
check "source sidebar entry removed" test ! -e "$A/claude-code-sessions/acct/org/local_a.json"
check "originals kept in the Trash" test -f "$sandbox"/.Trash/cdp-transfer-*/sidebar/local_a.json(N[1])
check "other project left alone" test -f "$A/claude-config/projects/-y-other/s3.jsonl"

# Continued in Beta, then moved back: Alpha gets the newer turns, once.
print -r -- '{"type":"assistant","cwd":"/x/proj","sessionId":"s1"}' >> "$B/claude-config/projects/-x-proj/s1.jsonl"
check "move back succeeds" cdp transfer beta alpha /x/proj
check "moved back with the new turns" test "$(wc -l < "$A/claude-config/projects/-x-proj/s1.jsonl")" -eq 2
check "moved back into the source account" test -f "$A/claude-code-sessions/acct/org/local_a.json"
check "no sidebar duplicate" test "$(print -l "$A"/claude-code-sessions/*/*/local_a.json(N) | wc -l)" -eq 1
check "destination emptied" test ! -e "$B/claude-config/projects/-x-proj"

# Same session diverged on both sides (an old manual copy): refuse, touch nothing.
mkdir -p "$B/claude-config/projects/-x-proj"
print -r -- '{"type":"user","cwd":"/x/proj","sessionId":"s1","other":"branch"}' > "$B/claude-config/projects/-x-proj/s1.jsonl"
check "diverged session refused" not cdp transfer alpha beta /x/proj
check "refusal keeps the source" test -f "$A/claude-config/projects/-x-proj/s1.jsonl"
check "refusal keeps the destination's version" grep -q branch "$B/claude-config/projects/-x-proj/s1.jsonl"

(( fails == 0 )) && print -- "all passed" || { print -- "$fails failed"; exit 1 }
