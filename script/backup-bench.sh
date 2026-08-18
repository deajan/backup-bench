#!/usr/bin/env bash

###############################################################################
# backup-bench.sh - a simple, reproducible benchmark for deduplicating backup
#                   programs
#
# Programs currently benchmarked:
#   bupstash, borg, borg beta (2.x), kopia, restic, rustic, duplicacy, plakar
#
# WHAT IS MEASURED
#
# For every backup program, against both a local and a remote (SSH/SFTP)
# repository, the script measures:
#   - the time needed to back up the dataset
#   - the resulting repository size
#   - the time needed to restore that backup
#   - whether the restored data is identical to the source
#
# Results are appended to ${CSV_RESULT_FILE} as a pseudo-CSV file (one block of
# rows per run), the log of the run lands in ${LOG_FILE}, and every backup
# program gets its own verbose log file in ${LOG_DIR}.
#
# Timings have a one second granularity and are taken around the whole backup
# process, so they include repository connection and cleanup. Run a monitoring
# agent (netdata, ...) alongside the script if you also want cpu/memory/io
# figures per program.
#
# KEEPING THE COMPARISON FAIR
#
#   - the page cache (and the ZFS ARC) is dropped before every single backup and
#     restore, see drop_caches()
#   - every program is configured to use zstd compression when it supports it
#   - the '.git' directory of the git dataset is excluded everywhere, since it
#     would otherwise dominate deduplication results
#   - no program is allowed to write into the dataset (this is why duplicacy is
#     driven with 'init -repository', see init_duplicacy_repository)
#   - programs that can use multiple threads are given 8 of them
#   - restores skip ACLs / xattrs / ownership when the program can, so all of
#     them do a comparable amount of work
#
# HOW BACKUP PROGRAMS ARE PLUGGED IN
#
# No list of programs is hardcoded in the benchmark logic: the script walks
# ${BACKUP_SOFTWARES} from the configuration file and calls functions whose names
# are derived from each program name. To add a program, add its name to
# ${BACKUP_SOFTWARES} and write these functions:
#
#   install_<name>            downloads / builds the binary into ${BIN_DIR}
#   get_version_<name>        echoes the version string (used in CSV headers)
#   init_<name>_repository    creates an empty repository        (arg: remotely)
#   clear_<name>_repository   destroys the repository            (arg: remotely)
#   backup_<name>             creates a backup    (args: remotely, backup_id)
#   restore_<name>            restores a backup   (args: remotely, backup_id)
#
# 'remotely' is the string "true" or "false" and tells the function whether to
# work on the local or on the remote target repository. 'backup_id' identifies
# one backup (an archive name, a tag, ... depending on the program) and is used
# again at restore time to find that backup back.
#
# Two more functions are optional and only called when they exist:
#
#   setup_source_<name>       extra source side setup (keys, plugins, ssh config)
#   setup_ssh_<name>_server   restricts the target authorized_keys to a serve
#                             command, for programs that speak their own protocol
#                             over ssh (borg, borg_beta, bupstash)
#
# So why are there so many nearly identical functions instead of one generic one?
# Because every program ends up needing its own quirks, and one function per
# program keeps those quirks visible and reviewable.
#
# REQUIREMENTS
#
# Tested on RHEL 9 & RHEL 10 clones, should work on Debian based distros too.
# Needs bash >= 4.3 and dnf or apt. borg beta needs glibc >= 2.39 (RHEL 10).
# Most operations need root, since we create users and drop kernel caches.
#
# See HOWTO.md for the command sequences to run.
###############################################################################

PROGRAM="backup-bench"
AUTHOR="(C) 2022-2026 by Orsiris de Jong"
PROGRAM_BUILD=2026081801

# Configuration files older than this one lack settings this script needs
MINIMUM_CONF_VERSION=2026081801

###############################################################################
# Generic helpers
###############################################################################

log() {
        local __log_line="${1}"
        local __log_level="${2:-INFO}"

        __log_line="${__log_level}: ${__log_line}"
        echo "${__log_line}"
        # ${LOG_FILE} only exists once the configuration file has been loaded
        [ -n "${LOG_FILE}" ] && echo "${__log_line}" >> "${LOG_FILE}"
        return 0
}

log_quit() {
        log "${1}" "${2}"
        log "Exiting script"
        exit 1
}

function check_result {
        # Logs the outcome of the command that just ran.
        # When ${3} is true, a failure aborts the whole script.
        local result="${1}"
        local context="${2}"
        local fatal="${3:-false}"

        if [ "${result}" -ne 0 ]; then
                log "${context} failed with exit code ${result}." "CRITICAL"
                if [ "${fatal}" == true ]; then
                        log "Exiting script" "CRITICAL"
                        exit 125
                fi
                return 1
        fi
        log "${context} succeeded." "DEBUG"
        return 0
}

function check_snapshot_id {
        # Snapshot lookups grep the program's own listing output, so an id can come back
        # empty when a backup is missing or when a program changes its output format.
        # Restoring with an empty id would silently restore something else, or nothing
        local id="${1}"
        local program="${2}"
        local backup_id="${3}"

        if [ -z "${id}" ]; then
                log "Cannot find any ${program} snapshot for backup id [${backup_id}]" "CRITICAL"
                return 1
        fi
        log "Using ${program} snapshot [${id}]" "NOTICE"
        return 0
}

function run_on_target {
        # Runs a shell command where the repositories live: locally, or on the remote
        # target over ssh when ${1} is true
        local remotely="${1}"
        local cmd="${2}"

        if [ "${remotely}" == true ]; then
                ${REMOTE_SSH_RUNNER} "${cmd}"
        else
                eval "${cmd}"
        fi
}

function drop_caches {
        # Timings are only comparable when nothing is served from RAM, so we flush the
        # page cache (which also drops the zfs arc) on both ends before each measure
        local remotely="${1:-false}"

        if [ -w /proc/sys/vm/drop_caches ]; then
                sync && echo 3 > /proc/sys/vm/drop_caches
        else
                log "Cannot drop local caches, timings will be biased." "WARN"
        fi
        if [ "${remotely}" == true ]; then
                ${REMOTE_SSH_RUNNER} "sync && echo 3 > /proc/sys/vm/drop_caches" || log "Cannot drop caches on remote target, timings will be biased." "WARN"
        fi
        return 0
}

function self_setup {
        # Fetches ofunctions.sh, which provides ExecTasks (used to run the backup
        # programs with soft and hard timeouts).
        # Runs after the configuration is loaded, since we need ${BACKUP_BENCH_ROOT}
        local ofunctions_path="${BACKUP_BENCH_ROOT}/ofunctions.sh"

        log "Setting up ofunctions" "NOTICE"
        if [ ! -f "${ofunctions_path}" ]; then
                curl -f -L https://raw.githubusercontent.com/deajan/ofunctions/main/ofunctions.sh -o "${ofunctions_path}" || log_quit "Cannot download ofunctions.sh" "CRITICAL"
        fi
        # shellcheck source=/dev/null
        source "${ofunctions_path}" || exit 99
        # Don't pollute RUN_DIR since we won't need alerts
        _log_WRITE_PARTIAL_LOGS=false
}

function download_prerequisites {
        local nodeps="${1:-false}"

        local result=true  # did we succeed in installing our stuff
        local pkg_manager

        if type -p dnf > /dev/null 2>&1; then
                pkg_manager=dnf
                log "Installing packages tar, bzip2, git using dnf" "NOTICE"
                dnf install -y tar bzip2 git || result=false

                # bupstash has no prebuilt binaries, we need a rust toolchain to build it
                dnf install -y rust cargo pkgconfig libsodium-devel || result=false
        elif type -p apt > /dev/null 2>&1; then
                pkg_manager=apt
                log "Installing packages tar, bzip2, git using apt" "NOTICE"
                apt install -y tar bzip2 git || result=false

                # bupstash has no prebuilt binaries, we need a rust toolchain to build it
                apt install -y rustc cargo pkgconf libsodium-dev || result=false
        else
                log "No supported package manager (dnf, apt) found." "WARN"
                result=false
        fi

        # semanage is needed to label the ssh keys we create outside of home directories
        if [ -n "${pkg_manager}" ] && type -p getenforce > /dev/null 2>&1; then
                if [ "$(getenforce)" == "Enforcing" ]; then
                        log "Installing SELinux package policycoreutils-python-utils using ${pkg_manager}" "NOTICE"
                        "${pkg_manager}" install -y policycoreutils-python-utils || result=false
                else
                        log "Skipping SELinux setup since it is disabled or permissive" "NOTICE"
                fi
        fi

        if [ "${result}" == false ]; then
                if [ "${nodeps}" == false ]; then
                        log "Could not install required packages. We need tar, bzip2, git, and a rust toolchain for bupstash. You can bypass required packages install by specifying --no-deps" "WARN"
                else
                        log "Required packages install bypassed" "NOTICE"
                fi
        else
                log "Successfully installed required packages." "NOTICE"
        fi
}

function get_latest_git_release {
        # Echoes the latest release tag (eg 'v1.2.3') of a github repository, or nothing
        # when the api call fails. Callers must check for an empty result.
        # We deliberately don't log() from here, since our callers capture our stdout.
        # Unauthenticated github api calls are rate limited to 60 per hour and per IP,
        # export GITHUB_TOKEN to raise that limit.
        local org="${1}"
        local repo="${2}"
        local curl_opts=(-s -L)

        [ -n "${GITHUB_TOKEN}" ] && curl_opts+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        curl "${curl_opts[@]}" "https://api.github.com/repos/${org}/${repo}/releases/latest" | grep '"tag_name"' | cut -d'"' -f4
}

function get_remote_certificate_fingerprint {
        # Used for kopia server certificate authentication
        local fqdn="${1}"
        local port="${2}"

        openssl s_client -connect "${fqdn}:${port}" < /dev/null 2>/dev/null | openssl x509 -fingerprint -sha256 -noout -in /dev/stdin | cut -d'=' -f2 | tr -d ':'
}

function get_certificate_fingerprint {
        local file="${1}"

        openssl x509 -fingerprint -sha256 -noout -in "${file}" | cut -d'=' -f2 | tr -d ':'
}

