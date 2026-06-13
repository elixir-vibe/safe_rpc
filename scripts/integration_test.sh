#!/usr/bin/env sh
set -eu

VM_NAME="${SAFERPC_LIMA_VM:-safe-rpc-test}"
PROJECT_DIR="${SAFERPC_PROJECT_DIR:-$(pwd)}"
REMOTE_DIR="${SAFERPC_REMOTE_DIR:-~/safe-rpc-test-src}"
LIMACTL="${LIMACTL:-limactl}"

if ! command -v "$LIMACTL" >/dev/null 2>&1; then
  if [ -x "$HOME/.local/bin/limactl" ]; then
    LIMACTL="$HOME/.local/bin/limactl"
  else
    echo "limactl not found. Install Lima or set LIMACTL=/path/to/limactl." >&2
    exit 127
  fi
fi

"$LIMACTL" shell "$VM_NAME" -- sh -lc "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
tar -C "$PROJECT_DIR" --exclude=_build --exclude=deps --exclude=doc -cf - . |
  "$LIMACTL" shell "$VM_NAME" -- tar -C "$REMOTE_DIR" -xf -

"$LIMACTL" shell "$VM_NAME" -- sh -lc "
  cd $REMOTE_DIR &&
  mix deps.get >/dev/null &&
  SAFERPC_INTEGRATION=1 SAFERPC_STRESS=1 mix test
"
