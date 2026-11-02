FROM python:3.13-slim-bookworm

ARG GIT_COMMIT=unknown

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    LC_CTYPE=C.UTF-8 \
    LANG=C.UTF-8 \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC \
    PORT=8080

# Enable contrib & non-free repositories for official unrar and install runtime tools
RUN if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources; \
    elif [ -f /etc/apt/sources.list ]; then \
        sed -i 's/main$/main contrib non-free non-free-firmware/g' /etc/apt/sources.list; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        7zip \
        ca-certificates \
        curl \
        gosu \
        libavahi-compat-libdnssd1 \
        par2 \
        tzdata \
        unrar \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies first for optimal layer caching
COPY requirements.txt /app/requirements.txt
RUN python3 -m pip install --no-cache-dir --upgrade pip wheel \
    && python3 -m pip install --no-cache-dir --no-dependencies -r /app/requirements.txt

# Copy application source and compile translations
COPY . /app
RUN if [ "${GIT_COMMIT}" != "unknown" ]; then \
        sed -i "s/__baseline__ = .*/__baseline__ = \"${GIT_COMMIT}\"/" /app/sabnzbd/version.py; \
    fi \
    && python3 /app/tools/make_mo.py \
    && rm -rf /app/po /app/tools

# Create NAS-friendly entrypoint supporting PUID/PGID, TZ, UMASK, and HOST_WHITELIST
RUN printf '#!/bin/sh\n\
set -e\n\
\n\
if [ -n "${TZ}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then\n\
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime\n\
    echo "${TZ}" > /etc/timezone\n\
fi\n\
\n\
if [ -n "${UMASK}" ]; then\n\
    umask "${UMASK}"\n\
fi\n\
\n\
mkdir -p /config /downloads /incomplete-downloads\n\
chown -R "${PUID}:${PGID}" /config\n\
\n\
# Ensure download dirs are writable when newly created\n\
chown "${PUID}:${PGID}" /downloads /incomplete-downloads 2>/dev/null || true\n\
\n\
if [ -n "${HOST_WHITELIST}" ] && [ -f /config/sabnzbd.ini ]; then\n\
    sed -i "s/^host_whitelist =.*/host_whitelist = ${HOST_WHITELIST}/" /config/sabnzbd.ini\n\
fi\n\
\n\
if [ "$(id -u)" = "0" ] && [ "${PUID}" != "0" ]; then\n\
    exec gosu "${PUID}:${PGID}" python3 /app/SABnzbd.py -f /config -s "0.0.0.0:${PORT:-8080}" -b 0 --console "$@"\n\
else\n\
    exec python3 /app/SABnzbd.py -f /config -s "0.0.0.0:${PORT:-8080}" -b 0 --console "$@"\n\
fi\n' > /usr/local/bin/docker-entrypoint.sh \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME ["/config", "/downloads", "/incomplete-downloads"]

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT:-8080}/" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

