#!/usr/bin/env bash
# gpu-vm installer. Downloads gpu-vm.sh to ~/.local/bin/gpu-vm and makes it executable.
#
#   curl -fsSL https://raw.githubusercontent.com/AlexBodner/gpu-vm/main/install.sh | bash
#
set -euo pipefail

REPO="${GPU_VM_REPO:-AlexBodner/gpu-vm}"
BRANCH="${GPU_VM_BRANCH:-main}"
BIN_DIR="${GPU_VM_BIN_DIR:-$HOME/.local/bin}"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/gpu-vm.sh"

mkdir -p "${BIN_DIR}"
echo "⬇️  Downloading gpu-vm from ${URL}"
curl -fsSL "${URL}" -o "${BIN_DIR}/gpu-vm"
chmod +x "${BIN_DIR}/gpu-vm"
echo "✅ Installed to ${BIN_DIR}/gpu-vm"

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "⚠️  ${BIN_DIR} is not on your PATH. Add this to your shell rc:"
     echo "      export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac

echo
echo "Next:"
echo "  gpu-vm help"
echo "  gcloud auth login && gcloud config set project YOUR_PROJECT_ID"
echo "  GPU=nvidia-l4 ZONE=us-central1-a gpu-vm create"
