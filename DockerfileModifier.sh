#!/bin/bash
set -ex
# Set variables first
REPO_NAME='context7-mcp'
BASE_IMAGE=$(cat ./build_data/base-image 2>/dev/null || echo "node:alpine")
CONTEXT7_VERSION=$(cat ./build_data/version 2>/dev/null || exit 1)
CONTEXT7_MCP_PKG="@upstash/context7-mcp@${CONTEXT7_VERSION}"
SUPERGATEWAY_PKG='supergateway@latest'
DOCKERFILE_NAME="Dockerfile.$REPO_NAME"

# Create a temporary file safely
TEMP_FILE=$(mktemp "${DOCKERFILE_NAME}.XXXXXX") || {
    echo "Error creating temporary file" >&2
    exit 1
}

# Check if this is a publication build
if [ -e ./build_data/publication ]; then
    # For publication builds, create a minimal Dockerfile that just tags the existing image
    {
        echo "ARG BASE_IMAGE=$BASE_IMAGE"
        echo "ARG CONTEXT7_VERSION=$CONTEXT7_VERSION"
        echo "FROM $BASE_IMAGE"
    } > "$TEMP_FILE"
else
    # Write the Dockerfile content to the temporary file first
    {
        echo "ARG BASE_IMAGE=$BASE_IMAGE"
        echo "ARG CONTEXT7_VERSION=$CONTEXT7_VERSION"
        cat << EOF
FROM $BASE_IMAGE AS build

# Author info:
LABEL org.opencontainers.image.authors="MOHAMMAD MEKAYEL ANIK <mekayel.anik@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/mekayelanik/context7-mcp-docker"

# Copy the entrypoint script into the container and make it executable
COPY ./resources/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/banner.sh \
    && chmod +r /usr/local/bin/build-timestamp.txt

# Install required APK packages
RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    apk --update-cache --no-cache add bash shadow su-exec tzdata && \
    rm -rf /var/cache/apk/*

# Check if package exists before installing
RUN echo "Checking if package exists: ${CONTEXT7_MCP_PKG}" && \
    if npm view ${CONTEXT7_MCP_PKG} >/dev/null 2>&1; then \
        echo "Package found, installing..." && \
        npm install -g ${CONTEXT7_MCP_PKG} --loglevel verbose && \
        echo "Package installed successfully"; \
    else \
        echo "ERROR: Package ${CONTEXT7_MCP_PKG} not found in registry!" >&2; \
        echo "Available versions:" && \
        npm view @upstash/context7-mcp versions --json | tr -d '\[\],' | tr '"' '\n' | grep -v '^$' | head -10; \
        exit 1; \
    fi

# Install Supergateway
RUN echo "Installing Supergateway..." && \
    npm install -g ${SUPERGATEWAY_PKG} --loglevel verbose && \
    npm cache clean --force

# Use an ARG for the default port
ARG PORT=8010

# Add ARG for API key
ARG API_KEY=""

# Set an ENV variable from the ARG for runtime
ENV PORT=\${PORT}
ENV API_KEY=\${API_KEY}

# Health check using nc (netcat) to check if the port is open
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \\
    CMD nc -z localhost \${PORT:-8010} || exit 1

# Set the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

EOF
    } > "$TEMP_FILE"
fi

# Atomically replace the target file with the temporary file
if mv -f "$TEMP_FILE" "$DOCKERFILE_NAME"; then
    echo "Dockerfile for $REPO_NAME created successfully."
else
    echo "Error: Failed to create Dockerfile for $REPO_NAME" >&2
    rm -f "$TEMP_FILE"
    exit 1
fi
