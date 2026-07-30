#!/usr/bin/env bash
# Lint the compose files. Run locally with `make lint`; CI runs the same script.
#
# Checks, in order:
#   1. YAML style (yamllint, config in .yamllint.yml)
#   2. Compose schema for the base file and each override combination
#   3. No ${VAR} left without a default — an unset var must not silently
#      interpolate to an empty string
#   4. Every ${VAR} the compose files reference is documented in .env.example
#   5. The GPU profile reserves an nvidia device and the CPU profile does not
set -uo pipefail
cd "$(dirname "$0")/.."

BASE=docker-compose.yml
RAW=docker-compose.raw-pcm.yml
CPU=docker-compose.cpu.yml
ALL=("${BASE}" "${RAW}" "${CPU}")
fail=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
skip() { printf '  \033[33m-\033[0m %s\n' "$1"; }

echo "Linting compose files"

# --- 1. YAML style -----------------------------------------------------------
if command -v yamllint >/dev/null 2>&1; then
  if out=$(yamllint -f parsable -c .yamllint.yml "${ALL[@]}" 2>&1); then
    ok "yamllint clean"
  else
    bad "yamllint:"
    printf '%s\n' "${out}" | sed 's/^/      /'
  fi
else
  skip "yamllint not installed (pip install yamllint)"
fi

# --- 2. Compose schema -------------------------------------------------------
if docker compose version >/dev/null 2>&1; then
  # Validated against an empty env file so the built-in defaults are what gets
  # checked; a developer's local .env cannot mask a broken default.
  empty_env=$(mktemp)
  trap 'rm -f "${empty_env}"' EXIT
  for args in "-f ${BASE}" "-f ${BASE} -f ${RAW}" "-f ${BASE} -f ${CPU}"; do
    label="${args//-f /}"
    if out=$(docker compose --env-file "${empty_env}" ${args} config 2>&1 >/dev/null); then
      ok "compose config: ${label}"
    else
      bad "compose config: ${label}"
      printf '%s\n' "${out}" | sed 's/^/      /'
      continue
    fi

    # --- 3. Unset variables ---
    if unset_vars=$(printf '%s\n' "${out}" | grep -oE 'The "[A-Za-z_][A-Za-z0-9_]*" variable is not set'); then
      bad "no default for: $(printf '%s\n' "${unset_vars}" | grep -oE '"[^"]+"' | tr -d '"' | sort -u | paste -sd' ' -)"
    fi
  done

  # --- 5. GPU is reserved by default, and the CPU profile clears it ---
  # Guards the `deploy: !reset null` in the CPU override: if that stopped
  # working, the CPU profile would demand a GPU and fail to start on the
  # cheap host it exists to support.
  gpu_cfg=$(docker compose --env-file "${empty_env}" -f "${BASE}" config 2>/dev/null)
  cpu_cfg=$(docker compose --env-file "${empty_env}" -f "${BASE}" -f "${CPU}" config 2>/dev/null)
  if printf '%s' "${gpu_cfg}" | grep -q 'driver: nvidia'; then
    ok "default profile reserves an nvidia device"
  else
    bad "default profile no longer reserves a GPU"
  fi
  if printf '%s' "${cpu_cfg}" | grep -q 'driver: nvidia'; then
    bad "CPU profile still reserves an nvidia device (deploy: !reset not applied)"
  else
    ok "CPU profile reserves no GPU"
  fi
  if printf '%s' "${cpu_cfg}" | grep -q 'llama.cpp:server-cuda'; then
    bad "CPU profile still uses the CUDA llama.cpp image"
  else
    ok "CPU profile uses the CPU llama.cpp image"
  fi
else
  skip "docker compose not available — schema and profile checks run in CI"
fi

# --- 4. .env.example coverage ------------------------------------------------
referenced=$(grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*' "${ALL[@]}" | cut -c3- | sort -u)
documented=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' .env.example | tr -d '=' | sort -u)
if missing=$(comm -23 <(printf '%s\n' "${referenced}") <(printf '%s\n' "${documented}")) && [[ -n "${missing}" ]]; then
  bad "referenced in compose but absent from .env.example: $(printf '%s\n' "${missing}" | paste -sd' ' -)"
else
  ok ".env.example documents all $(printf '%s\n' "${referenced}" | grep -c .) referenced variables"
fi

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "Compose lint passed."
else
  echo "Compose lint failed." >&2
  exit 1
fi