function create_certificate {
        # Create a RSA certificate for the kopia and restic https servers
        local name="${1}"

        openssl req -nodes -new -x509 -days 7300 -newkey rsa:2048 -keyout "${HOME}/${name}.key" -subj "/C=FR/O=SOMEORG/CN=${REMOTE_TARGET_FQDN}/OU=RD/L=City/ST=State/emailAddress=contact@example.tld" -out "${HOME}/${name}.crt"
}

###############################################################################
# Target and source system setup
###############################################################################

function upload_to_source {
        # Uploads stdin into a private file on the source system.
        # Runs on the target during --setup-remote-target: this is the only moment the
        # target needs to reach the source, and it will ask for a password once.
        # A shared ssh master connection keeps that to a single password prompt.
        local remote_file="${1}"

        ssh "${SOURCE_USER}@${SOURCE_FQDN}" -p "${SOURCE_SSH_PORT}" -o ControlMaster=auto -o ControlPersist=yes -o "ControlPath=/tmp/${PROGRAM}.ctrlm.$$" "cat > ${remote_file}; chmod 600 ${remote_file}"
}

function close_source_ssh_master {
        rm -f "/tmp/${PROGRAM}.ctrlm.$$"
}

function clear_users {
        # Removes the per program users from the target system, so that
        # --setup-remote-target can be run again from a clean state
        local backup_software

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if getent passwd "${backup_software}_user" > /dev/null 2>&1; then
                        log "Removing user ${backup_software}_user" "NOTICE"
                        userdel -r "${backup_software}_user" > /dev/null 2>&1
                fi
        done
}

function setup_root_access {
        # Quick and dirty ssh root setup on the target system when using remote
        # repositories. This allows the source machine to clear repositories on target.
        local key_file="/root/.ssh/backup-bench.rsa"

        [ ! -d /root/.ssh ] && mkdir -p /root/.ssh && chmod 700 /root/.ssh
        [ -f "${key_file}" ] && rm -f "${key_file}" "${key_file}.pub"
        ssh-keygen -b 2048 -t rsa -f "${key_file}" -q -N ""
        cat "${key_file}.pub" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
        type -p semanage > /dev/null 2>&1 && semanage fcontext -a -t ssh_home_t /root/.ssh/authorized_keys > /dev/null 2>&1
        type -p restorecon > /dev/null 2>&1 && restorecon -v /root/.ssh/authorized_keys

        log "Copying root key to source into [${SOURCE_USER_HOMEDIR}/.ssh/backup-bench.key]" "NOTICE"
        if ! upload_to_source "${SOURCE_USER_HOMEDIR}/.ssh/backup-bench.key" < "${key_file}"; then
                log "Failed to setup root access to target" "CRITICAL"
                log "Please copy file [${key_file}] to source system in [${SOURCE_USER_HOMEDIR}/.ssh/backup-bench.key] and execute chmod 600 on it" "CRITICAL"
        fi
}

function setup_target_local_repos {
        local backup_software

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                [ -d "${TARGET_ROOT}/${backup_software}" ] && rm -rf "${TARGET_ROOT:?}/${backup_software}"
                mkdir -p "${TARGET_ROOT}/${backup_software}" || log_quit "Cannot create ${TARGET_ROOT}/${backup_software}" "CRITICAL"
        done
}

function setup_target_remote_repos {
        # Quick and dirty per program user and ssh repo setup on the target system.
        # Every program gets its own user, home directory and ssh key, so a program
        # cannot see (nor slow down) another one's repository.
        local backup_software

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if [ "${HAVE_ZFS}" == true ]; then
                        # Datasets are expected to be mounted below ${TARGET_ROOT}
                        zfs create "${ZFS_POOL}/${backup_software}"
                        zfs set compression=off "${ZFS_POOL}/${backup_software}"
                        zfs set xattr=off "${ZFS_POOL}/${backup_software}"
                        zfs set atime=off "${ZFS_POOL}/${backup_software}"
                        # The following setting is targeted at qcow file backups
                        # bupstash tends to create smaller files than others
                        # We might want to set recordsize=128k for linux kernel benchmarks
                        zfs set recordsize=1M "${ZFS_POOL}/${backup_software}"
                else
                        mkdir -p "${TARGET_ROOT}" || exit 127
                fi
                if ! getent passwd "${backup_software}_user" > /dev/null 2>&1; then
                        useradd -d "${TARGET_ROOT}/${backup_software}" -m -r -U "${backup_software}_user"
                fi
                mkdir -p "${TARGET_ROOT}/${backup_software}/data"
                mkdir -p "${TARGET_ROOT}/${backup_software}/.ssh" && chmod 700 "${TARGET_ROOT}/${backup_software}/.ssh"
                [ -f "${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa" ] && rm -f "${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa"*
                ssh-keygen -b 2048 -t rsa -f "${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa" -q -N ""
                cat "${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa.pub" > "${TARGET_ROOT}/${backup_software}/.ssh/authorized_keys" && chmod 600 "${TARGET_ROOT}/${backup_software}/.ssh/authorized_keys"
                chown "${backup_software}_user" -R "${TARGET_ROOT}/${backup_software}"
                type -p semanage > /dev/null 2>&1 && semanage fcontext -a -t ssh_home_t "${TARGET_ROOT}/${backup_software}/.ssh/authorized_keys" > /dev/null 2>&1
                type -p restorecon > /dev/null 2>&1 && restorecon -v "${TARGET_ROOT}/${backup_software}/.ssh/authorized_keys"
        done

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                log "Copying RSA key for ${backup_software} to source into [${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key]" "NOTICE"
                if ! upload_to_source "${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key" < "${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa"; then
                        log "Failed to copy ssh key to source system" "CRITICAL"
                        log "Please copy file [${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa] to source system in [${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key] and execute chmod 600 on it" "CRITICAL"
                fi
        done
        close_source_ssh_master
}

###############################################################################
# bupstash
#
# - has no prebuilt binaries, so we build it from its source+deps tarball
# - speaks its own protocol over ssh, the target needs a forced serve command
# - keys are files instead of environment variables: we back up with a put-only
#   sub key and restore with the master key, like a real setup would
###############################################################################

function install_bupstash {
        local ORG=andrewchambers
        local REPO=bupstash
        local latest_version
        local src_dir
        local url

        latest_version="$(get_latest_git_release "${ORG}" "${REPO}")"
        [ -z "${latest_version}" ] && log_quit "Cannot get latest ${REPO} release from the github api. Rate limited ? Export GITHUB_TOKEN to raise the limit." "CRITICAL"

        log "Installing bupstash ${latest_version}" "NOTICE"
        url="https://github.com/${ORG}/${REPO}/releases/download/${latest_version}/bupstash-${latest_version}-src+deps.tar.gz"
        src_dir="${BACKUP_BENCH_ROOT}/bupstash/bupstash-${latest_version}"
        mkdir -p "${src_dir}" || log_quit "Cannot create ${src_dir}" "CRITICAL"
        log "Downloading ${url}" "NOTICE"
        curl -f -L -o "${src_dir}/bupstash-src+deps.tar.gz" "${url}" || log_quit "Cannot download bupstash" "CRITICAL"
        # Build in a subshell so the caller keeps its current directory
        (
                cd "${src_dir}" || exit 127
                tar xf "bupstash-src+deps.tar.gz" && cargo build --release && cp "target/release/bupstash" "${BIN_DIR}/"
        )
        check_result $? "bupstash build" true

        log "Installed bupstash $(get_version_bupstash)" "NOTICE"
}

function get_version_bupstash {
        "${BIN_DIR}/bupstash" --version | awk -F'-' '{print $2}'
}

function setup_source_bupstash {
        # bupstash keys live in files. We back up with a put+list sub key, so the source
        # cannot read the repository back, and keep the master key for restores
        if [ ! -f "${SOURCE_USER_HOMEDIR}/bupstash.master.key" ]; then
                log "Creating bupstash master key" "NOTICE"
                "${BIN_DIR}/bupstash" new-key -o "${SOURCE_USER_HOMEDIR}/bupstash.master.key"
                check_result $? "bupstash master key creation"
        fi
        if [ ! -f "${SOURCE_USER_HOMEDIR}/bupstash.store.key" ]; then
                log "Creating bupstash put-only sub key" "NOTICE"
                "${BIN_DIR}/bupstash" new-sub-key -k "${SOURCE_USER_HOMEDIR}/bupstash.master.key" --put --list -o "${SOURCE_USER_HOMEDIR}/bupstash.store.key"
                check_result $? "bupstash sub key creation"
        fi
}

function setup_ssh_bupstash_server {
        # Forced command, so the key can only ever serve that one repository.
        # ${BIN_DIR} is expanded on the target, where this function runs
        echo "$(echo -n "command=\"cd ${TARGET_ROOT}/bupstash; ${BIN_DIR}/bupstash serve ${TARGET_ROOT}/bupstash/data\",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc "; cat "${TARGET_ROOT}/bupstash/.ssh/authorized_keys")" > "${TARGET_ROOT}/bupstash/.ssh/authorized_keys"
}

function set_bupstash_repository {
        # bupstash uses BUPSTASH_REPOSITORY for local repositories and
        # BUPSTASH_REPOSITORY_COMMAND for remote ones, and only one of them may be set
        local remotely="${1}"

        if [ "${remotely}" == true ]; then
                export BUPSTASH_REPOSITORY_COMMAND="${BUPSTASH_REPOSITORY_COMMAND_REMOTE}"
                unset BUPSTASH_REPOSITORY
        else
                export BUPSTASH_REPOSITORY="${BUPSTASH_REPOSITORY_LOCAL}"
                unset BUPSTASH_REPOSITORY_COMMAND
        fi
}

function init_bupstash_repository {
        local remotely="${1:-false}"

        log "Initializing bupstash repository. Remote: ${remotely}." "NOTICE"
        set_bupstash_repository "${remotely}"
        "${BIN_DIR}/bupstash" init
        check_result $? "bupstash repository initialization" true
}

