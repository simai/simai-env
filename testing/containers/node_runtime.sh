# shellcheck shell=bash disable=SC2034,SC2329  # globals and stubs read by the evaluated bootstrap functions
# Sourced by container cases that run node sites. Fixtures require Node.js 18
# or newer; Ubuntu 22.04 ships Node 12, so there the runtime comes from the
# pinned NodeSource repository exactly as simai-env.sh bootstrap installs it.
# Newer releases keep their distribution nodejs and npm. Run from the
# simai-env checkout.
e2e_node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

e2e_ensure_node() {
  local min="${1:-18}" candidate
  if command -v node >/dev/null 2>&1 && (( $(e2e_node_major) >= min )); then
    return 0
  fi
  apt-get update -qq >/dev/null 2>&1
  candidate=$(apt-cache policy nodejs 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
  candidate=${candidate#*:}
  if [[ "${candidate%%.*}" =~ ^[0-9]+$ ]] && (( ${candidate%%.*} >= min )); then
    apt-get install -y -qq nodejs npm >/dev/null 2>&1 || return 1
  else
    (
      set +u
      export SCRIPT_DIR=$PWD SIMAI_ENV_ROOT=$PWD
      LOG_FILE=/tmp/e2e-node.log
      eval "$(sed -n '/^NODE_VERSION=/p; /^NODESOURCE_KEY_FPR=/p' simai-env.sh)"
      source lib/os_adapter.sh 2>/dev/null
      source lib/platform.sh 2>/dev/null
      eval "$(awk '/^apt_update_once\(\) \{/,/^\}/' simai-env.sh)"
      eval "$(awk '/^add_nodesource_repo\(\) \{/,/^\}/' simai-env.sh)"
      APT_UPDATED=0
      info() { :; }; error() { echo "error: $*" >&2; }
      run_long() { shift; env "$@" >/dev/null 2>&1; }
      os_adapter_init >/dev/null 2>&1 || true
      add_nodesource_repo && apt-get install -y -qq nodejs >/dev/null 2>&1
    ) || return 1
  fi
  command -v npm >/dev/null 2>&1 && (( $(e2e_node_major) >= min ))
}
