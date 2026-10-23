#!/usr/bin/env bash
# Compute the Nix hashes for one DeepSeek Harness release and print a JSON
# entry for versions.json.
#
# Usage: prefetch-dsh-version.sh <version> [version ...]
#
# For each version this resolves the exact tag commit, fetches the source as
# a commit-pinned tarball (deterministic, unlike the leaveDotGit git-clone
# fetch), and then the pnpm dependency store. Hashes are recovered in a
# single download: build the fetcher with an empty hash — the fixed-output
# failure leaves the produced store path behind — and hash that path.
#
# Environment:
#   DSH_REPO      upstream repo (default deepseek-ai/deepseek-harness)
#   NIX_FLAGS     extra flags for every nix call
#
# Output: one JSON object per line (jq-ready), e.g.
#   {"version":"0.2.1-rc.2","rev":"dsh-v0.2.1-rc.2","commit":"<sha>","srcHash":"sha256-...","pnpmDepsHash":"sha256-..."}

set -euo pipefail

DSH_REPO=${DSH_REPO:-deepseek-ai/deepseek-harness}
owner=${DSH_REPO%%/*}
repo=${DSH_REPO#*/}

# Run the repo-local flake's pinned nixpkgs when available so hashes are
# computed with the same nixpkgs the flake builds with.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# --no-update-lock-file: hashing a release must never rewrite the flake's
# own pins.
if nix flake metadata --no-update-lock-file "$script_dir/.." >/dev/null 2>&1; then
  nixpkgs_expr="import (builtins.getFlake \"$script_dir/..\").inputs.nixpkgs {}"
else
  nixpkgs_expr='import <nixpkgs> {}'
fi

# build_expr <expr> → runs it, prints the store path on success.
build_expr() {
  nix build -L --impure --no-link --print-out-paths --no-update-lock-file \
    ${NIX_FLAGS:-} --expr "
      let
        pkgs = $nixpkgs_expr;
      in
      $1
    "
}

# one_pass <make-expr-cmd> <args...> → real hash after a single download.
# <make-expr-cmd> receives the placeholder hash as its last argument and
# prints the Nix expression to build. Building once with the placeholder
# makes the fixed-output derivation fail, and Nix reports the hash it
# actually produced ("got: sha256-…") — which is exactly the value the
# attribute expects. Older Nix prints a store path instead, so both forms
# are handled.
one_pass() {
  local make_expr=$1
  shift
  local log hash path
  log=$(build_expr "$("$make_expr" "$@" "$fake_hash")" 2>&1 || true)
  hash=$(printf '%s\n' "$log" | grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' | tail -1)
  if [ -z "$hash" ]; then
    path=$(printf '%s\n' "$log" | grep -oP 'got path:\s+\K/nix/store/\S+' | tail -1)
    if [ -n "$path" ] && [ -d "$path" ]; then
      hash=$(nix hash path --sri "$path" 2>/dev/null)
    fi
  fi
  if [ -z "$hash" ]; then
    printf '%s\n' "$log" >&2
    echo "prefetch: could not read the hash out of the fixed-output error" >&2
    return 1
  fi
  printf '%s' "$hash"
}

# Resolve the exact tag commit (peeled) once per run. Three paths, because
# github.com's TLS is unreliable from CN networks while api.github.com (via
# an authenticated gh) and codeload keep working:
#   1. gh api (authenticated)
#   2. git ls-remote
#   3. the tag name itself — .git-commit is only a build stamp, and the
#      fetchzip source is pinned by the tag URL, so the hashes are unaffected.
resolve_commit() {
  if [ -n "${commit:-}" ]; then return; fi
  commit=$(timeout 45 gh api "repos/$owner/$repo/git/ref/tags/$rev" --jq '.object.sha' 2>/dev/null || true)
  if [ -n "$commit" ]; then
    otype=$(timeout 45 gh api "repos/$owner/$repo/git/tags/$commit" --jq '.object.type' 2>/dev/null || true)
    if [ "$otype" = "tag" ]; then
      commit=$(timeout 45 gh api "repos/$owner/$repo/git/tags/$commit" --jq '.object.sha' 2>/dev/null || true)
    fi
  fi
  if [ -z "$commit" ]; then
    commit=$(timeout 60 git ls-remote "https://github.com/$owner/$repo" "refs/tags/$rev" "refs/tags/$rev^{}" \
      | awk '$2 ~ /\^\{\}$/ { c = $1 } $2 !~ /\^\{\}$/ && c == "" { c = $1 } END { print c }')
  fi
  if [ -z "$commit" ]; then
    commit="$rev"
    echo "prefetch: could not resolve commit for ${rev}; using the tag name as the build stamp" >&2
  fi
}

# src_expr <hash> → fetchFromGitHub invocation exactly matching dsh.nix's
# commit-pinned branch. Depends on $rev and (resolved) $commit.
src_expr() {
  local hash=$1
  cat <<EOF
(pkgs.fetchzip {
        name = "dsh-src-\$(date +%s%N)";
        url = "https://github.com/$owner/$repo/archive/refs/tags/$rev.tar.gz";
        curlOpts = "--connect-timeout 10 --speed-time 30 --speed-limit 10240 --retry 8";
        postFetch = ''
          echo $commit > \$out/.git-commit
        '';
        hash = "$hash";
      })
EOF
}

# deps_expr <hash> → fetchPnpmDeps invocation exactly matching dsh.nix.
# Depends on $src_hash, $version, and this file's src_expr.
deps_expr() {
  local hash=$1
  cat <<EOF
(pkgs.fetchPnpmDeps {
        name = "dsh-deps-\$(date +%s%N)";
        pname = "deepseek-harness";
        version = "$version";
        src = $(src_expr "$src_hash");
        pnpm = pkgs.pnpm_11;
        fetcherVersion = 4;
        prePnpmInstall = ''
          printf 'fetch-timeout=60000\nfetch-retries=8\nfetch-retry-factor=2\nnetwork-concurrency=4\n' >> .npmrc
          # the registry lookup happens in the build, not in this script
          if [ -n "''\${NIX_NPM_REGISTRY:-}" ]; then
            printf 'registry=%s\n' "\$NIX_NPM_REGISTRY" >> .npmrc
          fi
        '';
        hash = "$hash";
      })
EOF
}

fake_hash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

# A version that could not be prefetched must fail the run: the caller
# appends whatever landed on stdout, so exiting 0 here would turn a broken
# fetch into a silently empty update.
failed=""

for version in "$@"; do
  rev="dsh-v${version}"
  commit=""
  echo "prefetch: computing hashes for ${rev}" >&2

  resolve_commit
  if [ -z "$commit" ]; then
    echo "prefetch: could not resolve commit for ${rev}" >&2
    failed=1
    continue
  fi
  echo "prefetch: ${rev} -> commit ${commit}" >&2

  if ! src_hash=$(one_pass src_expr); then
    echo "prefetch: FAILED src fetch for ${rev}" >&2
    failed=1
    continue
  fi
  echo "prefetch: srcHash for ${rev}: ${src_hash}" >&2

  if ! deps_hash=$(one_pass deps_expr); then
    echo "prefetch: FAILED pnpm deps fetch for ${rev}" >&2
    failed=1
    continue
  fi
  echo "prefetch: pnpmDepsHash for ${rev}: ${deps_hash}" >&2

  printf '{"version":"%s","rev":"%s","commit":"%s","srcHash":"%s","pnpmDepsHash":"%s"}\n' \
    "$version" "$rev" "$commit" "$src_hash" "$deps_hash"
done

[ -z "$failed" ] || exit 1
