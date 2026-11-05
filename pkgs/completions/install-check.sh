#!/usr/bin/env bash
# installCheck for the dsh shell completions.
#
# Existence alone is not a check: a completion script that cannot register
# itself is indistinguishable from a missing one to the user, and that is
# exactly how all three shells silently ended up without completions. Each
# shell is therefore driven through its own completion machinery and the
# words it offers are compared.
#
# The `plugin` subcommand is the interesting part now: dsh forwards its
# arguments to pnpm, and the scripts forward them to pnpm's own completion
# server instead of carrying a copied verb table. That delegation is what
# these cases pin down — in particular that a pnpm option (`--save-dev`)
# comes back, which no hand-written list here mentions.
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

# The scripts delegate to `pnpm completion-server`, which is installed beside
# dsh ($out/bin/pnpm). Put that directory on PATH for every shell below so the
# delegation path is the one a user actually gets, not the "pnpm is absent"
# fallback.
export PATH=$dsh_out/bin:$PATH
command -v pnpm >/dev/null || fail "pnpm is not on PATH next to dsh"

# A profile tree with one user profile, so the dynamic lookup has something to
# find beyond the shipped template names.
export DSH_HOME=$TMPDIR/dsh-home
mkdir -p "$DSH_HOME/profiles/web" "$DSH_HOME/profiles/scratch"
printf '{}\n' > "$DSH_HOME/profiles/web/package.json"
printf '{}\n' > "$DSH_HOME/profiles/scratch/package.json"

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
      { echo "bash: shipped profiles not completed" >&2; exit 1; }
    try "dsh --profile " 2 | grep -qx scratch ||
      { echo "bash: user profiles not completed" >&2; exit 1; }
    try "dsh --from-default-profile " 2 | grep -qx web ||
      { echo "bash: template names not completed" >&2; exit 1; }
    try "dsh plugin --profile web " 4 | grep -qx add ||
      { echo "bash: pnpm command list not completed" >&2; exit 1; }
    try "dsh plugin --profile web add " 5 | grep -q -- "--save-prod" ||
      { echo "bash: add options not completed" >&2; exit 1; }
    try "dsh plugin --profile web add --save-d" 5 | grep -qx -- --save-dev ||
      { echo "bash: pnpm option not completed through delegation" >&2; exit 1; }
    try "dsh plugin --profile web ve" 4 | grep -qx version-exemptions ||
      { echo "bash: dsh-owned verb not completed" >&2; exit 1; }
    try "dsh plugin --profile=w" 2 | grep -qx -- --profile=web ||
      { echo "bash: --profile= value not completed" >&2; exit 1; }
    # Faithful delegation, not a special case: pnpm treats a bare option as a
    # top-level one, so `--save-d` there is not an `add` option. Guard the
    # absence so nobody "fixes" it by inventing a mapping.
    if try "dsh plugin --profile web --save-d" 4 | grep -qx -- --save-dev; then
      echo "bash: --save-dev offered where pnpm does not offer it" >&2; exit 1
    fi
  '

# ── fish ────────────────────────────────────────────────────────────────────
# `complete -C` is fish's own query: the same code path a TAB press takes,
# including the dynamic profile lookup and the pnpm subprocess. fish prints
# `<candidate>\t<description>`, so candidates are compared field-wise — a
# literal tab in the pattern would be fragile across editors that normalise
# whitespace.
"$dsh_fish/bin/fish" --no-config -c '
    source "'"$FISH_COMPLETIONS"'"
    # cand <line> → the candidate column, one per line.
    function cand
      complete -C "$argv[1]" | cut -f1
    end
    cand "dsh --pro" | grep -qx -- --profile ||
      { echo "fish: --profile flag not completed" >&2; exit 1; }
    cand "dsh --profile " | grep -qx web ||
      { echo "fish: shipped profiles not completed" >&2; exit 1; }
    cand "dsh --profile " | grep -qx scratch ||
      { echo "fish: user profiles not completed" >&2; exit 1; }
    cand "dsh plugin --profile web " | grep -qx add ||
      { echo "fish: pnpm command list not completed" >&2; exit 1; }
    cand "dsh plugin --profile web add " | grep -qx -- --save-prod ||
      { echo "fish: add options not completed" >&2; exit 1; }
    cand "dsh plugin --profile web add --save-d" | grep -qx -- --save-dev ||
      { echo "fish: pnpm option not completed through delegation" >&2; exit 1; }
    cand "dsh plugin --profile web ve" | grep -qx version-exemptions ||
      { echo "fish: dsh-owned verb not completed" >&2; exit 1; }
    cand "dsh plugin --profile=w" | grep -qx -- --profile=web ||
      { echo "fish: --profile= value not completed" >&2; exit 1; }
    if cand "dsh plugin --profile web --save-d" | grep -qx -- --save-dev; then
      echo "fish: --save-dev offered where pnpm does not offer it" >&2; exit 1
    end
  '