function clear_bupstash_repository {
        local remotely="${1:-false}"

        # bupstash expects the directory not to exist in order to serve it via bupstash
        # serve, or even just to init it, since v0.12
        log "Clearing bupstash repository. Remote: ${remotely}." "NOTICE"
        local cmd="rm -rf \"${TARGET_ROOT:?}/bupstash\"; mkdir ${TARGET_ROOT:?}/bupstash; if getent passwd | grep bupstash_user > /dev/null; then chown bupstash_user \"${TARGET_ROOT}/bupstash\"; fi"
        run_on_target "${remotely}" "${cmd}"
}

function backup_bupstash {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching bupstash backup. Remote: ${remotely}." "NOTICE"
        set_bupstash_repository "${remotely}"
        "${BIN_DIR}/bupstash" put --compression zstd:3 --exclude '.git' --print-file-actions --print-stats "BACKUPID=${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.bupstash.log" 2>&1
        check_result $? "bupstash backup"
}

function restore_bupstash {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching bupstash restore. Remote: ${remotely}." "NOTICE"
        set_bupstash_repository "${remotely}"

        # The put-only sub key cannot read data back, so restores use the master key
        export BUPSTASH_KEY="${SOURCE_USER_HOMEDIR}/bupstash.master.key"
        "${BIN_DIR}/bupstash" restore --into "${RESTORE_DIR}" "BACKUPID=${backup_id}" >> "${LOG_DIR}/${PROGRAM}.bupstash.log" 2>&1
        check_result $? "bupstash restore"
        export BUPSTASH_KEY="${SOURCE_USER_HOMEDIR}/bupstash.store.key"
}

###############################################################################
# borg (stable 1.x)
#
# - speaks its own protocol over ssh, the target needs a forced serve command
# - -e repokey means AES-CTR-256 and HMAC-SHA256
#   see https://borgbackup.readthedocs.io/en/stable/usage/init.html
###############################################################################

function install_borg {
        local ORG=borgbackup
        local REPO=borg
        local latest_version
        local url

        latest_version="$(get_latest_git_release "${ORG}" "${REPO}")"
        [ -z "${latest_version}" ] && log_quit "Cannot get latest ${REPO} release from the github api. Rate limited ? Export GITHUB_TOKEN to raise the limit." "CRITICAL"

        log "Installing borg ${latest_version}" "NOTICE"
        # We use the oldest glibc build available, since the 'linuxnew' builds need a
        # more recent glibc than the RHEL clones we benchmark on
        url="https://github.com/${ORG}/${REPO}/releases/download/${latest_version}/borg-linux-glibc231-x86_64"
        log "Downloading ${url}" "NOTICE"
        curl -f -o "${BIN_DIR}/borg" -L "${url}" || log_quit "Cannot download borg" "CRITICAL"
        chmod 755 "${BIN_DIR}/borg"

        log "Installed borg $(get_version_borg)" "NOTICE"
}

function get_version_borg {
        "${BIN_DIR}/borg" --version | awk '{print $2}'
}

function setup_ssh_borg_server {
        # Forced command, so the key can only ever serve that one repository.
        # ${BIN_DIR} is expanded on the target, where this function runs
        echo "$(echo -n "command=\"cd ${TARGET_ROOT}/borg/data; ${BIN_DIR}/borg serve --restrict-to-path ${TARGET_ROOT}/borg/data\",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc "; cat "${TARGET_ROOT}/borg/.ssh/authorized_keys")" > "${TARGET_ROOT}/borg/.ssh/authorized_keys"
}

function init_borg_repository {
        local remotely="${1:-false}"

        log "Initializing borg repository. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                export BORG_REPO="${BORG_STABLE_REPO_REMOTE}"
                "${BIN_DIR}/borg" init -e repokey --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg.key -p ${REMOTE_TARGET_SSH_PORT} -o StrictHostKeyChecking=accept-new" "${BORG_REPO}"
        else
                export BORG_REPO="${BORG_STABLE_REPO_LOCAL}"
                "${BIN_DIR}/borg" init -e repokey "${BORG_REPO}"
        fi
        check_result $? "borg repository initialization" true
}

function clear_borg_repository {
        local remotely="${1:-false}"

        log "Clearing borg repository. Remote: ${remotely}." "NOTICE"
        # borg expects the data directory to already exist in order to serve it via borg serve
        local cmd="rm -rf \"${TARGET_ROOT:?}/borg/data\"; mkdir -p \"${TARGET_ROOT}/borg/data\"; if getent passwd | grep borg_user > /dev/null; then chown borg_user \"${TARGET_ROOT}/borg/data\"; fi"
        run_on_target "${remotely}" "${cmd}"
}

function backup_borg {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching borg backup. Remote: ${remotely}." "NOTICE"
        # Exclusion patterns can be checked with borg create --list --dry-run --exclude ...
        if [ "${remotely}" == true ]; then
                export BORG_REPO="${BORG_STABLE_REPO_REMOTE}"
                "${BIN_DIR}/borg" create --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT}" --compression zstd,3 --exclude 're:\.git/.*$' --stats --verbose "${BORG_REPO}"::"${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.borg.log" 2>&1
        else
                export BORG_REPO="${BORG_STABLE_REPO_LOCAL}"
                "${BIN_DIR}/borg" create --compression zstd,3 --exclude 're:\.git/.*$' --stats --verbose "${BORG_REPO}"::"${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.borg.log" 2>&1
        fi
        check_result $? "borg backup"
}

function restore_borg {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching borg restore. Remote: ${remotely}." "NOTICE"
        # borg extracts relative to the current directory
        cd "${RESTORE_DIR}" || return 127
        # --noacls and --noxattrs keep the restore comparable with the other programs
        if [ "${remotely}" == true ]; then
                export BORG_REPO="${BORG_STABLE_REPO_REMOTE}"
                "${BIN_DIR}/borg" extract --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg.key -p ${REMOTE_TARGET_SSH_PORT}" --noacls --noxattrs "${BORG_REPO}"::"${backup_id}" >> "${LOG_DIR}/${PROGRAM}.borg.log" 2>&1
        else
                export BORG_REPO="${BORG_STABLE_REPO_LOCAL}"
                "${BIN_DIR}/borg" extract --noacls --noxattrs "${BORG_REPO}"::"${backup_id}" >> "${LOG_DIR}/${PROGRAM}.borg.log" 2>&1
        fi
        check_result $? "borg restore"
}

###############################################################################
# borg beta (2.x)
#
# - installed as 'borg_beta' so it can live next to borg stable
# - the version is pinned: beta releases are github prereleases, which the
#   'releases/latest' api endpoint does not return
# - the binary needs glibc >= 2.39, so RHEL 9 clones cannot run it
# - the 2.x CLI differs from 1.x: 'repo-create' instead of 'init', no repository
#   in the archive name, --encryption instead of -e
# - aes256-ocb was picked by running 'borg_beta benchmark cpu' on the source
###############################################################################

function install_borg_beta {
        local version="2.0.0b22"
        local url

        url="https://github.com/borgbackup/borg/releases/download/${version}/borg-linux-glibc239-x86_64-gh"
        log "Installing borg beta ${version} from ${url}" "NOTICE"
        curl -f -L "${url}" -o "${BIN_DIR}/borg_beta" || log_quit "Cannot download borg beta" "CRITICAL"
        chmod 755 "${BIN_DIR}/borg_beta"
        log "Installed borg_beta $(get_version_borg_beta)" "NOTICE"
}

function get_version_borg_beta {
        "${BIN_DIR}/borg_beta" --version | awk '{print $2}'
}

function setup_ssh_borg_beta_server {
        # Forced command, so the key can only ever serve that one repository.
        # ${BIN_DIR} is expanded on the target, where this function runs
        echo "$(echo -n "command=\"cd ${TARGET_ROOT}/borg_beta/data; ${BIN_DIR}/borg_beta serve --restrict-to-path ${TARGET_ROOT}/borg_beta/data\",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc "; cat "${TARGET_ROOT}/borg_beta/.ssh/authorized_keys")" > "${TARGET_ROOT}/borg_beta/.ssh/authorized_keys"
}

function init_borg_beta_repository {
        local remotely="${1:-false}"

        log "Initializing borg_beta repository. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                export BORG_REPO="${BORG_BETA_REPO_REMOTE}"
                "${BIN_DIR}/borg_beta" --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key -p ${REMOTE_TARGET_SSH_PORT} -o StrictHostKeyChecking=accept-new" repo-create --encryption=aes256-ocb
        else
                export BORG_REPO="${BORG_BETA_REPO_LOCAL}"
                "${BIN_DIR}/borg_beta" repo-create --encryption=aes256-ocb
        fi
        check_result $? "borg_beta repository initialization" true
}

function clear_borg_beta_repository {
        local remotely="${1:-false}"

        log "Clearing borg_beta repository. Remote: ${remotely}." "NOTICE"
        # borg expects the data directory to already exist in order to serve it via borg serve
        local cmd="rm -rf \"${TARGET_ROOT:?}/borg_beta/data\"; mkdir -p \"${TARGET_ROOT}/borg_beta/data\"; if getent passwd | grep borg_beta_user > /dev/null; then chown borg_beta_user \"${TARGET_ROOT}/borg_beta/data\"; fi"
        run_on_target "${remotely}" "${cmd}"
}

function backup_borg_beta {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching borg_beta backup. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                export BORG_REPO="${BORG_BETA_REPO_REMOTE}"
                "${BIN_DIR}/borg_beta" create --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT}" --compression zstd,3 --exclude 're:\.git/.*$' --stats --verbose "${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.borg_beta.log" 2>&1
        else
                export BORG_REPO="${BORG_BETA_REPO_LOCAL}"
                "${BIN_DIR}/borg_beta" create --compression zstd,3 --exclude 're:\.git/.*$' --stats --verbose "${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.borg_beta.log" 2>&1
        fi
        check_result $? "borg_beta backup"
}

function restore_borg_beta {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching borg_beta restore. Remote: ${remotely}." "NOTICE"
        # borg extracts relative to the current directory
        cd "${RESTORE_DIR}" || return 127
        # --noacls and --noxattrs keep the restore comparable with the other programs
        if [ "${remotely}" == true ]; then
                export BORG_REPO="${BORG_BETA_REPO_REMOTE}"
                "${BIN_DIR}/borg_beta" extract --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key -p ${REMOTE_TARGET_SSH_PORT}" --noacls --noxattrs "${backup_id}" >> "${LOG_DIR}/${PROGRAM}.borg_beta.log" 2>&1
        else
                export BORG_REPO="${BORG_BETA_REPO_LOCAL}"
                "${BIN_DIR}/borg_beta" extract --noacls --noxattrs "${backup_id}" >> "${LOG_DIR}/${PROGRAM}.borg_beta.log" 2>&1
        fi
        check_result $? "borg_beta restore"
}

