#!/usr/bin/env bash

# Apache mode for PHP sites that rely on .htaccess. nginx stays the frontend
# (HTTPS, access rules, own directives, ACME) and proxies the site to Apache
# on 127.0.0.1 only; Apache reads .htaccess and runs PHP through the site's
# own PHP-FPM pool, so the PHP version and pool user do not change.
# The mode of a site lives in /etc/simai-env/sites/<domain>/web.env (BACKEND=apache).

SIMAI_APACHE_PORT="${SIMAI_APACHE_PORT:-8088}"
SIMAI_APACHE_DIR="${SIMAI_APACHE_DIR:-/etc/apache2}"
APACHE_PROFILES="generic laravel wordpress bitrix"

site_web_env_file() {
  echo "$(site_sites_config_dir)/$1/web.env"
}

# apache or nginx
site_web_backend() {
  local v
  v=$(sed -n 's/^BACKEND=//p' "$(site_web_env_file "$1")" 2>/dev/null | tail -n1)
  [[ "$v" == apache ]] && echo apache || echo nginx
}

site_web_backend_set() {
  local domain="$1" backend="$2" file
  file=$(site_web_env_file "$domain")
  if [[ "$backend" == apache ]]; then
    install -d -m 0750 "$(dirname "$file")"
    printf 'BACKEND=apache\n' >"$file"
    chmod 0640 "$file"
  else
    rm -f -- "$file"
  fi
}

apache_profile_supported() {
  [[ " ${APACHE_PROFILES} " == *" $1 "* ]]
}

apache_site_file() {
  echo "${SIMAI_APACHE_DIR}/sites-available/simai-$1.conf"
}

apache_installed() {
  command -v apache2ctl >/dev/null 2>&1 && [[ -d "${SIMAI_APACHE_DIR}/sites-available" ]]
}

# Installs Apache listening on 127.0.0.1 only. ports.conf is written before
# the package so it never starts on port 80 (nginx owns it); --force-confold
# keeps that file.
apache_install() {
  local d="$SIMAI_APACHE_DIR"
  install -d -m 0755 "$d"
  printf '# simai-env: Apache serves sites behind nginx on 127.0.0.1 only\nListen 127.0.0.1:%s\n' "$SIMAI_APACHE_PORT" >"${d}/ports.conf"
  if ! command -v apache2ctl >/dev/null 2>&1; then
    run_long "Installing Apache" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold apache2 || return 1
  fi
  apache_configure
}

apache_configure() {
  local d="$SIMAI_APACHE_DIR"
  printf '# simai-env: Apache serves sites behind nginx on 127.0.0.1 only\nListen 127.0.0.1:%s\n' "$SIMAI_APACHE_PORT" >"${d}/ports.conf"
  cat >"${d}/conf-available/simai.conf" <<'EOF'
# simai-env: Apache behind nginx. Managed by simai-admin.sh site apache.
ServerName localhost
ServerTokens Prod
ServerSignature Off
TraceEnable Off
# The client address and scheme come from nginx on this host.
RemoteIPHeader X-Real-IP
RemoteIPInternalProxy 127.0.0.1 ::1
SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on
EOF
  # Requests for a name no site has get 404, never another site.
  cat >"${d}/sites-available/000-simai-default.conf" <<EOF
# simai-env: first vhost answers unknown names
<VirtualHost 127.0.0.1:${SIMAI_APACHE_PORT}>
    ServerName simai-default.invalid
    DocumentRoot /var/www/html
    <Location />
        Require all denied
    </Location>
</VirtualHost>
EOF
  {
    a2dismod -q -f php8.1 php8.2 php8.3 php8.4 php8.5 mpm_prefork mpm_worker
    a2enmod -q mpm_event proxy_fcgi setenvif rewrite headers remoteip expires deflate
    a2enconf -q simai
    a2dissite -q 000-default
    a2ensite -q 000-simai-default
  } >>"$LOG_FILE" 2>&1 || true
  os_svc_enable_now apache2 >>"$LOG_FILE" 2>&1 || true
}

apache_reload() {
  local out
  if ! out=$(apache2ctl configtest 2>&1); then
    error "$(printf 'Apache config test failed:\n%s' "$(tail -n 8 <<<"$out")")"
    return 1
  fi
  if systemctl is-active --quiet apache2 2>/dev/null; then
    os_svc_reload apache2 >>"$LOG_FILE" 2>&1
  else
    os_svc_restart apache2 >>"$LOG_FILE" 2>&1
  fi
}

# Writes the Apache vhost of a site: domain project doc_root php socket_project host_mode wildcard_domain
apache_site_render() {
  local domain="$1" project="$2" doc_root="$3" php="$4" socket_project="$5" host_mode="${6:-standard}" wildcard="${7:-}"
  local file alias=""
  file=$(apache_site_file "$project")
  if [[ "$host_mode" == wildcard && -n "$wildcard" ]]; then
    alias="    ServerAlias ${wildcard}\n"
  fi
  {
    printf '# simai-env: Apache vhost of %s; managed by simai-admin.sh site apache\n# simai-domain: %s\n' "$domain" "$domain"
    sed -e "s#{{APACHE_PORT}}#${SIMAI_APACHE_PORT}#g" \
      -e "s#{{DOMAIN}}#${domain}#g" \
      -e "s#{{SERVER_ALIAS}}#${alias}#g" \
      -e "s#{{DOC_ROOT}}#${doc_root}#g" \
      -e "s#{{PROJECT_NAME}}#${project}#g" \
      -e "s#{{PHP_VERSION}}#${php}#g" \
      -e "s#{{PHP_SOCKET_PROJECT}}#${socket_project}#g" "${SCRIPT_DIR}/templates/apache-site.conf"
  } >"${file}.tmp" && mv -f "${file}.tmp" "$file"
  a2ensite -q "simai-${project}" >>"$LOG_FILE" 2>&1 || ln -sf "$file" "${SIMAI_APACHE_DIR}/sites-enabled/simai-${project}.conf"
}

apache_site_remove() {
  local project="$1"
  [[ "$project" =~ ^[a-z0-9-]+$ ]] || return 0
  local file
  file=$(apache_site_file "$project")
  [[ -e "$file" ]] || return 0
  rm -f -- "${SIMAI_APACHE_DIR}/sites-enabled/simai-${project}.conf" "$file"
  apache_installed && apache_reload >/dev/null 2>&1 || true
}

# The PHP version of a site changed: point its Apache vhost at the new socket.
apache_site_patch_socket() {
  local project="$1" new_php="$2" socket_project="$3" file
  file=$(apache_site_file "$project")
  [[ -f "$file" ]] || return 0
  SOCKET_PATTERN="/run/php/php[0-9.]+-fpm-${socket_project}\\.sock" NEW_SOCKET="/run/php/php${new_php}-fpm-${socket_project}.sock" \
    perl -0pi -e 's#$ENV{SOCKET_PATTERN}#$ENV{NEW_SOCKET}#g' "$file"
  apache_reload
}
