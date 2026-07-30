#!/usr/bin/env bash
# Verify an EC2 GPU host can run PipeKit. Read-only by default; pass
# --install-toolkit to install the NVIDIA Container Toolkit if it is missing
# (not needed on the Ubuntu Deep Learning AMI, which ships it).
set -euo pipefail

INSTALL_TOOLKIT=0
[[ "${1:-}" == "--install-toolkit" ]] && INSTALL_TOOLKIT=1

fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

echo "PipeKit preflight"

# --- GPU ---------------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
  vram_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
  ok "GPU: ${gpu_name} (${vram_mib} MiB)"
  if [[ "${vram_mib}" -lt 15000 ]]; then
    bad "Under ~16 GB VRAM. STT + LLM + TTS will not co-reside; use g4dn.xlarge or larger."
  elif [[ "${vram_mib}" -lt 23000 ]]; then
    warn "16 GB class card: set LLM_CTX=8192 in .env and keep NUM_PIPELINES=1."
  fi
else
  bad "nvidia-smi not found — no NVIDIA driver. Launch from the Ubuntu Deep Learning AMI."
fi

# --- Docker ------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  ok "docker: $(docker --version | cut -d, -f1)"
  docker info >/dev/null 2>&1 \
    && ok "docker daemon reachable as $(id -un)" \
    || bad "cannot talk to the docker daemon. Try: sudo usermod -aG docker \$USER && newgrp docker"
else
  bad "docker not installed"
fi

docker compose version >/dev/null 2>&1 \
  && ok "compose: $(docker compose version --short)" \
  || bad "docker compose v2 plugin missing (the 'docker-compose' v1 script will not work here)"

# --- NVIDIA Container Toolkit ------------------------------------------------
if docker info 2>/dev/null | grep -q 'Runtimes:.*nvidia'; then
  ok "nvidia container runtime registered"
elif [[ "${INSTALL_TOOLKIT}" -eq 1 ]]; then
  echo "  installing nvidia-container-toolkit…"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  ok "nvidia-container-toolkit installed"
else
  bad "nvidia runtime not registered. Re-run with --install-toolkit, or use the Deep Learning AMI."
fi

# --- End-to-end GPU passthrough ---------------------------------------------
if docker info >/dev/null 2>&1; then
  if docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi -L >/dev/null 2>&1; then
    ok "containers can see the GPU"
  else
    bad "'docker run --gpus all' failed — GPU passthrough is broken"
  fi
fi

# --- Disk --------------------------------------------------------------------
avail_gb=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
if [[ "${avail_gb}" -lt 60 ]]; then
  warn "${avail_gb} GB free. The CUDA image plus model weights want ~60 GB; grow the EBS volume."
else
  ok "${avail_gb} GB free disk"
fi

mkdir -p cache
[[ -f .env ]] || warn "no .env yet — cp .env.example .env"

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "Ready. Next: docker compose up -d"
else
  echo "Preflight failed — fix the ✗ items above first." >&2
  exit 1
fi
