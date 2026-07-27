#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
baseline_ref=${1:-v0.1.16}

if [[ $# -ge 2 ]]; then
  results_dir=$2
  mkdir -p "$results_dir"
else
  results_dir=$(mktemp -d "${TMPDIR:-/tmp}/safe-rpc-benchmark-results.XXXXXX")
fi

worktree=$(mktemp -d "${TMPDIR:-/tmp}/safe-rpc-benchmark.XXXXXX")
rmdir "$worktree"

cleanup() {
  git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT

export SAFERPC_BENCH_PAYLOADS=${SAFERPC_BENCH_PAYLOADS:-small,1kb,64kb}
export SAFERPC_BENCH_PARALLEL=${SAFERPC_BENCH_PARALLEL:-1,4,16}
export SAFERPC_BENCH_WARMUP=${SAFERPC_BENCH_WARMUP:-1}
export SAFERPC_BENCH_TIME=${SAFERPC_BENCH_TIME:-3}
export SAFERPC_BENCH_MEMORY_TIME=${SAFERPC_BENCH_MEMORY_TIME:-1}
export ELIXIR_ERL_OPTIONS=${ELIXIR_ERL_OPTIONS:-+S 8:8}

mkdir -p "$results_dir/baseline" "$results_dir/current"
git -C "$repo_root" worktree add --detach "$worktree" "$baseline_ref"
mkdir -p "$worktree/bench/support"
cp "$repo_root/bench/safe_rpc_bench.exs" "$worktree/bench/safe_rpc_bench.exs"
cp "$repo_root/bench/support/config.exs" "$worktree/bench/support/config.exs"

(
  cd "$worktree"
  mix deps.get
  SAFERPC_BENCH_SAVE_DIR="$results_dir/baseline" \
    SAFERPC_BENCH_TAG="$baseline_ref" \
    mix run bench/safe_rpc_bench.exs 2>&1 | tee "$results_dir/baseline.txt"
)

current_tag="current-$(git -C "$repo_root" rev-parse --short HEAD)"

if [[ -n $(git -C "$repo_root" status --porcelain) ]]; then
  current_tag="$current_tag-dirty"
fi

(
  cd "$repo_root"
  SAFERPC_BENCH_SAVE_DIR="$results_dir/current" \
    SAFERPC_BENCH_LOAD_DIR="$results_dir/baseline" \
    SAFERPC_BENCH_TAG="$current_tag" \
    mix run bench/safe_rpc_bench.exs 2>&1 | tee "$results_dir/current.txt"
)

printf 'Benchmark results: %s\n' "$results_dir"
