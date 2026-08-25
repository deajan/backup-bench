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
# For every backup program, against every storage backend, the script measures:
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
# STORAGE BACKENDS
#
# The backend is chosen with --backend=<name>, --local and --remote being kept as
# aliases of local and sftp:
#
#   local   repositories on a local filesystem path below ${TARGET_ROOT}
#   sftp    repositories on the remote target, reached over SSH. Each program uses
#           whatever it speaks best: its own protocol over ssh (borg, bupstash),
#           sftp (kopia, restic, rustic, duplicacy, plakar) or, when the matching
#           *_USE_HTTP option is enabled, an https server running on the target
#           (kopia server, rest-server)
#   s3      repositories in S3 buckets, one bucket per program. backup-bench does
#           not install nor manage an S3 server: it uses the endpoint configured in
#           S3_ENDPOINT, which can be MinIO, Garage, Ceph RGW, Wasabi, AWS, ...
#
# Not every program can reach every backend: bupstash only speaks its own protocol
# over ssh, and borg 1.x has no object storage support. Both are therefore skipped
# during an s3 run and get "n/a" in the results instead of a timing. Programs
# unable to reach a backend are declared in ${UNSUPPORTED_BACKENDS} below.
#
# TUNING PROFILES
#
# Programs do not ship with comparable defaults: borg compresses with lz4 and runs
# single threaded, bupstash already defaults to zstd:3 with one thread per
# processor, restic reads 2 files at a time, and plakar defaults to 8 x CPU + 1
# parallel tasks. Handing every program the same flags would therefore hide what
# people actually get, while running everything at its default hides what the
# programs are capable of. So --profile selects one of three passes:
#
#   default    no compression nor concurrency option is passed at all
#   equalised  every program is pushed as close to ${EQUALISED_ZSTD_LEVEL} and
#              ${EQUALISED_THREADS} as its own options allow
#   best       every program is asked for its strongest compression and as much
#              parallelism as it accepts
#
# Not every program can follow: duplicacy only ever uses LZ4, plakar 1.1.x exposes
# no compression option, restic and kopia only name their compression presets
# instead of taking a level, and borg, borg 2 and rustic expose no concurrency
# option at all. Each set_<name>_tuning_args function documents what its program
# could and could not do, and README.md carries the same table.
#
# The two profile targets only ever cover compression and concurrency. Exclusions,
# tags, encryption and repository format stay identical across profiles, otherwise
# the passes would not be comparable with each other.
#
# Repositories must be cleared between two profiles, since chunks are deduplicated
# on their plaintext: a second profile would reuse the first one's chunks instead
# of recompressing them, making both its timings and its size meaningless. The
# profile a repository was initialized with is recorded, and benchmarking a
# repository built by another profile is refused, see check_repository_profile().
#
# KEEPING THE COMPARISON FAIR
#
#   - the page cache (and the ZFS ARC) is dropped before every single backup and
#     restore, see drop_caches()
#   - the '.git' directory of the git dataset is excluded everywhere, since it
#     would otherwise dominate deduplication results
#   - no program is allowed to write into the dataset (this is why duplicacy is
#     driven with 'init -repository', see init_duplicacy_repository)
#   - restores skip ACLs / xattrs / ownership when the program can, so all of
#     them do a comparable amount of work
#   - one backend and one profile at a time: mixing transports or settings inside
#     a run would make the numbers of that run incomparable
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
#   init_<name>_repository    creates an empty repository        (arg: backend)
#   clear_<name>_repository   destroys the repository            (arg: backend)
#   backup_<name>             creates a backup    (args: backend, backup_id)
#   restore_<name>            restores a backup   (args: backend, backup_id)
#
# 'backend' is one of the names listed above and tells the function which
# repository to work on. 'backup_id' identifies one backup (an archive name, a
# tag, ... depending on the program) and is used again at restore time to find
# that backup back.
#
# Two more functions are optional and only called when they exist:
#
#   setup_source_<name>       extra source side setup (keys, plugins, ssh config)
#   setup_ssh_<name>_server   restricts the target authorized_keys to a serve
#                             command, for programs that speak their own protocol
#                             over ssh (borg, borg_beta, bupstash)
#   set_<name>_tuning_args    fills ${TUNING_ARGS} with the compression and
#                             concurrency options of the current ${PROFILE}
#
# By convention each program also has one helper turning a backend name into the
# arguments or the environment that program needs to reach its repository
# (set_restic_repo_args, get_duplicacy_storage_url, connect_kopia_repository, ...).
# Keeping that in a single place per program is what makes init/backup/restore
# one-liners, and what makes adding a backend cheap.
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
PROGRAM_BUILD=2026081804

# Configuration files older than this one lack settings this script needs
MINIMUM_CONF_VERSION=2026081804

# Set by repeat_benchmarks so every result block says which run produced it
RUN_NUMBER=""

# Whether the current result block already carries its header, see write_csv_header
CSV_HEADER_WRITTEN=false

# Separator of the results file. Not a comma: borg spells its compression level
# "--compression zstd,3", and recording that in a comma separated file needs quoting,
# which every naive reader (awk -F"," and friends) then gets wrong. A semicolon needs
# no quoting here, and is what a spreadsheet in a European locale expects anyway.
# Whatever this is set to, it has to be a character no recorded value can contain
CSV_SEPARATOR=";"

# Programs that cannot reach every backend. Anything not listed here is assumed to
# support all of them.
#   bupstash: only speaks the bupstash protocol over ssh, no object storage
#   borg:     borg 1.x has no object storage support (borg 2.x has, via borgstore)
declare -A UNSUPPORTED_BACKENDS=(
        [bupstash]="s3"
        [borg]="s3"
)

# Alias under which the mc client knows our endpoint, see export_s3_credentials
S3_MC_ALIAS="backupbench"

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

function supports_backend {
        # Programs listed in ${UNSUPPORTED_BACKENDS} cannot reach the given backend.
        # Anything not listed is assumed to support all of them
        local backup_software="${1}"
        local backend="${2}"
        local unsupported="${UNSUPPORTED_BACKENDS[${backup_software}]}"

        [ -z "${unsupported}" ] && return 0
        case " ${unsupported} " in
                *" ${backend} "*)
                return 1
                ;;
        esac
        return 0
}

function get_exec_outcome {
        # Echoes why a task did not complete, so the results file can say 'timeout' or
        # 'failed' instead of the elapsed seconds. Writing the seconds there would hand us
        # a number that looks like a measurement while only recording the moment we gave up.
        # ExecTasks returns the exit code of the task it watched, and sets
        # HARD_MAX_EXEC_TIME_REACHED_<id> when it killed that task for exceeding its hard
        # execution time.
        # The code we report is the one our own backup_/restore_ function returned, not
        # the backup program's: check_result already turned that one into a 1, and logged
        # it in the program's own log file
        local result="${1}"
        local id="${2}"
        local timed_out_var="HARD_MAX_EXEC_TIME_REACHED_${id}"

        if [ "${!timed_out_var}" == true ]; then
                echo "timeout"
        else
                echo "failed(${result})"
        fi
}

function get_profile_zstd_level {
        # Echoes the zstd level the current profile asks for, or nothing when the profile
        # passes no compression option at all
        case "${PROFILE}" in
                equalised)
                echo "${EQUALISED_ZSTD_LEVEL}"
                ;;
                best)
                echo "${BEST_ZSTD_LEVEL}"
                ;;
        esac
}

function get_profile_threads {
        # Echoes the thread count the current profile asks for, or nothing when the
        # profile passes no concurrency option at all
        case "${PROFILE}" in
                equalised)
                echo "${EQUALISED_THREADS}"
                ;;
                best)
                if [ "${BEST_THREADS}" -eq 0 ]; then
                        nproc
                else
                        echo "${BEST_THREADS}"
                fi
                ;;
        esac
}

function get_backup_software_settings {
        # Echoes every compression and concurrency option the current profile applies to
        # one program, so a result block states the settings that produced it.
        # Most of it comes straight from the program's own tuning function. kopia sets its
        # compression as a repository policy and rustic stores it inside the repository, so
        # those two are completed here from the same profile values.
        # We deliberately don't log() from here, since our caller captures our stdout
        local backup_software="${1}"
        local settings=""
        local level

        if declare -F "set_${backup_software}_tuning_args" > /dev/null; then
                "set_${backup_software}_tuning_args"
                settings="${TUNING_ARGS[*]}"
        fi

        level="$(get_profile_zstd_level)"
        case "${backup_software}" in
                kopia)
                # Compression is a repository policy, see set_kopia_policies
                case "${PROFILE}" in
                        equalised)
                        settings="policy --compression zstd ${settings}"
                        ;;
                        best)
                        settings="policy --compression zstd-best-compression ${settings}"
                        ;;
                esac
                ;;
                rustic)
                # Compression is stored in the repository at init time
                [ -n "${level}" ] && settings="init --set-compression ${level} ${settings}"
                ;;
        esac

        # Trim, and say so explicitly when the profile passed nothing at all
        settings="$(echo "${settings}" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
        [ -z "${settings}" ] && settings="none"
        echo "${settings}"
}

function get_profile_marker_file {
        # Remembers which profile built the repositories of a backend
        echo "${BACKUP_BENCH_ROOT}/state/${1}.profile"
}

function record_repository_profile {
        local backend="${1}"
        local marker

        marker="$(get_profile_marker_file "${backend}")"
        mkdir -p "$(dirname "${marker}")" && echo "${PROFILE}" > "${marker}"
}

function forget_repository_profile {
        local backend="${1}"

        rm -f "$(get_profile_marker_file "${backend}")"
}