###############################################################################
# kopia
#
# - can either be reached over sftp, or run as an https server on the target
#   (KOPIA_USE_HTTP), which is why it is also installed on the target
# - compression and exclusions are repository side policies, not backup flags
# - block hash and encryption were picked with 'kopia benchmark crypto'
# - zstd is used rather than s2-default: s2 produced 60% bigger repositories,
#   which would bias the comparison (see kopia issue #2375)
###############################################################################

function install_kopia {
        local ORG=kopia
        local REPO=kopia
        local latest_version
        local url

        latest_version="$(get_latest_git_release "${ORG}" "${REPO}")"
        [ -z "${latest_version}" ] && log_quit "Cannot get latest ${REPO} release from the github api. Rate limited ? Export GITHUB_TOKEN to raise the limit." "CRITICAL"

        log "Installing kopia ${latest_version}" "NOTICE"
        url="https://github.com/${ORG}/${REPO}/releases/download/${latest_version}/kopia-${latest_version:1}-linux-x64.tar.gz"
        log "Downloading ${url}" "NOTICE"
        curl -f -o "${BACKUP_BENCH_ROOT}/kopia.tar.gz" -L "${url}" || log_quit "Cannot download kopia" "CRITICAL"
        # Extract just the binary, wherever it sits in the archive
        tar xf "${BACKUP_BENCH_ROOT}/kopia.tar.gz" --wildcards --no-anchored --transform='s/.*\///' -C "${BIN_DIR}" 'kopia'
        [ ! -f "${BIN_DIR}/kopia" ] && log_quit "Cannot extract the kopia binary from its archive" "CRITICAL"
        chmod +x "${BIN_DIR}/kopia"

        log "Installed kopia $(get_version_kopia)" "NOTICE"
}

function get_version_kopia {
        "${BIN_DIR}/kopia" --version | awk '{print $1}'
}

function connect_kopia_repository {
        # kopia keeps its repository connection in a local config file, so every
        # operation starts by (re)connecting to the right repository
        local remotely="${1}"

        if [ "${remotely}" == true ]; then
                if [ "${KOPIA_USE_HTTP}" == true ]; then
                        "${BIN_DIR}/kopia" repository connect server "--url=https://${REMOTE_TARGET_FQDN}:${KOPIA_HTTP_PORT}" --server-cert-fingerprint="$(get_remote_certificate_fingerprint "${REMOTE_TARGET_FQDN}" "${KOPIA_HTTP_PORT}")" -p "${KOPIA_HTTP_PASSWORD}" "--override-username=${KOPIA_HTTP_USERNAME}" --override-hostname=backup-bench-source
                        # KOPIA_PASSWORD has to be empty in server mode, or operations fail
                        export KOPIA_PASSWORD=
                else
                        "${BIN_DIR}/kopia" repository connect sftp "--path=${TARGET_ROOT}/kopia/data" "--host=${REMOTE_TARGET_FQDN}" --port "${REMOTE_TARGET_SSH_PORT}" "--keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key" --username=kopia_user "--known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts"
                fi
        else
                "${BIN_DIR}/kopia" repository connect filesystem "--path=${TARGET_ROOT}/kopia/data"
        fi
}

function init_kopia_repository {
        local remotely="${1:-false}"

        log "Initializing kopia repository. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                if [ "${KOPIA_USE_HTTP}" == true ]; then
                        # In http mode the repository is created by serve_http_targets on the
                        # target before the server starts, so we only connect to it here
                        connect_kopia_repository true
                        "${BIN_DIR}/kopia" policy set "${KOPIA_HTTP_USERNAME}@backup-bench-source" --compression zstd
                        "${BIN_DIR}/kopia" policy set "${KOPIA_HTTP_USERNAME}@backup-bench-source" --add-ignore '.git'
                else
                        "${BIN_DIR}/kopia" repository create sftp "--path=${TARGET_ROOT}/kopia/data" "--host=${REMOTE_TARGET_FQDN}" --port "${REMOTE_TARGET_SSH_PORT}" "--keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key" --username=kopia_user "--known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts" --block-hash=BLAKE3-256 --encryption=AES256-GCM-HMAC-SHA256
                        "${BIN_DIR}/kopia" policy set --global --compression zstd
                        "${BIN_DIR}/kopia" policy set --global --add-ignore '.git'
                fi
        else
                "${BIN_DIR}/kopia" repository create filesystem "--path=${TARGET_ROOT}/kopia/data"
                # Policies are repository side, so they have to be set for every repository
                "${BIN_DIR}/kopia" policy set --global --compression zstd
                "${BIN_DIR}/kopia" policy set --global --add-ignore '.git'
        fi
        check_result $? "kopia repository initialization" true
}

function clear_kopia_repository {
        local remotely="${1:-false}"

        log "Clearing kopia repository. Remote: ${remotely}." "NOTICE"
        local cmd="rm -rf \"${TARGET_ROOT:?}/kopia/data\""
        run_on_target "${remotely}" "${cmd}"
}

function backup_kopia {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching kopia backup. Remote: ${remotely}." "NOTICE"
        connect_kopia_repository "${remotely}"
        # Exclusion patterns can be checked with kopia snapshot estimate
        "${BIN_DIR}/kopia" snapshot create --parallel 8 --tags "BACKUPID:${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.kopia.log" 2>&1
        check_result $? "kopia backup"
}

function restore_kopia {
        local remotely="${1}"
        local backup_id="${2}"
        local id

        log "Launching kopia restore. Remote: ${remotely}." "NOTICE"
        connect_kopia_repository "${remotely}"

        id="$("${BIN_DIR}/kopia" snapshot list --tags "BACKUPID:${backup_id}" | awk '{print $4}')"
        check_snapshot_id "${id}" kopia "${backup_id}" || return 1
        "${BIN_DIR}/kopia" restore --parallel 8 --skip-owners --skip-permissions "${id}" "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.kopia.log" 2>&1
        check_result $? "kopia restore"
}

###############################################################################
# restic
#
# - reached either over sftp, or through a rest-server running on the target
# - repository format 2 is required for compression support
###############################################################################

function install_restic {
        local ORG=restic
        local REPO=restic
        local latest_version
        local url

        latest_version="$(get_latest_git_release "${ORG}" "${REPO}")"
        [ -z "${latest_version}" ] && log_quit "Cannot get latest ${REPO} release from the github api. Rate limited ? Export GITHUB_TOKEN to raise the limit." "CRITICAL"

        log "Installing restic ${latest_version}" "NOTICE"
        url="https://github.com/${ORG}/${REPO}/releases/download/${latest_version}/restic_${latest_version:1}_linux_amd64.bz2"
        log "Downloading ${url}" "NOTICE"
        curl -f -o "${BACKUP_BENCH_ROOT}/restic.bz2" -L "${url}" || log_quit "Cannot download restic" "CRITICAL"
        bzip2 -d -f "${BACKUP_BENCH_ROOT}/restic.bz2" || log_quit "Cannot decompress restic" "CRITICAL"
        mv -f "${BACKUP_BENCH_ROOT}/restic" "${BIN_DIR}/restic" || log_quit "Cannot install the restic binary" "CRITICAL"
        chmod +x "${BIN_DIR}/restic"

        log "Installed restic $(get_version_restic)" "NOTICE"
}

function get_version_restic {
        "${BIN_DIR}/restic" version | awk '{print $2}'
}

function install_restic_rest_server {
        # rest-server serves both the restic and the rustic repositories, and only ever
        # runs on the target
        local latest_version
        local url

        latest_version="$(get_latest_git_release restic rest-server)"
        [ -z "${latest_version}" ] && log_quit "Cannot get latest rest-server release from the github api. Rate limited ? Export GITHUB_TOKEN to raise the limit." "CRITICAL"

        log "Installing restic rest-server ${latest_version}" "NOTICE"
        url="https://github.com/restic/rest-server/releases/download/${latest_version}/rest-server_${latest_version:1}_linux_amd64.tar.gz"
        log "Downloading ${url}" "NOTICE"
        curl -f -o "${BACKUP_BENCH_ROOT}/rest-server.tar.gz" -L "${url}" || log_quit "Cannot download rest-server" "CRITICAL"
        tar xf "${BACKUP_BENCH_ROOT}/rest-server.tar.gz" --wildcards --no-anchored --transform='s/.*\///' -C "${BIN_DIR}" 'rest-server'
        [ ! -f "${BIN_DIR}/rest-server" ] && log_quit "Cannot extract the rest-server binary from its archive" "CRITICAL"
        chmod +x "${BIN_DIR}/rest-server"
}

function init_restic_repository {
        local remotely="${1:-false}"

        log "Initializing restic repository. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                if [ "${RESTIC_USE_HTTP}" == true ]; then
                        "${BIN_DIR}/restic" --insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/" init --repository-version 2
                else
                        "${BIN_DIR}/restic" -r "sftp::${TARGET_ROOT}/restic/data" -o "sftp.command=ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" init --repository-version 2
                fi
        else
                "${BIN_DIR}/restic" -r "${TARGET_ROOT}/restic/data" init --repository-version 2
        fi
        check_result $? "restic repository initialization" true
}

function clear_restic_repository {
        local remotely="${1:-false}"

        log "Clearing restic repository. Remote: ${remotely}." "NOTICE"
        local cmd="rm -rf \"${TARGET_ROOT:?}/restic/data\""
        run_on_target "${remotely}" "${cmd}"
}

