#!/bin/sh
set -eu

: "${SMTP_RELAY_HOST:=smtp.serviciodecorreo.es}"
: "${SMTP_RELAY_PORT:=587}"
: "${SMTP_RELAY_USER:?SMTP_RELAY_USER is required}"
: "${SMTP_RELAY_PASSWORD:?SMTP_RELAY_PASSWORD is required}"
: "${SMTP_RELAY_MYHOSTNAME:=smtp-relay.local}"

RELAY="[${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT}"
MAP_TYPE="hash"
if postconf -m | grep -qx "lmdb"; then
  MAP_TYPE="lmdb"
fi

cat > /etc/postfix/sasl_passwd <<EOF
${RELAY} ${SMTP_RELAY_USER}:${SMTP_RELAY_PASSWORD}
EOF
chmod 600 /etc/postfix/sasl_passwd
postmap "${MAP_TYPE}:/etc/postfix/sasl_passwd"

postconf -e "myhostname = ${SMTP_RELAY_MYHOSTNAME}"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mynetworks = 127.0.0.0/8 172.16.0.0/12 192.168.0.0/16 10.0.0.0/8"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks,reject_unauth_destination"
postconf -e "relayhost = ${RELAY}"
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = ${MAP_TYPE}:/etc/postfix/sasl_passwd"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_sasl_tls_security_options = noanonymous"
postconf -e "smtp_sasl_mechanism_filter = plain, login"
postconf -e "smtp_tls_security_level = encrypt"
postconf -e "smtp_tls_wrappermode = no"
postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
postconf -e "smtp_tls_loglevel = 1"
postconf -e "maillog_file = /dev/stdout"

postfix check
exec postfix start-fg