function check_repository_profile {
        # Two profiles must never share a repository: chunks are deduplicated on their
        # plaintext, so the second profile would reuse the first one's chunks instead of
        # recompressing them, and both its timings and its size would be meaningless
        local backend="${1}"
        local marker
        local recorded

        marker="$(get_profile_marker_file "${backend}")"
        [ ! -f "${marker}" ] && return 0
        recorded="$(cat "${marker}")"
        if [ "${recorded}" != "${PROFILE}" ]; then
                log_quit "The ${backend} repositories were initialized with the '${recorded}' profile, but this run uses '${PROFILE}'. Run --clear-repos and --init-repos first, or both profiles would deduplicate against each other." "CRITICAL"
        fi
        return 0
}

function run_on_target {
        # Runs a shell command where the repositories live: locally for the local
        # backend, on the remote target over ssh otherwise.
        # The s3 backend has no shell, its repositories are handled with the mc client
        local backend="${1}"
        local cmd="${2}"

        if [ "${backend}" == local ]; then
                eval "${cmd}"
        else
                ${REMOTE_SSH_RUNNER} "${cmd}"
        fi
}

function drop_caches {
        # Timings are only comparable when nothing is served from RAM, so we flush the
        # page cache (which also drops the zfs arc) on both ends before each measure
        local backend="${1:-local}"
        local drop_remote=false

        if [ -w /proc/sys/vm/drop_caches ]; then
                sync && echo 3 > /proc/sys/vm/drop_caches
        else
                log "Cannot drop local caches, timings will be biased." "WARN"
        fi

        case "${backend}" in
                sftp)
                drop_remote=true
                ;;
                s3)
                # We only know how to reach the S3 server's shell when it runs on our target
                drop_remote="${S3_DROP_TARGET_CACHES}"
                ;;
        esac
        if [ "${drop_remote}" == true ]; then
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
# S3 backend helpers
#
# backup-bench is only an S3 *client*: it never installs nor configures a server.
# The mc client is used for the three things a benchmark cannot do without and
# that no backup program offers: creating the buckets, emptying them between runs,
# and measuring how much data a repository holds. Everything else works without
# mc, you then take care of those three yourself.
###############################################################################

function get_s3_scheme {
        if [ "${S3_USE_TLS}" == true ]; then
                echo "https"
        else
                echo "http"
        fi
}

function get_s3_url {
        # Endpoint with its scheme, the form restic, rustic and borg expect
        echo "$(get_s3_scheme)://${S3_ENDPOINT}"
}

function get_s3_bucket {
        # One bucket per program. S3 bucket names hold neither underscores nor
        # uppercase, so borg_beta ends up in ${S3_BUCKET_PREFIX}borg-beta
        local backup_software="${1}"

        echo "${S3_BUCKET_PREFIX}$(echo "${backup_software}" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
}

function export_s3_credentials {
        # Every program reads its S3 credentials from its own environment variables
        local mc_host

        export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}"          # restic, kopia, rustic (opendal)
        export AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}"
        export AWS_DEFAULT_REGION="${S3_REGION}"
        export DUPLICACY_S3_ID="${S3_ACCESS_KEY}"            # duplicacy
        export DUPLICACY_S3_SECRET="${S3_SECRET_KEY}"

        # mc reads MC_HOST_<alias> from the environment, which saves us from writing
        # an alias into its configuration file
        mc_host="$(get_s3_scheme)://${S3_ACCESS_KEY}:${S3_SECRET_KEY}@${S3_ENDPOINT}"
        # shellcheck disable=SC2163  # this exports MC_HOST_<alias>, not ${S3_MC_ALIAS} itself
        export "MC_HOST_${S3_MC_ALIAS}=${mc_host}"
}

function install_s3_client {
        # mc is the MinIO client, and talks to any S3 compatible endpoint.
        # It is not published through github releases, hence the fixed url
        local url="https://dl.min.io/client/mc/release/linux-amd64/mc"

        log "Installing S3 client (mc) from ${url}" "NOTICE"
        curl -f -L -o "${BIN_DIR}/mc" "${url}" || log_quit "Cannot download mc" "CRITICAL"
        chmod +x "${BIN_DIR}/mc"
        log "Installed S3 client $("${BIN_DIR}/mc" --version 2>/dev/null | head -n 1)" "NOTICE"
}

function have_s3_client {
        # Our warning goes to stderr on purpose: get_s3_repo_size captures our stdout,
        # and a log line landing in there would end up in the results file
        if [ ! -x "${BIN_DIR}/mc" ]; then
                log "No S3 client in [${BIN_DIR}/mc]. Install it with --install-s3-client, or create, empty and measure the buckets yourself." "WARN" >&2
                return 1
        fi
        return 0
}

function run_mc {
        local mc_opts=()

        [ "${S3_TLS_INSECURE}" == true ] && mc_opts+=(--insecure)
        "${BIN_DIR}/mc" "${mc_opts[@]}" "${@}"
}

function setup_s3_buckets {
        # Creates one bucket per program able to use the s3 backend
        local backup_software
        local bucket

        [ -z "${S3_ENDPOINT}" ] && log_quit "S3_ENDPOINT is not configured." "CRITICAL"
        have_s3_client || log_quit "Cannot create buckets without an S3 client." "CRITICAL"
        export_s3_credentials

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if ! supports_backend "${backup_software}" s3; then
                        log "Skipping bucket for ${backup_software}: it has no s3 backend." "NOTICE"
                        continue
                fi
                bucket="$(get_s3_bucket "${backup_software}")"
                log "Creating bucket [${bucket}] on ${S3_ENDPOINT}" "NOTICE"
                run_mc mb --ignore-existing "${S3_MC_ALIAS}/${bucket}"
                check_result $? "bucket ${bucket} creation"
        done
}

function clear_s3_bucket {
        # Empties the program's bucket, the s3 equivalent of removing a repository
        # directory
        local backup_software="${1}"
        local bucket

        bucket="$(get_s3_bucket "${backup_software}")"
        if ! have_s3_client; then
                log "Please empty bucket [${bucket}] yourself before benchmarking again." "WARN"
                return 1
        fi
        export_s3_credentials

        log "Emptying bucket [${bucket}]" "NOTICE"
        # mc rm exits non zero on an already empty bucket, which is not an error for us
        run_mc rm --recursive --force --quiet "${S3_MC_ALIAS}/${bucket}/" > /dev/null 2>&1
        # mb only fails when the endpoint or the credentials are wrong. Staying silent there
        # would let us benchmark a bucket still holding the previous run, and report figures
        # that mean nothing
        if ! run_mc mb --ignore-existing "${S3_MC_ALIAS}/${bucket}" > /dev/null 2>&1; then
                log "Cannot reach bucket [${bucket}] on ${S3_ENDPOINT}. It may still hold data from an earlier run." "CRITICAL"
                return 1
        fi
        return 0
}

function get_s3_repo_size {
        # Echoes the size of every object in the program's bucket, in kilobytes.
        # We sum the sizes 'mc ls --json' reports rather than use 'mc du', which only
        # prints human readable units we would have to parse back
        local backup_software="${1}"
        local bucket

        bucket="$(get_s3_bucket "${backup_software}")"
        if ! have_s3_client; then
                echo 0
                return 0
        fi
        export_s3_credentials
        run_mc ls --recursive --json "${S3_MC_ALIAS}/${bucket}" 2>/dev/null | sed -n 's/.*"size":\([0-9]*\).*/\1/p' | awk '{total += $1} END {printf "%d\n", total / 1024}'
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
        ssh -O exit -o "ControlPath=/tmp/${PROGRAM}.ctrlm.$$" "${SOURCE_USER}@${SOURCE_FQDN}" > /dev/null 2>&1
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
        ssh-keygen -b 2048 -t rsa -f "${key_file}" -q -N "" -C "backup-bench"
        # Drop the key an earlier run added, so repeated runs don't pile them up
        if [ -f /root/.ssh/authorized_keys ]; then
                grep -v " backup-bench$" /root/.ssh/authorized_keys > "/root/.ssh/authorized_keys.${PROGRAM}.tmp"
                mv -f "/root/.ssh/authorized_keys.${PROGRAM}.tmp" /root/.ssh/authorized_keys
        fi
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
# - has no object storage support at all, so it is skipped on the s3 backend
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
        local backend="${1}"

        if [ "${backend}" == local ]; then
                export BUPSTASH_REPOSITORY="${BUPSTASH_REPOSITORY_LOCAL}"
                unset BUPSTASH_REPOSITORY_COMMAND
        else
                export BUPSTASH_REPOSITORY_COMMAND="${BUPSTASH_REPOSITORY_COMMAND_REMOTE}"
                unset BUPSTASH_REPOSITORY
        fi
}

function set_bupstash_tuning_args {
        # bupstash takes both a zstd level and a thread count, so it can follow any
        # profile exactly. Worth knowing for the default profile: it already defaults to
        # zstd:3 and to one thread per processor
        local level
        local threads

        TUNING_ARGS=()
        level="$(get_profile_zstd_level)"
        [ -n "${level}" ] && TUNING_ARGS+=(--compression "zstd:${level}")
        threads="$(get_profile_threads)"
        [ -n "${threads}" ] && TUNING_ARGS+=(--threads "${threads}")
}

function init_bupstash_repository {
        local backend="${1:-local}"

        log "Initializing bupstash repository. Backend: ${backend}." "NOTICE"
        set_bupstash_repository "${backend}"
        "${BIN_DIR}/bupstash" init
        check_result $? "bupstash repository initialization" true
}

function clear_bupstash_repository {
        local backend="${1:-local}"

        # bupstash expects the directory not to exist in order to serve it via bupstash
        # serve, or even just to init it, since v0.12
        log "Clearing bupstash repository. Backend: ${backend}." "NOTICE"
        local cmd="rm -rf \"${TARGET_ROOT:?}/bupstash\"; mkdir ${TARGET_ROOT:?}/bupstash; if getent passwd | grep bupstash_user > /dev/null; then chown bupstash_user \"${TARGET_ROOT}/bupstash\"; fi"
        run_on_target "${backend}" "${cmd}"
}

