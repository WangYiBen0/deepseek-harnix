#!/usr/bin/env bash
# installCheck for the dsh shell completions.
#
# Existence alone is not a check: a completion script that cannot register
# itself is indistinguishable from a missing one to the user, and that is
# exactly how all three shells silently ended up without completions. Each
# shell is therefore driven through its own completion machinery and the
# words it offers are compared.
#
# Run by installCheckPhase with:
#   dsh_out      the installed dsh ($out)
#   dsh_bash     bash
#   dsh_bashcomp bash-completion
#   dsh_fish     fish
#   dsh_zsh      zsh
#   TMPDIR       scratch space
set -euo pipefail

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

BASH_COMPLETIONS=$dsh_out/share/bash-completion/completions/dsh
FISH_COMPLETIONS=$dsh_out/share/fish/vendor_completions.d/dsh.fish
ZSH_COMPLETIONS=$dsh_out/share/zsh/site-functions/_dsh

for f in "$BASH_COMPLETIONS" "$FISH_COMPLETIONS" "$ZSH_COMPLETIONS"; do
  [ -f "$f" ] || fail "missing completion file: $f"
done

# ── bash ────────────────────────────────────────────────────────────────────
# The file has to be found by bash-completion's own loader (that is what a TAB
# press uses) and then answer with the words a user expects.
XDG_DATA_DIRS=$dsh_out/share:${XDG_DATA_DIRS:-/usr/share} \
  "$dsh_bash/bin/bash" --norc --noprofile -c '
    source "'"$dsh_bashcomp"'/share/bash-completion/bash_completion"
    _comp_load dsh >/dev/null 2>&1
    complete -p dsh 2>/dev/null | grep -q "_dsh" ||
      { echo "bash: dsh completion did not register" >&2; exit 1; }
    try() {
      COMP_WORDS=($1); COMP_CWORD=$2; COMP_LINE="$1"; COMP_POINT=${#1}
      COMPREPLY=()
      _dsh 2>/dev/null
      printf "%s\n" "${COMPREPLY[@]}"
    }
    try "dsh --pro" 1 | grep -qx -- --profile ||
      { echo "bash: --profile flag not completed" >&2; exit 1; }
    try "dsh --profile " 2 | grep -qx web ||
      { echo "bash: profile names not completed" >&2; exit 1; }
    try "dsh --from-default-profile " 2 | grep -qx web ||
      { echo "bash: template names not completed" >&2; exit 1; }
    try "dsh plugin " 2 | grep -qx add ||
      { echo "bash: pnpm subcommands not completed" >&2; exit 1; }
  '

# ── fish ────────────────────────────────────────────────────────────────────
# `complete -C` is fish's own query: the same code path a TAB press takes,
# including the dynamic profile lookup.
DSH_HOME=$TMPDIR/fish-home \
  "$dsh_fish/bin/fish" --no-config -c '
    mkdir -p "$DSH_HOME/profiles/web" "$DSH_HOME/profiles/scratch"
    echo "{}" > "$DSH_HOME/profiles/web/package.json"
    echo "{}" > "$DSH_HOME/profiles/scratch/package.json"
    source "'"$FISH_COMPLETIONS"'"
    complete -C "dsh --pro" | grep -q -- "--profile" ||
      { echo "fish: --profile flag not completed" >&2; exit 1; }
    complete -C "dsh --profile " | grep -q "^web	" ||
      { echo "fish: shipped profiles not completed" >&2; exit 1; }
    complete -C "dsh --profile " | grep -q "^scratch	" ||
      { echo "fish: user profiles not completed" >&2; exit 1; }
    complete -C "dsh plugin " | grep -q "^add	" ||
      { echo "fish: pnpm subcommands not completed" >&2; exit 1; }
  '

# ── zsh ─────────────────────────────────────────────────────────────────────
# `_arguments` only runs inside ZLE, so the completion primitives are stubbed
# and the script's own dispatch is exercised. This still catches a syntax
# error, a missing flag, or a broken branch without needing a tty.
zsh_out=$TMPDIR/zsh-out.txt
"$dsh_zsh/bin/zsh" -f -c '
    _arguments() { print -r -- "ARGUMENTS $*" }
    _alternative() { print -r -- "ALTERNATIVE $*" }
    _describe() { print -r -- "DESCRIBE $*" }
    _files() { print -r -- "FILES" }
    _default() { : }
    source "'"$ZSH_COMPLETIONS"'"
  ' > "$zsh_out" || fail "zsh: completion script failed to run"

grep -q -- '--profile=.*:profile:_dsh_profiles' "$zsh_out" ||
  fail "zsh: --profile does not complete profile names"
grep -q -- '--from-default-profile=.*:template:_dsh_templates' "$zsh_out" ||
  fail "zsh: --from-default-profile does not complete templates"
grep -q -- 'dump-default-config' "$zsh_out" ||
  fail "zsh: --dump-default-config missing from the option list"

# ── all three agree with the CLI they describe ──────────────────────────────
# A flag added to or removed from the launcher must reach every script. fish
# spells long options `-l profile`, the other two `--profile`, so the pattern
# accepts either form.
help=$("$dsh_out/bin/dsh" --help)
for flag in profile from-default-profile patch dump-config \
            dump-config-schema dump-default-config version help; do
  printf '%s\n' "$help" | grep -q -- "--$flag" ||
    fail "dsh --help no longer mentions --$flag"
  for script in "$BASH_COMPLETIONS" "$ZSH_COMPLETIONS"; do
    grep -q -- "--$flag" "$script" ||
      fail "$(basename "$script"): missing --$flag"
  done
  grep -Eq -- "(-l $flag|--$flag)" "$FISH_COMPLETIONS" ||
    fail "dsh.fish: missing --$flag"
done
