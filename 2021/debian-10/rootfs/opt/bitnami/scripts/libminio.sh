#!/bin/bash
#
# Bitnami MinIO library

# shellcheck disable=SC1091

# Load Libraries
. /opt/bitnami/scripts/libservice.sh
. /opt/bitnami/scripts/libnet.sh
. /opt/bitnami/scripts/libos.sh
. /opt/bitnami/scripts/libvalidations.sh
. /opt/bitnami/scripts/libminioclient.sh

# Functions

########################
# Checks if MINIO_DISTRIBUTED_NODES uses the ellipses syntax {1...n}
# Globals:
#   MINIO_DISTRIBUTED_NODES
# Arguments:
#   None
# Returns:
#   Boolean
#########################
is_distributed_ellipses_syntax() {
    ! is_empty_value "$MINIO_DISTRIBUTED_NODES" && [[ $MINIO_DISTRIBUTED_NODES == *"..."* ]]
}

########################
# Obtain the list of drives used by the MinIO node
# Globals:
#   MINIO_DISTRIBUTED_NODES
# Arguments:
#   None
# Returns:
#   Array with MinIO node drives
#########################
minio_distributed_drives() {
    local -a drives=()
    local -a nodes

    if ! is_empty_value "$MINIO_DISTRIBUTED_NODES"; then
        read -r -a nodes <<< "$(tr ',;' ' ' <<< "${MINIO_DISTRIBUTED_NODES}")"
        for node in "${nodes[@]}"; do
            drive="$(parse_uri "${MINIO_SCHEME}://${node}" "path")"
            drives+=("$drive")
        done
    fi
    echo "${drives[@]}"
}

########################
# Checks if MinIO is running
# Globals:
#   MINIO_PID
# Arguments:
#   None
# Returns:
#   Boolean
#########################
is_minio_running() {
    local status
    if [[ -z "${MINIO_PID:-}" ]]; then
        false
    else
        if ! is_service_running "$MINIO_PID"; then
            false
        else
            status="$(minio_client_execute_timeout admin info local --json | jq -r .info.mode)"
            if [[ "$status" = "online" ]]; then
                true
            else
                false
            fi
        fi
    fi
}

########################
# Start MinIO in background and wait until it's ready
# Globals:
#   MINIO_*
# Arguments:
#   None
# Returns:
#   None
#########################
minio_start_bg() {
    local -r exec=$(command -v minio)
    local -a args=("server" "--certs-dir" "${MINIO_CERTS_DIR}" "--console-address" ":${MINIO_CONSOLE_PORT_NUMBER}" "--address" ":${MINIO_API_PORT_NUMBER}")
    local -a nodes

    if is_boolean_yes "$MINIO_DISTRIBUTED_MODE_ENABLED"; then
        read -r -a nodes <<< "$(tr ',;' ' ' <<< "${MINIO_DISTRIBUTED_NODES}")"
        for node in "${nodes[@]}"; do
            if is_distributed_ellipses_syntax; then
                args+=("${MINIO_SCHEME}://${node}")
            else
                args+=("${MINIO_SCHEME}://${node}:${MINIO_API_PORT_NUMBER}/${MINIO_DATA_DIR}")
            fi
        done
    else
        args+=("${MINIO_DATA_DIR}")
    fi

    is_minio_running && return
    info "Starting MinIO in background..."
    if [[ "${BITNAMI_DEBUG:-false}" = true ]]; then
        "${exec}" "${args[@]}" &
    else
        "${exec}" "${args[@]}" >/dev/null 2>&1 &
    fi
    export MINIO_PID="$!"
    sleep 10
}

########################
# Stop MinIO
# Arguments:
#   None
# Returns:
#   None
#########################
minio_stop() {
    if is_minio_running; then
        info "Stopping MinIO..."
        minio_client_execute_timeout admin service stop local >/dev/null 2>&1 || true

        local counter=5
        while is_minio_running || is_service_running "$MINIO_PID"; do
            if [[ "$counter" -le 0 ]]; then
                break
            fi
            sleep 1;
            counter=$((counter - 1))
        done
    else
        info "MinIO is already stopped..."
    fi
}

