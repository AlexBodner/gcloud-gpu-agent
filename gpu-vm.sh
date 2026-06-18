#!/usr/bin/env bash
# gpu-vm — spin up a Google Cloud GPU VM and run code on it, in one command.
#
# A thin, dependency-free wrapper around `gcloud`. Every subcommand runs on YOUR
# machine and executes on the VM via `gcloud compute ssh --command`, so you (or an
# AI agent) can drive a remote GPU and read its output without an interactive shell.
#
# Repo:    https://github.com/AlexBodner/gpu-vm
# License: MIT
#
# One-time setup on your machine:
#   1) Install gcloud:        brew install --cask google-cloud-sdk   (or see cloud.google.com/sdk)
#   2) Log in:                gcloud auth login
#   3) Pick a project:        gcloud config set project YOUR_PROJECT_ID
#   4) Make sure you have GPU quota (IAM & Admin → Quotas).
#
# Config via env vars (defaults in parentheses) — set per command:
set -euo pipefail

VERSION="1.0.0"

NAME="${NAME:-gpu-vm}"
ZONE="${ZONE:-us-central1-a}"
GPU="${GPU:-nvidia-l4}"            # nvidia-l4 | nvidia-tesla-t4 | nvidia-tesla-v100 | nvidia-tesla-a100 | nvidia-a100-80gb | nvidia-h100-80gb
COUNT="${COUNT:-1}"
MACHINE="${MACHINE:-}"            # empty = auto from GPU
DISK_SIZE="${DISK_SIZE:-200GB}"
IMAGE_FAMILY="${IMAGE_FAMILY:-common-cu129-ubuntu-2204-nvidia-580}"
IMAGE_PROJECT="${IMAGE_PROJECT:-deeplearning-platform-release}"
SPOT="${SPOT:-0}"                 # 1 = cheaper preemptible instance (can be reclaimed)

SELF="$(basename "$0")"

# Default machine per GPU. A2/A3 families bundle the GPU (no --accelerator flag).
auto_machine() {
  case "${GPU}" in
    nvidia-tesla-a100)             echo "a2-highgpu-${COUNT}g" ;;
    nvidia-a100-80gb)              echo "a2-ultragpu-${COUNT}g" ;;
    nvidia-h100-80gb)              echo "a3-highgpu-8g" ;;
    nvidia-l4)                     echo "g2-standard-8" ;;
    *)                             echo "n1-standard-8" ;;   # T4 / V100 / other
  esac
}

is_bundled_gpu() { [[ "${1}" == a2-* || "${1}" == a3-* ]]; }

# ------------------------------------------------------------------ helpers

require_gcloud() {
  command -v gcloud >/dev/null 2>&1 || {
    echo "❌ gcloud not found. Install: brew install --cask google-cloud-sdk"; exit 1; }
  gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q . \
    || { echo "❌ No active account. Run: gcloud auth login"; exit 1; }
  gcloud config get-value project 2>/dev/null | grep -q . \
    || { echo "❌ No project set. Run: gcloud config set project YOUR_PROJECT_ID"; exit 1; }
}

remote() { gcloud compute ssh "${NAME}" --zone "${ZONE}" --command "$1"; }

# --------------------------------------------------------------- subcommands

cmd_create() {
  local machine; machine="${MACHINE:-$(auto_machine)}"
  echo "🚀 Creating ${NAME} (${machine}, ${COUNT}x ${GPU}) in ${ZONE}..."
  local args=(
    "${NAME}" --zone="${ZONE}" --machine-type="${machine}"
    --image-family="${IMAGE_FAMILY}" --image-project="${IMAGE_PROJECT}"
    --maintenance-policy=TERMINATE --boot-disk-size="${DISK_SIZE}"
    --metadata="install-nvidia-driver=True"
  )
  is_bundled_gpu "${machine}" || args+=( --accelerator="type=${GPU},count=${COUNT}" )
  [[ "${SPOT}" == "1" ]] && args+=( --provisioning-model=SPOT --instance-termination-action=STOP )
  gcloud compute instances create "${args[@]}"
  echo "✅ Created. First boot installs the driver (~1-2 min)."
  echo "   Next: ${SELF} status   (confirm nvidia-smi sees the GPU)"
  echo "💸 Billing runs while the VM is RUNNING. '${SELF} stop' when idle, '${SELF} delete' when done."
}

# Upload a local repo/dir to the VM. For a git repo, uses `git archive HEAD`
# (committed files only — works with PRIVATE repos, no credentials on the VM).
cmd_push() {
  local src="${1:-.}" dest="${2:-$(basename "$(cd "${1:-.}" && pwd)")}"
  local tar="/tmp/gpu_vm_push_$$.tar.gz"
  if git -C "${src}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "📦 git archive ${src} (HEAD — committed files only)..."
    ( cd "${src}" && git archive --format=tar.gz -o "${tar}" HEAD )
  else
    echo "📦 Packing ${src} (tar)..."
    tar czf "${tar}" -C "$(dirname "${src}")" "$(basename "${src}")"
  fi
  gcloud compute scp "${tar}" "${NAME}:~/_push.tar.gz" --zone "${ZONE}"
  remote "set -e; rm -rf ${dest} && mkdir -p ${dest} && tar xzf _push.tar.gz -C ${dest} && rm _push.tar.gz"
  rm -f "${tar}"
  echo "✅ Uploaded to ~/${dest} on the VM."
}

