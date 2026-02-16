#!/bin/bash
set -e
/usr/local/bin/banner.sh

# Default values
readonly DEFAULT_PUID=1000
readonly DEFAULT_PGID=1000
readonly DEFAULT_PORT=8010
readonly DEFAULT_INTERNAL_PORT=38011
readonly DEFAULT_PROTOCOL="SHTTP"
readonly DEFAULT_API_KEY=""
readonly SAFE_API_KEY_REGEX='^[A-Za-z0-9_:.@+= -]{5,128}$'
readonly FIRST_RUN_FILE="/tmp/first_run_complete"

# Function to trim whitespace using parameter expansion
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# Validate positive integers
is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

# Generate HAProxy configuration dynamically
generate_haproxy_config() {
    local config_file="/tmp/haproxy.cfg"
    local template_file="/etc/haproxy/haproxy.cfg.template"
    
    echo "Generating HAProxy configuration..."
    
    # Read template
    if [[ ! -f "$template_file" ]]; then
        echo "Error: HAProxy template not found at $template_file"
        exit 1
    fi
    
    # Generate API key check block
    local api_key_check=""
    if [[ -n "$API_KEY" ]]; then
        # Escape API_KEY for use in HAProxy config (handle special chars)
        local escaped_key="${API_KEY//\\/\\\\}"
        escaped_key="${escaped_key//\"/\\\"}"
        
        api_key_check="    # API Key authentication enabled
    acl auth_header_present var(txn.auth_header) -m found
    acl auth_valid var(txn.auth_header) -m str \"Bearer ${escaped_key}\"
    
    # Deny requests without valid authentication
    http-request deny deny_status 401 content-type \"application/json\" string '{\"error\":\"Unauthorized\",\"message\":\"Valid API key required\"}' if !auth_header_present
    http-request deny deny_status 403 content-type \"application/json\" string '{\"error\":\"Forbidden\",\"message\":\"Invalid API key\"}' if auth_header_present !auth_valid"
    else
        api_key_check="    # API Key authentication disabled - all requests allowed"
    fi
    
    # Generate CORS check block
    local cors_check=""
    local cors_preflight_condition=""
    local cors_response_condition=""
    
    if [[ "$HAPROXY_CORS_ENABLED" == "true" ]]; then
        if [[ "$ALLOW_ALL_CORS" == "true" ]]; then
            # Allow all origins
            cors_check="    # CORS enabled - allowing ALL origins"
            cors_preflight_condition="{ var(txn.origin) -m found }"
            cors_response_condition="{ var(txn.origin) -m found }"
        else
            # Allow specific origins
            cors_check="    # CORS enabled - allowing specific origins
    acl cors_origin_allowed var(txn.origin) -m str -i"
            
            # Add each allowed origin
            for origin in "${HAPROXY_CORS_ORIGINS[@]}"; do
                cors_check+=" ${origin}"
            done
            cors_check+="
    
    # Deny requests from non-allowed origins
    http-request deny deny_status 403 content-type \"application/json\" string '{\"error\":\"Forbidden\",\"message\":\"Origin not allowed\"}' if { var(txn.origin) -m found } !cors_origin_allowed"
            
            cors_preflight_condition="cors_origin_allowed"
            cors_response_condition="cors_origin_allowed"
        fi
    else
        # CORS disabled
        cors_check="    # CORS disabled - no origin restrictions"
        cors_preflight_condition="FALSE"
        cors_response_condition="FALSE"
    fi
    
    # Replace placeholders in template
    sed -e "s|__PORT__|${PORT}|g" \
        -e "s|__INTERNAL_PORT__|${INTERNAL_PORT}|g" \
        -e "s|__CORS_PREFLIGHT_CONDITION__|${cors_preflight_condition}|g" \
        -e "s|__CORS_RESPONSE_CONDITION__|${cors_response_condition}|g" \
        "$template_file" > "$config_file.tmp"
    
    # Replace the API_KEY_CHECK placeholder with the generated block
    awk -v replacement="$api_key_check" '
        /__API_KEY_CHECK__/ {
            print replacement
            next
        }
        { print }
    ' "$config_file.tmp" > "$config_file.tmp2"
    
    # Replace the CORS_CHECK placeholder with the generated block
    awk -v replacement="$cors_check" '
        /__CORS_CHECK__/ {
            print replacement
            next
        }
        { print }
    ' "$config_file.tmp2" > "$config_file"
    
    rm -f "$config_file.tmp" "$config_file.tmp2"
    
    echo "HAProxy configuration generated at $config_file"
    return 0
}