########################
# Validate settings in MINIO_* env vars.
# Globals:
#   MINIO_*
# Arguments:
#   None
# Returns:
#   None
#########################
minio_validate() {
    debug "Validating settings in MINIO_* env vars.."
    local error_code=0

    # Auxiliary functions
    print_validation_error() {
        error "$1"
        error_code=1
    }
    check_yes_no_value() {
        if ! is_yes_no_value "${!1}"; then
            print_validation_error "The allowed values for $1 are [yes, no]"
        fi
    }
    check_allowed_port() {
        local validate_port_args=()
        ! am_i_root && validate_port_args+=("-unprivileged")
        if ! err=$(validate_port "${validate_port_args[@]}" "${!1}"); then
            print_validation_error "An invalid port was specified in the environment variable $1: $err"
        fi
    }

    if is_boolean_yes "$MINIO_DISTRIBUTED_MODE_ENABLED"; then
        if [[ -z "${MINIO_ROOT_USER:-}" ]] || [[ -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
            print_validation_error "Distributed mode is enabled. Both MINIO_ROOT_USER and MINIO_ROOT_PASSWORD environment must be set"
        fi
        if [[ -z "${MINIO_DISTRIBUTED_NODES:-}" ]]; then
            print_validation_error "Distributed mode is enabled. Nodes must be indicated setting the environment variable MINIO_DISTRIBUTED_NODES"
        else
            read -r -a nodes <<< "$(tr ',;' ' ' <<< "${MINIO_DISTRIBUTED_NODES}")"
            if ! is_distributed_ellipses_syntax && ([[ "${#nodes[@]}" -lt 4 ]] || (( "${#nodes[@]}" % 2 ))); then
                print_validation_error "Number of nodes must even and greater than 4."
            fi
        fi
    else
        if [[ -n "${MINIO_DISTRIBUTED_NODES:-}" ]]; then
            warn "Distributed mode is not enabled. The nodes set at the environment variable MINIO_DISTRIBUTED_NODES will be ignored."
        fi
    fi
    if [[ -n "${MINIO_BROWSER:-}" ]]; then
        shopt -s nocasematch
        if [[ "$MINIO_BROWSER" = "off" ]]; then
            warn "Access to MinIO web UI is disabled!! More information at: https://github.com/minio/minio/tree/master/docs/config/#browser"
        fi
        shopt -u nocasematch
    fi
    if [[ -n "${MINIO_HTTP_TRACE:-}" ]]; then
        if [[ -w "$MINIO_HTTP_TRACE" ]]; then
            info "HTTP log trace enabled. Find the HTTP logs at: $MINIO_HTTP_TRACE"
        else
            print_validation_error "The HTTP log file specified at the environment variable MINIO_HTTP_TRACE is not writtable by current user \"$(id -u)\""
        fi
    fi

    check_yes_no_value MINIO_SKIP_CLIENT
    check_yes_no_value MINIO_DISTRIBUTED_MODE_ENABLED
    check_yes_no_value MINIO_FORCE_NEW_KEYS
    check_allowed_port MINIO_CONSOLE_PORT_NUMBER
    check_allowed_port MINIO_API_PORT_NUMBER

    [[ "$error_code" -eq 0 ]] || exit "$error_code"
}

########################
# Create default buckets
# Globals:
#   MINIO_DEFAULT_BUCKETS
# Arguments:
#   None
# Returns:
#   None
#########################
minio_create_default_buckets() {
    if [[ -n "$MINIO_DEFAULT_BUCKETS" ]]; then
        read -r -a buckets <<< "$(tr ',;' ' ' <<< "${MINIO_DEFAULT_BUCKETS}")"
        info "Creating default buckets..."
        for b in "${buckets[@]}"; do
            read -r -a bucket_info <<< "$(tr ':' ' ' <<< "${b}")"
            if ! minio_client_bucket_exists "local/${bucket_info[0]}"; then
                if [[ -n "${MINIO_REGION_NAME:-}" ]]; then
                    minio_client_execute mb "--region" "${MINIO_REGION_NAME}" "local/${bucket_info[0]}"
                else
                    minio_client_execute mb "local/${bucket_info[0]}"
                fi
                if [ ${#bucket_info[@]} -eq 2 ]; then
                    info "Setting policy ${bucket_info[1]} for local bucket ${bucket_info[0]}"
                    minio_client_execute policy set "${bucket_info[1]}" local/"${bucket_info[0]}"/
                fi
            else
                info "Bucket local/${bucket_info[0]} already exists, skipping creation."
            fi
        done
    fi
}

########################
# Regenerate MinIO credentials
# Globals:
#   MINIO_*
# Arguments:
#   None
# Returns:
#   None
#########################
minio_regenerate_keys() {
    local error_code=0
    if is_boolean_yes "$MINIO_FORCE_NEW_KEYS" && [[ -f "${MINIO_DATA_DIR}/.root_user" ]] && [[ -f "${MINIO_DATA_DIR}/.root_password" ]]; then
        MINIO_ROOT_USER_OLD="$(cat "${MINIO_DATA_DIR}/.root_user")"
        MINIO_ROOT_PASSWORD_OLD="$(cat "${MINIO_DATA_DIR}/.root_password")"
        if [[ "$MINIO_ROOT_USER_OLD" != "$MINIO_ROOT_USER" ]] || [[ "$MINIO_ROOT_PASSWORD_OLD" != "$MINIO_ROOT_PASSWORD" ]]; then
            info "Reconfiguring MinIO credentials..."
            export MINIO_ROOT_USER_OLD MINIO_ROOT_PASSWORD_OLD
            # Restart MinIO to reconfigure credentials
            # ref: https://docs.min.io/docs/minio-server-configuration-guide.html
            minio_start_bg
            info "Forcing container restart after key regeneration"
            error_code=1
        fi
    fi
    echo "$MINIO_ROOT_USER" > "${MINIO_DATA_DIR}/.root_user"
    echo "$MINIO_ROOT_PASSWORD" > "${MINIO_DATA_DIR}/.root_password"
    chmod 600 "${MINIO_DATA_DIR}/.root_user" "${MINIO_DATA_DIR}/.root_password"

    [[ "$error_code" -eq 0 ]] || exit "$error_code"
}

########################
# Return the node name of this instance
# Globals:
#   MINIO_DISTRIBUTED_MODE_ENABLED
#   MINIO_DISTRIBUTED_NODES
# Arguments:
#   None
# Returns:
#   None
#########################
minio_node_hostname() {
    if is_boolean_yes "$MINIO_DISTRIBUTED_MODE_ENABLED"; then
        read -r -a nodes <<< "$(tr ',;' ' ' <<< "${MINIO_DISTRIBUTED_NODES}")"
        for node in "${nodes[@]}"; do
            [[ $(get_machine_ip) = $(dns_lookup "$node") ]] && echo "$node" && return
        done
        error "Could not find own node in MINIO_DISTRIBUTE_NODES: ${MINIO_DISTRIBUTED_NODES}"
        exit 1
    else
        echo "localhost"
    fi
}