function backup_restic {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching restic backup. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                if [ "${RESTIC_USE_HTTP}" == true ]; then
                        "${BIN_DIR}/restic" --insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/" backup --verbose --exclude=".git" --tag="${backup_id}" --compression=auto "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.restic.log" 2>&1
                else
                        "${BIN_DIR}/restic" -r "sftp::${TARGET_ROOT}/restic/data" -o "sftp.command=ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -s sftp" backup --verbose --exclude=".git" --tag="${backup_id}" --compression=auto "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.restic.log" 2>&1
                fi
        else
                "${BIN_DIR}/restic" -r "${TARGET_ROOT}/restic/data" backup --verbose --exclude=".git" --tag="${backup_id}" --compression=auto "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.restic.log" 2>&1
        fi
        check_result $? "restic backup"
}

function restore_restic {
        local remotely="${1}"
        local backup_id="${2}"
        local id

        log "Launching restic restore. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                if [ "${RESTIC_USE_HTTP}" == true ]; then
                        id=$("${BIN_DIR}/restic" --insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/" snapshots | grep "${backup_id}" | awk '{print $1}')
                        check_snapshot_id "${id}" restic "${backup_id}" || return 1
                        "${BIN_DIR}/restic" --insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/" restore "${id}" --target "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.restic.log" 2>&1
                else
                        id=$("${BIN_DIR}/restic" -r "sftp::${TARGET_ROOT}/restic/data" -o "sftp.command=ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -s sftp" snapshots | grep "${backup_id}" | awk '{print $1}')
                        check_snapshot_id "${id}" restic "${backup_id}" || return 1
                        "${BIN_DIR}/restic" -r "sftp::${TARGET_ROOT}/restic/data" -o "sftp.command=ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -s sftp" restore "${id}" --target "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.restic.log" 2>&1
                fi
        else
                id=$("${BIN_DIR}/restic" -r "${TARGET_ROOT}/restic/data" snapshots | grep "${backup_id}" | awk '{print $1}')
                check_snapshot_id "${id}" restic "${backup_id}" || return 1
                "${BIN_DIR}/restic" -r "${TARGET_ROOT}/restic/data" restore "${id}" --target "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.restic.log" 2>&1
        fi
        check_result $? "restic restore"
}

###############################################################################
# rustic
#
# - restic compatible repositories, reached over sftp or through rest-server
# - the musl build is used, since the gnu build needs a more recent glibc than
#   the RHEL clones we benchmark on
# - rustic always creates repository format 2 with compression enabled, so there
#   is no --set-version to pass
###############################################################################

function install_rustic {
        local ORG=rustic-rs
        local REPO=rustic
        local latest_version
        local url

        latest_version="$(get_latest_git_release "${ORG}" "${REPO}")"
        [ -z "${latest_version}" ] && log_quit "Cannot get latest ${REPO} release from the github api. Rate limited ? Export GITHUB_TOKEN to raise the limit." "CRITICAL"

        log "Installing rustic ${latest_version}" "NOTICE"
        url="https://github.com/${ORG}/${REPO}/releases/download/${latest_version}/rustic-${latest_version}-x86_64-unknown-linux-musl.tar.gz"
        log "Downloading ${url}" "NOTICE"
        curl -f -o "${BACKUP_BENCH_ROOT}/rustic.tar.gz" -L "${url}" || log_quit "Cannot download rustic" "CRITICAL"
        tar xf "${BACKUP_BENCH_ROOT}/rustic.tar.gz" --wildcards --no-anchored --transform='s/.*\///' -C "${BIN_DIR}" 'rustic'
        [ ! -f "${BIN_DIR}/rustic" ] && log_quit "Cannot extract the rustic binary from its archive" "CRITICAL"
        chmod +x "${BIN_DIR}/rustic"

        log "Installed rustic $(get_version_rustic)" "NOTICE"
}

function get_version_rustic {
        "${BIN_DIR}/rustic" --version | awk '{print $2}'
}

function init_rustic_repository {
        local remotely="${1:-false}"

        log "Initializing rustic repository. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                if [ "${RUSTIC_USE_HTTP}" == true ]; then
                        "${BIN_DIR}/rustic" --insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RUSTIC_HTTP_PORT}/" init
                else
                        "${BIN_DIR}/rustic" -r "sftp::${TARGET_ROOT}/rustic/data" -o "sftp.command=ssh rustic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/rustic.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" init
                fi
        else
                "${BIN_DIR}/rustic" -r "${TARGET_ROOT}/rustic/data" init
        fi
        check_result $? "rustic repository initialization" true
}

function clear_rustic_repository {
        local remotely="${1:-false}"

        log "Clearing rustic repository. Remote: ${remotely}." "NOTICE"
        local cmd="rm -rf \"${TARGET_ROOT:?}/rustic/data\""
        run_on_target "${remotely}" "${cmd}"
}

function backup_rustic {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching rustic backup. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                if [ "${RUSTIC_USE_HTTP}" == true ]; then
                        "${BIN_DIR}/rustic" --insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RUSTIC_HTTP_PORT}/" backup --glob="!.git" --tag="${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.rustic.log" 2>&1
                else
                        "${BIN_DIR}/rustic" -r "sftp::${TARGET_ROOT}/rustic/data" -o "sftp.command=ssh rustic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/rustic.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -s sftp" backup --glob="!.git" --tag="${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.rustic.log" 2>&1
                fi
        else
                "${BIN_DIR}/rustic" -r "${TARGET_ROOT}/rustic/data" backup --glob="!.git" --tag="${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.rustic.log" 2>&1
        fi
        check_result $? "rustic backup"
}

function restore_rustic {
        local remotely="${1}"
        local backup_id="${2}"
        local id

        log "Launching rustic restore. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                if [ "${RUSTIC_USE_HTTP}" == true ]; then
                        id=$("${BIN_DIR}/rustic" --insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RUSTIC_HTTP_PORT}/" snapshots | grep "${backup_id}" | awk '{print $2}')
                        check_snapshot_id "${id}" rustic "${backup_id}" || return 1
                        "${BIN_DIR}/rustic" --insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RUSTIC_HTTP_PORT}/" restore "${id}" "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.rustic.log" 2>&1
                else
                        id=$("${BIN_DIR}/rustic" -r "sftp::${TARGET_ROOT}/rustic/data" -o "sftp.command=ssh rustic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/rustic.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -s sftp" snapshots | grep "${backup_id}" | awk '{print $2}')
                        check_snapshot_id "${id}" rustic "${backup_id}" || return 1
                        "${BIN_DIR}/rustic" -r "sftp::${TARGET_ROOT}/rustic/data" -o "sftp.command=ssh rustic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/rustic.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -s sftp" restore "${id}" "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.rustic.log" 2>&1
                fi
        else
                id=$("${BIN_DIR}/rustic" -r "${TARGET_ROOT}/rustic/data" snapshots | grep "${backup_id}" | awk '{print $2}')
                check_snapshot_id "${id}" rustic "${backup_id}" || return 1
                "${BIN_DIR}/rustic" -r "${TARGET_ROOT}/rustic/data" restore "${id}" "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.rustic.log" 2>&1
        fi
        check_result $? "rustic restore"
}

###############################################################################
# duplicacy
#
# duplicacy has no repository argument: it looks for a '.duplicacy' directory in
# the current directory (or above it) and reads the storage and source paths from
# there. Running it inside the dataset would therefore write into the data we
# benchmark, which is why we run it from ${DUPLICACY_PREF_DIR} and point it at
# the dataset with 'init -repository' instead (see issue #21). Restores need a
# second such directory, since duplicacy restores into its repository path.
#
# Two more duplicacy specifics worth knowing:
#   - exclusions are not command line flags, they live in a 'filters' file inside
#     the '.duplicacy' directory
#   - sftp storage paths are relative to the user home directory, unless the URL
#     holds a double slash before the path, which is what the '/${TARGET_ROOT}'
#     below produces
###############################################################################

function install_duplicacy {
        local ORG=gilbertchen
        local REPO=duplicacy
        local latest_version
        local url

        latest_version="$(get_latest_git_release "${ORG}" "${REPO}")"
        [ -z "${latest_version}" ] && log_quit "Cannot get latest ${REPO} release from the github api. Rate limited ? Export GITHUB_TOKEN to raise the limit." "CRITICAL"

        log "Installing duplicacy ${latest_version}" "NOTICE"
        url="https://github.com/${ORG}/${REPO}/releases/download/${latest_version}/duplicacy_linux_x64_${latest_version:1}"
        log "Downloading ${url}" "NOTICE"
        curl -f -L -o "${BIN_DIR}/duplicacy" "${url}" || log_quit "Cannot download duplicacy" "CRITICAL"
        chmod +x "${BIN_DIR}/duplicacy"
        log "Installed duplicacy $(get_version_duplicacy)" "NOTICE"
}

function get_version_duplicacy {
        # duplicacy without arguments prints its usage, which holds the version
        "${BIN_DIR}/duplicacy" | grep -A1 "VERSION" | tail -n 1 | awk '{print $1}'
}

function get_duplicacy_storage_url {
        # Echoes the storage URL, so init and restore cannot disagree on it
        local remotely="${1}"

        if [ "${remotely}" == true ]; then
                echo "sftp://duplicacy_user@${REMOTE_TARGET_FQDN}:${REMOTE_TARGET_SSH_PORT}/${TARGET_ROOT}/duplicacy/data"
        else
                echo "${TARGET_ROOT}/duplicacy/data"
        fi
}

function get_duplicacy_snapshot_id {
        # The snapshot id tells local and remote backups apart inside the storage
        local remotely="${1}"

        if [ "${remotely}" == true ]; then
                echo "remoteid"
        else
                echo "localid"
        fi
}

function init_duplicacy_repository {
        local remotely="${1:-false}"
        local pref_dir="${2:-${DUPLICACY_PREF_DIR}}"
        local repository="${3:-${BACKUP_ROOT}}"
        local fatal="${4:-true}"

        log "Initializing duplicacy repository for [${repository}] in [${pref_dir}]. Remote: ${remotely}." "NOTICE"

        # Remove earlier repo setup, including any '.duplicacy' left inside the dataset
        # by an older version of this script
        rm -rf "${pref_dir:?}"
        rm -rf "${BACKUP_ROOT:?}/.duplicacy"
        mkdir -p "${pref_dir}" || log_quit "Cannot create duplicacy preferences directory [${pref_dir}]" "CRITICAL"
        cd "${pref_dir}" || log_quit "Cannot enter duplicacy preferences directory [${pref_dir}]" "CRITICAL"

        # -e encrypts the storage, the password comes from ${DUPLICACY_PASSWORD}
        "${BIN_DIR}/duplicacy" init -e -repository "${repository}" "$(get_duplicacy_snapshot_id "${remotely}")" "$(get_duplicacy_storage_url "${remotely}")" >> "${LOG_DIR}/${PROGRAM}.duplicacy.log" 2>&1
        check_result $? "duplicacy repository initialization" "${fatal}" || return 1

        # Exclusions live in [pref dir]/.duplicacy/filters, 'e:' introduces a regex.
        # duplicacy init creates that directory, we just make sure of it
        mkdir -p "${pref_dir}/.duplicacy"
        echo "e:\.git/.*$" > "${pref_dir}/.duplicacy/filters"
}

