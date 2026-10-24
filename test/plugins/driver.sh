#!/usr/bin/env bash
# Robustness test driver: build ONE real plugin through mkDshPlugin.
# Usage: test-driver.sh <case.sh>   (case files in .prefetch/cases/)
# Case variables: NAME URL VERSION (npm) | NAME REPO BRANCH KIND LOCK PACKAGE_DIR SUBMODULES AUTO_INSTALL_PEERS NESTED_VENDOR (src)
set -u
export XDG_CACHE_HOME=/tmp/nixcache NIX_CONFIG="eval-cache = false
connect-timeout = 30
stalled-download-timeout = 30"
export NIX_NPM_REGISTRY="https://registry.npmmirror.com/"
cd "$(dirname "$0")/../.."

sha_of() {
  local out attempt
  for attempt in 1 2 3; do
    out=$(timeout 1200 nix build -L --impure --no-link --expr "let pkgs = import <nixpkgs> {}; in $1" 2>&1 |
      grep -oP 'got path: */nix/store/\S+' | tail -1 | awk '{print $3}')
    [ -n "$out" ] && [ -e "$out" ] && break
    sleep 5
  done
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
  printf "%-30s " "$NAME"

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
      if [ -n "${NPM_DEPS_HASH:-}" ]; then
        args="$args npmDepsHash = \"$NPM_DEPS_HASH\";"
      fi
      ;;
    src)
      local commit src_hash deps_hash fetcher_src
      # git ls-remote needs no API quota; gh api is the fallback, and a
      # cached sha keeps the suite runnable while GitHub is flaky.
      commit_cache=".prefetch/commits/${REPO//\//_}-${BRANCH//\//_}"
      for _try in 1 2 3; do
        commit=$(timeout 90 git ls-remote "https://github.com/$REPO.git" "$BRANCH" 2>/dev/null | head -1 | cut -f1)
        [ -n "$commit" ] && break
        commit=$(timeout 90 env XDG_CACHE_HOME="$PWD/.prefetch/ghcache" \
          gh api "repos/$REPO/commits/$BRANCH" --jq '.sha' 2>/dev/null)
        [ -n "$commit" ] && break
        sleep 5
      done
      if [ -z "$commit" ] && [ -f "$commit_cache" ]; then
        commit=$(cat "$commit_cache")
        echo "      (using cached commit ${commit:0:12})"
      fi
      if [ -z "$commit" ]; then
        echo "FAIL  (commit resolve)"; return 1
      fi
      mkdir -p "$(dirname "$commit_cache")"
      printf '%s\n' "$commit" > "$commit_cache"
      if ! src_hash=$(sha_of "$(src_fetcher "")"); then
        echo "FAIL  (src fetch)"; return 1
      fi
      if [ "$LOCK" = "pnpm" ]; then
        if ! deps_hash=$(sha_of "pkgs.fetchPnpmDeps { pname = \"dsh-plugin-test\"; version = \"0\"; src = $(src_fetcher "$src_hash"); pnpm = pkgs.pnpm_11; fetcherVersion = 4; hash = \"\"; }"); then
          echo "FAIL  (pnpm deps)"; return 1
        fi
        args="source = $(src_fetcher "$src_hash"); pnpmDepsHash = \"$deps_hash\";"
        if [ "$AUTO_INSTALL_PEERS" = "true" ]; then
          args="$args autoInstallPeers = true;"
        fi
        if [ -n "$PACKAGE_DIR" ]; then
          args="$args packageDir = \"$PACKAGE_DIR\";"
        fi
        if [ -n "${NESTED_VENDOR:-}" ]; then
          local nested_expr nested_hash
          nested_expr="pkgs.fetchPnpmDeps { pname = \"dsh-plugin-test-nested\"; version = \"0\"; src = ($(src_fetcher "$src_hash")) + \"/$NESTED_VENDOR\"; pnpm = pkgs.pnpm_11; fetcherVersion = 4; hash = \"\"; }"
          if ! nested_hash=$(sha_of "$nested_expr"); then
            echo "FAIL  (nested pnpm deps)"; return 1
          fi
          args="$args nestedPnpmDeps = pkgs.fetchPnpmDeps { pname = \"dsh-plugin-test-nested\"; version = \"0\"; src = ($(src_fetcher "$src_hash")) + \"/$NESTED_VENDOR\"; pnpm = pkgs.pnpm_11; fetcherVersion = 4; hash = \"$nested_hash\"; }; nestedPnpmDir = \"$NESTED_VENDOR\";"
          if [ -n "${BUILD_SCRIPT:-}" ]; then
            args="$args npmBuildScript = \"$BUILD_SCRIPT\";"
          fi
        fi
      else
        if ! deps_hash=$(sha_of "pkgs.fetchNpmDeps { pname = \"dsh-plugin-test\"; version = \"0\"; src = $(src_fetcher "$src_hash"); hash = \"\"; }"); then
          echo "FAIL  (npm deps)"; return 1
        fi
        args="source = $(src_fetcher "$src_hash"); npmDepsHash = \"$deps_hash\";"
      fi
      ;;
  esac

  if [ -n "${NPM_REGISTRY:-}" ]; then
    args="$args npmRegistry = \"$NPM_REGISTRY\";"
  fi

  local expr="let pkgs = import <nixpkgs> {}; in
      pkgs.callPackage ./pkgs/mkDshPlugin.nix ({ source = null; } // { $args })"

  # First attempt may fail on a missing fixed-output hash; the mismatch
  # message carries the real digest, so bootstrap it and retry once.
  if ! timeout 3000 nix build -L --impure --no-link --expr "$expr" > "$log" 2>&1; then
    local got
    got=$(grep -aoP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' "$log" | tail -1)
    if [ -n "$got" ]; then
      if grep -q 'npm-deps' "$log"; then
        args="$args npmDepsHash = \"$got\";"
      elif grep -q 'pnpm-deps' "$log"; then
        args="$args pnpmDepsHash = \"$got\";"
      fi
      expr="let pkgs = import <nixpkgs> {}; in
      pkgs.callPackage ./pkgs/mkDshPlugin.nix ({ source = null; } // { $args })"
      echo "      (bootstrapped deps hash, retrying)"
    fi
  fi

  local link=".prefetch/out-$safe"
  rm -f "$link"
  if timeout 3000 nix build -L --impure --out-link "$link" --expr "$expr" > "$log" 2>&1; then
    local out pkg_ok
    out=$(readlink -f "$link")
    pkg_ok=no
    if [ -f "$out/package.json" ] && grep -q '"dsh"' "$out/package.json"; then
      pkg_ok=yes
    fi
    echo "PASS  ${out##*/}  (plugin-ok=$pkg_ok)"
    return 0
  fi
  local reason
  reason=$(grep -oP '(mkDshPlugin: .*|error: .*|ERROR: .*)' "$log" | head -1 | head -c 130)
  echo "FAIL  ${reason:-see $log}"
  return 1
}

for case_file in "$@"; do
  # Case files are sourced into this shell: clear every knob first so one
  # case cannot inherit another's configuration.
  unset NAME VERSION URL REPO BRANCH KIND LOCK PACKAGE_DIR SUBMODULES \
    AUTO_INSTALL_PEERS NESTED_VENDOR BUILD_SCRIPT NPM_LOCKFILE NPM_REGISTRY \
    NPM_DEPS_HASH PNPM_DEPS_HASH
  run_case "$case_file" || true
done