function backup_bupstash {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching bupstash backup. Backend: ${backend}. Profile: ${PROFILE}." "NOTICE"
        set_bupstash_repository "${backend}"
        set_bupstash_tuning_args
        "${BIN_DIR}/bupstash" put "${TUNING_ARGS[@]}" --exclude '.git' --print-file-actions --print-stats "BACKUPID=${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.bupstash.log" 2>&1
        check_result $? "bupstash backup"
}

function restore_bupstash {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching bupstash restore. Backend: ${backend}." "NOTICE"
        set_bupstash_repository "${backend}"

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
# - 1.x knows only local paths and ssh. Object storage arrived with borg 2 and
#   borgstore, so borg stable is skipped on the s3 backend
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

function set_borg_repo_args {
        # Exports ${BORG_REPO} and fills ${REPO_ARGS} with the --rsh option needed to
        # reach a repository over ssh
        local backend="${1}"

        REPO_ARGS=()
        if [ "${backend}" == local ]; then
                export BORG_REPO="${BORG_STABLE_REPO_LOCAL}"
        else
                export BORG_REPO="${BORG_STABLE_REPO_REMOTE}"
                REPO_ARGS=(--rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -o StrictHostKeyChecking=accept-new")
        fi
}

function set_borg_tuning_args {
        # borg takes a zstd level (1 to 22) but exposes no concurrency option at all, so
        # it stays single threaded in every profile. Its own default is lz4, not zstd
        local level

        TUNING_ARGS=()
        level="$(get_profile_zstd_level)"
        [ -n "${level}" ] && TUNING_ARGS=(--compression "zstd,${level}")
}

function init_borg_repository {
        local backend="${1:-local}"

        log "Initializing borg repository. Backend: ${backend}." "NOTICE"
        set_borg_repo_args "${backend}"
        "${BIN_DIR}/borg" init "${REPO_ARGS[@]}" -e repokey "${BORG_REPO}"
        check_result $? "borg repository initialization" true
}

function clear_borg_repository {
        local backend="${1:-local}"

        log "Clearing borg repository. Backend: ${backend}." "NOTICE"
        # borg expects the data directory to already exist in order to serve it via borg serve
        local cmd="rm -rf \"${TARGET_ROOT:?}/borg/data\"; mkdir -p \"${TARGET_ROOT}/borg/data\"; if getent passwd | grep borg_user > /dev/null; then chown borg_user \"${TARGET_ROOT}/borg/data\"; fi"
        run_on_target "${backend}" "${cmd}"
}

function backup_borg {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching borg backup. Backend: ${backend}. Profile: ${PROFILE}." "NOTICE"
        set_borg_repo_args "${backend}"
        set_borg_tuning_args
        # Exclusion patterns can be checked with borg create --list --dry-run --exclude ...
        "${BIN_DIR}/borg" create "${REPO_ARGS[@]}" "${TUNING_ARGS[@]}" --exclude 're:\.git/.*$' --stats --verbose "${BORG_REPO}"::"${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.borg.log" 2>&1
        check_result $? "borg backup"
}

function restore_borg {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching borg restore. Backend: ${backend}." "NOTICE"
        set_borg_repo_args "${backend}"
        # borg extracts relative to the current directory
        cd "${RESTORE_DIR}" || return 127
        # --noacls and --noxattrs keep the restore comparable with the other programs
        "${BIN_DIR}/borg" extract "${REPO_ARGS[@]}" --noacls --noxattrs "${BORG_REPO}"::"${backup_id}" >> "${LOG_DIR}/${PROGRAM}.borg.log" 2>&1
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
#   in the archive name, --encryption instead of -e, options before the command
# - aes256-ocb was picked by running 'borg_beta benchmark cpu' on the source
# - borg 2 reaches object storage through borgstore, whose s3 URL carries the
#   credentials: s3:KEY:SECRET@scheme://host:port/bucket/path
###############################################################################

function install_borg_beta {
        local version="2.0.0b23"
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

function set_borg_beta_repo_args {
        # Exports ${BORG_REPO} and fills ${REPO_ARGS} with the global options borg 2
        # expects before its command
        local backend="${1}"

        REPO_ARGS=()
        case "${backend}" in
                s3)
                # The two substitutions are hoisted out of the export, so their exit
                # status is not masked by the export builtin (SC2155)
                local s3_url
                local bucket
                s3_url="$(get_s3_url)"
                bucket="$(get_s3_bucket borg_beta)"
                export BORG_REPO="s3:${S3_ACCESS_KEY}:${S3_SECRET_KEY}@${s3_url}/${bucket}/data"
                ;;
                sftp)
                export BORG_REPO="${BORG_BETA_REPO_REMOTE}"
                REPO_ARGS=(--rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -o StrictHostKeyChecking=accept-new")
                ;;
                *)
                export BORG_REPO="${BORG_BETA_REPO_LOCAL}"
                ;;
        esac
}

function set_borg_beta_tuning_args {
        # Same as borg stable: a zstd level, and no concurrency option
        local level

        TUNING_ARGS=()
        level="$(get_profile_zstd_level)"
        [ -n "${level}" ] && TUNING_ARGS=(--compression "zstd,${level}")
}

function init_borg_beta_repository {
        local backend="${1:-local}"

        log "Initializing borg_beta repository. Backend: ${backend}." "NOTICE"
        set_borg_beta_repo_args "${backend}"
        "${BIN_DIR}/borg_beta" "${REPO_ARGS[@]}" repo-create --encryption=aes256-ocb
        check_result $? "borg_beta repository initialization" true
}

function clear_borg_beta_repository {
        local backend="${1:-local}"

        log "Clearing borg_beta repository. Backend: ${backend}." "NOTICE"
        if [ "${backend}" == s3 ]; then
                clear_s3_bucket borg_beta
                return $?
        fi
        # borg expects the data directory to already exist in order to serve it via borg serve
        local cmd="rm -rf \"${TARGET_ROOT:?}/borg_beta/data\"; mkdir -p \"${TARGET_ROOT}/borg_beta/data\"; if getent passwd | grep borg_beta_user > /dev/null; then chown borg_beta_user \"${TARGET_ROOT}/borg_beta/data\"; fi"
        run_on_target "${backend}" "${cmd}"
}

function backup_borg_beta {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching borg_beta backup. Backend: ${backend}. Profile: ${PROFILE}." "NOTICE"
        set_borg_beta_repo_args "${backend}"
        set_borg_beta_tuning_args
        "${BIN_DIR}/borg_beta" "${REPO_ARGS[@]}" create "${TUNING_ARGS[@]}" --exclude 're:\.git/.*$' --stats --verbose "${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.borg_beta.log" 2>&1
        check_result $? "borg_beta backup"
}

function restore_borg_beta {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching borg_beta restore. Backend: ${backend}." "NOTICE"
        set_borg_beta_repo_args "${backend}"
        # borg extracts relative to the current directory
        cd "${RESTORE_DIR}" || return 127
        # --noacls and --noxattrs keep the restore comparable with the other programs
        "${BIN_DIR}/borg_beta" "${REPO_ARGS[@]}" extract --noacls --noxattrs "${backup_id}" >> "${LOG_DIR}/${PROGRAM}.borg_beta.log" 2>&1
        check_result $? "borg_beta restore"
}

###############################################################################
# kopia
#
# - reached over sftp, as an https server on the target (KOPIA_USE_HTTP) or on S3,
#   which is why it is also installed on the target
# - the repository connection is kept in a local configuration file, so every
#   operation starts by reconnecting to the right repository
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

function set_kopia_s3_args {
        # Fills ${REPO_ARGS} with the S3 arguments shared by 'repository create s3' and
        # 'repository connect s3'. kopia wants an endpoint without any scheme
        REPO_ARGS=("--bucket=$(get_s3_bucket kopia)" "--endpoint=${S3_ENDPOINT}" "--access-key=${S3_ACCESS_KEY}" "--secret-access-key=${S3_SECRET_KEY}" "--region=${S3_REGION}" "--prefix=data/")
        [ "${S3_USE_TLS}" == false ] && REPO_ARGS+=(--disable-tls)
        [ "${S3_TLS_INSECURE}" == true ] && REPO_ARGS+=(--disable-tls-verification)
}

function connect_kopia_repository {
        local backend="${1}"

        case "${backend}" in
                s3)
                set_kopia_s3_args
                "${BIN_DIR}/kopia" repository connect s3 "${REPO_ARGS[@]}"
                ;;
                sftp)
                if [ "${KOPIA_USE_HTTP}" == true ]; then
                        "${BIN_DIR}/kopia" repository connect server "--url=https://${REMOTE_TARGET_FQDN}:${KOPIA_HTTP_PORT}" --server-cert-fingerprint="$(get_remote_certificate_fingerprint "${REMOTE_TARGET_FQDN}" "${KOPIA_HTTP_PORT}")" -p "${KOPIA_HTTP_PASSWORD}" "--override-username=${KOPIA_HTTP_USERNAME}" --override-hostname=backup-bench-source
                        # KOPIA_PASSWORD has to be empty in server mode, or operations fail
                        export KOPIA_PASSWORD=
                else
                        "${BIN_DIR}/kopia" repository connect sftp "--path=${TARGET_ROOT}/kopia/data" "--host=${REMOTE_TARGET_FQDN}" --port "${REMOTE_TARGET_SSH_PORT}" "--keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key" --username=kopia_user "--known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts"
                fi
                ;;
                *)
                "${BIN_DIR}/kopia" repository connect filesystem "--path=${TARGET_ROOT}/kopia/data"
                ;;
        esac
}