function clear_duplicacy_repository {
        local remotely="${1:-false}"

        log "Clearing duplicacy repository. Remote: ${remotely}." "NOTICE"
        if [ "${remotely}" == true ]; then
                local cmd="rm -rf \"${TARGET_ROOT:?}/duplicacy/data\" && mkdir -p \"${TARGET_ROOT}/duplicacy/data\" && chown duplicacy_user \"${TARGET_ROOT}/duplicacy/data\""
        else
                local cmd="rm -rf \"${TARGET_ROOT:?}/duplicacy/data\" && mkdir -p \"${TARGET_ROOT}/duplicacy/data\""
        fi
        run_on_target "${remotely}" "${cmd}"

        # Drop the local repository metadata too, so the next init starts clean
        rm -rf "${DUPLICACY_PREF_DIR:?}"
        rm -rf "${DUPLICACY_RESTORE_PREF_DIR:?}"
}

function backup_duplicacy {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching duplicacy backup. Remote: ${remotely}." "NOTICE"
        # duplicacy works on the '.duplicacy' directory found in the current directory
        cd "${DUPLICACY_PREF_DIR}" || return 127

        # -threads 8 as per https://github.com/deajan/backup-bench/issues/14
        "${BIN_DIR}/duplicacy" backup -t "${backup_id}" -stats -threads 8 >> "${LOG_DIR}/${PROGRAM}.duplicacy.log" 2>&1
        check_result $? "duplicacy backup"
}

function restore_duplicacy {
        local remotely="${1}"
        local backup_id="${2}"
        local revision

        log "Launching duplicacy restore. Remote: ${remotely}." "NOTICE"

        # duplicacy restores into its own repository path, so we need a second
        # repository, pointing at ${RESTORE_DIR} instead of at the dataset
        init_duplicacy_repository "${remotely}" "${DUPLICACY_RESTORE_PREF_DIR}" "${RESTORE_DIR}" false || return 1
        cd "${DUPLICACY_RESTORE_PREF_DIR}" || return 127

        # 'list -t' filters on the tag we backed up with. Revisions are printed as
        # 'Snapshot <id> revision <n> created at <date> <tag>', so the revision is field 4
        revision="$("${BIN_DIR}/duplicacy" list -t "${backup_id}" | grep "^Snapshot " | tail -n 1 | awk '{print $4}')"
        if [ -z "${revision}" ]; then
                log "Cannot find any duplicacy revision tagged [${backup_id}]" "CRITICAL"
                return 1
        fi
        log "Using revision [${revision}]" "NOTICE"

        # -ignore-owner keeps the restore comparable with the other programs
        "${BIN_DIR}/duplicacy" restore -r "${revision}" -stats -overwrite -ignore-owner -threads 8 >> "${LOG_DIR}/${PROGRAM}.duplicacy.log" 2>&1
        check_result $? "duplicacy restore"
}

###############################################################################
# plakar
#
# - repositories ('kloset stores') are addressed with 'plakar at <store>', which
#   has to come before the command, while command options come after it
# - the encryption passphrase comes from ${PLAKAR_PASSPHRASE}
# - remote stores need the sftp store connector, which is not part of the binary
#   and is installed with 'plakar pkg add sftp' by setup_source_plakar
# - that connector shells out to the 'sftp' binary and takes no key or port
#   option, so the ssh client configuration carries those, see setup_source_plakar
# - compression, hashing and chunking are not tunable from the CLI as of 1.1.x,
#   so plakar runs with its defaults
###############################################################################

function install_plakar {
        local ORG=PlakarKorp
        local REPO=plakar
        local latest_version
        local url

        latest_version="$(get_latest_git_release "${ORG}" "${REPO}")"
        [ -z "${latest_version}" ] && log_quit "Cannot get latest ${REPO} release from the github api. Rate limited ? Export GITHUB_TOKEN to raise the limit." "CRITICAL"

        log "Installing plakar ${latest_version}" "NOTICE"
        url="https://github.com/${ORG}/${REPO}/releases/download/${latest_version}/plakar_${latest_version:1}_linux_amd64.tar.gz"
        log "Downloading ${url}" "NOTICE"
        curl -f -o "${BACKUP_BENCH_ROOT}/plakar.tar.gz" -L "${url}" || log_quit "Cannot download plakar" "CRITICAL"
        tar xf "${BACKUP_BENCH_ROOT}/plakar.tar.gz" --wildcards --no-anchored --transform='s/.*\///' -C "${BIN_DIR}" 'plakar'
        [ ! -f "${BIN_DIR}/plakar" ] && log_quit "Cannot extract the plakar binary from its archive" "CRITICAL"
        chmod +x "${BIN_DIR}/plakar"

        log "Installed plakar $(get_version_plakar)" "NOTICE"
}

function get_version_plakar {
        # The wording of 'plakar version' changed over releases, so we just keep the semver
        "${BIN_DIR}/plakar" version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

function setup_source_plakar {
        local ssh_config="${SOURCE_USER_HOMEDIR}/.ssh/config"
        local marker="# ${PROGRAM}: plakar sftp store settings"
        local tmp_config="${ssh_config}.${PROGRAM}.tmp"

        # Store connectors are shipped as packages, not built into the binary
        log "Adding plakar sftp store connector" "NOTICE"
        "${BIN_DIR}/plakar" pkg add sftp >> "${LOG_FILE}" 2>&1 || log "Cannot add the plakar sftp connector, remote plakar benchmarks will fail." "WARN"

        # The sftp connector has no key nor port option, so those have to come from the
        # ssh client configuration. 'Match' scopes the settings to plakar_user, so the
        # other programs keep using their own keys on that same host, and we prepend the
        # block because ssh keeps the first value it finds for a given keyword
        if grep -qF "${marker}" "${ssh_config}" 2>/dev/null; then
                log "ssh configuration already holds the plakar settings" "NOTICE"
                return 0
        fi
        log "Adding plakar ssh configuration to [${ssh_config}]" "NOTICE"
        mkdir -p "${SOURCE_USER_HOMEDIR}/.ssh" && chmod 700 "${SOURCE_USER_HOMEDIR}/.ssh"
        {
                echo "${marker}"
                echo "Match host ${REMOTE_TARGET_FQDN} user plakar_user"
                echo "        Port ${REMOTE_TARGET_SSH_PORT}"
                echo "        IdentityFile ${SOURCE_USER_HOMEDIR}/.ssh/plakar.key"
                echo "        StrictHostKeyChecking accept-new"
                echo ""
                [ -f "${ssh_config}" ] && cat "${ssh_config}"
        } > "${tmp_config}" && mv -f "${tmp_config}" "${ssh_config}"
        check_result $? "plakar ssh configuration"
        chmod 600 "${ssh_config}"
}

function get_plakar_repository {
        local remotely="${1}"

        if [ "${remotely}" == true ]; then
                echo "${PLAKAR_REPOSITORY_REMOTE}"
        else
                echo "${PLAKAR_REPOSITORY_LOCAL}"
        fi
}

function init_plakar_repository {
        local remotely="${1:-false}"

        log "Initializing plakar repository. Remote: ${remotely}." "NOTICE"
        # Stores are encrypted unless -plaintext is given
        "${BIN_DIR}/plakar" at "$(get_plakar_repository "${remotely}")" create >> "${LOG_DIR}/${PROGRAM}.plakar.log" 2>&1
        check_result $? "plakar repository initialization" true
}

function clear_plakar_repository {
        local remotely="${1:-false}"

        log "Clearing plakar repository. Remote: ${remotely}." "NOTICE"
        # The data directory is recreated empty, since the sftp user needs to own it
        local cmd="rm -rf \"${TARGET_ROOT:?}/plakar/data\"; mkdir -p \"${TARGET_ROOT}/plakar/data\"; if getent passwd | grep plakar_user > /dev/null; then chown plakar_user \"${TARGET_ROOT}/plakar/data\"; fi"
        run_on_target "${remotely}" "${cmd}"
}

function backup_plakar {
        local remotely="${1}"
        local backup_id="${2}"

        log "Launching plakar backup. Remote: ${remotely}." "NOTICE"
        # -ignore takes gitignore style patterns and may be repeated
        "${BIN_DIR}/plakar" at "$(get_plakar_repository "${remotely}")" backup -tag "${backup_id}" -ignore '.git' "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.plakar.log" 2>&1
        check_result $? "plakar backup"
}

function restore_plakar {
        local remotely="${1}"
        local backup_id="${2}"
        local repository
        local id

        log "Launching plakar restore. Remote: ${remotely}." "NOTICE"
        repository="$(get_plakar_repository "${remotely}")"

        # 'ls -tags' prints one snapshot per line as
        # '<date> <snapshot id> <size> <duration> <path> <tags>', so the id is field 2
        id="$("${BIN_DIR}/plakar" at "${repository}" ls -tags | grep "${backup_id}" | tail -n 1 | awk '{print $2}')"
        check_snapshot_id "${id}" plakar "${backup_id}" || return 1
        # -skip-permissions keeps the restore comparable with the other programs
        "${BIN_DIR}/plakar" at "${repository}" restore -to "${RESTORE_DIR}" -skip-permissions "${id}" >> "${LOG_DIR}/${PROGRAM}.plakar.log" 2>&1
        check_result $? "plakar restore"
}

###############################################################################
# Dataset, repositories and installation drivers
###############################################################################

function setup_git_dataset {
        # We assume ${BACKUP_ROOT} is the git root, so we clone into its parent directory.
        # This is the only case where backup-bench deletes and recreates ${BACKUP_ROOT}
        local git_parent_dir
        git_parent_dir="$(dirname "${BACKUP_ROOT:?}")"

        [ ! -d "${git_parent_dir}" ] && mkdir -p "${git_parent_dir}"
        cd "${git_parent_dir}" || exit 127

        log "Cloning git dataset ${GIT_DATASET_REPOSITORY} into ${git_parent_dir}/${GIT_ROOT_DIRECTORY}" "NOTICE"
        [ -d "${GIT_ROOT_DIRECTORY}" ] && rm -rf "${GIT_ROOT_DIRECTORY}"
        git clone "${GIT_DATASET_REPOSITORY}"
        check_result $? "git dataset clone" true
}

function get_repo_sizes {
        local remotely="${1:-false}"
        local backup_software
        local size

        local CSV_SIZE="size(kb),"

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                size="$(run_on_target "${remotely}" "du -cs \"${TARGET_ROOT}/${backup_software}\"" 2>/dev/null | tail -n 1 | awk '{print $1}')"
                [ -z "${size}" ] && size=0
                CSV_SIZE="${CSV_SIZE}${size},"
                log "Repo size for ${backup_software}: ${size} kb. Remote: ${remotely}." "NOTICE"
        done
        echo "${CSV_SIZE}" >> "${CSV_RESULT_FILE}"
}

