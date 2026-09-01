#!/bin/bash
set -e

# Source environment variables
if [ -f /home/vars/var.env ]; then
  set -a
  . /home/vars/var.env
  set +a
fi

# Apply timezone from var.env (TIMEZONE); falls back to the image default if unset/invalid
if [ -n "${TIMEZONE}" ] && [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  echo "${TIMEZONE}" > /etc/timezone
fi

# Use persistent marker directory (survives restarts with volumes)
MARKER_DIR="/etc/gromox/.setup"
mkdir -p "${MARKER_DIR}"

# Allow forced reconfiguration via environment variable
if [ "${FORCE_RECONFIG}" = "true" ]; then
  rm -f "${MARKER_DIR}/db_done" "${MARKER_DIR}/entry_done"
fi

# Wait for database to be reachable
echo "Waiting for database ${MYSQL_HOST}..."
for i in $(seq 1 30); do
  mysql -u "${MYSQL_USER}" -h "${MYSQL_HOST}" -p"${MYSQL_PASS}" -e "SELECT 1" >/dev/null 2>&1 && break
  echo "  attempt $i/30 - retrying in 2s..."
  sleep 2
done

# Admin API config can live outside the one-time setup path depending on image
# upgrades and mounted volumes. Regenerate it on every start so the API never
# falls back to offline DB mode after a rebuild.
mkdir -p /etc/grommunio-admin-api/conf.d
. /home/common/helpers
generate_admin_db_conf "/etc/grommunio-admin-api/conf.d/database.yaml"

# Run DB initialization (once)
if [ ! -f "${MARKER_DIR}/db_done" ]; then
  /home/scripts/db.sh
  touch "${MARKER_DIR}/db_done"
fi

# Run entrypoint configuration (once)
if [ ! -f "${MARKER_DIR}/entry_done" ]; then
  /home/entrypoint.sh
  touch "${MARKER_DIR}/entry_done"
fi

# The configuration above is initialized only once, but this environment
# mapping must also be restored when the persistent marker already exists.
for fpm_conf in /etc/php8/fpm/php-fpm.d/gromox.conf /etc/php7/fpm/php-fpm.d/gromox.conf; do
  if [ -f "$fpm_conf" ] && [ -n "${GROMMUNIO_SHARED_ONLY_STORES:-}" ]; then
    # PHP-FPM does not reliably expand an environment variable in pool
    # configuration. Write the already-resolved JSON value instead.
    sed -i '/^env\[GROMMUNIO_SHARED_ONLY_STORES\]/d' "$fpm_conf"
    printf '\n; Shared-only mailbox allowlist for the webmail PHP process.\nenv[GROMMUNIO_SHARED_ONLY_STORES] = %s\n' "$GROMMUNIO_SHARED_ONLY_STORES" >> "$fpm_conf"
  fi
done

# Keep a file fallback because PHP-FPM pool environment handling differs
# between distributions and may hide Docker-provided variables from workers.
if [ -n "${GROMMUNIO_SHARED_ONLY_STORES:-}" ]; then
  mkdir -p /etc/grommunio
  printf '%s\n' "$GROMMUNIO_SHARED_ONLY_STORES" > /etc/grommunio/shared-only-stores.json
  chmod 0640 /etc/grommunio/shared-only-stores.json
fi

# ── Port remapping ─────────────────────────────────────────────────
# Remap nginx to listen on high ports (>1024) so no privileges needed.
# The actual listen directives are in the included files under /usr/share/.

# Grommunio web: 80 -> 8080, 443 -> 8443
# Handle both "listen 80" and "listen [::]:80" formats
for f in /usr/share/grommunio-common/nginx.conf /etc/nginx/nginx.conf; do
  [ -f "$f" ] || continue
  sed -i 's/\blisten\s\+80\b/listen 8080/g; s/\blisten\s\+\[::]\:80\b/listen [::]:8080/g' "$f"
  sed -i 's/\blisten\s\+443\b/listen 8443/g; s/\blisten\s\+\[::]\:443\b/listen [::]:8443/g' "$f"
done

# Admin HTTP: 8080 -> 9080 (avoid conflict with remapped web port)
sed -i 's/\blisten\s\+8080\b/listen 9080/g; s/\blisten\s\+\[::]\:8080\b/listen [::]:9080/g' \
  /usr/share/grommunio-admin-common/nginx.conf

# Admin HTTPS: 8443 -> 9443
sed -i 's/\blisten\s\+8443\b/listen 9443/g; s/\blisten\s\+\[::]\:8443\b/listen [::]:9443/g' \
  /usr/share/grommunio-admin-common/nginx-ssl.conf

# Remap postfix to listen on high ports
postconf -e "smtp_bind_address=" || true
if [ -f /etc/postfix/master.cf ]; then
  # smtp (25->2525), submission (587->2587), smtps (465->2465)
  sed -i 's/^smtp\(\s\+\)inet/2525\1inet/' /etc/postfix/master.cf
  sed -i 's/^submission\(\s\+\)inet/2587\1inet/' /etc/postfix/master.cf
  sed -i 's/^smtps\(\s\+\)inet/2465\1inet/' /etc/postfix/master.cf
fi

# Keep local delivery to Gromox separate from outbound mail. The dedicated
# smtp-relay container handles STARTTLS/auth with the external provider.
postconf -e "myhostname = correo.local"
postconf -e "myorigin = ${DOMAIN:-arvera.es}"
postconf -e "relay_domains ="
postconf -e "relayhost = [smtp-relay]:25"
postconf -e "default_transport = smtp"
postconf -e "relay_transport = smtp"
postconf -e "transport_maps ="
postconf -e "virtual_transport = smtp:[127.0.0.1]:24"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtp_tls_wrappermode = no"
postconf -X sender_dependent_relayhost_maps 2>/dev/null || true
postconf -X smtp_sender_dependent_authentication 2>/dev/null || true

# Remap gromox imap/pop3 ports
if [ -f /etc/gromox/imap.cfg ]; then
  sed -i 's/^listen_ssl_port\s*=\s*993/listen_ssl_port=2993/' /etc/gromox/imap.cfg
  sed -i 's/^listen_port\s*=\s*143/listen_port=2143/' /etc/gromox/imap.cfg
fi
if [ -f /etc/gromox/pop3.cfg ]; then
  sed -i 's/^listen_ssl_port\s*=\s*995/listen_ssl_port=2995/' /etc/gromox/pop3.cfg
  sed -i 's/^listen_port\s*=\s*110/listen_port=2110/' /etc/gromox/pop3.cfg
fi

# ── Conditional services ──────────────────────────────────────────

# Enable grommunio-chat if configured (check for chat config file existence)
if [ -f "${CHAT_CONFIG}" ] && [ -f /etc/supervisor.d/grommunio-chat.conf ]; then
  sed -i 's/autostart=false/autostart=true/' /etc/supervisor.d/grommunio-chat.conf
fi

# Set up certbot renewal if Let's Encrypt is enabled
if [ "${SSL_INSTALL_TYPE}" = "2" ]; then
  # On an actual renewal, rebuild the concatenated bundle that nginx and the
  # gromox http/imap/pop3 daemons read (certbot only refreshes the files under
  # /etc/letsencrypt/live, not this bundle) and restart the TLS services.
  # $RENEWED_LINEAGE is set by certbot to the renewed cert's live directory.
  cat > /usr/local/bin/grommunio-cert-deploy <<'DEPLOY'
#!/bin/bash
[ -n "${RENEWED_LINEAGE}" ] || exit 0
cat "${RENEWED_LINEAGE}/cert.pem" "${RENEWED_LINEAGE}/fullchain.pem" > /etc/grommunio-common/ssl/server-bundle.pem
cp -f "${RENEWED_LINEAGE}/privkey.pem" /etc/grommunio-common/ssl/server.key
chown gromox:gromox /etc/grommunio-common/ssl/* 2>/dev/null || true
supervisorctl restart gromox-http gromox-imap gromox-pop3 2>/dev/null || true
DEPLOY
  chmod +x /usr/local/bin/grommunio-cert-deploy

  # Renew on the published HTTP port (host :80 -> container :8080). nginx owns
  # 8080, so free it only while a renewal actually runs: the pre/post hooks
  # fire only when at least one certificate is due.
  echo "0 */12 * * * root certbot renew --quiet --standalone --http-01-port 8080 --pre-hook 'supervisorctl stop nginx' --deploy-hook /usr/local/bin/grommunio-cert-deploy --post-hook 'supervisorctl start nginx'" > /etc/cron.d/certbot-renew
fi

# /run is tmpfs-like runtime state in containers; recreate socket directories on every start.
mkdir -p /run/php-fpm /run/gromox /run/uwsgi /run/grommunio /run/grommunio-admin-api
chown gromox:gromox /run/gromox 2>/dev/null || true
chown nginx:nginx /run/php-fpm /run/uwsgi /run/grommunio /run/grommunio-admin-api 2>/dev/null || true
chmod 0775 /run/php-fpm /run/gromox /run/uwsgi /run/grommunio /run/grommunio-admin-api

# Recreate generated nginx SSL include when persistent volumes skip setup.
mkdir -p /etc/grommunio-admin-common /etc/grommunio-common/nginx
cp -f /home/config/certificate.conf /etc/grommunio-common/nginx/ssl_certificate.conf
ln -sf /etc/grommunio-common/nginx/ssl_certificate.conf /etc/grommunio-admin-common/nginx-ssl.conf

# Public folders read/unread mode:
# 1 = per user, 0 = shared state for all users.
: "${PUBLIC_FOLDERS_READ_PER_USER:=0}"
mkdir -p /etc/gromox
touch /etc/gromox/exmdb_provider.cfg
if grep -q "^exmdb_pf_read_per_user" /etc/gromox/exmdb_provider.cfg; then
  sed -i "s/^exmdb_pf_read_per_user.*/exmdb_pf_read_per_user=${PUBLIC_FOLDERS_READ_PER_USER}/" /etc/gromox/exmdb_provider.cfg
else
  printf "\nexmdb_pf_read_per_user=%s\n" "${PUBLIC_FOLDERS_READ_PER_USER}" >> /etc/gromox/exmdb_provider.cfg
fi

# Let users with store-owner rights manage rules for shared mailboxes from
# grommunio-web Settings > Rules.
if [ -f /etc/grommunio-web/config.php ] && ! grep -q "ENABLE_SHARED_RULES" /etc/grommunio-web/config.php; then
  printf "\ndefine(\"ENABLE_SHARED_RULES\", true);\n" >> /etc/grommunio-web/config.php
elif [ -f /etc/grommunio-web/config.php ]; then
  sed -i 's/define("ENABLE_SHARED_RULES".*/define("ENABLE_SHARED_RULES", true);/' /etc/grommunio-web/config.php
fi
if [ -f /etc/grommunio-web/config.php ] && ! grep -q "ALWAYS_ENABLED_PLUGINS_LIST" /etc/grommunio-web/config.php; then
  printf "\ndefine(\"ALWAYS_ENABLED_PLUGINS_LIST\", \"passwd;mdm;runrulesnow\");\n" >> /etc/grommunio-web/config.php
elif [ -f /etc/grommunio-web/config.php ]; then
  current_plugins="$(grep 'define("ALWAYS_ENABLED_PLUGINS_LIST"' /etc/grommunio-web/config.php | sed -E 's/.*"([^"]*)".*/\1/' | tail -n 1)"
  case ";${current_plugins};" in
    *";runrulesnow;"*) ;;
    *) sed -i "s/define(\"ALWAYS_ENABLED_PLUGINS_LIST\".*/define(\"ALWAYS_ENABLED_PLUGINS_LIST\", \"${current_plugins};runrulesnow\");/" /etc/grommunio-web/config.php ;;
  esac
fi
rm -f /var/lib/grommunio-web/tmp/session/*.plugin 2>/dev/null || true
chmod -R a+rX /usr/share/grommunio-web/plugins/runrulesnow 2>/dev/null || true

exec /usr/local/bin/supervisord -n -c /etc/supervisord.conf