function set_kopia_tuning_args {
        # kopia takes a thread count. Its compression is a repository policy instead of a
        # backup option, so it is handled by set_kopia_policies
        local threads

        TUNING_ARGS=()
        threads="$(get_profile_threads)"
        [ -n "${threads}" ] && TUNING_ARGS=(--parallel "${threads}")
}

function set_kopia_policies {
        # Policies live in the repository, so they have to be set for every new one.
        # kopia names its compression presets instead of taking a zstd level, so the
        # equalised profile uses plain 'zstd' as the closest thing to a default level
        local target="${1:---global}"
        local compression

        case "${PROFILE}" in
                equalised)
                compression=zstd
                ;;
                best)
                compression=zstd-best-compression
                ;;
        esac
        [ -n "${compression}" ] && "${BIN_DIR}/kopia" policy set "${target}" --compression "${compression}"
        "${BIN_DIR}/kopia" policy set "${target}" --add-ignore '.git'
}

function init_kopia_repository {
        local backend="${1:-local}"

        log "Initializing kopia repository. Backend: ${backend}." "NOTICE"
        case "${backend}" in
                s3)
                set_kopia_s3_args
                "${BIN_DIR}/kopia" repository create s3 "${REPO_ARGS[@]}"
                check_result $? "kopia repository initialization" true
                set_kopia_policies --global
                ;;
                sftp)
                if [ "${KOPIA_USE_HTTP}" == true ]; then
                        # In http mode the repository is created by serve_http_targets on the
                        # target before the server starts, so we only connect to it here
                        connect_kopia_repository sftp
                        check_result $? "kopia repository connection" true
                        set_kopia_policies "${KOPIA_HTTP_USERNAME}@backup-bench-source"
                else
                        "${BIN_DIR}/kopia" repository create sftp "--path=${TARGET_ROOT}/kopia/data" "--host=${REMOTE_TARGET_FQDN}" --port "${REMOTE_TARGET_SSH_PORT}" "--keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key" --username=kopia_user "--known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts" --block-hash=BLAKE3-256 --encryption=AES256-GCM-HMAC-SHA256
                        check_result $? "kopia repository initialization" true
                        set_kopia_policies --global
                fi
                ;;
                *)
                "${BIN_DIR}/kopia" repository create filesystem "--path=${TARGET_ROOT}/kopia/data"
                check_result $? "kopia repository initialization" true
                set_kopia_policies --global
                ;;
        esac
}

function clear_kopia_repository {
        local backend="${1:-local}"

        log "Clearing kopia repository. Backend: ${backend}." "NOTICE"
        if [ "${backend}" == s3 ]; then
                clear_s3_bucket kopia
                return $?
        fi
        run_on_target "${backend}" "rm -rf \"${TARGET_ROOT:?}/kopia/data\""
}

function backup_kopia {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching kopia backup. Backend: ${backend}. Profile: ${PROFILE}." "NOTICE"
        connect_kopia_repository "${backend}"
        set_kopia_tuning_args
        # Exclusion patterns can be checked with kopia snapshot estimate
        "${BIN_DIR}/kopia" snapshot create "${TUNING_ARGS[@]}" --tags "BACKUPID:${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.kopia.log" 2>&1
        check_result $? "kopia backup"
}

function restore_kopia {
        local backend="${1}"
        local backup_id="${2}"
        local id

        log "Launching kopia restore. Backend: ${backend}." "NOTICE"
        connect_kopia_repository "${backend}"

        id="$("${BIN_DIR}/kopia" snapshot list --tags "BACKUPID:${backup_id}" | awk '{print $4}')"
        check_snapshot_id "${id}" kopia "${backup_id}" || return 1
        set_kopia_tuning_args
        "${BIN_DIR}/kopia" restore "${TUNING_ARGS[@]}" --skip-owners --skip-permissions "${id}" "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.kopia.log" 2>&1
        check_result $? "kopia restore"
}

###############################################################################
# restic
#
# - reached over sftp, through a rest-server on the target (RESTIC_USE_HTTP) or on
#   S3, where credentials come from the AWS_* environment variables
# - repository format 2 is required for compression support
# - restic only supports path style S3 URLs (endpoint/bucket, never bucket.endpoint)
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

function set_restic_repo_args {
        # Fills ${REPO_ARGS} with the arguments selecting the repository
        local backend="${1}"

        REPO_ARGS=()
        case "${backend}" in
                s3)
                REPO_ARGS=(-r "s3:$(get_s3_url)/$(get_s3_bucket restic)/data")
                [ "${S3_TLS_INSECURE}" == true ] && REPO_ARGS+=(--insecure-tls)
                ;;
                sftp)
                if [ "${RESTIC_USE_HTTP}" == true ]; then
                        REPO_ARGS=(--insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/")
                else
                        REPO_ARGS=(-r "sftp::${TARGET_ROOT}/restic/data" -o "sftp.command=ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -s sftp")
                fi
                ;;
                *)
                REPO_ARGS=(-r "${TARGET_ROOT}/restic/data")
                ;;
        esac
}

function set_restic_tuning_args {
        # restic names its compression modes (auto|off|fastest|better|max) instead of
        # taking a zstd level, so the equalised profile uses 'auto', its own zstd default,
        # and the best profile uses 'max'. --read-concurrency defaults to 2
        local threads

        TUNING_ARGS=()
        case "${PROFILE}" in
                equalised)
                TUNING_ARGS+=(--compression auto)
                ;;
                best)
                TUNING_ARGS+=(--compression max)
                ;;
        esac
        threads="$(get_profile_threads)"
        [ -n "${threads}" ] && TUNING_ARGS+=(--read-concurrency "${threads}")
}

function init_restic_repository {
        local backend="${1:-local}"

        log "Initializing restic repository. Backend: ${backend}." "NOTICE"
        set_restic_repo_args "${backend}"
        "${BIN_DIR}/restic" "${REPO_ARGS[@]}" init --repository-version 2
        check_result $? "restic repository initialization" true
}

function clear_restic_repository {
        local backend="${1:-local}"

        log "Clearing restic repository. Backend: ${backend}." "NOTICE"
        if [ "${backend}" == s3 ]; then
                clear_s3_bucket restic
                return $?
        fi
        run_on_target "${backend}" "rm -rf \"${TARGET_ROOT:?}/restic/data\""
}

function backup_restic {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching restic backup. Backend: ${backend}. Profile: ${PROFILE}." "NOTICE"
        set_restic_repo_args "${backend}"
        set_restic_tuning_args
        "${BIN_DIR}/restic" "${REPO_ARGS[@]}" backup "${TUNING_ARGS[@]}" --verbose --exclude=".git" --tag="${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.restic.log" 2>&1
        check_result $? "restic backup"
}

function restore_restic {
        local backend="${1}"
        local backup_id="${2}"
        local id

        log "Launching restic restore. Backend: ${backend}." "NOTICE"
        set_restic_repo_args "${backend}"
        id="$("${BIN_DIR}/restic" "${REPO_ARGS[@]}" snapshots | grep "${backup_id}" | awk '{print $1}')"
        check_snapshot_id "${id}" restic "${backup_id}" || return 1
        "${BIN_DIR}/restic" "${REPO_ARGS[@]}" restore "${id}" --target "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.restic.log" 2>&1
        check_result $? "restic restore"
}

###############################################################################
# rustic
#
# - restic compatible repositories, reached over sftp, through rest-server or on
#   S3, which rustic talks to through opendal
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

function set_rustic_repo_args {
        # Fills ${REPO_ARGS} with the arguments selecting the repository
        local backend="${1}"

        REPO_ARGS=()
        case "${backend}" in
                s3)
                REPO_ARGS=(-r "opendal:s3" -o "bucket=$(get_s3_bucket rustic)" -o "endpoint=$(get_s3_url)" -o "region=${S3_REGION}" -o "root=/data" -o "access_key_id=${S3_ACCESS_KEY}" -o "secret_access_key=${S3_SECRET_KEY}")
                ;;
                sftp)
                if [ "${RUSTIC_USE_HTTP}" == true ]; then
                        REPO_ARGS=(--insecure-tls -r "rest:https://${REMOTE_TARGET_FQDN}:${RUSTIC_HTTP_PORT}/")
                else
                        REPO_ARGS=(-r "sftp::${TARGET_ROOT}/rustic/data" -o "sftp.command=ssh rustic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/rustic.key ${SSH_OPTS} -p ${REMOTE_TARGET_SSH_PORT} -s sftp")
                fi
                ;;
                *)
                REPO_ARGS=(-r "${TARGET_ROOT}/rustic/data")
                ;;
        esac
}

function init_rustic_repository {
        local backend="${1:-local}"
        local level
        local init_args=()

        log "Initializing rustic repository. Backend: ${backend}. Profile: ${PROFILE}." "NOTICE"
        set_rustic_repo_args "${backend}"
        # rustic keeps its compression level in the repository, so unlike every other
        # program its profile has to be applied at init time
        level="$(get_profile_zstd_level)"
        [ -n "${level}" ] && init_args=(--set-compression "${level}")
        "${BIN_DIR}/rustic" "${REPO_ARGS[@]}" init "${init_args[@]}"
        check_result $? "rustic repository initialization" true
}

function clear_rustic_repository {
        local backend="${1:-local}"

        log "Clearing rustic repository. Backend: ${backend}." "NOTICE"
        if [ "${backend}" == s3 ]; then
                clear_s3_bucket rustic
                return $?
        fi
        run_on_target "${backend}" "rm -rf \"${TARGET_ROOT:?}/rustic/data\""
}

function backup_rustic {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching rustic backup. Backend: ${backend}." "NOTICE"
        set_rustic_repo_args "${backend}"
        "${BIN_DIR}/rustic" "${REPO_ARGS[@]}" backup --glob="!.git" --tag="${backup_id}" "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.rustic.log" 2>&1
        check_result $? "rustic backup"
}

