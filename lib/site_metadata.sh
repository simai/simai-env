#!/usr/bin/env bash
set -euo pipefail

# Render canonical nginx metadata block (metadata v2).
site_nginx_metadata_render() {
  local domain="$1" slug="$2" profile="$3" root="$4" project="$5" php="$6" ssl="$7" updated_at="$8" target="$9" socket_project="${10}" template="${11}" public_dir="${12}"
  [[ -z "$updated_at" ]] && updated_at="$(date +%Y-%m-%d)"
  cat <<EOF
# simai-managed: yes
# simai-meta-version: 2
# simai-domain: ${domain}
# simai-slug: ${slug}
# simai-profile: ${profile}
# simai-root: ${root}
# simai-project: ${project}
# simai-php: ${php}
# simai-ssl: ${ssl}
# simai-target: ${target}
# simai-php-socket-project: ${socket_project}
# simai-nginx-template: ${template}
# simai-public-dir: ${public_dir}
# simai-updated-at: ${updated_at}

EOF
}
