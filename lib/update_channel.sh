#!/usr/bin/env bash

update_ref_default() {
  local branch="${SIMAI_UPDATE_BRANCH:-main}"
  local ref="${SIMAI_UPDATE_REF:-refs/heads/${branch}}"
  if [[ "$ref" =~ ^refs/(heads|tags)/[A-Za-z0-9._/-]+$ ]]; then
    printf '%s\n' "$ref"
    return 0
  fi
  printf '%s\n' "refs/heads/main"
}

update_repo_http_url() {
  local url="${1:-${REPO_URL:-https://github.com/simai/simai-env}}"
  url="${url%.git}"
  url="${url%/}"
  case "$url" in
    git@github.com:*)
      url="https://github.com/${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      url="https://github.com/${url#ssh://git@github.com/}"
      ;;
  esac
  printf '%s\n' "$url"
}

update_repo_slug() {
  local repo_url
  repo_url="$(update_repo_http_url "${1:-}")"
  case "$repo_url" in
    https://github.com/*/*)
      printf '%s\n' "${repo_url#https://github.com/}"
      ;;
    *)
      printf '%s\n' "simai/simai-env"
      ;;
  esac
}

update_resolve_ref_sha() {
  local ref="${1:-}"
  local repo_url
  repo_url="$(update_repo_http_url "${2:-}")"
  [[ -n "$ref" ]] || ref="$(update_ref_default)"

  command -v git >/dev/null 2>&1 || return 1

  local sha=""
  sha=$(git ls-remote "$repo_url" "$ref" 2>/dev/null | awk 'NR==1{print $1}')
  if [[ -z "$sha" && "$ref" == refs/tags/* ]]; then
    sha=$(git ls-remote "$repo_url" "${ref}^{}" 2>/dev/null | awk 'NR==1{print $1}')
  fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$sha"
}

update_tarball_url() {
  local ref="${1:-}"
  local repo_url sha
  repo_url="$(update_repo_http_url "${2:-}")"
  [[ -n "$ref" ]] || ref="$(update_ref_default)"
  sha="$(update_resolve_ref_sha "$ref" "$repo_url" 2>/dev/null || true)"
  if [[ -n "$sha" ]]; then
    printf '%s\n' "${repo_url}/archive/${sha}.tar.gz"
    return 0
  fi
  printf '%s\n' "${repo_url}/archive/${ref}.tar.gz"
}

update_remote_version_url() {
  local ref="${1:-}"
  local repo_url slug sha
  repo_url="$(update_repo_http_url "${2:-}")"
  slug="$(update_repo_slug "$repo_url")"
  [[ -n "$ref" ]] || ref="$(update_ref_default)"
  sha="$(update_resolve_ref_sha "$ref" "$repo_url" 2>/dev/null || true)"
  if [[ -n "$sha" ]]; then
    printf '%s\n' "https://raw.githubusercontent.com/${slug}/${sha}/VERSION"
    return 0
  fi
  case "$ref" in
    refs/heads/*)
      printf '%s\n' "https://raw.githubusercontent.com/${slug}/${ref#refs/heads/}/VERSION"
      ;;
    refs/tags/*)
      printf '%s\n' "https://raw.githubusercontent.com/${slug}/${ref#refs/tags/}/VERSION"
      ;;
    *)
      printf '%s\n' "https://raw.githubusercontent.com/${slug}/main/VERSION"
      ;;
  esac
}
