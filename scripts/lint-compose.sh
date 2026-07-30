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
  # working, the CPU profile would demand a GPU and fail to start on the cheap
  # host it exists to support. Note `devices: []` does NOT clear an inherited
  # reservation (verified against Compose v2.38) — only the !reset/!override
  # tags do, which is why the override uses one.
  #
  # This inspects the parsed service tree, not the rendered text: `config`
  # echoes top-level x- extension fields verbatim, so the x-gpu anchor in the
  # base file makes a naive `grep nvidia` match under every profile.
  profile_gpu() {
    docker compose --env-file "${empty_env}" "$@" config --format json 2>/dev/null \
      | python3 -c '
import json, sys
doc = json.load(sys.stdin)
for name, svc in sorted(doc.get("services", {}).items()):
    resources = (svc.get("deploy") or {}).get("resources") or {}
    devices = (resources.get("reservations") or {}).get("devices") or []
    drivers = sorted({str(d.get("driver", "?")) for d in devices})
    print(name, ",".join(drivers) or "none")
'
  }

  gpu_devs=$(profile_gpu -f "${BASE}")
  cpu_devs=$(profile_gpu -f "${BASE}" -f "${CPU}")

  if printf '%s\n' "${gpu_devs}" | grep -q 'nvidia'; then
    ok "default profile reserves an nvidia device ($(printf '%s' "${gpu_devs}" | tr '\n' ' '))"
  else
    bad "default profile no longer reserves a GPU: ${gpu_devs}"
  fi
  if printf '%s\n' "${cpu_devs}" | grep -q 'nvidia'; then
    bad "CPU profile still reserves a GPU: $(printf '%s' "${cpu_devs}" | tr '\n' ' ')"
  else
    ok "CPU profile reserves no GPU"
  fi

  cpu_image=$(docker compose --env-file "${empty_env}" -f "${BASE}" -f "${CPU}" config --format json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["llm-engine"]["image"])')
  case "${cpu_image}" in
    *server-cuda) bad "CPU profile still uses the CUDA llama.cpp image: ${cpu_image}" ;;
    *llama.cpp:server) ok "CPU profile uses the CPU llama.cpp image" ;;
    *) bad "unexpected CPU profile LLM image: ${cpu_image}" ;;
  esac
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
