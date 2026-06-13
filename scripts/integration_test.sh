#!/usr/bin/env sh
set -eu

VM_NAME="${SAFERPC_LIMA_VM:-safe-rpc-test}"
PROJECT_DIR="${SAFERPC_PROJECT_DIR:-$(pwd)}"
REMOTE_DIR="${SAFERPC_REMOTE_DIR:-~/safe-rpc-test-src}"

~/.local/bin/limactl shell "$VM_NAME" -- sh -lc "
  rm -rf $REMOTE_DIR &&
  mkdir -p $REMOTE_DIR &&
  tar -C '$PROJECT_DIR' --exclude=_build --exclude=deps --exclude=doc -cf - . | tar -C $REMOTE_DIR -xf - &&
  cd $REMOTE_DIR &&
  mix deps.get >/dev/null &&
  SAFERPC_INTEGRATION=1 SAFERPC_STRESS=1 mix test
"
