FROM ubuntu:24.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    gnupg2 \
    ca-certificates \
    lsb-release \
    ubuntu-keyring \
    git \
    && rm -rf /var/lib/apt/lists/*

# Add NGINX official repository
RUN curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null && \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list

# Install NGINX 1.30.3 (intentionally vulnerable version for training)
RUN apt-get update && apt-get install -y \
    nginx=1.30.3-1~noble \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy application files
COPY package*.json ./
RUN npm install --production

COPY app.js ./
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh

# Create nginx directories
RUN mkdir -p /var/run/nginx /var/log/nginx

# Set environment variables
ENV NGINX_VERSION=1.30.3
ENV VULNERABILITY_STATUS=vulnerable
ENV ENVIRONMENT=training
ENV PORT=3000

# Expose ports
EXPOSE 3000 80 443

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Run entrypoint
ENTRYPOINT ["/entrypoint.sh"]
