ARG BASE_OS_IMAGE=ubuntu
ARG BASE_OS_VERSION=24.04
FROM ${BASE_OS_IMAGE}:${BASE_OS_VERSION}

ARG BASE_OS_IMAGE=ubuntu
ARG BASE_OS_VERSION=24.04
ARG NGINX_VERSION=1.30.3
ARG NODE_MAJOR_VERSION=20
ARG VULNERABILITY_STATUS=vulnerable
ARG PORT=3000
ARG DEFENDER_ENABLED=false
ARG NPM_REGISTRY_URL=https://registry.npmjs.org
ARG NPM_USE_MIRROR=true
ARG NPM_NETWORK_MODE=online

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    ca-certificates \
    lsb-release \
    ubuntu-keyring \
    && rm -rf /var/lib/apt/lists/*

# Add NGINX official repository
RUN curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null && \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list

# Pin the training dependency so scanners see the intended lab state.
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx=${NGINX_VERSION}-1~noble \
    && rm -rf /var/lib/apt/lists/*

RUN nginx -v 2>&1 | tee /opt/nginx-version.txt
RUN dpkg-query -W nginx | tee /opt/nginx-package-version.txt
RUN dpkg -l | grep nginx | tee /opt/nginx-installed-packages.txt

LABEL security.repro.cve="CVE-2026-42533"
LABEL security.repro.component="nginx"
LABEL security.repro.version="1.30.3"
LABEL security.repro.expected_result="Defender should associate CVE-2026-42533"

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR_VERSION}.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy application files
COPY package*.json ./
RUN if [ "${NPM_NETWORK_MODE}" = "offline" ]; then \
        npm ci --offline --omit=dev --ignore-scripts; \
    else \
        if [ "${NPM_USE_MIRROR}" = "true" ]; then npm config set registry "${NPM_REGISTRY_URL}"; else npm config delete registry || true; fi && \
        npm ci --omit=dev --ignore-scripts; \
    fi && \
    npm cache clean --force

COPY src ./src
COPY nginx.conf /etc/nginx/nginx.conf.template
COPY entrypoint.sh /entrypoint.sh
COPY scripts/verify.sh /usr/local/bin/verify.sh

# Create nginx directories
RUN mkdir -p /var/run/nginx /var/log/nginx

# Set environment variables
ENV BASE_OS_IMAGE=${BASE_OS_IMAGE}
ENV BASE_OS_VERSION=${BASE_OS_VERSION}
ENV NGINX_VERSION=${NGINX_VERSION}
ENV NODE_MAJOR_VERSION=${NODE_MAJOR_VERSION}
ENV VULNERABILITY_STATUS=${VULNERABILITY_STATUS}
ENV PORT=${PORT}
ENV DEFENDER_ENABLED=${DEFENDER_ENABLED}

# Expose ports
EXPOSE 80 ${PORT}

# Make container scripts executable
RUN chmod +x /entrypoint.sh /usr/local/bin/verify.sh

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

# Run entrypoint
ENTRYPOINT ["/entrypoint.sh"]