# First run handling
handle_first_run() {
    local uid_gid_changed=0

    # Handle PUID/PGID logic
    if [[ -z "$PUID" && -z "$PGID" ]]; then
        PUID="$DEFAULT_PUID"
        PGID="$DEFAULT_PGID"
        echo "PUID and PGID not set. Using defaults: PUID=$PUID, PGID=$PGID"
    elif [[ -n "$PUID" && -z "$PGID" ]]; then
        if is_positive_int "$PUID"; then
            PGID="$PUID"
        else
            echo "Invalid PUID: '$PUID'. Using default: $DEFAULT_PUID"
            PUID="$DEFAULT_PUID"
            PGID="$DEFAULT_PGID"
        fi
    elif [[ -z "$PUID" && -n "$PGID" ]]; then
        if is_positive_int "$PGID"; then
            PUID="$PGID"
        else
            echo "Invalid PGID: '$PGID'. Using default: $DEFAULT_PGID"
            PUID="$DEFAULT_PUID"
            PGID="$DEFAULT_PGID"
        fi
    else
        if ! is_positive_int "$PUID"; then
            echo "Invalid PUID: '$PUID'. Using default: $DEFAULT_PUID"
            PUID="$DEFAULT_PUID"
        fi
        
        if ! is_positive_int "$PGID"; then
            echo "Invalid PGID: '$PGID'. Using default: $DEFAULT_PGID"
            PGID="$DEFAULT_PGID"
        fi
    fi

    # Check existing UID/GID conflicts
    local current_user current_group
    current_user=$(id -un "$PUID" 2>/dev/null || true)
    current_group=$(getent group "$PGID" | cut -d: -f1 2>/dev/null || true)

    [[ -n "$current_user" && "$current_user" != "node" ]] &&
        echo "Warning: UID $PUID already in use by $current_user - may cause permission issues"

    [[ -n "$current_group" && "$current_group" != "node" ]] &&
        echo "Warning: GID $PGID already in use by $current_group - may cause permission issues"

    # Modify UID/GID if needed - use test command instead of arithmetic expressions
    if [ "$(id -u node)" -ne "$PUID" ]; then
        if usermod -o -u "$PUID" node 2>/dev/null; then
            uid_gid_changed=1
        else
            echo "Error: Failed to change UID to $PUID. Using existing UID $(id -u node)"
            PUID=$(id -u node)
        fi
    fi

    if [ "$(id -g node)" -ne "$PGID" ]; then
        if groupmod -o -g "$PGID" node 2>/dev/null; then
            uid_gid_changed=1
        else
            echo "Error: Failed to change GID to $PGID. Using existing GID $(id -g node)"
            PGID=$(id -g node)
        fi
    fi

    [ "$uid_gid_changed" -eq 1 ] && echo "Updated UID/GID to PUID=$PUID, PGID=$PGID"
    
    # Generate HAProxy config on first run
    if ! generate_haproxy_config; then
        echo "Error: Failed to generate HAProxy configuration"
        exit 1
    fi
    
    touch "$FIRST_RUN_FILE"
}

