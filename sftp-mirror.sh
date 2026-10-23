#!/usr/bin/env bash
#===============================================================================
# Name:         sftp-mirror.sh
# Author:       Flo
# Date:         2026-10-23
# Purpose:      Mirror a remote SFTP location (e.g. a web space) to a local
#               directory. The remote side is mounted read-only via sshfs and
#               synchronized with rsync. Files deleted on the remote side are
#               deleted in the mirror too, protected by a plausibility check
#               of the source and a limit on the number of deletions.
# Usage:        sftp-mirror.sh [--dry-run] [--help]
#                 --dry-run   Run everything (mount, checks, rsync --dry-run)
#                             without changing the mirror. No marker file is
#                             written.
#                 --help      Show this help and exit.
# Requires:     bash, sshfs, fuse3 (fusermount3), rsync, flock, mountpoint,
#               timeout, find; runs as root (cron)
# Config:       sftp-mirror.config next to this script (chmod 660)
# Secrets:      file named in the config (root:root, chmod 600): REMOTE_USER
#               and REMOTE_PASSWORD (not needed when key authentication is used)
# Exit codes:   0 ok | 1 error | 2 usage | 3 config/secrets | 4 already running
#               5 mount failed | 6 source plausibility check failed
#               7 rsync failed
#===============================================================================

# Config variables are set by the sourced config and the handlers below are
# called via trap, so shellcheck cannot see these uses.
# shellcheck disable=SC2153,SC2329
set -euo pipefail

VERSION="1.0.0"
REQUIRED_CONFIG_VERSION="1"

# The only paths derived in the script: its own directory and, by convention,
# the config next to it. Every other path comes from the config.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.config"

# --- Exit codes ---
EXIT_OK=0
EXIT_ERROR=1
EXIT_USAGE=2
EXIT_CONFIG=3
EXIT_LOCKED=4
EXIT_MOUNT=5
EXIT_SOURCE=6
EXIT_RSYNC=7

# --- State ---
DRY_RUN=0
WE_MOUNTED=0

# Print the header block of this script as help text
usage() {
    sed -n '/^# Name:/,/^#====/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Write one log line with timestamp and level.
# Before the config is loaded there is no LOG_FILE yet, so fall back to stderr.
log() {
    local line
    line="$(printf '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2")"
    if [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "${line}" >&2
}

# Log an error and terminate with the given exit code
die() {
    log "ERROR" "$2"
    exit "$1"
}

# Abort unless file exists and has the expected octal permissions.
# With a third argument "root" the file must also be owned by root:root
# (used for the secrets file; the config only gets the permission check).
check_file() {
    local file="$1" expected="$2" need_owner="${3:-}" actual owner
    [[ -f "${file}" ]] || die "${EXIT_CONFIG}" "Missing file: ${file}"
    if [[ "${need_owner}" == "root" ]]; then
        owner="$(stat -c '%U:%G' "${file}")"
        [[ "${owner}" == "root:root" ]] \
            || die "${EXIT_CONFIG}" "Wrong owner on ${file}: ${owner} (expected root:root)"
    fi
    actual="$(stat -c '%a' "${file}")"
    [[ "${actual}" == "${expected}" ]] \
        || die "${EXIT_CONFIG}" "Wrong permissions on ${file}: ${actual} (expected ${expected})"
}

# Abort unless the named config variable has a non-empty value
require_var() {
    local name="$1"
    [[ -n "${!name:-}" ]] || die "${EXIT_CONFIG}" "Missing config value: ${name}"
}

# Abort unless the named config variable is a non-negative integer
require_int() {
    local name="$1"
    require_var "${name}"
    [[ "${!name}" =~ ^[0-9]+$ ]] || die "${EXIT_CONFIG}" "Config value ${name} must be a number: '${!name}'"
}

# Unmount the remote side (normal unmount first, lazy unmount as fallback)
unmount_remote() {
    fusermount3 -u "${MOUNT_POINT}" 2>/dev/null \
        || fusermount3 -uz "${MOUNT_POINT}" 2>/dev/null \
        || log "WARN" "Could not unmount ${MOUNT_POINT}"
}

# Always unmount what we mounted and log the end of the run with the exit code
on_exit() {
    local rc=$?
    if [[ "${WE_MOUNTED}" -eq 1 ]]; then
        unmount_remote
    fi
    log "INFO" "END (exit ${rc})"
}

# Mount the remote location read-only via sshfs.
# Password authentication reads the password from stdin (never from the
# command line); key authentication is used when SSH_KEY_FILE is set.
mount_remote() {
    local target="${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
    local -a args=(-p "${REMOTE_PORT}" -o "${SSHFS_OPTIONS}")
    if [[ -n "${SSH_KEY_FILE}" ]]; then
        args+=(-o "IdentityFile=${SSH_KEY_FILE},IdentitiesOnly=yes,BatchMode=yes")
        sshfs "${args[@]}" "${target}" "${MOUNT_POINT}" >> "${LOG_FILE}" 2>&1
    else
        args+=(-o "password_stdin")
        printf '%s\n' "${REMOTE_PASSWORD}" \
            | sshfs "${args[@]}" "${target}" "${MOUNT_POINT}" >> "${LOG_FILE}" 2>&1
    fi
}

# --- Parse arguments (before the trap, so --help does not log) ---
for arg in "$@"; do
    case "${arg}" in
        --help|-h) usage; exit "${EXIT_OK}" ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "Unknown option: ${arg}" >&2; usage >&2; exit "${EXIT_USAGE}" ;;
    esac
