ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ARG NGINX_VERSION=1.30.3
ARG NODE_MAJOR_VERSION=20
ARG VULNERABILITY_STATUS=vulnerable
ARG PORT=3000

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

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR_VERSION}.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy application files
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY app.js ./
COPY config.json ./
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh

# Create nginx directories
RUN mkdir -p /var/run/nginx /var/log/nginx

# Set environment variables
ENV NGINX_VERSION=${NGINX_VERSION}
ENV VULNERABILITY_STATUS=${VULNERABILITY_STATUS}
ENV PORT=${PORT}

# Expose ports
EXPOSE 80 ${PORT}

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f "http://localhost:${PORT}/health" || exit 1

# Run entrypoint
ENTRYPOINT ["/entrypoint.sh"]
