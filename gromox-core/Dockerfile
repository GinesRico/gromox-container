# Container image with openSUSE Leap + supervisord
#
# Description:
#
# This image runs grommunio-core services using supervisord as PID 1,
# eliminating the need for systemd, privileged mode, and sysbox runtime.

FROM opensuse/leap:16.0

ARG GROMMUNIO_REPO=openSUSE_Leap_16.0

ARG ARVERA_USE_GROMMUNIO_WEB_FORK=0
ARG ARVERA_GROMMUNIO_WEB_REPO=https://github.com/GinesRico/grommunio-web.git
ARG ARVERA_GROMMUNIO_WEB_REF=arvera-operator-users

ARG ARVERA_USE_ADMIN_API_FORK=0
ARG ARVERA_ADMIN_API_REPO=https://github.com/GinesRico/admin-api.git
ARG ARVERA_ADMIN_API_REF=arvera-operator-users

ARG ARVERA_USE_ADMIN_WEB_FORK=0
ARG ARVERA_ADMIN_WEB_REPO=https://github.com/GinesRico/admin-web.git
ARG ARVERA_ADMIN_WEB_REF=arvera-operator-users

ARG ARVERA_USE_GROMOX_FORK=0
ARG ARVERA_GROMOX_REPO=https://github.com/GinesRico/gromox.git
ARG ARVERA_GROMOX_REF=arvera-shared-only-mapi

# Source snapshots are supplied by the build context. Keeping them local makes
# the image build independent of GitHub availability and credentials.
COPY vendor/gromox.tar.gz /tmp/gromox.tar.gz
COPY vendor/grommunio-web /opt/vendor/grommunio-web
COPY vendor/admin-api /opt/vendor/admin-api
COPY vendor/admin-web /opt/vendor/admin-web


# ----------------------------------------------------------------------
# Base packages
# ----------------------------------------------------------------------