function restore_rustic {
        local backend="${1}"
        local backup_id="${2}"
        local id

        log "Launching rustic restore. Backend: ${backend}." "NOTICE"
        set_rustic_repo_args "${backend}"
        id="$("${BIN_DIR}/rustic" "${REPO_ARGS[@]}" snapshots | grep "${backup_id}" | awk '{print $2}')"
        check_snapshot_id "${id}" rustic "${backup_id}" || return 1
        "${BIN_DIR}/rustic" "${REPO_ARGS[@]}" restore "${id}" "${RESTORE_DIR}" >> "${LOG_DIR}/${PROGRAM}.rustic.log" 2>&1
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
# Three more duplicacy specifics worth knowing:
#   - exclusions are not command line flags, they live in a 'filters' file inside
#     the '.duplicacy' directory
#   - sftp storage paths are relative to the user home directory, unless the URL
#     holds a double slash before the path, which is what the '/${TARGET_ROOT}'
#     below produces
#   - its generic S3 driver is 'minio://' over HTTP and 'minios://' over HTTPS,
#     plain 's3://' being reserved for AWS itself
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
        local backend="${1}"

        case "${backend}" in
                s3)
                if [ "${S3_USE_TLS}" == true ]; then
                        echo "minios://${S3_REGION}@${S3_ENDPOINT}/$(get_s3_bucket duplicacy)/data"
                else
                        echo "minio://${S3_REGION}@${S3_ENDPOINT}/$(get_s3_bucket duplicacy)/data"
                fi
                ;;
                sftp)
                echo "sftp://duplicacy_user@${REMOTE_TARGET_FQDN}:${REMOTE_TARGET_SSH_PORT}/${TARGET_ROOT}/duplicacy/data"
                ;;
                *)
                echo "${TARGET_ROOT}/duplicacy/data"
                ;;
        esac
}

function set_duplicacy_tuning_args {
        # duplicacy only ever uses LZ4, there is no compression option to pass, so only
        # its thread count follows the profile (-threads, see issue #14)
        local threads

        TUNING_ARGS=()
        threads="$(get_profile_threads)"
        [ -n "${threads}" ] && TUNING_ARGS=(-threads "${threads}")
}

function get_duplicacy_snapshot_id {
        # The snapshot id tells the backends apart inside the storage
        local backend="${1}"

        echo "${backend}id"
}

function init_duplicacy_repository {
        local backend="${1:-local}"
        local pref_dir="${2:-${DUPLICACY_PREF_DIR}}"
        local repository="${3:-${BACKUP_ROOT}}"
        local fatal="${4:-true}"

        log "Initializing duplicacy repository for [${repository}] in [${pref_dir}]. Backend: ${backend}." "NOTICE"

        # Remove earlier repo setup, including any '.duplicacy' left inside the dataset
        # by an older version of this script
        rm -rf "${pref_dir:?}"
        rm -rf "${BACKUP_ROOT:?}/.duplicacy"
        mkdir -p "${pref_dir}" || log_quit "Cannot create duplicacy preferences directory [${pref_dir}]" "CRITICAL"
        cd "${pref_dir}" || log_quit "Cannot enter duplicacy preferences directory [${pref_dir}]" "CRITICAL"

        # -e encrypts the storage, the password comes from ${DUPLICACY_PASSWORD}
        "${BIN_DIR}/duplicacy" init -e -repository "${repository}" "$(get_duplicacy_snapshot_id "${backend}")" "$(get_duplicacy_storage_url "${backend}")" >> "${LOG_DIR}/${PROGRAM}.duplicacy.log" 2>&1
        check_result $? "duplicacy repository initialization" "${fatal}" || return 1

        # Exclusions live in [pref dir]/.duplicacy/filters, 'e:' introduces a regex.
        # duplicacy init creates that directory, we just make sure of it
        mkdir -p "${pref_dir}/.duplicacy"
        echo "e:\.git/.*$" > "${pref_dir}/.duplicacy/filters"
}

function clear_duplicacy_repository {
        local backend="${1:-local}"

        log "Clearing duplicacy repository. Backend: ${backend}." "NOTICE"
        case "${backend}" in
                s3)
                clear_s3_bucket duplicacy
                ;;
                sftp)
                run_on_target "${backend}" "rm -rf \"${TARGET_ROOT:?}/duplicacy/data\" && mkdir -p \"${TARGET_ROOT}/duplicacy/data\" && chown duplicacy_user \"${TARGET_ROOT}/duplicacy/data\""
                ;;
                *)
                run_on_target "${backend}" "rm -rf \"${TARGET_ROOT:?}/duplicacy/data\" && mkdir -p \"${TARGET_ROOT}/duplicacy/data\""
                ;;
        esac

        # Drop the local repository metadata too, so the next init starts clean
        rm -rf "${DUPLICACY_PREF_DIR:?}"
        rm -rf "${DUPLICACY_RESTORE_PREF_DIR:?}"
}

function backup_duplicacy {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching duplicacy backup. Backend: ${backend}. Profile: ${PROFILE}." "NOTICE"
        # duplicacy works on the '.duplicacy' directory found in the current directory
        cd "${DUPLICACY_PREF_DIR}" || return 127

        set_duplicacy_tuning_args
        "${BIN_DIR}/duplicacy" backup -t "${backup_id}" -stats "${TUNING_ARGS[@]}" >> "${LOG_DIR}/${PROGRAM}.duplicacy.log" 2>&1
        check_result $? "duplicacy backup"
}

function restore_duplicacy {
        local backend="${1}"
        local backup_id="${2}"
        local revision

        log "Launching duplicacy restore. Backend: ${backend}." "NOTICE"

        # duplicacy restores into its own repository path, so we need a second
        # repository, pointing at ${RESTORE_DIR} instead of at the dataset
        init_duplicacy_repository "${backend}" "${DUPLICACY_RESTORE_PREF_DIR}" "${RESTORE_DIR}" false || return 1
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
        set_duplicacy_tuning_args
        "${BIN_DIR}/duplicacy" restore -r "${revision}" -stats -overwrite -ignore-owner "${TUNING_ARGS[@]}" >> "${LOG_DIR}/${PROGRAM}.duplicacy.log" 2>&1
        check_result $? "duplicacy restore"
}

###############################################################################
# plakar
#
# - repos ('kloset stores') are addressed 'plakar [OPTS] at <store> COMMAND [OPTS]',
#   so option placement matters: global options before 'at', command options after
#   the command
# - the encryption passphrase comes from ${PLAKAR_PASSPHRASE}
# - store connectors are packages, not part of the binary: setup_source_plakar
#   installs the sftp and s3 ones with 'plakar pkg add'
# - the sftp connector shells out to the 'sftp' binary and takes no key or port
#   option, so the ssh client configuration carries those, see setup_source_plakar
# - the s3 connector wants its credentials in the store configuration, so that
#   store is registered once with 'plakar store add' and referenced as '@name'
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
        log "Adding plakar sftp and s3 store connectors" "NOTICE"
        "${BIN_DIR}/plakar" pkg add sftp >> "${LOG_FILE}" 2>&1 || log "Cannot add the plakar sftp connector, sftp plakar benchmarks will fail." "WARN"
        "${BIN_DIR}/plakar" pkg add s3 >> "${LOG_FILE}" 2>&1 || log "Cannot add the plakar s3 connector, s3 plakar benchmarks will fail." "WARN"

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

function register_plakar_s3_store {
        # The s3 connector reads its credentials from the store configuration, which
        # plakar keeps on disk, so this only needs to run at repository init time
        log "Registering plakar s3 store [${PLAKAR_S3_STORE_NAME}]" "NOTICE"
        # Replace the store a previous run may have registered under that name
        "${BIN_DIR}/plakar" store rm "${PLAKAR_S3_STORE_NAME}" > /dev/null 2>&1
        "${BIN_DIR}/plakar" store add "${PLAKAR_S3_STORE_NAME}" "s3://${S3_ENDPOINT}/$(get_s3_bucket plakar)" "access_key=${S3_ACCESS_KEY}" "secret_access_key=${S3_SECRET_KEY}" "use_tls=${S3_USE_TLS}" "tls_insecure_no_verify=${S3_TLS_INSECURE}" >> "${LOG_DIR}/${PROGRAM}.plakar.log" 2>&1
        check_result $? "plakar s3 store registration"
}

function set_plakar_tuning_args {
        # plakar 1.1.x exposes no compression option at all, so only its concurrency
        # follows the profile. '-concurrency' is a global option, it has to come before
        # the 'at' clause.
        # Only the equalised profile sets it: plakar already defaults to 8 x CPU + 1
        # parallel tasks, which is more than the best profile would ask for
        TUNING_ARGS=()
        if [ "${PROFILE}" == "equalised" ]; then
                TUNING_ARGS=(-concurrency "${EQUALISED_THREADS}")
        fi
}

function get_plakar_repository {
        local backend="${1}"

        case "${backend}" in
                s3)
                # A registered store is referenced by its name, prefixed with an @
                echo "@${PLAKAR_S3_STORE_NAME}"
                ;;
                sftp)
                echo "${PLAKAR_REPOSITORY_REMOTE}"
                ;;
                *)
                echo "${PLAKAR_REPOSITORY_LOCAL}"
                ;;
        esac
}

function init_plakar_repository {
        local backend="${1:-local}"

        log "Initializing plakar repository. Backend: ${backend}." "NOTICE"
        [ "${backend}" == s3 ] && register_plakar_s3_store
        # Stores are encrypted unless -plaintext is given
        "${BIN_DIR}/plakar" at "$(get_plakar_repository "${backend}")" create >> "${LOG_DIR}/${PROGRAM}.plakar.log" 2>&1
        check_result $? "plakar repository initialization" true
}