done

# --- Startup ---
trap on_exit EXIT

# Load config (SCRIPT_DIR and SCRIPT_NAME are available inside it)
check_file "${CONFIG_FILE}" 660
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Config must match the version this script expects
[[ "${CONFIG_VERSION:-}" == "${REQUIRED_CONFIG_VERSION}" ]] \
    || die "${EXIT_CONFIG}" "CONFIG_VERSION '${CONFIG_VERSION:-unset}' does not match required '${REQUIRED_CONFIG_VERSION}'"

# Validate config values
for var in LOG_FILE MARKER_FILE LOCK_FILE SECRETS_FILE REMOTE_HOST REMOTE_PATH \
           MOUNT_POINT MIRROR_DIR SSHFS_OPTIONS; do
    require_var "${var}"
done
for var in REMOTE_PORT SANITY_TIMEOUT RSYNC_TIMEOUT MAX_DELETE; do
    require_int "${var}"
done
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
SANITY_CHECK_PATH="${SANITY_CHECK_PATH:-}"
[[ -d "${LOG_FILE%/*}" ]] || die "${EXIT_CONFIG}" "Log directory does not exist: ${LOG_FILE%/*}"

log "INFO" "START (version ${VERSION}, dry-run ${DRY_RUN})"

# Prevent parallel runs (LOCK_FILE comes from the config)
exec 9>"${LOCK_FILE}" || die "${EXIT_ERROR}" "Cannot open lock file: ${LOCK_FILE}"
flock -n 9 || die "${EXIT_LOCKED}" "Another instance is already running"

# Load secrets (SECRETS_FILE comes from the config)
check_file "${SECRETS_FILE}" 600 root
# shellcheck source=/dev/null
source "${SECRETS_FILE}"
REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
require_var REMOTE_USER
if [[ -n "${SSH_KEY_FILE}" ]]; then
    [[ -r "${SSH_KEY_FILE}" ]] || die "${EXIT_CONFIG}" "SSH key file not readable: ${SSH_KEY_FILE}"
else
    require_var REMOTE_PASSWORD
fi

# --- Mount ---
# Clear a stale mount left behind by a crashed run, then mount if needed.
# The mount point directory must already exist: it is never created here,
# because a missing parent mount would otherwise fill the wrong disk.
if ! mountpoint -q "${MOUNT_POINT}"; then
    fusermount3 -uz "${MOUNT_POINT}" 2>/dev/null || true
    [[ -d "${MOUNT_POINT}" ]] || die "${EXIT_CONFIG}" "Mount point directory does not exist: ${MOUNT_POINT}"
    log "INFO" "Mounting ${REMOTE_HOST}:${REMOTE_PORT} on ${MOUNT_POINT}"
    mount_remote || die "${EXIT_MOUNT}" "Mount failed"
    WE_MOUNTED=1
else
    log "INFO" "Already mounted: ${MOUNT_POINT} (used as is, will not be unmounted)"
fi

# The mirror directory must exist for the same reason as above
[[ -d "${MIRROR_DIR}" ]] || die "${EXIT_CONFIG}" "Mirror directory does not exist: ${MIRROR_DIR}"

# --- Plausibility check of the source ---
# Without it, --delete could empty the mirror if the mount is empty or broken.
SRC="${MOUNT_POINT%/}/"
DST="${MIRROR_DIR%/}/"
if [[ -n "${SANITY_CHECK_PATH}" ]]; then
    timeout "${SANITY_TIMEOUT}" test -d "${SRC}${SANITY_CHECK_PATH#/}" \
        || die "${EXIT_SOURCE}" "Plausibility check failed: ${SRC}${SANITY_CHECK_PATH#/} not readable, aborting"
else
    [[ -n "$(timeout "${SANITY_TIMEOUT}" find "${SRC}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] \
        || die "${EXIT_SOURCE}" "Plausibility check failed: ${SRC} is empty or not readable, aborting"
fi

# --- Mirror ---
rsync_args=(-rlt --no-owner --no-group
            --delete "--max-delete=${MAX_DELETE}"
            "--timeout=${RSYNC_TIMEOUT}"
            "--log-file=${LOG_FILE}")
for pattern in ${RSYNC_EXCLUDES[@]+"${RSYNC_EXCLUDES[@]}"}; do
    rsync_args+=("--exclude=${pattern}")
done
if [[ "${DRY_RUN}" -eq 1 ]]; then
    rsync_args+=(--dry-run)
    log "INFO" "Dry run: the mirror will not be changed"
fi

log "INFO" "Start rsync"
rc=0
rsync "${rsync_args[@]}" "${SRC}" "${DST}" || rc=$?

if [[ "${rc}" -eq 24 ]]; then
    # 24 = files vanished during the run, normal for live sites
    log "WARN" "rsync reported vanished source files (exit 24), treated as success"
elif [[ "${rc}" -eq 25 ]]; then
    die "${EXIT_RSYNC}" "rsync stopped: --max-delete limit (${MAX_DELETE}) reached, mirror not fully updated"
elif [[ "${rc}" -ne 0 ]]; then
    die "${EXIT_RSYNC}" "rsync failed with exit code ${rc}"
fi

# --- Success: write marker as the very last step (not on a dry run) ---
if [[ "${DRY_RUN}" -eq 0 ]]; then
    date '+%Y-%m-%d %H:%M:%S' > "${MARKER_FILE}"
fi
log "INFO" "OK (rsync rc=${rc})"
exit "${EXIT_OK}"
