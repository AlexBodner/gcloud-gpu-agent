---
name: gpu-vm
description: Launch GPU VMs on Google Cloud (GCE) and run commands on them over SSH. Use when the user wants to spin up a cloud GPU instance (L4/T4/V100/A100/H100), train or run code on a remote GPU, push a local repo to a VM, stream remote logs, or manage (create/ssh/stop/delete) GPU VMs. Triggers: "launch a GPU VM", "run this on a cloud GPU", "create an L4/A100 instance", "send commands to the VM".
---

# GPU VM on Google Cloud

Create and drive a GCE GPU VM from the terminal. All actions go through the
bundled `gpu-vm.sh` (a `gcloud` wrapper). Each command runs locally and executes
on the VM via `gcloud compute ssh --command`, so you (Claude) can run jobs and
read their output without an interactive shell.

Call the script as `bash "$CLAUDE_PLUGIN_ROOT/gpu-vm.sh" <cmd>`.

## Before anything: check prerequisites

These are the user's to do once; you cannot do the interactive login.
```bash
gcloud auth list --filter=status:ACTIVE --format="value(account)"   # must print an account
gcloud config get-value project                                     # must print a project
```
If either is empty, tell the user to run `gcloud auth login` (suggest `! gcloud auth login` in-session) and `gcloud config set project <ID>`. If `gcloud` itself is missing: `brew install --cask google-cloud-sdk`.

Also confirm GPU quota before creating (avoids a confusing failure):
```bash
gcloud compute regions describe us-central1 --format="value(quotas)" | tr ';' '\n' | grep -i gpus
```
Quota 0 → the user must request it in IAM & Admin → Quotas (can take time).

## Configuration (env vars)

Set per-invocation; defaults in parentheses:
`NAME` (gpu-vm) · `ZONE` (us-central1-a) · `GPU` (nvidia-l4) · `COUNT` (1) ·
`MACHINE` (auto from GPU) · `DISK_SIZE` (200GB) · `IMAGE_FAMILY`
(common-cu129-ubuntu-2204-nvidia-580) · `IMAGE_PROJECT` (deeplearning-platform-release) ·
`SPOT` (0; set 1 for cheaper preemptible instances).

GPU → machine auto-mapping: `nvidia-l4`→g2-standard-8, `nvidia-tesla-t4`/`-v100`→n1-standard-8,
`nvidia-tesla-a100`→a2-highgpu, `nvidia-a100-80gb`→a2-ultragpu, `nvidia-h100-80gb`→a3-highgpu-8g.
(A2/A3 bundle the GPU; the script omits `--accelerator` for them automatically.)

## Typical flow

```bash
S="$CLAUDE_PLUGIN_ROOT/gpu-vm.sh"
NAME=ml-l4 GPU=nvidia-l4 ZONE=us-central1-a bash "$S" create
NAME=ml-l4 ZONE=us-central1-a bash "$S" status                 # verify nvidia-smi sees the GPU
NAME=ml-l4 ZONE=us-central1-a bash "$S" push ~/path/to/repo    # git archive HEAD → scp (works on PRIVATE repos)
NAME=ml-l4 ZONE=us-central1-a bash "$S" ssh "cd repo && pip install -r requirements.txt"
NAME=ml-l4 ZONE=us-central1-a bash "$S" run "cd repo && python train.py" train   # long job in tmux
NAME=ml-l4 ZONE=us-central1-a bash "$S" logs "repo/train.log"  # tail -f (Ctrl-C to stop)
NAME=ml-l4 ZONE=us-central1-a bash "$S" pull repo/outputs ./outputs
NAME=ml-l4 ZONE=us-central1-a bash "$S" stop                   # or: delete
```

Use **one** zone consistently for a given VM (pass the same `ZONE` every time).

## Commands

`create` · `push <dir> [dest]` · `ssh "<cmd>"` (one-shot, returns output) ·
`shell` (interactive) · `run "<cmd>" [session]` (tmux, survives disconnect,
logs to `~/<session>.log`) · `wait [session]` (block until the tmux session ends) ·
`logs <remote-file>` · `status` (tmux + nvidia-smi) · `pull <remote> [local]` ·
`put <local> <remote>` · `list` · `start` · `stop` · `delete`.

## Operational notes (learned the hard way)

- **Long jobs:** always use `run` (tmux), never `ssh` for something that takes
  minutes — the SSH command would block. Then poll with `status`/`logs`. For
  multi-minute setup/installs, run the `ssh`/`push` command as a **background**
  Bash task and read its output when notified.
- **First boot:** right after `create`, SSH and `nvidia-smi` need ~1-2 min
  (boot + driver + key propagation). Retry a few times before concluding failure.
- **STOCKOUT** (`does not have enough resources` / `currently unavailable`): the
  GPU is momentarily out of stock in that zone — NOT a quota issue. Retry another
  zone in the same region (quota is regional), e.g. `ZONE=us-central1-c ... create`.
- **Image family not found:** families get retired. Discover current ones:
  `gcloud compute images list --project deeplearning-platform-release --filter="family~cu12" --format="value(family)" | sort -u`
- **Private git repo:** `push` uses `git archive HEAD` + scp, so no GitHub
  credentials are needed on the VM. Only committed files are sent — commit first.
- **Cost (say this to the user):** GPU VMs bill while RUNNING. Always `stop`
  (keeps disk) or `delete` (frees everything) when done. Remind them.
- **Confirm before `delete`** unless the user clearly authorized it.
- **Waiting for a job to finish:** use `wait <session>` (it checks `tmux
  has-session`). Do NOT hand-roll `while pgrep -f <script>; do ...` — the wait
  loop's own command line contains `<script>`, so `pgrep -f` matches itself and
  never exits.