function clear_plakar_repository {
        local backend="${1:-local}"

        log "Clearing plakar repository. Backend: ${backend}." "NOTICE"
        if [ "${backend}" == s3 ]; then
                clear_s3_bucket plakar
                return $?
        fi
        # The data directory is recreated empty, since the sftp user needs to own it
        local cmd="rm -rf \"${TARGET_ROOT:?}/plakar/data\"; mkdir -p \"${TARGET_ROOT}/plakar/data\"; if getent passwd | grep plakar_user > /dev/null; then chown plakar_user \"${TARGET_ROOT}/plakar/data\"; fi"
        run_on_target "${backend}" "${cmd}"
}

function backup_plakar {
        local backend="${1}"
        local backup_id="${2}"

        log "Launching plakar backup. Backend: ${backend}. Profile: ${PROFILE}." "NOTICE"
        set_plakar_tuning_args
        # -ignore takes gitignore style patterns and may be repeated
        "${BIN_DIR}/plakar" "${TUNING_ARGS[@]}" at "$(get_plakar_repository "${backend}")" backup -tag "${backup_id}" -ignore '.git' "${BACKUP_ROOT}/" >> "${LOG_DIR}/${PROGRAM}.plakar.log" 2>&1
        check_result $? "plakar backup"
}

function restore_plakar {
        local backend="${1}"
        local backup_id="${2}"
        local repository
        local id

        log "Launching plakar restore. Backend: ${backend}." "NOTICE"
        repository="$(get_plakar_repository "${backend}")"

        # 'ls -tags' prints one snapshot per line as
        # '<date> <snapshot id> <size> <duration> <path> <tags>', so the id is field 2
        id="$("${BIN_DIR}/plakar" at "${repository}" ls -tags | grep "${backup_id}" | tail -n 1 | awk '{print $2}')"
        check_snapshot_id "${id}" plakar "${backup_id}" || return 1
        set_plakar_tuning_args
        # -skip-permissions keeps the restore comparable with the other programs
        "${BIN_DIR}/plakar" "${TUNING_ARGS[@]}" at "${repository}" restore -to "${RESTORE_DIR}" -skip-permissions "${id}" >> "${LOG_DIR}/${PROGRAM}.plakar.log" 2>&1
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

function get_source_size {
        # Records the size of the dataset that was just backed up, so a compression and
        # deduplication ratio can be computed from a result block alone, without knowing
        # which dataset (or which git tag) produced it.
        # Measured the same way repository sizes are, with du, and with the same '.git'
        # exclusion every program was given, so both figures are comparable.
        # The value is repeated in every column, so a program's ratio is the division of
        # two cells of its own column
        local backend="${1:-local}"
        local backup_id="${2}"
        local backup_software
        local size

        # The label carries the backup id, so a block of several backups can be read
        # without knowing the order of ${GIT_TAGS}
        local CSV_SOURCE_SIZE="source size(kb) ${backup_id}${CSV_SEPARATOR}"

        size="$(du -cs --exclude=.git "${BACKUP_ROOT}" 2>/dev/null | tail -n 1 | awk '{print $1}')"
        [ -z "${size}" ] && size=0
        log "Source dataset size: ${size} kb." "NOTICE"

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if ! supports_backend "${backup_software}" "${backend}"; then
                        CSV_SOURCE_SIZE="${CSV_SOURCE_SIZE}n/a${CSV_SEPARATOR}"
                        continue
                fi
                CSV_SOURCE_SIZE="${CSV_SOURCE_SIZE}${size}${CSV_SEPARATOR}"
        done
        echo "${CSV_SOURCE_SIZE}" >> "${CSV_RESULT_FILE}"
}

function get_repo_sizes {
        local backend="${1:-local}"
        local backup_id="${2}"
        local backup_software
        local size

        local CSV_SIZE="size(kb) ${backup_id}${CSV_SEPARATOR}"

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if ! supports_backend "${backup_software}" "${backend}"; then
                        CSV_SIZE="${CSV_SIZE}n/a${CSV_SEPARATOR}"
                        continue
                fi
                if [ "${backend}" == s3 ]; then
                        size="$(get_s3_repo_size "${backup_software}")"
                else
                        # Measure the repository itself, not the program's directory: on the
                        # sftp backend that directory is also the user's home, and would add
                        # its ssh keys and dotfiles to the figure
                        size="$(run_on_target "${backend}" "du -cs \"${TARGET_ROOT}/${backup_software}/data\"" 2>/dev/null | tail -n 1 | awk '{print $1}')"
                fi
                [ -z "${size}" ] && size=0
                CSV_SIZE="${CSV_SIZE}${size}${CSV_SEPARATOR}"
                log "Repo size for ${backup_software}: ${size} kb. Backend: ${backend}." "NOTICE"
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
                # sftp, http or S3, so the target needs nothing of them
                install_restic
                install_rustic
                install_duplicacy
                install_plakar
                # The S3 client is only needed where the benchmarks run
                [ -n "${S3_ENDPOINT}" ] && install_s3_client
        fi
}

function setup_source {
        local backend="${1:-local}"
        local backup_software

        log "Setting up source server" "NOTICE"
        download_prerequisites "${NODEPS}"

        install_backup_programs false

        if [ "${backend}" == local ]; then
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
        local backend="${1:-local}" # Has no use here obviously, but we'll keep it since the backend argument is passed
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
        local backend="${1:-local}"
        local backup_software

        log "Clearing all repositories from earlier data. Backend: ${backend}." "NOTICE"
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if ! supports_backend "${backup_software}" "${backend}"; then
                        log "Skipping ${backup_software}: it has no ${backend} backend." "NOTICE"
                        continue
                fi
                clear_"${backup_software}"_repository "${backend}"
        done
        # The repositories are empty, so they no longer belong to any profile
        forget_repository_profile "${backend}"
        log "Clearing done" "NOTICE"
}

function init_repositories {
        local backend="${1:-local}"
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

        log "Initializing repositories. Backend: ${backend}. Profile: ${PROFILE}." "NOTICE"
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if ! supports_backend "${backup_software}" "${backend}"; then
                        log "Skipping ${backup_software}: it has no ${backend} backend." "NOTICE"
                        continue
                fi
                init_"${backup_software}"_repository "${backend}"
        done
        # Remember which profile these repositories belong to, see check_repository_profile
        record_repository_profile "${backend}"
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
        local backend="${1}"
        local backup_id="${2:-defaultid}"
        local backup_software
        local seconds_begin
        local exec_time
        local exec_result
        local outcome

        local CSV_BACKUP_EXEC_TIME="backup(s) ${backup_id}${CSV_SEPARATOR}"

        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if ! supports_backend "${backup_software}" "${backend}"; then
                        log "Skipping ${backup_software} backup: it has no ${backend} backend." "NOTICE"
                        CSV_BACKUP_EXEC_TIME="${CSV_BACKUP_EXEC_TIME}n/a${CSV_SEPARATOR}"
                        continue
                fi
                drop_caches "${backend}"
                log "Starting backup bench of ${backup_software} name=${backup_id}" "NOTICE"
                seconds_begin=$SECONDS
                # Launch the backup in the background, so ExecTasks can enforce timeouts
                backup_"${backup_software}" "${backend}" "${backup_id}" &
                ExecTasks "$!" "${backup_software}_bench" false 3600 36000 3600 36000
                exec_result=$?
                exec_time=$((SECONDS - seconds_begin))
                if [ "${exec_result}" -eq 0 ]; then
                        CSV_BACKUP_EXEC_TIME="${CSV_BACKUP_EXEC_TIME}${exec_time}${CSV_SEPARATOR}"
                        log "It took ${exec_time} seconds to backup." "NOTICE"
                else
                        # Never write the elapsed seconds of a backup that did not finish
                        outcome="$(get_exec_outcome "${exec_result}" "${backup_software}_bench")"
                        CSV_BACKUP_EXEC_TIME="${CSV_BACKUP_EXEC_TIME}${outcome}${CSV_SEPARATOR}"
                        log "Backup of ${backup_software} did not complete after ${exec_time} seconds: ${outcome}." "CRITICAL"
                fi
        done

        echo "${CSV_BACKUP_EXEC_TIME}" >> "${CSV_RESULT_FILE}"
        # Recorded per backup, not once per run: with the git dataset every tag is a
        # different amount of data
        get_source_size "${backend}" "${backup_id}"
        get_repo_sizes "${backend}" "${backup_id}"
}

function benchmark_backup_git {
        local backend="${1}"
        local tag

        log "Running git dataset backup benchmarks. Backend: ${backend}" "NOTICE"

        if [ ! -d "${BACKUP_ROOT}/.git" ]; then
                log_quit "No git dataset found in [${BACKUP_ROOT}]. Please run --init-repos --git first." "CRITICAL"
        fi
        cd "${BACKUP_ROOT}" || exit 127

        # Back up one kernel version after another, so every program sees the same
        # sequence of changes and deduplication can be compared
        for tag in "${GIT_TAGS[@]}"; do
                log "Checking out git tag ${tag}" "NOTICE"
                git checkout "${tag}" || log_quit "Cannot checkout git tag ${tag}" "CRITICAL"
                benchmark_backup_standard "${backend}" "bkp-${tag}"
        done
}