# ── zsh ─────────────────────────────────────────────────────────────────────
# `_arguments` and friends only run inside ZLE, so they are stubbed and the
# script's own dispatch is exercised. `_describe` is what carries a candidate
# list to the user, and it receives the *name* of an array, so the stub
# dereferences it — that is the delegation result, recorded per case.
#
# `_arguments` cannot be observed this way (it is one big option-spec call),
# so the assertions for it are the load-time greps below, plus direct calls to
# the helper it names (`_dsh_profiles`, `_dsh_templates`).
zsh_out=$TMPDIR/zsh-out.txt
"$dsh_zsh/bin/zsh" -f -c '
    print -r -- "LOAD-ARGUMENTS $*" > /dev/null
    _arguments() { print -r -- "LOAD-ARGUMENTS $*" }
    _alternative() { print -r -- "LOAD-ALTERNATIVE $*" }
    _files() { print -r -- "LOAD-FILES" }
    _default() { : }

    # `_describe [-t tag] <label> <array-name>`; expand the name.
    _describe() {
      local -a items
      local arg last
      for arg in "$@"; do last=$arg; done
      items=(${(P)last})
      print -r -- "DESCRIBE-tag ${1}"
      for arg in "${items[@]}"; do print -r -- "DESCRIBE $arg"; done
    }

    source "'"$ZSH_COMPLETIONS"'"

    # words/CURRENT are what a real ZLE supplies; words[CURRENT] is the word
    # being completed, so an empty one is an empty last element.
    _dsh_case() {
      local name=$1
      shift
      print -r -- "CASE $name"
      words=("$@")
      CURRENT=${#words}
      _dsh
    }
    _dsh_helper() {
      print -r -- "CASE $1"
      shift
      "$@"
    }

    _dsh_case load
    _dsh_helper profiles _dsh_profiles
    _dsh_helper templates _dsh_templates
    _dsh_case plugin-command dsh plugin --profile web ""
    _dsh_case plugin-option dsh plugin --profile web add ""
    _dsh_case plugin-delegated-option dsh plugin --profile web add --save-d
    _dsh_case plugin-verb dsh plugin --profile web ve
    _dsh_case plugin-profile-eq dsh plugin --profile=w
    _dsh_case plugin-not-an-add-option dsh plugin --profile web --save-d
  ' > "$zsh_out" || fail "zsh: completion script failed to run"

# The option specs still reach `_arguments`; the two value completers still name
# the helpers asserted below.
grep -q -- '--profile=.*:profile:_dsh_profiles' "$zsh_out" ||
  fail "zsh: --profile does not complete profile names"
grep -q -- '--from-default-profile=.*:template:_dsh_templates' "$zsh_out" ||
  fail "zsh: --from-default-profile does not complete templates"
grep -q -- 'dump-default-config' "$zsh_out" ||
  fail "zsh: --dump-default-config missing from the option list"

# section <name> → the DESCRIBE lines recorded for that case only. `name` is
# the awk variable, not `case`: gawk rejects the latter (it is a keyword).
section() {
  awk -v name="$1" '
    $1 == "CASE" { in_case = ($2 == name) }
    in_case && $1 == "DESCRIBE" { sub(/^DESCRIBE /, ""); print }
  ' "$zsh_out"
}

# The dynamic profile lookup: user profiles from $DSH_HOME plus the templates.
section profiles | grep -qx web || fail "zsh: shipped profiles not completed"
section profiles | grep -qx scratch || fail "zsh: user profiles not completed"
section templates | grep -qx web || fail "zsh: template names not completed"
section plugin-command | grep -qx add ||
  fail "zsh: pnpm command list not completed"
section plugin-option | grep -qx -- --save-prod ||
  fail "zsh: add options not completed"
section plugin-delegated-option | grep -qx -- --save-dev ||
  fail "zsh: pnpm option not completed through delegation"
section plugin-verb | grep -qx version-exemptions ||
  fail "zsh: dsh-owned verb not completed"
section plugin-profile-eq | grep -qx -- --profile=web ||
  fail "zsh: --profile= value not completed"
if section plugin-not-an-add-option | grep -qx -- --save-dev; then
  fail "zsh: --save-dev offered where pnpm does not offer it"
fi

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

# The three verbs dsh handles itself (it forwards everything else to pnpm) must
# be offered by every script, or `dsh plugin version-exemptions` looks like a
# typo.
for verb in allow-version revoke-version version-exemptions; do
  for script in "$BASH_COMPLETIONS" "$ZSH_COMPLETIONS" "$FISH_COMPLETIONS"; do
    grep -q -- "$verb" "$script" ||
      fail "$(basename "$script"): missing dsh-owned verb $verb"
  done
done

# A copied-in pnpm verb table is the bug this replaced: those verbs were not
# pnpm's, and one of them (`update`) does not exist at all. Guard that the
# scripts no longer hardcode such a list — the only completion source for the
# plugin subcommand is pnpm itself.
for script in "$BASH_COMPLETIONS" "$ZSH_COMPLETIONS" "$FISH_COMPLETIONS"; do
  if grep -Eq "(compgen -W|printf '%s..n'|_describe)[^|]*(add install remove update list why)" "$script"; then
    fail "$(basename "$script"): still carries a hardcoded pnpm verb list"
  fi
done