# The default Leap image can point repo-oss at a stale CDN endpoint. Use the
# official HTTPS mirror while keeping checksum verification enabled.
RUN zypper clean --all && \
    rm -rf /var/cache/zypp/* /var/tmp/zypp.* && \
    zypper -n modifyservice --disable openSUSE || true; \
    zypper -n ar -f \
      https://ftp.gwdg.de/pub/opensuse/distribution/leap/16.0/repo/oss/x86_64/ \
      repo-oss-gwdg || true; \
    sed -i \
      -e 's#http://cdn.opensuse.org#https://download.opensuse.org#g' \
      -e 's#https://cdn.opensuse.org#https://download.opensuse.org#g' \
      -e 's#https://download.opensuse.org/distribution/#https://download.opensuse.org/download/distribution/#g' \
      /etc/zypp/repos.d/*.repo && \
    for attempt in 1 2 3 4 5; do \
      zypper --gpg-auto-import-keys --non-interactive refresh -f && break; \
      echo "Repository refresh attempt ${attempt} failed; retrying..."; \
      sleep 5; \
    done && \
    zypper -n install -y \
        iptables \
        iproute2 \
        kmod \
        curl \
        patterns-base-apparmor \
        patterns-base-base \
        procps \
        sudo \
        cronie \
        bind-utils \
        timezone \
        nano \
        lsof


# ----------------------------------------------------------------------
# Default timezone
# Can be overridden at runtime via TIMEZONE in var.env
# ----------------------------------------------------------------------

RUN ln -sf /usr/share/zoneinfo/Europe/Vienna /etc/localtime && \
    echo "Europe/Vienna" > /etc/timezone


# ----------------------------------------------------------------------
# grommunio repository
# ----------------------------------------------------------------------

RUN curl https://download.grommunio.com/RPM-GPG-KEY-grommunio > gr.key && \
    rpm --import gr.key && \
    zypper --non-interactive --quiet ar -C \
      https://download.grommunio.com/community/${GROMMUNIO_REPO} \
      grommunio && \
    zypper --gpg-auto-import-keys ref && \
    zypper -n refresh grommunio


# ----------------------------------------------------------------------
# Install grommunio packages
# Retry up to 3 times for transient download errors
# ----------------------------------------------------------------------

RUN zypper --non-interactive install -y \
        vim mysql nginx \
        gromox \
        grommunio-admin-api \
        grommunio-admin-web \
        grommunio-antispam \
        grommunio-common \
        grommunio-web \
        grommunio-sync \
        grommunio-dav \
        postfix \
        postfix-mysql \
        grommunio-chat \
        grommunio-keycloak \
        grommunio-auth \
        cyrus-sasl-saslauthd \
        cyrus-sasl-plain \
        jq \
        redis \
    || { \
        echo "Retry 1..."; \
        zypper clean -a; \
        sleep 5; \
        zypper --non-interactive install -y \
          vim mysql nginx \
          gromox \
          grommunio-admin-api \
          grommunio-admin-web \
          grommunio-antispam \
          grommunio-common \
          grommunio-web \
          grommunio-sync \
          grommunio-dav \
          postfix \
          postfix-mysql \
          grommunio-chat \
          grommunio-keycloak \
          grommunio-auth \
          cyrus-sasl-saslauthd \
          cyrus-sasl-plain \
          jq \
          redis; \
    } \
    || { \
        echo "Retry 2..."; \
        zypper clean -a; \
        sleep 10; \
        zypper --non-interactive install -y \
          vim mysql nginx \
          gromox \
          grommunio-admin-api \
          grommunio-admin-web \
          grommunio-antispam \
          grommunio-common \
          grommunio-web \
          grommunio-sync \
          grommunio-dav \
          postfix \
          postfix-mysql \
          grommunio-chat \
          grommunio-keycloak \
          grommunio-auth \
          cyrus-sasl-saslauthd \
          cyrus-sasl-plain \
          jq \
          redis; \
    }


# ----------------------------------------------------------------------
# Optional Arvera Gromox fork
# ----------------------------------------------------------------------

RUN if [ "${ARVERA_USE_GROMOX_FORK}" = "1" ]; then \
      zypper --non-interactive install -y gcc-c++ make autoconf automake libtool pkg-config && \
      zypper --non-interactive si -d gromox && \
      mkdir -p /opt/vendor/gromox && \
      tar -xzf /tmp/gromox.tar.gz -C /opt/vendor/gromox && \
      cd /opt/vendor/gromox && \
      sed -i 's/\r$//' qconf && \
      sh qconf && \
      make -j"$(nproc)" && \
      make install; \
    fi


# ----------------------------------------------------------------------
# Certbot + iconv modules
# ----------------------------------------------------------------------

RUN zypper -n install -y \
        python313-certbot \
        python313-certbot-nginx \
        glibc-gconv-modules-extra


# ----------------------------------------------------------------------
# Supervisord
# Python 3.13 is the system default on openSUSE Leap 16
# ----------------------------------------------------------------------

RUN zypper -n install -y python313-pip && \
    pip3.13 install --no-cache-dir supervisor


# ----------------------------------------------------------------------
# Optional Arvera grommunio-web fork
# ----------------------------------------------------------------------

RUN if [ "${ARVERA_USE_GROMMUNIO_WEB_FORK}" = "1" ]; then \
      zypper --non-interactive install -y nodejs npm make gettext-tools && \
      cd /opt/vendor/grommunio-web && \
      npm ci && \
      make deploy && \
      cp -a deploy/. /usr/share/grommunio-web/ && \
      rm -rf node_modules; \
    fi


# ----------------------------------------------------------------------
# Optional Arvera admin-api fork
#
# The packaged service, uwsgi config and runtime state stay in place.
# Only the application source is replaced.
# ----------------------------------------------------------------------

RUN if [ "${ARVERA_USE_ADMIN_API_FORK}" = "1" ]; then \
      test -f /opt/vendor/admin-api/main.py && \
      rm -rf \
        /usr/share/grommunio-admin-api/api \
        /usr/share/grommunio-admin-api/cli \
        /usr/share/grommunio-admin-api/endpoints \
        /usr/share/grommunio-admin-api/orm \
        /usr/share/grommunio-admin-api/res \
        /usr/share/grommunio-admin-api/services \
        /usr/share/grommunio-admin-api/tools && \
      cp -a \
        /opt/vendor/admin-api/api \
        /opt/vendor/admin-api/cli \
        /opt/vendor/admin-api/endpoints \
        /opt/vendor/admin-api/orm \
        /opt/vendor/admin-api/res \
        /opt/vendor/admin-api/services \
        /opt/vendor/admin-api/tools \
        /usr/share/grommunio-admin-api/ && \
      cp -a \
        /opt/vendor/admin-api/main.py \
        /usr/share/grommunio-admin-api/main.py && \
      cp -a \
        /opt/vendor/admin-api/data/api-config.ini \
        /usr/share/grommunio-admin-api/api-config.ini && \
      true; \
    fi


# ----------------------------------------------------------------------
# ARVERA CUSTOM USER POLICY
#
# This file overrides orm/users.py from either:
#   - the packaged grommunio-admin-api
#   - or the optional Arvera admin-api fork above
#
# MAX_USERS is read at runtime from var.env.
# MAX_USERS=0 means no custom global user limit.
# ----------------------------------------------------------------------

COPY gromox-core/custom/users.py \
     /usr/share/grommunio-admin-api/orm/users.py

COPY gromox-core/custom/config.yaml \
     /usr/share/grommunio-admin-api/config.yaml
# ----------------------------------------------------------------------
# Optional Arvera admin-web fork
# ----------------------------------------------------------------------

RUN if [ "${ARVERA_USE_ADMIN_WEB_FORK}" = "1" ]; then \
      zypper --non-interactive install -y nodejs npm make && \
      cd /opt/vendor/admin-web && \
      npm install --global yarn@1.22.22 && \
      yarn install --frozen-lockfile --network-timeout 600000 && \
      DISABLE_ESLINT_PLUGIN=true yarn build && \
      ADMIN_WEB_DIR="/usr/share/grommunio-admin-web" && \
      test -d "${ADMIN_WEB_DIR}" && \
      rm -rf "${ADMIN_WEB_DIR:?}"/* && \
      cp -a build/. "${ADMIN_WEB_DIR}/" && \
      rm -rf node_modules; \
    fi


# ----------------------------------------------------------------------
# OpenMail branding
# ----------------------------------------------------------------------

COPY gromox-core/branding/openmail /tmp/openmail-branding

RUN set -eux; \
    cp -a /tmp/openmail-branding/grommunio-web/. /usr/share/grommunio-web/; \
    cp -a /tmp/openmail-branding/admin-web/. /usr/share/grommunio-admin-web/; \
    if [ -f /usr/share/grommunio-admin-web/index.html ]; then \
      sed -i \
        -e 's#grommunio admin-web#OpenMail admin web#g' \
        -e 's#<title>grommunio</title>#<title>OpenMail</title>#g' \
        -e 's|<meta name="theme-color" content="[^"]*" />|<meta name="theme-color" content="#1265dc" />|g' \
        /usr/share/grommunio-admin-web/index.html; \
    fi; \
    if [ -f /usr/share/grommunio-admin-web/manifest.json ]; then \
      tmp="$(mktemp)"; \
      jq '.short_name = "OpenMail admin" | .name = "OpenMail admin web" | .theme_color = "#1265dc"' \
        /usr/share/grommunio-admin-web/manifest.json > "${tmp}" && \
      mv "${tmp}" /usr/share/grommunio-admin-web/manifest.json; \
    fi; \
    chmod -R a+rX \
      /usr/share/grommunio-web/plugins/openmail \
      /usr/share/grommunio-web/client/resources/images/openmail \
      /usr/share/grommunio-admin-web/openmail


# ----------------------------------------------------------------------
# Create default user if needed
# ----------------------------------------------------------------------

RUN groupadd 'wheel' && \
    useradd -m -s /bin/bash -G wheel admin && \
    echo "admin:admin" | chpasswd


# ----------------------------------------------------------------------
# Container configuration
# ----------------------------------------------------------------------

COPY gromox-core/scripts /home/scripts
COPY gromox-core/common /home/common
COPY gromox-core/config /home/config


# ----------------------------------------------------------------------
# grommunio-web plugins
# ----------------------------------------------------------------------

COPY grommunio-web-plugins /tmp/arvera-grommunio-web-plugins

RUN if [ "${ARVERA_USE_GROMMUNIO_WEB_FORK}" != "1" ]; then \
      cp -a /tmp/arvera-grommunio-web-plugins/. \
            /usr/share/grommunio-web/plugins/; \
    fi && \
    chmod -R a+rX \
      /usr/share/grommunio-web/plugins/runrulesnow \
      2>/dev/null || true


# ----------------------------------------------------------------------
# Scripts
# ----------------------------------------------------------------------

RUN chmod +x /home/scripts/db.sh

COPY gromox-core/entrypoint.sh /home/entrypoint.sh

RUN chmod +x /home/entrypoint.sh

COPY gromox-core/docker-entrypoint.sh /home/docker-entrypoint.sh

RUN sed -i 's/\r$//' /home/docker-entrypoint.sh && \
    chmod +x /home/docker-entrypoint.sh


# ----------------------------------------------------------------------
# Supervisord
# ----------------------------------------------------------------------

COPY gromox-core/supervisord.conf /etc/supervisord.conf
COPY gromox-core/supervisor.d /etc/supervisor.d


# ----------------------------------------------------------------------
# Entrypoint
# ----------------------------------------------------------------------

ENTRYPOINT ["/home/docker-entrypoint.sh"]
