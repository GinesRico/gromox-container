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


# ----------------------------------------------------------------------
# Base packages
# ----------------------------------------------------------------------

RUN zypper -n install -y \
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
      zypper --non-interactive install -y git nodejs npm make gettext-tools && \
      git clone \
        --depth 1 \
        --branch "${ARVERA_GROMMUNIO_WEB_REF}" \
        "${ARVERA_GROMMUNIO_WEB_REPO}" \
        /tmp/arvera-grommunio-web && \
      cd /tmp/arvera-grommunio-web && \
      npm ci && \
      make deploy && \
      cp -a deploy/. /usr/share/grommunio-web/ && \
      rm -rf /tmp/arvera-grommunio-web; \
    fi


# ----------------------------------------------------------------------
# Optional Arvera admin-api fork
#
# The packaged service, uwsgi config and runtime state stay in place.
# Only the application source is replaced.
# ----------------------------------------------------------------------

RUN if [ "${ARVERA_USE_ADMIN_API_FORK}" = "1" ]; then \
      zypper --non-interactive install -y git && \
      git clone \
        --depth 1 \
        --branch "${ARVERA_ADMIN_API_REF}" \
        "${ARVERA_ADMIN_API_REPO}" \
        /tmp/arvera-admin-api && \
      rm -rf \
        /usr/share/grommunio-admin-api/api \
        /usr/share/grommunio-admin-api/cli \
        /usr/share/grommunio-admin-api/endpoints \
        /usr/share/grommunio-admin-api/orm \
        /usr/share/grommunio-admin-api/res \
        /usr/share/grommunio-admin-api/services \
        /usr/share/grommunio-admin-api/tools && \
      cp -a \
        /tmp/arvera-admin-api/api \
        /tmp/arvera-admin-api/cli \
        /tmp/arvera-admin-api/endpoints \
        /tmp/arvera-admin-api/orm \
        /tmp/arvera-admin-api/res \
        /tmp/arvera-admin-api/services \
        /tmp/arvera-admin-api/tools \
        /usr/share/grommunio-admin-api/ && \
      cp -a \
        /tmp/arvera-admin-api/main.py \
        /usr/share/grommunio-admin-api/main.py && \
      cp -a \
        /tmp/arvera-admin-api/data/api-config.ini \
        /usr/share/grommunio-admin-api/api-config.ini && \
      rm -rf /tmp/arvera-admin-api; \
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
      zypper --non-interactive install -y git nodejs npm make && \
      git clone \
        --depth 1 \
        --branch "${ARVERA_ADMIN_WEB_REF}" \
        "${ARVERA_ADMIN_WEB_REPO}" \
        /tmp/arvera-admin-web && \
      cd /tmp/arvera-admin-web && \
      npm install --global yarn@1.22.22 && \
      yarn install --frozen-lockfile --network-timeout 600000 && \
      DISABLE_ESLINT_PLUGIN=true yarn build && \
      ADMIN_WEB_DIR="/usr/share/grommunio-admin-web" && \
      test -d "${ADMIN_WEB_DIR}" && \
      rm -rf "${ADMIN_WEB_DIR:?}"/* && \
      cp -a build/. "${ADMIN_WEB_DIR}/" && \
      rm -rf /tmp/arvera-admin-web; \
    fi


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
