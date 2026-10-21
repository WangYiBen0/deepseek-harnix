#!/usr/bin/env bash
# Robustness test driver: build ONE real plugin through mkDshPlugin.
# Usage: test-driver.sh <case.sh>   (case files in .prefetch/cases/)
# Case variables: NAME URL VERSION (npm) | NAME REPO BRANCH KIND LOCK PACKAGE_DIR SUBMODULES AUTO_INSTALL_PEERS (src)
set -u
export XDG_CACHE_HOME=/tmp/nixcache NIX_CONFIG="eval-cache = false
connect-timeout = 10
stalled-download-timeout = 30"
export NIX_NPM_REGISTRY="https://registry.npmmirror.com/"
cd /home/w1ngd1nga5ter/Projects/deepseek-harnix

sha_of() {
  local out
  out=$(timeout 1200 nix build -L --impure --no-link --expr "let pkgs = import <nixpkgs> {}; in $1" 2>&1 |
    grep -oP 'got path: */nix/store/\S+' | tail -1 | awk '{print $3}')
  if [ -z "$out" ] || [ ! -e "$out" ]; then
    return 1
  fi
  if [ -f "$out" ]; then nix hash file --sri "$out"; else nix hash path --sri "$out"; fi
}

safe_name() {
  printf '%s' "$1" | tr '/@' '__'
}

src_fetcher() {
  # $1 = hash placeholder ("") for discovery, or the real hash.
  if [ "${SUBMODULES:-}" = "true" ]; then
    printf 'pkgs.fetchgit { url = "https://github.com/%s.git"; rev = "%s"; fetchSubmodules = true; hash = "%s"; }' "$REPO" "$commit" "$1"
  else
    printf 'pkgs.fetchzip { url = "https://github.com/%s/archive/%s.tar.gz"; hash = "%s"; }' "$REPO" "$commit" "$1"
  fi
}

run_case() {
  local case_file=$1
  # shellcheck disable=SC1090
  source "$case_file"
  : "${KIND:=npm}"
  : "${AUTO_INSTALL_PEERS:=}"
  : "${PACKAGE_DIR:=}"
  local safe log
  safe=$(safe_name "$NAME")
  log=".prefetch/t-$safe.log"
  printf "%-30s" "$NAME"

  local args=""
  case "$KIND" in
    npm)
      local tar_hash
      if ! tar_hash=$(sha_of "pkgs.fetchurl { url = \"$URL\"; hash = \"\"; }"); then
        echo "FAIL  (tarball fetch)"; return 1
      fi
      args="npmName = \"$NAME\"; npmVersion = \"$VERSION\"; hash = \"$tar_hash\";"
      if [ -n "${NPM_LOCKFILE:-}" ]; then
        args="$args npmLockfile = ./$NPM_LOCKFILE;"
      fi
      ;;
    src)
      local commit src_hash deps_hash fetcher_src
      if ! commit=$(timeout 60 gh api "repos/$REPO/commits/$BRANCH" --jq '.sha' 2>/dev/null); then
        echo "FAIL  (commit resolve)"; return 1
      fi
      if ! src_hash=$(sha_of "$(src_fetcher "")"); then
        echo "FAIL  (src fetch)"; return 1
      fi
      if [ "$LOCK" = "pnpm" ]; then
        if ! deps_hash=$(sha_of "pkgs.fetchPnpmDeps { pname = \"dsh-plugin-test\"; version = \"0\"; src = $(src_fetcher "$src_hash"); pnpm = pkgs.pnpm_11; fetcherVersion = 4; hash = \"\"; }"); then
          echo "FAIL  (pnpm deps)"; return 1
        fi
        args="src = $(src_fetcher "$src_hash"); pnpmDepsHash = \"$deps_hash\";"
        if [ "$AUTO_INSTALL_PEERS" = "true" ]; then
          args="$args autoInstallPeers = true;"
        fi
        if [ -n "$PACKAGE_DIR" ]; then
          args="$args packageDir = \"$PACKAGE_DIR\";"
        fi
      else
        if ! deps_hash=$(sha_of "pkgs.fetchNpmDeps { pname = \"dsh-plugin-test\"; version = \"0\"; src = $(src_fetcher "$src_hash"); hash = \"\"; }"); then
          echo "FAIL  (npm deps)"; return 1
        fi
        args="src = $(src_fetcher "$src_hash"); npmDepsHash = \"$deps_hash\";"
      fi
      ;;
  esac

  if timeout 3000 nix build -L --impure --no-link --expr "
      let pkgs = import <nixpkgs> {}; in
      pkgs.callPackage ./pkgs/mkDshPlugin.nix ({ source = null; } // { $args })
    " > "$log" 2>&1; then
    local out
    out=$(grep -oP '/nix/store/\S+' "$log" | head -1 | sed 's|/nix/store/[^-]*-||')
    echo "PASS  $out"
    return 0
  fi
  local reason
  reason=$(grep -oP '(mkDshPlugin: .*|error: .*|ERROR: .*)' "$log" | head -1 | head -c 130)
  echo "FAIL  ${reason:-see $log}"
  return 1
}

for case_file in "$@"; do
  run_case "$case_file" || true
done