# Validate and set PORT
validate_port() {
    # Ensure PORT has a value
    PORT=${PORT:-$DEFAULT_PORT}
    
    # Check if PORT is a positive integer
    if ! is_positive_int "$PORT"; then
        echo "Invalid PORT: '$PORT'. Using default: $DEFAULT_PORT"
        PORT="$DEFAULT_PORT"
    elif [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "Invalid PORT: '$PORT'. Using default: $DEFAULT_PORT"
        PORT="$DEFAULT_PORT"
    fi
    
    # Check if port is privileged - use test command instead of arithmetic expression
    if [ "$PORT" -lt 1024 ] && [ "$(id -u)" -ne 0 ]; then
        echo "Warning: Port $PORT is privileged and might require root"
    fi
}

# Validate and set API_KEY
validate_api_key() {
    if [[ -n "$API_KEY" ]]; then
        if [[ "$API_KEY" =~ $SAFE_API_KEY_REGEX ]]; then
            [[ "$API_KEY" =~ ^(password|secret|admin|token|key|test|demo)$ ]] &&
                echo "Warning: API_KEY is using a common value - consider more complex key"
            # Export for HAProxy to use
            export API_KEY
        else
            echo "Invalid API_KEY. Must be 5-128 chars with safe symbols. Ignoring API_KEY."
            unset API_KEY
        fi
    else
        unset API_KEY
    fi
}

# Validate CORS patterns - HAProxy only
validate_cors() {
    ALLOW_ALL_CORS=false
    HAPROXY_CORS_ENABLED=false
    HAPROXY_CORS_ORIGINS=()
    local cors_value

    if [[ -n "${CORS}" ]]; then
        HAPROXY_CORS_ENABLED=true
        IFS=',' read -ra CORS_VALUES <<< "$CORS"
        for cors_value in "${CORS_VALUES[@]}"; do
            cors_value=$(trim "$cors_value")
            [[ -z "$cors_value" ]] && continue

            if [[ "$cors_value" =~ ^(all|\*)$ ]]; then
                ALLOW_ALL_CORS=true
                HAPROXY_CORS_ORIGINS=("*")
                echo "Caution! CORS allowing ALL origins - security risk in production!"
                break
            elif [[ "$cors_value" =~ ^https?:// ]]; then
                # Valid HTTP/HTTPS URL
                HAPROXY_CORS_ORIGINS+=("$cors_value")
            elif [[ "$cors_value" =~ ^https?://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
                # Valid HTTP/HTTPS with IP
                HAPROXY_CORS_ORIGINS+=("$cors_value")
            elif [[ "$cors_value" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?$ ]]; then
                # Domain without protocol - add both http and https variants for HAProxy
                HAPROXY_CORS_ORIGINS+=("http://$cors_value")
                HAPROXY_CORS_ORIGINS+=("https://$cors_value")
            elif [[ "$cors_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
                # IP address without protocol - add both http and https variants for HAProxy
                HAPROXY_CORS_ORIGINS+=("http://$cors_value")
                HAPROXY_CORS_ORIGINS+=("https://$cors_value")
            elif [[ "$cors_value" =~ ^/.*/$ ]]; then
                # Regex pattern - not supported by HAProxy
                echo "Warning: CORS regex pattern '$cors_value' not supported by HAProxy - skipping"
            else
                echo "Warning: Invalid CORS pattern '$cors_value' - skipping"
            fi
        done
    fi
}

# Start HAProxy with dynamically generated configuration
start_haproxy() {
    echo "Starting HAProxy on port $PORT..."
    
    # Display authentication status
    if [[ -n "$API_KEY" ]]; then
        echo "API_KEY authentication ENABLED via HAProxy"
    else
        echo "API_KEY authentication DISABLED - all requests will be forwarded"
    fi
    
    # Display CORS status
    if [[ "$HAPROXY_CORS_ENABLED" == "true" ]]; then
        if [[ "$ALLOW_ALL_CORS" == "true" ]]; then
            echo "CORS: Allowing ALL origins (wildcard)"
        else
            echo "CORS: Restricting to allowed origins:"
            for origin in "${HAPROXY_CORS_ORIGINS[@]}"; do
                echo "  - $origin"
            done
        fi
    else
        echo "CORS: Disabled (no origin restrictions)"
    fi
    
    # Validate HAProxy config
    if ! haproxy -c -f /tmp/haproxy.cfg 2>&1; then
        echo "Error: Invalid HAProxy configuration"
        cat /tmp/haproxy.cfg
        exit 1
    fi
    
    # Start HAProxy in background as root (needed for port binding)
    haproxy -f /tmp/haproxy.cfg &
    HAPROXY_PID=$!
    
    # Wait a moment for HAProxy to start
    sleep 2
    
    if ! kill -0 $HAPROXY_PID 2>/dev/null; then
        echo "Error: HAProxy failed to start"
        exit 1
    fi
    
    echo "HAProxy started successfully (PID: $HAPROXY_PID)"
}

# Main execution
main() {
    # Trim all input parameters
    [[ -n "${PUID:-}" ]] && PUID=$(trim "$PUID")
    [[ -n "${PGID:-}" ]] && PGID=$(trim "$PGID")
    [[ -n "${PORT:-}" ]] && PORT=$(trim "$PORT")
    [[ -n "${API_KEY:-}" ]] && API_KEY=$(trim "$API_KEY")
    [[ -n "${PROTOCOL:-}" ]] && PROTOCOL=$(trim "$PROTOCOL")
    [[ -n "${CORS:-}" ]] && CORS=$(trim "$CORS")

    # Validate configurations FIRST (before first run handling)
    validate_port
    validate_api_key
    validate_cors

    # Set INTERNAL_PORT early so it's available for config generation
    INTERNAL_PORT=$DEFAULT_INTERNAL_PORT

    # First run handling (now with all variables set)
    if [[ ! -f "$FIRST_RUN_FILE" ]]; then
        handle_first_run
    fi

    # Build MCP server command - Context7 MCP
    MCP_SERVER_CMD="npx -y @upstash/context7-mcp"
    
    # Add API key to MCP command only if it's set and valid
    # Note: This is for the MCP server itself, HAProxy handles the authentication
    # but we can still pass it to the MCP server for additional validation
    if [[ -n "$API_KEY" ]]; then
        MCP_SERVER_CMD+=" --api-key $API_KEY"
    fi

    # Protocol selection - now using INTERNAL_PORT instead of PORT
    local PROTOCOL_UPPER=${PROTOCOL:-$DEFAULT_PROTOCOL}
    PROTOCOL_UPPER=${PROTOCOL_UPPER^^}

    case "$PROTOCOL_UPPER" in
        "SHTTP"|"STREAMABLEHTTP")
            CMD_ARGS=(npx --yes supergateway --port "$INTERNAL_PORT" --streamableHttpPath /mcp --outputTransport streamableHttp --healthEndpoint /healthz --stdio "$MCP_SERVER_CMD")
            PROTOCOL_DISPLAY="SHTTP/streamableHttp"
            ;;
        "SSE")
            CMD_ARGS=(npx --yes supergateway --port "$INTERNAL_PORT" --ssePath /sse --outputTransport sse --healthEndpoint /healthz --stdio "$MCP_SERVER_CMD")
            PROTOCOL_DISPLAY="SSE/Server-Sent Events"
            ;;
        "WS"|"WEBSOCKET")
            CMD_ARGS=(npx --yes supergateway --port "$INTERNAL_PORT" --messagePath /message --outputTransport ws --healthEndpoint /healthz --stdio "$MCP_SERVER_CMD")
            PROTOCOL_DISPLAY="WS/WebSocket"
            ;;
        *)
            echo "Invalid PROTOCOL: '$PROTOCOL'. Using default: $DEFAULT_PROTOCOL"
            CMD_ARGS=(npx --yes supergateway --port "$INTERNAL_PORT" --streamableHttpPath /mcp --outputTransport streamableHttp --healthEndpoint /healthz --stdio "$MCP_SERVER_CMD")
            PROTOCOL_DISPLAY="SHTTP/streamableHttp"
            ;;
    esac

    # Debug mode handling
    case "${DEBUG_MODE:-}" in
        [1YyTt]*|[Oo][Nn]|[Yy][Ee][Ss]|[Ee][Nn][Aa][Bb][Ll][Ee]*)
            echo "DEBUG MODE: Installing nano and pausing container"
            apk add --no-cache nano 2>/dev/null || echo "Warning: Failed to install nano"
            echo "Container paused for debugging. Exec into container to investigate."
            exec tail -f /dev/null
            ;;
        *)
            # Normal execution
            echo "Launching Context7 MCP Server with protocol: $PROTOCOL_DISPLAY"
            echo "External port: $PORT (via HAProxy). *** Use this port to connect to this MCP server. ***"
            echo "Internal port: $INTERNAL_PORT (MCP server)"
            
            # Check for npx availability
            if ! command -v npx &>/dev/null; then
                echo "Error: npx not available. Cannot start server."
                exit 1
            fi

            # Check for haproxy availability
            if ! command -v haproxy &>/dev/null; then
                echo "Error: haproxy not available. Cannot start reverse proxy."
                exit 1
            fi

            # Start HAProxy first (runs as root)
            start_haproxy

            # Execute MCP server with appropriate user switching
            if [ "$(id -u)" -eq 0 ]; then
                exec su-exec node "${CMD_ARGS[@]}"
            else
                if [ "$INTERNAL_PORT" -lt 1024 ]; then
                    echo "Error: Cannot bind to privileged port $INTERNAL_PORT without root"
                    exit 1
                fi
                exec "${CMD_ARGS[@]}"
            fi
            ;;
    esac
}

# Run the script with error handling
if main "$@"; then
    exit 0
else
    exit 1
fi