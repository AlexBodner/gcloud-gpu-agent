# gpu-vm

**Spin up a Google Cloud GPU VM and run your code on it — in one command.**

No Terraform, no Python, no SDK. Just a single ~200-line Bash script that wraps
`gcloud`. Create an L4 / A100 / H100 box, push your repo, launch training in a
detached session, stream the logs, pull your results, and shut it down — all from
your terminal. Because every command returns its output to your shell, it's also
perfect for **AI coding agents** (Claude Code, etc.) to drive a remote GPU.

```bash
GPU=nvidia-l4 ZONE=us-central1-a gpu-vm create     # 🚀 a 24GB GPU box
gpu-vm push ~/my-project                            # 📦 upload (private repos OK)
gpu-vm run "cd my-project && python train.py" train # 🏃 detached job in tmux
gpu-vm logs train.log                               # 📜 stream the logs
gpu-vm pull my-project/outputs ./outputs            # ⬇️  bring results home
gpu-vm stop                                         # ⏸  stop billing (disk kept)
```

---

## Why

Renting a cloud GPU for an afternoon shouldn't require learning an
infrastructure framework. The console is clicky, raw `gcloud` is verbose, and
notebooks die when your laptop sleeps. `gpu-vm` gives you the five verbs you
actually use — **create, push, run, pull, stop** — with sane GPU defaults and the
gotchas (stockouts, first-boot driver install, private-repo upload, tmux jobs)
already handled.

- 🧩 **One file, zero deps.** Pure Bash + `gcloud`. Read it in two minutes.
- 🤖 **Agent-friendly.** Each command runs locally and returns the VM's output —
  no interactive shell — so an AI agent can run jobs and read results.
- 🔒 **Private repos just work.** `push` ships `git archive HEAD` over scp; no
  GitHub credentials ever land on the VM.
- 🧵 **Long jobs survive disconnects.** `run` launches inside tmux; `wait` blocks
  until it's done without the classic `pgrep` self-match footgun.
- 💸 **Cost-aware by default.** Reminds you to `stop`/`delete`; `SPOT=1` for
  cheap preemptible instances.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/AlexBodner/gpu-vm/main/install.sh | bash
```

This drops `gpu-vm` into `~/.local/bin`. Make sure that's on your `PATH`.

<details>
<summary>Manual install</summary>

```bash
curl -fsSL https://raw.githubusercontent.com/AlexBodner/gpu-vm/main/gpu-vm.sh \
  -o ~/.local/bin/gpu-vm && chmod +x ~/.local/bin/gpu-vm
```
Or just clone and run `./gpu-vm.sh`.
</details>

### Prerequisites (one time)

```bash
brew install --cask google-cloud-sdk     # or: https://cloud.google.com/sdk/docs/install
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

You also need **GPU quota**. New projects often start at 0 — request it under
**IAM & Admin → Quotas** (search e.g. `NVIDIA_L4_GPUS`). Approval can take minutes
to a day.

```bash
# Check your current GPU quota:
gcloud compute regions describe us-central1 \
  --format="value(quotas)" | tr ';' '\n' | grep -i gpus
```

---

## Quickstart

```bash
# 1. Create a VM (defaults: nvidia-l4, us-central1-a, 200GB disk)
GPU=nvidia-l4 ZONE=us-central1-a NAME=ml gpu-vm create

# 2. Confirm the GPU is up (first boot installs the driver, ~1-2 min)
NAME=ml gpu-vm status

# 3. Upload your code (a git repo → committed files only; works with private repos)
NAME=ml gpu-vm push ~/path/to/project

# 4. Install deps (one-shot command; output comes back to your terminal)
NAME=ml gpu-vm ssh "cd project && pip install -r requirements.txt"

# 5. Launch a long training job in tmux (survives SSH disconnects)
NAME=ml gpu-vm run "cd project && python train.py" train

# 6. Watch it
NAME=ml gpu-vm logs train.log        # tail -f, Ctrl-C to stop watching
NAME=ml gpu-vm status                # tmux sessions + nvidia-smi
NAME=ml gpu-vm wait train            # block until the job finishes

# 7. Get your results and shut down
NAME=ml gpu-vm pull project/outputs ./outputs
NAME=ml gpu-vm stop                  # keeps the disk; or `delete` to free everything
```