cmd_ssh()   { remote "$1"; }                                   # one-shot command, returns output
cmd_shell() { gcloud compute ssh "${NAME}" --zone "${ZONE}"; } # interactive SSH

# Run a long command in tmux (survives disconnect). The session ENDS when the job
# finishes (no `exec bash`), so `wait` can detect completion. Logs to a file.
cmd_run() {
  local cmd="$1" session="${2:-job}"
  echo "🏃 Launching in tmux '${session}' (log: ~/${session}.log)..."
  remote "tmux new-session -d -s ${session} '${cmd} 2>&1 | tee ~/${session}.log'"
  echo "✅ Running. Logs: ${SELF} logs ${session}.log   |   wait for end: ${SELF} wait ${session}"
}

# Block until the tmux session ends. Uses `tmux has-session`, NOT `pgrep -f
# <script>` (which matches its own command line and never exits).
cmd_wait() {
  local session="${1:-job}"
  echo "⏳ Waiting for tmux session '${session}' to finish..."
  remote "while tmux has-session -t ${session} 2>/dev/null; do sleep 10; done; echo SESSION_DONE; tail -n 20 ~/${session}.log 2>/dev/null"
}

cmd_logs()   { remote "tail -n 40 -f '${1:?usage: logs <remote-file>}'"; }
cmd_status() { remote "tmux ls 2>/dev/null || echo '(no tmux sessions)'; echo ---; nvidia-smi"; }
cmd_pull()   { gcloud compute scp --recurse --zone "${ZONE}" "${NAME}:~/${1:?usage: pull <remote> [local]}" "${2:-.}"; }
cmd_put()    { gcloud compute scp --recurse --zone "${ZONE}" "${1:?usage: put <local> <remote>}" "${NAME}:~/${2:?}"; }
cmd_list()   { gcloud compute instances list; }
cmd_start()  { echo "▶️  Starting ${NAME}..."; gcloud compute instances start "${NAME}" --zone "${ZONE}"; }
cmd_stop()   { echo "⏸  Stopping ${NAME} (disk is kept)..."; gcloud compute instances stop "${NAME}" --zone "${ZONE}"; }
cmd_delete() { echo "🗑  Deleting ${NAME}..."; gcloud compute instances delete "${NAME}" --zone "${ZONE}" --quiet; }

usage() {
  cat <<EOF
gpu-vm ${VERSION} — spin up a Google Cloud GPU VM and run code on it.

Usage: ${SELF} <command> [args]

  create                      create the VM (GPU from \$GPU, zone from \$ZONE)
  push <dir> [dest]           upload a local repo/dir (git archive for git repos)
  ssh "<cmd>"                 run one command on the VM, return its output
  shell                       open an interactive SSH session
  run "<cmd>" [session]       run a long job in tmux (survives disconnect)
  wait [session]              block until the tmux session ends
  logs <remote-file>          tail -f a remote log file
  status                      tmux sessions + nvidia-smi
  pull <remote> [local]       download files from the VM
  put <local> <remote>        upload files to the VM
  list                        list all instances
  start | stop | delete       lifecycle (stop keeps disk; delete frees everything)

Config (env vars): NAME ZONE GPU COUNT MACHINE DISK_SIZE IMAGE_FAMILY IMAGE_PROJECT SPOT
Example: NAME=ml GPU=nvidia-a100-80gb ZONE=us-central1-c ${SELF} create
EOF
}

# --------------------------------------------------------------------- main

ACTION="${1:-}"; shift || true
case "${ACTION}" in
  create) require_gcloud; cmd_create ;;
  push)   require_gcloud; cmd_push "$@" ;;
  ssh)    require_gcloud; cmd_ssh "$@" ;;
  shell)  require_gcloud; cmd_shell ;;
  run)    require_gcloud; cmd_run "$@" ;;
  wait)   require_gcloud; cmd_wait "$@" ;;
  logs)   require_gcloud; cmd_logs "$@" ;;
  status) require_gcloud; cmd_status ;;
  pull)   require_gcloud; cmd_pull "$@" ;;
  put)    require_gcloud; cmd_put "$@" ;;
  list)   require_gcloud; cmd_list ;;
  start)  require_gcloud; cmd_start ;;
  stop)   require_gcloud; cmd_stop ;;
  delete) require_gcloud; cmd_delete ;;
  version|--version|-v) echo "gpu-vm ${VERSION}" ;;
  help|--help|-h|"") usage ;;
  *) echo "Unknown command: ${ACTION}"; echo; usage; exit 1 ;;
esac