function write_csv_header {
        # Opens a result block: what produced it, which versions ran, and what each program
        # was handed. Written by benchmark_backup, and by benchmark_restore when it runs on
        # its own, so that --benchmark-restore doesn't leave a bare row with no context
        local backend="${1}"
        local git="${2:-false}"
        local backup_software
        local settings
        local run_info=""
        local CSV_HEADER
        local CSV_ARGUMENTS

        # ${RUN_NUMBER} is only set when repeat_benchmarks drives us
        [ -n "${RUN_NUMBER}" ] && run_info=" Run: ${RUN_NUMBER}/${RUNS},"
        echo "# $PROGRAM $PROGRAM_BUILD $(date) Backend: ${backend},${run_info} Profile: ${PROFILE}, Git: ${git}" >> "${CSV_RESULT_FILE}"

        CSV_HEADER="${CSV_SEPARATOR}"
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                CSV_HEADER="${CSV_HEADER}${backup_software} $(get_version_"${backup_software}")${CSV_SEPARATOR}"
        done
        echo "${CSV_HEADER}" >> "${CSV_RESULT_FILE}"

        # Record what each program was actually handed. The profile name alone doesn't say
        # it: in the best profile plakar gets nothing (its own default is already more
        # parallel), borg never gets a thread count, and duplicacy never gets a compression
        # option, since neither program has one
        CSV_ARGUMENTS="arguments${CSV_SEPARATOR}"
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if ! supports_backend "${backup_software}" "${backend}"; then
                        CSV_ARGUMENTS="${CSV_ARGUMENTS}n/a${CSV_SEPARATOR}"
                        continue
                fi
                settings="$(get_backup_software_settings "${backup_software}")"
                log "Settings handed to ${backup_software}: ${settings}" "NOTICE"
                # No quoting needed: ${CSV_SEPARATOR} is not a character these options hold
                CSV_ARGUMENTS="${CSV_ARGUMENTS}${settings}${CSV_SEPARATOR}"
        done
        echo "${CSV_ARGUMENTS}" >> "${CSV_RESULT_FILE}"

        if [ "${backend}" == s3 ] && [ "${S3_DROP_TARGET_CACHES}" != true ]; then
                log "S3_DROP_TARGET_CACHES is disabled: the page cache of the S3 server is not dropped between measures." "WARN"
        fi

        CSV_HEADER_WRITTEN=true
}

function benchmark_backup {
        local backend="${1}"
        local git="${2:-false}"
        local backup_id_timestamp="${3:-false}"
        local backup_id

        check_repository_profile "${backend}"

        # A backup always opens its own block, so repeated runs each get their own header
        write_csv_header "${backend}" "${git}"

        if [ "${git}" == true ]; then
                benchmark_backup_git "${backend}"
        else
                if [ "${backup_id_timestamp}" == true ]; then
                        backup_id="$(date +"%Y-%m-%d-T%H-%M-%S")"
                else
                        backup_id="defaultid"
                fi
                benchmark_backup_standard "${backend}" "${backup_id}"
        fi
}

function benchmark_restore_standard {
        local backend="${1}"
        local backup_id="${2:-defaultid}"
        local backup_software
        local seconds_begin
        local exec_time
        local exec_result
        local outcome
        local restored_path
        local result

        local CSV_RESTORE_EXEC_TIME="restoration(s) ${backup_id}${CSV_SEPARATOR}"

        # Restore the given backup and compare it with the current dataset
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if ! supports_backend "${backup_software}" "${backend}"; then
                        log "Skipping ${backup_software} restore: it has no ${backend} backend." "NOTICE"
                        CSV_RESTORE_EXEC_TIME="${CSV_RESTORE_EXEC_TIME}n/a${CSV_SEPARATOR}"
                        continue
                fi
                drop_caches "${backend}"

                [ -d "${RESTORE_DIR}" ] && rm -rf "${RESTORE_DIR:?}"
                mkdir -p "${RESTORE_DIR}"

                log "Starting restore bench of ${backup_software} name=${backup_id}" "NOTICE"
                seconds_begin=$SECONDS
                # Launch the restore in the background, so ExecTasks can enforce timeouts
                restore_"${backup_software}" "${backend}" "${backup_id}" &
                ExecTasks "$!" "${backup_software}_restore" false 3600 18000 3600 18000
                exec_result=$?
                exec_time=$((SECONDS - seconds_begin))
                if [ "${exec_result}" -ne 0 ]; then
                        # Never write the elapsed seconds of a restore that did not finish,
                        # and don't compare a restore directory we know to be incomplete
                        outcome="$(get_exec_outcome "${exec_result}" "${backup_software}_restore")"
                        CSV_RESTORE_EXEC_TIME="${CSV_RESTORE_EXEC_TIME}${outcome}${CSV_SEPARATOR}"
                        log "Restore of ${backup_software} did not complete after ${exec_time} seconds: ${outcome}. Skipping the comparison." "CRITICAL"
                        continue
                fi
                CSV_RESTORE_EXEC_TIME="${CSV_RESTORE_EXEC_TIME}${exec_time}${CSV_SEPARATOR}"
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
        local backend="${1}"
        local tag_count
        local tag_index
        local tag

        log "Running git dataset restore benchmarks. Backend: ${backend}" "NOTICE"

        if [ ! -d "${BACKUP_ROOT}/.git" ]; then
                log_quit "No git dataset found in [${BACKUP_ROOT}]. Please run --init-repos --git first." "CRITICAL"
        fi

        # Restoring the snapshot that was just written is the easiest case a program can be
        # given, since its chunks are the ones it wrote last. ${GIT_RESTORE_OFFSET} steps
        # back from there, so the restore has to walk chunks shared with older snapshots
        # and reach an index entry that is no longer the most recent one
        tag_count="${#GIT_TAGS[@]}"
        tag_index=$((tag_count - 1 - GIT_RESTORE_OFFSET))
        if [ "${tag_index}" -lt 0 ]; then
                log "GIT_RESTORE_OFFSET is ${GIT_RESTORE_OFFSET}, but only ${tag_count} tag(s) were backed up. Restoring the last snapshot instead." "WARN"
                tag_index=$((tag_count - 1))
        fi
        tag="${GIT_TAGS[${tag_index}]}"
        # Recomputed, so the message stays true when the offset above was clamped
        log "Restoring the backup of tag ${tag}, $((tag_count - 1 - tag_index)) snapshot(s) back from the last one" "NOTICE"

        cd "${BACKUP_ROOT}/" || exit 127
        # The dataset has to hold the version we are about to restore, or the comparison
        # would fail for the wrong reason
        git checkout "${tag}" || log_quit "Cannot checkout git tag ${tag}" "CRITICAL"
        benchmark_restore_standard "${backend}" "bkp-${tag}"
}

function benchmark_restore {
        local backend="${1}"
        local git="${2:-false}"
        local backup_id_timestamp="${3:-false}"
        local backup_id

        check_repository_profile "${backend}"

        # Only when we run without a backup before us, so --benchmarks keeps writing one
        # header for the two of us while --benchmark-restore still gets its context
        if [ "${CSV_HEADER_WRITTEN}" != true ]; then
                write_csv_header "${backend}" "${git}"
        fi

        if [ "${git}" == true ]; then
                benchmark_restore_git "${backend}"
        else
                if [ "${backup_id_timestamp}" == true ]; then
                        backup_id="$(date +"%Y-%m-%d-T%H-%M-%S")"
                else
                        backup_id="defaultid"
                fi
                benchmark_restore_standard "${backend}" "${backup_id}"
        fi
}

function benchmarks {
        local backend="${1}"
        local git="${2:-false}"
        local backup_id_timestamp="${3:-false}"

        benchmark_backup "${backend}" "${git}" "${backup_id_timestamp}"
        benchmark_restore "${backend}" "${git}" "${backup_id_timestamp}"
}

function plan_benchmarks {
        # Prints what a run would do, and what it would destroy, without doing any of it.
        # A full sweep is ${RUNS} cycles per backend per profile, so it is worth knowing
        # what you are committing a machine to before starting it
        local backend="${1:-local}"
        local git="${2:-false}"
        local backup_software
        local supported=0
        local tag_count=1
        local settings
        local version

        log "----- Plan: ${backend} backend, ${PROFILE} profile, ${RUNS} run(s). Nothing below is executed -----" "NOTICE"

        if [ "${git}" == true ]; then
                tag_count="${#GIT_TAGS[@]}"
                log "Dataset:      ${BACKUP_ROOT}, deleted and re-cloned once from ${GIT_DATASET_REPOSITORY}" "NOTICE"
                log "              ${tag_count} tag(s) backed up in this order: ${GIT_TAGS[*]}" "NOTICE"
        else
                log "Dataset:      ${BACKUP_ROOT}, used as is and never modified" "NOTICE"
        fi
        log "Restore dir:  ${RESTORE_DIR}, emptied before every single restore" "NOTICE"
        log "Results:      ${CSV_RESULT_FILE}" "NOTICE"
        if [ "${backend}" == s3 ]; then
                log "Repositories: one bucket per program on ${S3_ENDPOINT}, named ${S3_BUCKET_PREFIX}<program>, emptied before every run" "NOTICE"
        else
                log "Repositories: ${TARGET_ROOT}/<program>/data, deleted before every run" "NOTICE"
        fi

        log "Programs, with the settings the ${PROFILE} profile hands them:" "NOTICE"
        for backup_software in "${BACKUP_SOFTWARES[@]}"; do
                if ! supports_backend "${backup_software}" "${backend}"; then
                        log "  ${backup_software}: skipped, it has no ${backend} backend" "NOTICE"
                        continue
                fi
                supported=$((supported + 1))
                version="not installed"
                [ -x "${BIN_DIR}/${backup_software}" ] && version="$(get_version_"${backup_software}")"
                settings="$(get_backup_software_settings "${backup_software}")"
                log "  ${backup_software} ${version}: ${settings}" "NOTICE"
        done

        if [ "${supported}" -eq 0 ]; then
                log "No program in BACKUP_SOFTWARES can use the ${backend} backend, there would be nothing to measure" "WARN"
                log "----- End of plan -----" "NOTICE"
                return 0
        fi

        log "Every run clears and reinitializes ${supported} repositories, takes ${tag_count} backup(s) per program, then restores one snapshot per program" "NOTICE"
        log "Totals over ${RUNS} run(s): $((RUNS * tag_count * supported)) backups, $((RUNS * supported)) restores, $((RUNS * supported)) repository clears" "NOTICE"
        if [ "${PROFILE}" == best ]; then
                log "The best profile compresses with zstd ${BEST_ZSTD_LEVEL}, which is slow. Expect this to take considerably longer than the other profiles" "WARN"
        fi
        log "----- End of plan -----" "NOTICE"
}

