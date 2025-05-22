#!/bin/bash

# Helper function to gracefully shut down our child processes when we exit.
clean_exit() {
    for PID in "${NGINX_PID}" "${CERTBOT_LOOP_PID}"; do
        if kill -0 "${PID}" 2>/dev/null; then
            kill -SIGTERM "${PID}"
            wait "${PID}"
        fi
    done
}

# Make bash listen to the SIGTERM, SIGINT and SIGQUIT kill signals, and make
# them trigger a normal "exit" command in this script. Then we tell bash to
# execute the "clean_exit" function, seen above, in the case an "exit" command
# is triggered. This is done to give the child processes a chance to exit
# gracefully.
trap "exit" TERM INT QUIT
trap "clean_exit" EXIT

# Source "util.sh" so we can have our nice tools.
. "$(cd "$(dirname "$0")"; pwd)/util.sh"

# Configuration file
if [ -n "${NGINX_CERTBOT_CONFIG_FILE}" ] && [ ! -f "${NGINX_CERTBOT_CONFIG_FILE}" ]; then
    # If the variable is set but the file doesn't exist we error out since this
    # is most likely a user error.
    error "NGINX_CERTBOT_CONFIG_FILE is configured but '${NGINX_CERTBOT_CONFIG_FILE}' does not exist, exiting"
    exit 1
fi
export CONFIG_FILE="${NGINX_CERTBOT_CONFIG_FILE:-/etc/nginx-certbot/config.yml}"

# If the config file exist we extract configuration from it and override any corresponding environment variables:
#   - nginx-certbot.debug overrides DEBUG
#   - nginx-certbot.dhparam-size overrides DHPARAM_SIZE
#   - nginx-certbot.renewal-interval overrides RENEWAL_INTERVAL
if [ -f "${CONFIG_FILE}" ]; then
    debug "Configuration file '${CONFIG_FILE}' exist."
    YAML_DEBUG=$(shyaml get-value nginx-certbot.debug '' < "${CONFIG_FILE}")
    if [ "${YAML_DEBUG}" == "True" ] || [ "${YAML_DEBUG}" == "1" ]; then
        export DEBUG=1
    elif [ "${YAML_DEBUG}" == "False" ] || [ "${YAML_DEBUG}" == "0" ]; then
        export DEBUG=0
    fi
    YAML_DHPARAM_SIZE=$(shyaml get-value nginx-certbot.dhparam-size '' < "${CONFIG_FILE}")
    if [ -n "${YAML_DHPARAM_SIZE}" ]; then
        export DHPARAM_SIZE=${YAML_DHPARAM_SIZE}
    fi
    YAML_RENEWAL_INTERVAL=$(shyaml get-value nginx-certbot.renewal-interval '' < "${CONFIG_FILE}")
    if [ -n "${YAML_RENEWAL_INTERVAL}" ]; then
        export RENEWAL_INTERVAL=${YAML_RENEWAL_INTERVAL}
    fi
else
    debug "Configuration file '${CONFIG_FILE}' doesn't exist. Falling back to environment variables and default values."
fi

# If the environment variable `DEBUG=1` is set, then this message is printed.
debug "Debug messages are enabled"

# Immediately symlink files to the correct locations and then run
# 'auto_enable_configs' so that Nginx is in a runnable state
# This will temporarily disable any misconfigured servers.
symlink_user_configs
auto_enable_configs

# Start Nginx without its daemon mode (and save its PID).
if [ 1 = "${DEBUG}" ]; then
    info "Starting the Nginx service in debug mode"
    nginx-debug -g "daemon off;" &
    NGINX_PID=$!
else
    info "Starting the Nginx service"
    nginx -g "daemon off;" &
    NGINX_PID=$!
fi
debug "PID of the main Nginx process: ${NGINX_PID}"

# Make sure a renewal interval is set before continuing.
if [ -z "${RENEWAL_INTERVAL}" ]; then
    debug "RENEWAL_INTERVAL unset, using default of '8d'"
    RENEWAL_INTERVAL='8d'
fi

# Instead of trying to run 'cron' or something like that, just sleep and
# call on certbot after the defined interval.
(
set -e
while true; do
    info "Running the autorenewal service"

    # Create symlinks from conf.d/ to user_conf.d/ if necessary.
    symlink_user_configs

    # Check that all dhparam files exists.
    "$(cd "$(dirname "$0")"; pwd)/create_dhparams.sh"

    if [ 1 = "${USE_LOCAL_CA}" ]; then
        # Renew all certificates with the help of the local CA.
        "$(cd "$(dirname "$0")"; pwd)/run_local_ca.sh"
    else
        # Run certbot to check if any certificates needs renewal.
        "$(cd "$(dirname "$0")"; pwd)/run_certbot.sh"
    fi

    # Finally we sleep for the defined time interval before checking the
    # certificates again.
    # The "if" statement afterwards is to enable us to terminate this sleep
    # process (via the HUP trap) without tripping the "set -e" setting.
    info "Autorenewal service will now sleep ${RENEWAL_INTERVAL}"
    sleep "${RENEWAL_INTERVAL}" || x=$?; if [ -n "${x}" ] && [ "${x}" -ne "143" ]; then exit "${x}"; fi
done
) &
CERTBOT_LOOP_PID=$!
debug "PID of the autorenewal loop: ${CERTBOT_LOOP_PID}"

# A helper function to prematurely terminate the sleep process, inside the
# autorenewal loop process, in order to immediately restart the loop again
# and thus reload any configuration files.
reload_configs() {
    info "Received SIGHUP signal; terminating the autorenewal sleep process"
    if ! pkill -15 -P "${CERTBOT_LOOP_PID}" -fx "sleep ${RENEWAL_INTERVAL}"; then
        warning "No sleep process found, this most likely means that a renewal process is currently running"
    fi
    # On success we return 128 + SIGHUP in order to reduce the complexity of
    # the final wait loop.
    return 129
}

# Create a trap that listens to SIGHUP and runs the reloader function in case
# such a signal is received.
trap "reload_configs" HUP

# Signal handler for SIGUSR1: forward it to nginx to reopen log files
reopen_logs() {
    info "Received SIGUSR1 signal; telling nginx to reopen log files"
    nginx -s reopen
    return 138 # 128 + SIGUSR1
}
trap "reopen_logs" USR1

# Nginx and the certbot update-loop process are now our children. As a parent
# we will wait for both of their PIDs, and if one of them exits we will follow
# suit and use the same status code as the program which exited first.
# The loop is necessary since the signal traps will make any "wait" return
# immediately when triggered, and to not exit the entire program we will have
# to wait on the original PIDs again.
while [ -z "${exit_code}" ] || [ "${exit_code}" = "129" ] || [ "${exit_code}" = "138" ]; do
    wait -n ${NGINX_PID} ${CERTBOT_LOOP_PID}
    exit_code=$?
done

debug "Exiting with code ${exit_code}"
exit "${exit_code}"