function install_backup_programs {
        local is_remote="${1:-false}"

        # Programs speaking their own protocol over ssh, and kopia which can act as a
        # server, need to be installed on both ends
        install_bupstash
        install_borg
        install_borg_beta
        install_kopia

        if [ "${is_remote}" == true ]; then
                # rest-server serves both the restic and the rustic repositories
                install_restic_rest_server
        else
                # restic, rustic, duplicacy and plakar reach their repositories over
                # sftp or http, so the target needs nothing of them
                install_restic
                install_rustic
                install_duplicacy
                install_plakar
        fi
}

function setup_source {
        local remotely="${1:-false}"
        local backup_software

        log "Setting up source server" "NOTICE"
        download_prerequisites "${NODEPS}"

        install_backup_programs false

        if [ "${remotely}" == false ]; then
                log "Setting up local target" "NOTICE"
                setup_target_local_repos
        fi

        # Programs needing extra source side setup provide a setup_source_<name> function
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if declare -F "setup_source_${backup_software}" > /dev/null; then
                        log "Running source setup for ${backup_software}" "NOTICE"
                        "setup_source_${backup_software}"
                fi
        done
}

function setup_remote_target {
        local remotely="${1:-false}" # Has no use here obviously, but we'll keep it since remotely argument is passed
        local backup_software

        log "Setting up remote target server" "NOTICE"

        setup_root_access
        download_prerequisites "${NODEPS}"

        install_backup_programs true

        clear_users
        setup_target_remote_repos

        # Programs speaking their own protocol over ssh restrict their key to a serve
        # command, and provide a setup_ssh_<name>_server function to do so
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if declare -F "setup_ssh_${backup_software}_server" > /dev/null; then
                        log "Setting up ssh serve command for ${backup_software}" "NOTICE"
                        "setup_ssh_${backup_software}_server"
                fi
        done

        create_certificate https_backup-bench
}

function clear_repositories {
        local remotely="${1:-false}"
        local backup_software

        log "Clearing all repositories from earlier data. Remote clean: ${remotely}." "NOTICE"
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                clear_"${backup_software}"_repository "${remotely}"
        done
        log "Clearing done" "NOTICE"
}

function init_repositories {
        local remotely="${1:-false}"
        local git="${2:-false}"
        local backup_software

        # The dataset has to exist before we initialize the repositories, because
        # duplicacy needs its repository path to exist at init time
        if [ "${git}" == true ]; then
                # This deletes and re-clones ${BACKUP_ROOT}
                setup_git_dataset
        fi
        if [ ! -d "${BACKUP_ROOT}" ]; then
                log_quit "Backup root [${BACKUP_ROOT}] does not exist. Point BACKUP_ROOT at your dataset, or use --git to download the git dataset." "CRITICAL"
        fi

        log "Initializing repositories. Remote: ${remotely}." "NOTICE"
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                init_"${backup_software}"_repository "${remotely}"
        done
        log "Initialization done." "NOTICE"
}

function serve_http_targets {
        # Runs on the target: starts the kopia and rest-server https servers used when
        # KOPIA_USE_HTTP / RESTIC_USE_HTTP / RUSTIC_USE_HTTP are enabled
        local cmd
        local pid

        [ ! -f "${TARGET_ROOT}/kopia/data/kopia.repository.f" ] && "${BIN_DIR}/kopia" repository create filesystem "--path=${TARGET_ROOT}/kopia/data"
        cmd="${BIN_DIR}/kopia server start --address 0.0.0.0:${KOPIA_HTTP_PORT} --no-ui --tls-cert-file=\"${HOME}/https_backup-bench.crt\" --tls-key-file=\"${HOME}/https_backup-bench.key\""
        log "Running kopia server with following command:\n${cmd}" "NOTICE"
        eval "${cmd}" &
        pid=$!
        # add acls for user
        cmd="${BIN_DIR}/kopia server users add ${KOPIA_HTTP_USERNAME}@backup-bench-source --user-password=${KOPIA_HTTP_PASSWORD}"
        log "Adding kopia user with following command:\n${cmd}" "NOTICE"
        eval "${cmd}"
        # reload server
        cmd="${BIN_DIR}/kopia server refresh --address https://localhost:${KOPIA_HTTP_PORT} --server-cert-fingerprint=$(get_certificate_fingerprint "${HOME}/https_backup-bench.crt")  --server-control-username=${KOPIA_SERVER_CONTROL_USER} --server-control-password=${KOPIA_SERVER_CONTROL_PASSWORD}"
        log "Running kopia refresh with following command:\n${cmd}" "NOTICE"
        sleep 2 # arbitrary wait time
        eval "${cmd}" &
        log "Serving kopia on http port ${KOPIA_HTTP_PORT} using pid ${pid}." "NOTICE"

        "${BIN_DIR}/rest-server" --no-auth --listen "0.0.0.0:${RESTIC_HTTP_PORT}" --path "${TARGET_ROOT}/restic/data" --tls --tls-cert="${HOME}/https_backup-bench.crt" --tls-key="${HOME}/https_backup-bench.key" &
        pid=$!
        log "Serving rest-server for restic on http port ${RESTIC_HTTP_PORT} using pid ${pid}." "NOTICE"

        "${BIN_DIR}/rest-server" --no-auth --listen "0.0.0.0:${RUSTIC_HTTP_PORT}" --path "${TARGET_ROOT}/rustic/data" --tls --tls-cert="${HOME}/https_backup-bench.crt" --tls-key="${HOME}/https_backup-bench.key" &
        pid=$!
        log "Serving rest-server for rustic on http port ${RUSTIC_HTTP_PORT} using pid ${pid}." "NOTICE"
        log "Stop servers using $0 --stop-http-targets" "NOTICE"
        echo ""  # Just clear the line at the end
}

function stop_serve_http_targets {
        local i
        for i in $(pgrep kopia); do kill "${i}"; done
        for i in $(pgrep rest-server); do kill "${i}"; done
}

###############################################################################
# Benchmarks
###############################################################################

function benchmark_backup_standard {
        local remotely="${1}"
        local backup_id="${2:-defaultid}"
        local backup_software
        local seconds_begin
        local exec_time

        local CSV_BACKUP_EXEC_TIME="backup(s),"

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                drop_caches "${remotely}"
                log "Starting backup bench of ${backup_software} name=${backup_id}" "NOTICE"
                seconds_begin=$SECONDS
                # Launch the backup in the background, so ExecTasks can enforce timeouts
                backup_"${backup_software}" "${remotely}" "${backup_id}" &
                ExecTasks "$!" "${backup_software}_bench" false 3600 36000 3600 36000
                exec_time=$((SECONDS - seconds_begin))
                CSV_BACKUP_EXEC_TIME="${CSV_BACKUP_EXEC_TIME}${exec_time},"
                log "It took ${exec_time} seconds to backup." "NOTICE"
        done

        echo "${CSV_BACKUP_EXEC_TIME}" >> "${CSV_RESULT_FILE}"
        get_repo_sizes "${remotely}"
}

function benchmark_backup_git {
        local remotely="${1}"
        local tag

        log "Running git dataset backup benchmarks. Remote: ${remotely}" "NOTICE"

        if [ ! -d "${BACKUP_ROOT}/.git" ]; then
                log_quit "No git dataset found in [${BACKUP_ROOT}]. Please run --init-repos --git first." "CRITICAL"
        fi
        cd "${BACKUP_ROOT}" || exit 127

        # Back up one kernel version after another, so every program sees the same
        # sequence of changes and deduplication can be compared
        for tag in "${GIT_TAGS[@]}"; do
                log "Checking out git tag ${tag}" "NOTICE"
                git checkout "${tag}" || log_quit "Cannot checkout git tag ${tag}" "CRITICAL"
                benchmark_backup_standard "${remotely}" "bkp-${tag}"
        done
}

function benchmark_backup {
        local remotely="${1}"
        local git="${2:-false}"
        local backup_id_timestamp="${3:-false}"
        local backup_software
        local backup_id
        local CSV_HEADER

        echo "# $PROGRAM $PROGRAM_BUILD $(date) Remote: ${remotely}, Git: ${git}" >> "${CSV_RESULT_FILE}"
        CSV_HEADER=","

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                CSV_HEADER="${CSV_HEADER}${backup_software} $(get_version_"${backup_software}"),"
        done
        echo "${CSV_HEADER}" >> "${CSV_RESULT_FILE}"

        if [ "${git}" == true ]; then
                benchmark_backup_git "${remotely}"
        else
                if [ "${backup_id_timestamp}" == true ]; then
                        backup_id="$(date +"%Y-%m-%d-T%H-%M-%S")"
                else
                        backup_id="defaultid"
                fi
                benchmark_backup_standard "${remotely}" "${backup_id}"
        fi
}