function repeat_benchmarks {
        # Runs the whole cycle ${RUNS} times, so a difference between two programs or two
        # profiles can be told apart from the noise of a single measure.
        #
        # The repetition has to wrap the clearing and the initialization, not just the
        # backup: running the same backup twice into the same repository would find every
        # chunk already there the second time, and would measure deduplication instead of
        # the backup itself.
        #
        # The dataset, on the other hand, is prepared once. Every run checks its tags out
        # again from the same clone, and since each run starts from empty repositories
        # there is no state left for a fresh clone to change
        local backend="${1:-local}"
        local git="${2:-false}"
        local backup_id_timestamp="${3:-false}"
        local run

        log "Running ${RUNS} benchmark cycles on the ${backend} backend with the ${PROFILE} profile" "NOTICE"
        [ "${git}" == true ] && setup_git_dataset

        for ((run = 1; run <= RUNS; run++)); do
                RUN_NUMBER="${run}"
                log "Starting run ${run} of ${RUNS}" "NOTICE"
                clear_repositories "${backend}"
                # false: the dataset is already there, it must not be downloaded again
                init_repositories "${backend}" false
                benchmarks "${backend}" "${git}" "${backup_id_timestamp}"
        done
        RUN_NUMBER=""
        log "Finished ${RUNS} benchmark cycles on the ${backend} backend" "NOTICE"
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
        echo "--setup-source                    Install backup programs and setup repositories for the given backend (executed on source)"
        echo "--setup-s3-buckets                Create one S3 bucket per backup program using the S3_* settings (executed on source)"
        echo "--init-repos                      Reinitialize repositories after clearing. Must be used with --git if multiple version benchmarks is used) (executed on source)"
        echo "--serve-http-targets              Launch http servers for kopia and restic manually (executed on target)"
        echo "--stop-http-targets               Stop http servers for kopia and restic (executed on target)"
        echo "--benchmark-backup                Run backup benchmarks"
        echo "--benchmark-restore               Run restore benchmarks, restores to local restore path"
        echo "--benchmarks                      Run both backup and restore benchmarks once"
        echo "--repeat-benchmarks               Clear, init and benchmark RUNS times, so results carry their own variance"
        echo "--plan                            Print what a run would do and destroy, without running it"
        echo "--all                             Same as --repeat-benchmarks, with the git dataset, on every configured backend"
        echo ""
        echo "MODIFIERS"
        echo "--backend=local|sftp|s3           Storage backend to work on (defaults to local)"
        echo "                                    local: filesystem repositories below TARGET_ROOT"
        echo "                                    sftp:  repositories on the remote target, over SSH/SFTP"
        echo "                                    s3:    repositories in S3 buckets, needs the S3_* settings"
        echo "                                  bupstash and borg 1.x have no s3 backend and are skipped there"
        echo "--local                           Alias of --backend=local"
        echo "--remote                          Alias of --backend=sftp"
        echo "--profile=default|equalised|best  How much each program is tuned (defaults to default)"
        echo "                                    default:   no compression nor concurrency option is passed"
        echo "                                    equalised: pushed as close to EQUALISED_ZSTD_LEVEL and"
        echo "                                               EQUALISED_THREADS as each program allows"
        echo "                                    best:      strongest compression and most parallelism"
        echo "                                  Repositories must be cleared and reinitialized between two"
        echo "                                  profiles, or they would deduplicate against each other"
        echo "--runs=N                          How many cycles --repeat-benchmarks and --all run (defaults to RUNS)"
        echo "--git                             Use git dataset (multiple version benchmark). WARNING: deletes and re-clones BACKUP_ROOT"
        echo "--backup-id-timestamp             Add a timestamp as backup id when not using --git. If this option is disabled, backupid will be \"defaultid\". There cannot be multiple backups with the same id"
        echo ""
        echo "After some benchmarks, you might want to remove earlier data from repositories"
        echo "--clear-repos                     Removes data from the repositories of the given backend"
        echo ""
        echo "DEBUG commands"
        echo "--setup-root-access               Manually setup root access (executed on target)"
        echo "--no-deps                         Do not install dependencies. This requires you to have them installed manually"
        echo "--install-backup-programs         Install / upgrade the programs this machine needs into BIN_DIR."
        echo "                                  Add --target-side when running it on the target"
        echo "--install-s3-client               Install the mc client used to create, empty and measure S3 buckets"
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
BACKEND="local"
PROFILE="default"
RUNS_OVERRIDE=""
USE_GIT_VERSIONS=false
ALL=false
CONFIG_FILE="backup-bench.conf"
NODEPS=false
BACKUP_ID_TIMESTAMP=false
# Which machine we are installing on. This is not a backend question: an sftp target
# needs the programs that serve their own protocol plus rest-server, while an s3
# target needs nothing installed at all
TARGET_SIDE=false

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
                --setup-s3-buckets)
                cmd="setup_s3_buckets"
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
                --repeat-benchmarks)
                cmd="repeat_benchmarks"
                ;;
                --plan)
                cmd="plan_benchmarks"
                ;;
                --runs=*)
                RUNS_OVERRIDE="${i##*=}"
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
                --backend=*)
                BACKEND="${i##*=}"
                ;;
                --profile=*)
                PROFILE="${i##*=}"
                ;;
                --local)
                BACKEND="local"
                ;;
                --remote)
                BACKEND="sftp"
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
                --target-side)
                TARGET_SIDE=true
                ;;
                --install-backup-programs)
                cmd="install_backup_programs"
                ;;
                --install-s3-client)
                cmd="install_s3_client"
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

# 'remote' is accepted as an alias of 'sftp', since that backend also covers the
# programs speaking their own protocol over ssh
case "${BACKEND}" in
        local|sftp|s3)
        ;;
        remote)
        BACKEND="sftp"
        ;;
        *)
        log_quit "Unknown backend [${BACKEND}]. Supported backends: local, sftp, s3." "CRITICAL"
        ;;
esac

# 'equalized' is accepted as an alias, so both spellings work
case "${PROFILE}" in
        default|equalised|best)
        ;;
        equalized)
        PROFILE="equalised"
        ;;
        *)
        log_quit "Unknown profile [${PROFILE}]. Supported profiles: default, equalised, best." "CRITICAL"
        ;;
esac
log "Using the ${PROFILE} tuning profile" "NOTICE"

# --runs overrides the configured RUNS
if [ -n "${RUNS_OVERRIDE}" ]; then
        if ! [[ "${RUNS_OVERRIDE}" =~ ^[1-9][0-9]*$ ]]; then
                log_quit "Invalid run count [${RUNS_OVERRIDE}]. It must be a positive integer." "CRITICAL"
        fi
        RUNS="${RUNS_OVERRIDE}"
fi
if ! [[ "${RUNS}" =~ ^[1-9][0-9]*$ ]]; then
        log_quit "Invalid RUNS value [${RUNS}] in [${CONFIG_FILE}]. It must be a positive integer." "CRITICAL"
fi
if ! [[ "${GIT_RESTORE_OFFSET}" =~ ^[0-9]+$ ]]; then
        log_quit "Invalid GIT_RESTORE_OFFSET value [${GIT_RESTORE_OFFSET}] in [${CONFIG_FILE}]. It must be zero or a positive integer." "CRITICAL"
fi

if [ "${BACKEND}" == s3 ] || [ "${cmd}" == "setup_s3_buckets" ]; then
        [ -z "${S3_ENDPOINT}" ] && log_quit "The s3 backend needs S3_ENDPOINT to be set in [${CONFIG_FILE}]." "CRITICAL"
        export_s3_credentials
fi

self_setup

# install_backup_programs takes which machine we are on, not a backend, so it is
# dispatched here rather than through the generic backend convention below
if [ "${cmd}" == "install_backup_programs" ]; then
        if [ "${BACKEND}" != local ] && [ "${TARGET_SIDE}" != true ]; then
                log "--backend has no effect on which programs get installed. Add --target-side when installing on the target." "WARN"
        fi
        install_backup_programs "${TARGET_SIDE}"
        exit $?
fi

# --plan is checked before --all, so asking for a plan of the whole sweep prints it
# instead of running it
if [ "${cmd}" == "plan_benchmarks" ]; then
        if [ "${ALL}" == true ]; then
                for one_backend in local sftp s3; do
                        if [ "${one_backend}" == s3 ] && [ -z "${S3_ENDPOINT}" ]; then
                                log "Skipping the s3 backend: S3_ENDPOINT is not configured." "NOTICE"
                                continue
                        fi
                        plan_benchmarks "${one_backend}" true
                done
        else
                plan_benchmarks "${BACKEND}" "${USE_GIT_VERSIONS}"
        fi
elif [ "${ALL}" == true ]; then
        # prepare repos and run all tests on every backend we can reach, using the git dataset
        for one_backend in local sftp s3; do
                if [ "${one_backend}" == s3 ]; then
                        if [ -z "${S3_ENDPOINT}" ]; then
                                log "Skipping the s3 backend: S3_ENDPOINT is not configured." "NOTICE"
                                continue
                        fi
                        export_s3_credentials
                fi
                log "Running all benchmarks on the ${one_backend} backend" "NOTICE"
                repeat_benchmarks "${one_backend}" true "${BACKUP_ID_TIMESTAMP}"
        done
elif [ -n "${cmd}" ]; then
        full_cmd="${cmd} ${BACKEND} ${USE_GIT_VERSIONS} ${BACKUP_ID_TIMESTAMP}"
        log "Running: ${full_cmd}" "DEBUG"
        eval "${full_cmd}"
else
        echo "No action given."
        usage
fi