> Use the **same `NAME`/`ZONE`** for every command targeting a given VM.

---

## Commands

| Command | What it does |
|---|---|
| `create` | Create the VM (GPU from `$GPU`, zone from `$ZONE`) |
| `push <dir> [dest]` | Upload a local repo/dir (`git archive` for git repos) |
| `ssh "<cmd>"` | Run one command on the VM, return its output |
| `shell` | Open an interactive SSH session |
| `run "<cmd>" [session]` | Run a long job in tmux; logs to `~/<session>.log` |
| `wait [session]` | Block until the tmux session ends |
| `logs <remote-file>` | `tail -f` a remote log |
| `status` | tmux sessions + `nvidia-smi` |
| `pull <remote> [local]` | Download files from the VM |
| `put <local> <remote>` | Upload files to the VM |
| `list` | List all instances |
| `start` / `stop` / `delete` | Lifecycle (`stop` keeps disk, `delete` frees all) |

---

## Configuration

Set as env vars per command (defaults in parentheses):

| Var | Default | Notes |
|---|---|---|
| `NAME` | `gpu-vm` | Instance name |
| `ZONE` | `us-central1-a` | Try `-b`/`-c`/`-f` on stockouts (quota is regional) |
| `GPU` | `nvidia-l4` | See table below |
| `COUNT` | `1` | Number of GPUs |
| `MACHINE` | auto | Override the machine type |
| `DISK_SIZE` | `200GB` | Boot disk size |
| `IMAGE_FAMILY` | `common-cu129-ubuntu-2204-nvidia-580` | Deep Learning VM image |
| `IMAGE_PROJECT` | `deeplearning-platform-release` | |
| `SPOT` | `0` | `1` = cheaper preemptible (can be reclaimed) |

### GPUs and default machines

| `GPU=` | Default machine | VRAM | Notes |
|---|---|---|---|
| `nvidia-tesla-t4` | `n1-standard-8` | 16 GB | cheapest |
| `nvidia-l4` | `g2-standard-8` | 24 GB | best price/perf for fine-tuning |
| `nvidia-tesla-v100` | `n1-standard-8` | 16 GB | older |
| `nvidia-tesla-a100` | `a2-highgpu-1g` | 40 GB | GPU bundled in machine type |
| `nvidia-a100-80gb` | `a2-ultragpu-1g` | 80 GB | GPU bundled |
| `nvidia-h100-80gb` | `a3-highgpu-8g` | 8×80 GB | sold only as 8× |

For T4/L4/V100 the script adds `--accelerator`. For A2/A3 the GPU is part of the
machine type, so it's omitted automatically.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `currently unavailable` / stockout | No stock in that zone right now (not a quota issue). Retry another zone in the same region. |
| `image ... not found` | Image family retired. List current ones: `gcloud compute images list --project deeplearning-platform-release --filter="family~cu12" --format="value(family)" \| sort -u` |
| `could not read Username for github.com` | Private repo — use `push` (git archive + scp), not `git clone` on the VM. |
| SSH refused right after `create` | Boot/driver not finished. Wait 1–2 min and retry. |
| `nvidia-smi: command not found` | Driver still installing on first boot; wait and retry. |
| CUDA OOM | Smaller batch/resolution, gradient checkpointing, or a bigger-VRAM GPU. |
| Surprise bill | A VM was left running. `gpu-vm list`, then `stop`/`delete`. |

---

## 💸 Cost warning

**GPU VMs bill for every minute they're RUNNING**, whether or not you're using the
GPU. Always `gpu-vm stop` (keeps your disk and environment) when idle, or
`gpu-vm delete` (frees everything) when you're done. `gpu-vm list` shows anything
still running. Set `SPOT=1` on `create` for cheaper preemptible instances if your
job checkpoints frequently.

---

## License

MIT — see [LICENSE](LICENSE). Contributions welcome.