function benchmark_restore_standard {
        local remotely="${1}"
        local backup_id="${2:-defaultid}"
        local backup_software
        local seconds_begin
        local exec_time
        local restored_path
        local result

        local CSV_RESTORE_EXEC_TIME="restoration(s),"

        # Restore the given backup and compare it with the current dataset
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                drop_caches "${remotely}"

                [ -d "${RESTORE_DIR}" ] && rm -rf "${RESTORE_DIR:?}"
                mkdir -p "${RESTORE_DIR}"

                log "Starting restore bench of ${backup_software} name=${backup_id}" "NOTICE"
                seconds_begin=$SECONDS
                # Launch the restore in the background, so ExecTasks can enforce timeouts
                restore_"${backup_software}" "${remotely}" "${backup_id}" &
                ExecTasks "$!" "${backup_software}_restore" false 3600 18000 3600 18000
                exec_time=$((SECONDS - seconds_begin))
                CSV_RESTORE_EXEC_TIME="${CSV_RESTORE_EXEC_TIME}${exec_time},"
                log "It took ${exec_time} seconds to restore." "NOTICE"

                # Some programs restore the full source path below the restore directory,
                # others restore the content of the source directory directly. We detect
                # which one we got instead of keeping a list of programs per behaviour
                if [ -d "${RESTORE_DIR}/${BACKUP_ROOT}" ]; then
                        restored_path="${RESTORE_DIR}/${BACKUP_ROOT}"
                else
                        restored_path="${RESTORE_DIR}"
                fi

                log "Comparing restored data in [${restored_path}] with source [${BACKUP_ROOT}]" "NOTICE"
                diff -x .git -x .duplicacy -qr "${restored_path}" "${BACKUP_ROOT}/"
                result=$?
                if [ "${result}" -ne 0 ]; then
                        log "Failure with exit code ${result} for ${backup_software} restore comparison." "CRITICAL"
                else
                        log "Restored files match source." "NOTICE"
                fi
        done
        echo "${CSV_RESTORE_EXEC_TIME}" >> "${CSV_RESULT_FILE}"
}

function benchmark_restore_git {
        local remotely="${1}"

        log "Running git dataset restore benchmarks. Remote: ${remotely}" "NOTICE"

        if [ ! -d "${BACKUP_ROOT}/.git" ]; then
                log_quit "No git dataset found in [${BACKUP_ROOT}]. Please run --init-repos --git first." "CRITICAL"
        fi
        cd "${BACKUP_ROOT}/" || exit 127
        # We restore the last backed up tag, so the dataset we compare against is the
        # one that was checked out during the last backup
        git checkout "${GIT_TAGS[-1]}" || log_quit "Cannot checkout git tag ${GIT_TAGS[-1]}" "CRITICAL"
        benchmark_restore_standard "${remotely}" "bkp-${GIT_TAGS[-1]}"
}

function benchmark_restore {
        local remotely="${1}"
        local git="${2:-false}"
        local backup_id_timestamp="${3:-false}"
        local backup_id

        if [ "${git}" == true ]; then
                benchmark_restore_git "${remotely}"
        else
                if [ "${backup_id_timestamp}" == true ]; then
                        backup_id="$(date +"%Y-%m-%d-T%H-%M-%S")"
                else
                        backup_id="defaultid"
                fi
                benchmark_restore_standard "${remotely}" "${backup_id}"
        fi
}

function benchmarks {
        local remotely="${1}"
        local git="${2:-false}"
        local backup_id_timestamp="${3:-false}"

        benchmark_backup "${remotely}" "${git}" "${backup_id_timestamp}"
        benchmark_restore "${remotely}" "${git}" "${backup_id_timestamp}"
}

function versions {
        local backup_software
        local version

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if [ ! -x "${BIN_DIR}/${backup_software}" ]; then
                        echo "${backup_software} is not installed in ${BIN_DIR}"
                        continue
                fi
                version="$(get_version_"${backup_software}")"
                echo "${backup_software} ${version}"
        done
}

function usage {
        echo "${PROGRAM} ${PROGRAM_BUILD}"
        echo "${AUTHOR}"
        echo ""
        echo "Please setup your config file (defaults to backup-bench.conf)"
        echo "Once you've setup the configuration, you may use it to initialize target, then source."
        echo "After initialization, benchmarks may run"
        echo ""
        echo "--config=/path/to/file.conf       Alternative configuration file"
        echo "--setup-remote-target             Install backup programs and setup SSH access (executed on target)"
        echo "--setup-source                    Install backup programs and setup local (or remote with --remote) repositories (executed on source)"
        echo "--init-repos                      Reinitialize local (or remote with --remote) repositories after clearing. Must be used with --git if multiple version benchmarks is used) (executed on source)"
        echo "--serve-http-targets              Launch http servers for kopia and restic manually (executed on target)"
        echo "--stop-http-targets               Stop http servers for kopia and restic (executed on target)"
        echo "--benchmark-backup                Run backup benchmarks using local (or remote with --remote) repositories"
        echo "--benchmark-restore               Run restore benchmarks using local (or remote with --remote) repositories, restores to local restore path"
        echo "--benchmarks                      Run both backup and restore benchmark using local (or remote with --remote) repositories and local restore path"
        echo "--all                             Clear, init and run backup with git dataset for both local and remote targets"
        echo ""
        echo "MODIFIERS"
        echo "--git                             Use git dataset (multiple version benchmark). WARNING: deletes and re-clones BACKUP_ROOT"
        echo "--local                           Execute locally (works for --clear-repos, --init-repos, --benchmark*)"
        echo "--remote                          Execute remotely (works for --clear-repos, --init-repos, --benchmark*)"
        echo "--backup-id-timestamp             Add a timestamp as backup id when not using --git. If this option is disabled, backupid will be \"defaultid\". There cannot be multiple backups with the same id"
        echo ""
        echo "After some benchmarks, you might want to remove earlier data from repositories"
        echo "--clear-repos                     Removes data from local (or remote with --remote) repositories"
        echo ""
        echo "DEBUG commands"
        echo "--setup-root-access               Manually setup root access (executed on target)"
        echo "--no-deps                         Do not install dependencies. This requires you to have them installed manually"
        echo "--install-backup-programs         Locally install / upgrade backup programs into BIN_DIR. If launched with --remote, it will install only remote target required programs"
        echo "--versions                        Show versions of all installed backup programs"
        exit 128
}

###############################################################################
# Script entry point
###############################################################################

if [ "$#" -eq 0 ]; then
        usage
fi

cmd=""
REMOTELY=false
USE_GIT_VERSIONS=false
ALL=false
CONFIG_FILE="backup-bench.conf"
NODEPS=false
BACKUP_ID_TIMESTAMP=false

for i in "${@}"; do
        case "${i}" in
                --config=*)
                CONFIG_FILE="${i##*=}"
                ;;
                --setup-root-access)
                cmd="setup_root_access"
                ;;
                --setup-source)
                cmd="setup_source"
                ;;
                --setup-remote-target)
                cmd="setup_remote_target"
                ;;
                --serve-http-targets)
                cmd="serve_http_targets"
                ;;
                --stop-http-targets)
                cmd="stop_serve_http_targets"
                ;;
                --benchmarks)
                cmd="benchmarks"
                ;;
                --benchmark-backup)
                cmd="benchmark_backup"
                ;;
                --benchmark-restore)
                cmd="benchmark_restore"
                ;;
                --clear-repos)
                cmd="clear_repositories"
                ;;
                --init-repos)
                cmd="init_repositories"
                ;;
                --local)
                REMOTELY=false
                ;;
                --remote)
                REMOTELY=true
                ;;
                --git)
                USE_GIT_VERSIONS=true
                ;;
                --backup-id-timestamp)
                BACKUP_ID_TIMESTAMP=true
                ;;
                --no-deps)
                NODEPS=true
                ;;
                --install-backup-programs)
                cmd="install_backup_programs"
                ;;
                --all)
                ALL=true
                ;;
                --versions)
                cmd="versions"
                ;;
                *)
                echo "Unknown parameter: ${i}"
                usage
                ;;
        esac
done

# Load configuration file
if [ ! -f "${CONFIG_FILE}" ]; then
        echo "Cannot find configuration file [${CONFIG_FILE}]."
        exit 127
fi
# shellcheck source=/dev/null
source "${CONFIG_FILE}" || { echo "Cannot load configuration file [${CONFIG_FILE}]."; exit 127; }

mkdir -p "${LOG_DIR}" || { echo "Cannot create log directory [${LOG_DIR}]."; exit 127; }
mkdir -p "${BIN_DIR}" || { echo "Cannot create binary directory [${BIN_DIR}]."; exit 127; }
mkdir -p "${BACKUP_BENCH_ROOT}" || { echo "Cannot create root directory [${BACKUP_BENCH_ROOT}]."; exit 127; }
cd "${BACKUP_BENCH_ROOT}" || { echo "Cannot enter root directory [${BACKUP_BENCH_ROOT}]."; exit 127; }

log "Running ${PROGRAM} ${PROGRAM_BUILD} using configuration file ${CONFIG_FILE}" "NOTICE"
log "Logs of this run are kept in ${LOG_DIR}" "NOTICE"

# Refuse configuration files that predate settings this script needs
if ! [[ "${CONF_VERSION}" =~ ^[0-9]+$ ]] || [ "${CONF_VERSION}" -lt "${MINIMUM_CONF_VERSION}" ]; then
        log_quit "Configuration file [${CONFIG_FILE}] is too old (found version '${CONF_VERSION}', need at least ${MINIMUM_CONF_VERSION}). Please update it from the shipped backup-bench.conf" "CRITICAL"
fi

self_setup

if [ "${ALL}" == true ]; then
        # prepare repos and run all tests locally and remotely, using the git dataset
        clear_repositories false
        init_repositories false true
        benchmarks false true "${BACKUP_ID_TIMESTAMP}"
        clear_repositories true
        init_repositories true true
        benchmarks true true "${BACKUP_ID_TIMESTAMP}"
elif [ -n "${cmd}" ]; then
        full_cmd="${cmd} ${REMOTELY} ${USE_GIT_VERSIONS} ${BACKUP_ID_TIMESTAMP}"
        log "Running: ${full_cmd}" "DEBUG"
        eval "${full_cmd}"
else
        echo "No action given."
        usage
fi
