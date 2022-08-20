#!/usr/bin/env bash

# This script is a (very) simple backup benchmark for the following backup programs:
# bupstash
# borg
# kopia
# restic
# duplicacy

# It (should) allow to produce reproductible results, and give an idea of what program is the fastest and creates the smallest backups
# Results can be found in /var/log as pseudo-CSV file
# Should be executed together with a monitoring system that matches cpu/ram/io usage against the running backup solution (disclaimer: I use netdata)

# Script tailored for RHEL 8 and clones (requires bash >=4.2 and uses dnf)

# So why do we have multiple functions that could be factored into one ? Because each backup program might get different settings at some time, so it's easier to have one function per program

PROGRAM="backup-bench"
AUTHOR="(C) 2022 by Orsiris de Jong"
PROGRAM_BUILD=2022081901

source "./backup-bench.conf"

function self_setup {
	echo "Setting up ofunctions"
	ofunctions_path="/tmp/ofunctions.sh"

	# Download copy of ofunctions.sh so we get Logger and ExecTasks functions
	[ ! -f "${ofunctions_path}" ] && curl -L https://raw.githubusercontent.com/deajan/ofunctions/main/ofunctions.sh -o "${ofunctions_path}"
	source "${ofunctions_path}" || exit 99
	# Don't polluate RUN_DIR since we won't need alerts
	_LOGGER_WRITE_PARTIAL_LOGS=false
}

function clear_users {
	# clean users on target system when using remote repositories
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		userdel -r "${backup_software}"_user
	done
}

function setup_root_access {
	# Quick and dirty ssh root setup on target sysetem when using remote repositories
	ssh-keygen -b 2048 -t rsa -f /root/.ssh/backup-bench.rsa -q -N ""
	cat /root/.ssh/backup-bench.rsa.pub > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
	semanage fcontext -a -t ssh_home_t /root/.ssh/authorized_keys
	restorecon -v /root/.ssh/authorized_keys

	cat /root/.ssh/backup-bench.rsa | ssh ${SOURCE_USER}@${SOURCE_FQDN} -p ${SOURCE_SSH_PORT} -o ControlMaster=auto -o ControlPersist=yes -o ControlPath=/tmp/$PROGRAM.ctrlm.%r@%h.$$ "cat > ${SOURCE_USER_HOMEDIR}/.ssh/backup-bench.key; chmod 600 ${SOURCE_USER_HOMEDIR}/.ssh/backup-bench.key"
	if [ "$?" != 0 ]; then
		echo "Failed to setup root access to target"
		echo  "Please copy file \"/root/.ssh/backup-bench.rsa\" to source system in \"${SOURCE_USER_HOMEDIR}/.ssh/backup-bench.key\" and execute \"chmod 600 ${SOURCE_USER_HOMEDIR}/.ssh/backup-bench.key\""
	fi
}

function setup_target_local_repos {
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		[ -d ${TARGET_ROOT}/"${backup_software}" ] && rm -rf ${TARGET_ROOT:?}/"${backup_software}"
		mkdir -p ${TARGET_ROOT}/"${backup_software}"
	done
}

function setup_target_remote_repos {
	# Quick and dirty ssh repo setup on target system
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		if [ "${HAVE_ZFS}" == true ]; then
			zfs create backup/"${backup_software}"
			zfs set compression=off backup/"${backup_software}"
		else
			mkdir ${TARGET_ROOT} || exit 127
		fi
		useradd -d ${TARGET_ROOT}/"${backup_software}" -m -r -U "${backup_software}"_user
		mkdir ${TARGET_ROOT}/"${backup_software}"/data
		mkdir ${TARGET_ROOT}/"${backup_software}"/.ssh && chmod 700 ${TARGET_ROOT}/"${backup_software}"/.ssh
		ssh-keygen -b 2048 -t rsa -f ${TARGET_ROOT}/"${backup_software}"/.ssh/"${backup_software}".rsa -q -N ""
		cat ${TARGET_ROOT}/"${backup_software}"/.ssh/"${backup_software}".rsa.pub > ${TARGET_ROOT}/"${backup_software}"/.ssh/authorized_keys && chmod 600 ${TARGET_ROOT}/"${backup_software}"/.ssh/authorized_keys
		chown "${backup_software}"_user -R ${TARGET_ROOT}/"${backup_software}"
		semanage fcontext -a -t ssh_home_t ${TARGET_ROOT}/"${backup_software}"/.ssh/authorized_keys
		restorecon -v ${TARGET_ROOT}/"${backup_software}"/.ssh/authorized_keys
	done
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		cat "${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa" | ssh ${SOURCE_USER}@${SOURCE_FQDN} -p ${SOURCE_SSH_PORT} -o ControlMaster=auto -o ControlPersist=yes -o ControlPath=/tmp/$PROGRAM.ctrlm.%r@%h.$$ "cat > ${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key; chmod 600 ${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key"
		if [ "$?" != 0 ]; then
			echo "Failed to copy ssh key to source system"
			echo "Please copy file \"${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa\" to source system in \"${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key\" and execute chmod 600 \"${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key\""
		fi
	done
}

function install_bupstash {
	local version="${1}"

	Logger "Installing bupstash" "NOTICE"
	dnf install -y rust cargo pkgconfig libsodium-devel tar
	mkdir -p /opt/bupstash/bupstash-v"${version}" && cd /opt/bupstash/bupstash-v"${version}" || exit 127
	curl -OL https://github.com/andrewchambers/bupstash/releases/download/v"${version}"/bupstash-v"${version}"-src+deps.tar.gz
	tar xvf bupstash-v"${version}"-src+deps.tar.gz
	cargo build --release
	cp target/release/bupstash /usr/local/bin/

	Logger "Installed bupstash $(get_version_bupstash)" "NOTICE"
}

function get_version_bupstash {
	echo "$(bupstash --version | awk -F'-' '{print $2}')"
}

function setup_ssh_bupstash_server {
	echo "$(echo -n 'command="cd ${TARGET_ROOT}/bupstash; bupstash serve ${TARGET_ROOT}/bupstash/data",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc '; cat ${TARGET_ROOT}/bupstash/.ssh/authorized_keys)" > ${TARGET_ROOT}/bupstash/.ssh/authorized_keys
	[ ! -f "${SOURCE_USER_HOMEDIR}/bupstash.master.key" ] && bupstash new-key -o ${SOURCE_USER_HOMEDIR}/bupstash.master.key
	[ ! -f "${SOURCE_USER_HOMEDIR}/bupstash.store.key" ] && bupstash new-sub-key -k ${SOURCE_USER_HOMEDIR}/bupstash.master.key --put --list -o ${SOURCE_USER_HOMEDIR}/bupstash.store.key
}

function init_bupstash_repository {
	local remotely="${1:-false}"

	Logger "Initializing bupstash repository. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		export BUPSTASH_REPOSITORY_COMMAND=${BUPSTASH_REPOSITORY_COMMAND_REMOTE}
		unset BUPSTASH_REPOSITORY
	else
		export BUPSTASH_REPOSITORY="${BUPSTASH_REPOSITORY_LOCAL}"
		unset BUPSTASH_REPOSITORY_COMMAND
	fi
	bupstash init
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
		exit 125
	fi
}

function clear_bupstash_repository {
		local remotely="${1:-false}"

	Logger "Clearing bupstash repository. Remote: ${remotely}." "NOTICE"
	cmd="rm -rf \"${TARGET_ROOT:?}/bupstash/data\""
	if [ "${remotely}" == true ]; then
		$REMOTE_SSH_RUNNER $cmd
	else
		eval "${cmd}"
	fi
}

function install_borg {

	Logger "Installing borg" "NOTICE"
	dnf install -y libacl-devel openssl-devel gcc-c++
	dnf -y install python39 python39-devel
	python3.9 -m pip install --upgrade pip setuptools wheel
	python3.9 -m pip install borgbackup

	Logger "Installed borg $(get_version_borg)" "NOTICE"
}

function get_version_borg {
	echo "$(borg --version | awk '{print $2}')"
}

function install_borg_beta {
	Logger "Installing borg beta" "NOTICE"
	curl -L https://github.com/borgbackup/borg/releases/download/2.0.0b1/borg-linux64 -o /usr/local/bin/borg_beta && chmod 755 /usr/local/bin/borg_beta
	Logger "Installed borg_beta $(get_version_borg_beta)" "NOTICE"
}

function get_version_borg_beta {
	echo "$(borg_beta --version | awk '{print $2}')"
}

function setup_ssh_borg_server {
	echo "$(echo -n 'command="cd ${TARGET_ROOT}/borg/data; borg serve --restrict-to-path ${TARGET_ROOT}/borg/data",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc '; cat ${TARGET_ROOT}/borg/.ssh/authorized_keys)" > ${TARGET_ROOT}/borg/.ssh/authorized_keys
}

function setup_ssh_borg_beta_server {
	echo "$(echo -n 'command="cd ${TARGET_ROOT}/borg_beta/data; borg_beta serve --restrict-to-path ${TARGET_ROOT}/borg_beta/data",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc '; cat ${TARGET_ROOT}/borg_beta/.ssh/authorized_keys)" > ${TARGET_ROOT}/borg_beta/.ssh/authorized_keys
}

function init_borg_repository {
	local remotely="${1:-false}"

	Logger "Initializing borg repository. Remote: ${remotely}." "NOTICE"
	# -e repokey means AES-CTR-256 and HMAC-SHA256, see https://borgbackup.readthedocs.io/en/stable/usage/init.html)
	if [ "${remotely}" == true ]; then
		export BORG_REPO="$BORG_STABLE_REPO_REMOTE"
		borg init -e repokey --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg.key -p ${REMOTE_TARGET_SSH_PORT} -o StrictHostKeyChecking=accept-new" ${BORG_REPO}
	else
		export BORG_REPO="$BORG_STABLE_REPO_LOCAL"
		borg init -e repokey ${BORG_REPO}
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
		exit 125
	fi
}

function init_borg_beta_repository {
	local remotely="${1:-false}"

	Logger "Initializing borg_beta repository. Remote: ${remotely}." "NOTICE"
	# --encrpytion=repokey-aes-ocb was found using borg_beta benchmark cpu
	if [ "${remotely}" == true ]; then
		export BORG_REPO="$BORG_BETA_REPO_REMOTE"
		borg_beta --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key -p ${REMOTE_TARGET_SSH_PORT} -o StrictHostKeyChecking=accept-new" rcreate --encryption=repokey-aes-ocb
	else
		export BORG_REPO="$BORG_BETA_REPO_LOCAL"
		borg_beta rcreate --encryption=repokey-aes-ocb
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
		exit 125
	fi
}

function clear_borg_repository {
	local remotely="${1:-false}"

	Logger "Clearing borg repository. Remote: ${remotely}." "NOTICE"
	# borg expects the data directory to already exist in order to serve it via borg --serve
	if [ "${remotely}" == true ]; then
		cmd="rm -rf \"${TARGET_ROOT:?}/borg/data\"; mkdir \"${TARGET_ROOT}/borg/data\" && chown borg_user \"${TARGET_ROOT}/borg/data\""
		$REMOTE_SSH_RUNNER $cmd
	else
		cmd="rm -rf \"${TARGET_ROOT:?}/borg/data\"; mkdir \"${TARGET_ROOT}/borg/data\""
		eval "${cmd}"
	fi
}

function clear_borg_beta_repository {
	local remotely="${1:-false}"

	Logger "Clearing borg_beta repository. Remote: ${remotely}." "NOTICE"
	# borg expects the data directory to already exist in order to serve it via borg --serve
	if [ "${remotely}" == true ]; then
		cmd="rm -rf \"${TARGET_ROOT:?}/borg_beta/data\"; mkdir \"${TARGET_ROOT}/borg_beta/data\" && chown borg_beta_user \"${TARGET_ROOT}/borg_beta/data\""
		$REMOTE_SSH_RUNNER $cmd
	else
		cmd="rm -rf \"${TARGET_ROOT:?}/borg_beta/data\"; mkdir \"${TARGET_ROOT}/borg_beta/data\""
		eval "${cmd}"
	fi

}

function install_kopia {
	Logger "Installing kopia" "NOTICE"

	rpm --import https://kopia.io/signing-key
	cat <<EOF | sudo tee /etc/yum.repos.d/kopia.repo
[Kopia]
name=Kopia
baseurl=http://packages.kopia.io/rpm/stable/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://kopia.io/signing-key
EOF

	dnf install -y kopia

	Logger "Installed kopia $(get_version_kopia)" "NOTICE"
}

function get_version_kopia {
	echo "$(kopia --version | awk '{print $1}')"
}

function init_kopia_repository {
	local remotely="${1:-false}"

	Logger "Initializing kopia repository. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		# This should be executed on the source system

		# Set default encryption and hash algorithm based on what kopia benchmark crypto provided
		kopia repository create sftp --path=${TARGET_ROOT}/kopia/data --host=${REMOTE_TARGET_FQDN} --port ${REMOTE_TARGET_SSH_PORT} --keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key --username=kopia_user --known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts --block-hash=BLAKE3-256 --encryption=AES256-GCM-HMAC-SHA256
	else
		kopia repository create filesystem --path=${TARGET_ROOT}/kopia/data
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
		exit 125
	fi
	# Set default zstd compression for *ALL* repositories. Can be overrided.
	kopia policy set --global --compression zstd
	kopia policy set --global --add-ignore '.git' --add-ignore '.duplicacy'
}

function clear_kopia_repository {
	local remotely="${1:-false}"

	Logger "Clearing kopia repository. Remote: ${remotely}." "NOTICE"
	cmd="rm -rf \"${TARGET_ROOT:?}/kopia/data\""
	if [ "${remotely}" == true ]; then
		$REMOTE_SSH_RUNNER $cmd
	else
		eval "${cmd}"
	fi
}

function install_restic {
	Logger "Installing restic" "NOTICE"
	dnf install -y epel-release
	dnf install -y restic
	Logger "Installed restic $(get_version_restic)" "NOTICE"
}

function get_version_restic {
	echo "$(restic version | awk '{print $2}')"
}

function install_restic_rest_server {
	Logger "Installing restic rest-server" "NOTICE"
	curl -o /tmp/rest-server.tar.gz -L https://github.com/restic/rest-server/releases/download/v0.11.0/rest-server_0.11.0_linux_amd64.tar.gz
	tar xvf /tmp/rest-server.tar.gz --wildcards --no-anchored --transform='s/.*\///' -C /usr/local/bin 'rest-server'
	chmod +x /usr/local/bin/rest-server
}

function install_restic_beta {
	Logger "Installing restic beta" "NOTICE"
	curl -o /usr/local/bin/restic_beta -L https://beta.restic.net/latest_restic_linux_amd64 && chmod +x /usr/local/bin/restic_beta
	Logger "Installed restic_beta $(get_version_restic_beta)" "NOTICE"
}

function get_version_restic_beta {
	echo "$(restic_beta version | awk '{print $2}')"
}

function init_restic_repository {
	local remotely="${1:-false}"


	Logger "Initializing restic repository. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		# This should be executed on the source system
		if [ "${RESTIC_USE_HTTP}" == true ]; then
			restic -r rest:http://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/ init
		else
			restic -r sftp::${TARGET_ROOT}/restic/data -o sftp.command="ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" init
		fi
	else
		restic -r ${TARGET_ROOT}/restic/data init
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
		exit 125
	fi
}

function clear_restic_repository {
	local remotely="${1:-false}"

	Logger "Clearing restic repository. Remote: ${remotely}." "NOTICE"
	cmd="rm -rf \"${TARGET_ROOT:?}/restic/data\""
	if [ "${remotely}" == true ]; then
		$REMOTE_SSH_RUNNER $cmd
	else
		eval "${cmd}"
	fi
}

function init_restic_beta_repository {
	local remotely="${1:-false}"

	Logger "Initializing restic_beta repository. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		# This should be executed on the source system
		if [ "${RESTIC_BETA_USE_HTTP}" == true ]; then
			restic_beta -r rest:http://${REMOTE_TARGET_FQDN}:${RESTIC_BETA_HTTP_PORT}/ init --repository-version 2
		else
			restic_beta -r sftp::${TARGET_ROOT}/restic_beta/data -o sftp.command="ssh restic_beta_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic_beta.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" init --repository-version 2
		fi
	else
		restic_beta -r ${TARGET_ROOT}/restic_beta/data init --repository-version 2
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
		exit 125
	fi
}

function clear_restic_beta_repository {
	local remotely="${1:-false}"

	Logger "Clearing restic_beta repository. Remote: ${remotely}." "NOTICE"
	cmd="rm -rf \"${TARGET_ROOT:?}/restic_beta/data\""
	if [ "${remotely}" == true ]; then
		$REMOTE_SSH_RUNNER $cmd
	else
		eval "${cmd}"
	fi
}

function install_duplicacy {
	local version="${1}"

	Logger "Installing duplicacy" "NOTICE"
	curl -L -o /usr/local/bin/duplicacy https://github.com/gilbertchen/duplicacy/releases/download/v"${version}"/duplicacy_linux_x64_"${version}"
	chmod +x /usr/local/bin/duplicacy
	Logger "Installed duplicacy (${version})" "NOTICE"
}

function get_version_duplicacy {
	echo "${DUPLICACY_VERSION}"
}

function init_duplicacy_repository {
	local remotely="${1}"

	Logger "Initializing duplicacy repository. Remote: ${remotely}." "NOTICE"
	cd "${BACKUP_ROOT}" || exit 125

	# Remove earlier repo setup
	rm -rf "${BACKUP_ROOT:?}/.duplicacy"

	if [ "${remotely}" == true ]; then
		# This should be executed on the source system
		duplicacy init -e remoteid sftp://duplicacy_user@${REMOTE_TARGET_FQDN}:${REMOTE_TARGET_SSH_PORT}/${TARGET_ROOT}/duplicacy/data
	else
		duplicacy init -e localid ${TARGET_ROOT}/duplicacy/data
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
		exit 125
	fi

	# Exclusions are set in [source_dir]/.duplicacy/filters file
	echo "e:\.git/.*$" > "${BACKUP_ROOT}/.duplicacy/filters"
}

function clear_duplicacy_repository {
	local remotely="${1:-false}"

	Logger "Clearing duplicacy repository. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		cmd="rm -rf \"${TARGET_ROOT:?}/duplicacy/data\" && mkdir \"${TARGET_ROOT}/duplicacy/data\" && chown duplicacy_user \"${TARGET_ROOT}/duplicacy/data\""
		$REMOTE_SSH_RUNNER $cmd
	else
		cmd="rm -rf \"${TARGET_ROOT:?}/duplicacy/data\" && mkdir \"${TARGET_ROOT}/duplicacy/data\""
		eval "${cmd}"
	fi
	# We also need to delete .duplicacy folder in source
	rm -rf "${BACKUP_ROOT}/.duplicacy"
}

function setup_git_dataset {
	dnf install -y git
	# We'll assume that BACKUP_ROOT will be a git root, so we need to git clone in parent directory
	git_parent_dir="$(dirname ${BACKUP_ROOT:?})"
	[ ! -d "${git_parent_dir}" ] && mkdir "${git_parent_dir}"
	cd "${git_parent_dir}" || exit 127

	[ -d "${GIT_ROOT_DIRECTORY}" ] && rm -rf "${GIT_ROOT_DIRECTORY}"
	git clone ${GIT_DATASET_REPOSITORY}
}

function backup_bupstash {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing bupstash backup. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		export BUPSTASH_REPOSITORY_COMMAND=${BUPSTASH_REPOSITORY_COMMAND_REMOTE}
		unset BUPSTASH_REPOSITORY
	else
		export BUPSTASH_REPOSITORY=${BUPSTASH_REPOSITORY_LOCAL}
		unset BUPSTASH_REPOSITORY_COMMAND
	fi
	bupstash put --compression zstd:3 --exclude '.git' --exclude '.duplicacy' --print-file-actions --print-stats BACKUPID="${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.bupstash_test.log 2>&1
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function restore_bupstash {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing bupstash restore. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		export BUPSTASH_REPOSITORY_COMMAND=${BUPSTASH_REPOSITORY_COMMAND_REMOTE}
		unset BUPSTASH_REPOSITORY
	else
		export BUPSTASH_REPOSITORY=${BUPSTASH_REPOSITORY_LOCAL}
		unset BUPSTASH_REPOSITORY_COMMAND
	fi

	# Change store key by master key in order to be able to restore data
	export BUPSTASH_KEY="${SOURCE_USER_HOMEDIR}/bupstash.master.key"
	bupstash restore --into "${RESTORE_DIR}" BACKUPID="${backup_id}"
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
	export BUPSTASH_KEY="${SOURCE_USER_HOMEDIR}/bupstash.store.key"
}

function backup_borg {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing borg backup. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		export BORG_REPO="$BORG_STABLE_REPO_REMOTE"
		borg create --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg.key -p ${REMOTE_TARGET_SSH_PORT}" --compression zstd,3 --exclude 're:\.git/.*$' --exclude 're:\.duplicacy/.*$' --stats --verbose ${BORG_REPO}::"${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.borg_tests.log 2>&1
	else
		export BORG_REPO="$BORG_STABLE_REPO_LOCAL"
		borg create --compression zstd,3 --exclude 're:\.git/.*$' --exclude 're:\.duplicacy/.*$' --stats --verbose ${BORG_REPO}::"${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.borg_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
	# We can check the exclusion patterns with borg create --list --dry-run --exclude ...
}

function restore_borg {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing borg restore. Remote: ${remotely}." "NOTICE"
	cd "${RESTORE_DIR}" || return 127
	# We'll use --noacls and --noxattrs to make sure we have same functionnality as others
	if [ "${remotely}" == true ]; then
		export BORG_REPO="$BORG_STABLE_REPO_REMOTE"
		borg extract --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg.key -p ${REMOTE_TARGET_SSH_PORT}" --noacls --noxattrs ${BORG_REPO}::"${backup_id}" >> /var/log/${PROGRAM}.borg_tests.log 2>&1
	else
		export BORG_REPO="$BORG_STABLE_REPO_LOCAL"
		borg extract --noacls --noxattrs ${BORG_REPO}::"${backup_id}" >> /var/log/${PROGRAM}.borg_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function backup_borg_beta {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing borg_beta backup. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		export BORG_REPO="$BORG_BETA_REPO_REMOTE"
		borg_beta create --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key -p ${REMOTE_TARGET_SSH_PORT}" --compression zstd,3 --exclude 're:\.git/.*$' --exclude 're:\.duplicacy/.*$' --stats --verbose "${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.borg_beta_tests.log 2>&1
	else
		export BORG_REPO="$BORG_BETA_REPO_LOCAL"
		borg_beta create  --compression zstd,3 --exclude 're:\.git/.*$' --exclude 're:\.duplicacy/.*$' --stats --verbose "${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.borg_beta_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
	# We can check the exclusion patterns with borg create --list --dry-run --exclude ...
}

function restore_borg_beta {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing borg_beta restore. Remote: ${remotely}." "NOTICE"
	cd "${RESTORE_DIR}" || return 127
	# We'll use --noacls and --noxattrs to make sure we have same functionnality as others
	if [ "${remotely}" == true ]; then
		export BORG_REPO="$BORG_BETA_REPO_REMOTE"
		borg_beta extract --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key -p ${REMOTE_TARGET_SSH_PORT}" --noacls --noxattrs "${backup_id}" >> /var/log/${PROGRAM}.borg_beta_tests.log 2>&1
	else
		export BORG_REPO="$BORG_BETA_REPO_LOCAL"
		borg_beta extract --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key -p ${REMOTE_TARGET_SSH_PORT}" --noacls --noxattrs "${backup_id}" >> /var/log/${PROGRAM}.borg_beta_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function backup_kopia {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing kopia backup. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		kopia repository connect sftp --path=${TARGET_ROOT}/kopia/data --host=${REMOTE_TARGET_FQDN} --port ${REMOTE_TARGET_SSH_PORT} --keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key --username=kopia_user --known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts
	else
		kopia repository connect filesystem --path=${TARGET_ROOT}/kopia/data
	fi
	kopia snapshot create --tags BACKUPID:"${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.kopia_test.log 2>&1
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
	# We can check the exclusion patterns with kopia snapshot estimate

}

function restore_kopia {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing kopia restore. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		kopia repository connect sftp --path=${TARGET_ROOT}/kopia/data --host=${REMOTE_TARGET_FQDN} --port ${REMOTE_TARGET_SSH_PORT} --keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key --username=kopia_user --known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts
	else
		kopia repository connect filesystem --path=${TARGET_ROOT}/kopia/data
	fi
	id="$(kopia snapshot list --tags BACKUPID:${backup_id} | awk '{print $4}')"
	kopia restore --skip-owners --skip-permissions ${id} "${RESTORE_DIR}"  >> /var/log/${PROGRAM}.kopia_test.log 2>&1
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function backup_restic {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing restic backup. Remote: ${remotely}." "NOTICE"

	# I know that RESTIC_REPOSITORY exists, but there was no way I could get that to work with sftp port different to 22, so I had to specificy repository manually
	if [ "${remotely}" == true ]; then
		if [ "${RESTIC_USE_HTTP}" == true ]; then
			restic -r rest:http://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/ --verbose --exclude=".git" --exclude=".duplicacy" --tag="${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
		else
			restic -r sftp::${TARGET_ROOT}/restic/data -o sftp.command="ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" backup --verbose --exclude=".git" --exclude=".duplicacy" --tag="${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
		fi
	else
		restic -r ${TARGET_ROOT}/restic/data backup --verbose --exclude=".git" --exclude=".duplicacy" --tag="${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
	# We can check the exclusion patterns with restic backup --dry-run --verbose
}

function restore_restic {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing restic restore. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		if [ "${RESTIC_USE_HTTP}" == true ]; then
			id=$(restic -r rest:http://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/ snapshots | grep "${backup_id}" | awk '{print $1}')
			restic -r rest:http://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/ restore "$id" --target "${RESTORE_DIR}" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
		else
			id=$(restic -r sftp::${TARGET_ROOT}/restic/data -o sftp.command="ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" snapshots | grep "${backup_id}" | awk '{print $1}')
			restic -r sftp::${TARGET_ROOT}/restic/data -o sftp.command="ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" restore "$id" --target "${RESTORE_DIR}" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
		fi
	else
		id=$(restic -r ${TARGET_ROOT}/restic/data snapshots | grep "${backup_id}" | awk '{print $1}')
		restic -r ${TARGET_ROOT}/restic/data restore "$id" --target "${RESTORE_DIR}" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function backup_restic_beta {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing restic_beta backup. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		if [ "${RESTIC_BETA_USE_HTTP}" == true ]; then
			restic_beta -r rest:http://${REMOTE_TARGET_FQDN}:${RESTIC_BETA_HTTP_PORT}/ --verbose --exclude=".git" --exclude=".duplicacy" --tag="${backup_id}" --compression=auto "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.restic_beta_tests.log 2>&1
		else
			restic_beta -r sftp::${TARGET_ROOT}/restic_beta/data -o sftp.command="ssh restic_beta_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic_beta.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" backup --verbose --exclude=".git" --exclude=".duplicacy" --tag="${backup_id}" --compression=auto "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.restic_beta_tests.log 2>&1
		fi
	else
		restic_beta -r ${TARGET_ROOT}/restic_beta/data backup --verbose --exclude=".git" --exclude=".duplicacy" --tag="${backup_id}" --compression=auto "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.restic_beta_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function restore_restic_beta {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing restic_beta restore. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		if [ "${RESTIC_BETA_USE_HTTP}" == true ]; then
			id=$(restic_beta -r rest:http://${REMOTE_TARGET_FQDN}:${RESTIC_BETA_HTTP_PORT}/ snapshots | grep "${backup_id}" | awk '{print $1}')
			restic_beta -r rest:http://${REMOTE_TARGET_FQDN}:${RESTIC_BETA_HTTP_PORT}/ restore "$id" --target "${RESTORE_DIR}" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
		else
			id=$(restic_beta -r sftp::${TARGET_ROOT}/restic_beta/data -o sftp.command="ssh restic_beta_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic_beta.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" snapshots | grep "${backup_id}" | awk '{print $1}')
			restic_beta -r sftp::${TARGET_ROOT}/restic_beta/data -o sftp.command="ssh restic_beta_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic_beta.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" restore "$id" --target "${RESTORE_DIR}" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
		fi
	else
		id=$(restic_beta -r ${TARGET_ROOT}/restic_beta/data snapshots | grep "${backup_id}" | awk '{print $1}')
		restic_beta -r ${TARGET_ROOT}/restic_beta/data restore "$id" --target "${RESTORE_DIR}" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}


function backup_duplicacy {
	local remotely="${1}"
	local backup_id="${2}"

	cd "${BACKUP_ROOT}" || exit 124

	Logger "Initializing duplicacy backup. Remote: ${remotely}." "NOTICE"

	duplicacy backup -t "${backup_id}" --stats >> /var/log/${PROGRAM}.duplicacy_tests.log 2>&1
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function restore_duplicacy {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Initializing duplicacy restore. Remote: ${remotely}." "NOTICE"

	# duplicacy needs to init the repo (named someid here) to another directory so it can be restored
	if [ "${remotely}" == true ]; then
		cd "${RESTORE_DIR}" && duplicacy init -e remoteid sftp://duplicacy_user@${REMOTE_TARGET_FQDN}:${REMOTE_TARGET_SSH_PORT}/${TARGET_ROOT}/duplicacy/data
	else
		cd "${RESTORE_DIR}" && duplicacy init -e localid ${TARGET_ROOT}/duplicacy/data
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi

	revision=$(duplicacy list | grep "${backup_id}" | awk '{print $4}')
	Logger "Using revision [${revision}]" "NOTICE"

	duplicacy restore -r ${revision} >> /var/log/${PROGRAM}.duplicacy_tests.log 2>&1
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}


function get_repo_sizes {
	local remotely="${1:-false}"

	CSV_SIZE="size(kb),"

	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		if [ "${remotely}" == true ]; then
			size=$($REMOTE_SSH_RUNNER du -cs "${TARGET_ROOT}/${backup_software}" | tail -n 1 | awk '{print $1}')
		else
			size=$(du -cs "${TARGET_ROOT}/${backup_software}" | tail -n 1 | awk '{print $1}')
		fi
		CSV_SIZE="${CSV_SIZE}${size},"
		Logger "Repo size for ${backup_software}: ${size} kb. Remote: ${remotely}." "NOTICE"
	done
	echo "${CSV_SIZE}" >> "${CSV_RESULT_FILE}"
}

function setup_source {
	local remotely="${1:-false}"

	Logger "Setting up source server" "NOTICE"
	install_bupstash ${BUPSTASH_VERSION}
	install_borg
	install_borg_beta
	install_kopia
	install_restic
	install_restic_beta
	install_duplicacy ${DUPLICACY_VERSION}

	Logger "Setting up local target" "NOTICE"
	[ "${remotely}" == false ] && setup_target_local_repos
}

function setup_remote_target {
	local remotely="${1:-false}" # Has no use here obviously, but we'll keep it since remotely argument is passed

	Logger "Setting up remote target server" "NOTICE"

	setup_root_access

	install_bupstash ${BUPSTASH_VERSION}
	install_borg
	install_borg_beta
	install_restic_rest_server
	clear_users
	setup_target_remote_repos

	setup_ssh_bupstash_server

	setup_ssh_borg_server
}

function clear_repositories {
	local remotely="${1:-false}"

	Logger "Clearing all repositories from earlier data. Remote clean: $remotely". "NOTICE"
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		clear_"${backup_software}"_repository "${remotely}"
	done
	Logger "Clearing done" "NOTICE"
}

function init_repositories {
	local remotely="${1:-false}"
	local git="${2:-false}"

	[ "${git}" == true ] && setup_git_dataset

	Logger "Initializing reposiories. Remote: ${remotely}." "NOTICE"
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		init_"${backup_software}"_repository "${remotely}"
	done
	Logger "Initialization done." "NOTICE"
}

function serve_http_targets {
	kopia server start --address 0.0.0.0:${KOPIA_HTTP_PORT} --no-ui --insecure --without-password &
	pid=$?
	Logger "Serving kopia on http port ${KOPIA_HTTP_PORT} using pid $pid. Kill server with 'kill -9 $pid'" "NOTICE"
	./rest-server --no-auth --listen ${RESTIC_HTTP_PORT} --path ${TARGET_ROOT}/restic/data &
	pid=$?
	Logger "Serving rest-serve for restic on http port ${RESTIC_HTTP_PORT} using pid $pid. Kill server with 'kill -9 $pid'" "NOTICE"
	./rest-server --no-auth --listen ${RESTIC_BETA_HTTP_PORT} --path ${TARGET_ROOT}/restic_beta/data &
	pid=$?
	Logger "Serving rest-serve for restic_beta on http port ${RESTIC_BETA_HTTP_PORT} using pid $pid. Kill server with 'kill -9 $pid'" "NOTICE"
}

function benchmark_backup_standard {
	local remotely="${1}"
	local backup_id="${2:-defaultid}"

	CSV_BACKUP_EXEC_TIME="backup(s),"

	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		CSV_HEADER="${CSV_HEADER}${backup_software},"
		echo 3 > /proc/sys/vm/drop_caches       # Make sure we drop caches (including zfs arc cache before every backup)
		[ "${remotely}" == true ] && $REMOTE_SSH_RUNNER "echo 3 > /proc/sys/vm/drop_caches"
		Logger "Starting backup bench of ${backup_software} for git dataset ${backup_id}" "NOTICE"
		seconds_begin=$SECONDS
		# Launch backup software from function "name"_backup as background so we keep control
		backup_"${backup_software}" "${remotely}" "${backup_id}" &
		ExecTasks "$!" "${backup_software}_bench" false 3600 18000 3600 18000
		exec_time=$((SECONDS - seconds_begin))
		CSV_BACKUP_EXEC_TIME="${CSV_BACKUP_EXEC_TIME}${exec_time},"
		Logger "It took ${exec_time} seconds to backup." "NOTICE"
	done

	echo "$CSV_BACKUP_EXEC_TIME" >> "${CSV_RESULT_FILE}"
	get_repo_sizes "${remotely}"
}

function benchmark_backup_git {
	local remotely="${1}"

	Logger "Running git dataset backup benchmarks. Remote: ${remotely}" "NOTICE"

	cd "${BACKUP_ROOT}" || exit 127

	# Backup that kernel
	for tag in "${GIT_TAGS[@]}"; do

		# Thanks to duplicacy who tampers with backup root conntent by adding '.duplicacy'... we need to save .duplicacy directory before every git checkout in order not to loose the files
		#alias cp=cp && cp -R "${BACKUP_ROOT}/.duplicacy" "/tmp/backup_bench.duplicacy"
		# Make sure we always we checkout a specific kernel version so results are reproductible
		git checkout "${tag}"
		#alias cp=cp && cp -R "/tmp/backup_bench.duplicacy" "${BACKUP_ROOT}/.duplicacy"
		benchmark_backup_standard "${remotely}" "bkp-${tag}"
	done
}

function benchmark_backup {
	local remotely="${1}"
	local git="${2:-false}"

	echo "# $PROGRAM $PROGRAM_BUILD $(date) Remote: ${remotely}, Git: ${git}" >> "${CSV_RESULT_FILE}"
	CSV_HEADER=","

	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		CSV_HEADER="${CSV_HEADER}${backup_software} $(get_version_${backup_software}),"
	done
	echo "${CSV_HEADER}" >> "${CSV_RESULT_FILE}"

	if [ "${git}" == true ]; then
		benchmark_backup_git "${remotely}"
	else
		benchmark_backup_standard "${remotely}"
	fi
}

function benchmark_restore_standard {
	local remotely="${1}"
	local backup_id="${2:-defaultid}"

	CSV_RESTORE_EXEC_TIME="restoration(s),"

	# Restore last snapshot and compare with actual kernel
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		echo 3 > /proc/sys/vm/drop_caches       # Make sure we drop caches (including zfs arc cache before every backup)
		[ "${remotely}" == true ] && $REMOTE_SSH_RUNNER "echo 3 > /proc/sys/vm/drop_caches"

		[ -d "${RESTORE_DIR}" ] && rm -rf "${RESTORE_DIR:?}"
		mkdir "${RESTORE_DIR}"

		Logger "Starting restore bench of ${backup_software} tag ${backup_id}" "NOTICE"
		seconds_begin=$SECONDS
		# Launch backup software from function "name"_restore as background so we keep control
		restore_"${backup_software}" "${remotely}" "${backup_id}" &
		ExecTasks "$!" "${backup_software}_restore" false 3600 18000 3600 18000
		exec_time=$((SECONDS - seconds_begin))
		CSV_RESTORE_EXEC_TIME="${CSV_RESTORE_EXEC_TIME}${exec_time},"
		Logger "It took ${exec_time} seconds to restore." "NOTICE"

		# Make sure restored version matches current version
		Logger "Compare restored version to original directory" "NOTICE"
		# borg and restic restore full paths, so we need to change restored path
		if [ "${backup_software}" == "borg" ] || [ "${backup_software}" == "borg_beta" ] || [ "${backup_software}" == "restic" ] || [ "${backup_software}" == "restic_beta" ]; then
			restored_path="${RESTORE_DIR}"/"${BACKUP_ROOT}/"
		else
			restored_path="${RESTORE_DIR}"
		fi
		diff -x .git -x .duplicacy -qr "${restored_path}" "${BACKUP_ROOT}/"
		result=$?
		if [ "${result}" -ne 0 ]; then
			Logger "Failure with exit code $result for restore comparaison" "CRITICAL"
		fi
	done
	echo "$CSV_RESTORE_EXEC_TIME" >> "${CSV_RESULT_FILE}"

}

function benchmark_restore_git {
	local remotely="${1}"

	Logger "Running git dataset restore Benchmarks. Remote: ${remotely}" "NOTICE"

	cd "${BACKUP_ROOT}/" || exit 127
	git checkout "${GIT_TAGS[-1]}"
	benchmark_restore_standard "${remotely}" "bkp-${GIT_TAGS[-1]}"
}

function benchmark_restore {
	local remotely="${1}"
	local git="${2:-false}"

	if [ "${git}" == true ]; then
		benchmark_restore_git "${remotely}"
	else
		benchmark_restore_standard "${remotely}"
	fi
}

function benchmarks {
	local remotely="${1}"
	local git="${2:-false}"

	benchmark_backup "${remotely}" "${git}"
	benchmark_restore "${remotely}" "${git}"
}

function usage {
	echo "$PROGRAM $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo ""
	echo "Please open the file and adjust variables until #### END OF CONF #### line is reached"
	echo "Once you've setup this script, you may use it to initialize target, than source."
	echo "After initialization, benchmarks may run"
	echo ""
	echo "--setup-target-remote	     	Install backup programs and setup SSH access (executed on target)"
	echo "--setup-source            	Install backup programs and setup local (or remote with --remote) repositories (executed on source)"
	echo "--init-repos	        	Reinitialize local (or remote with --remote) repositories after clearing. Must be used with --git if multiple version benchmarks is used) (executed on source)"
	echo "--benchmark-backup		Run backup benchmarks using local (or remote with --remote) repositories"
	echo "--benchmark-restore		Run restore benchmarks using local (or remote with --remote) repositories, restores to local restore path"
	echo "--benchmarks	        	Run both backup and restore benchmark using local (or remote with --remote) repositories and local restore path"
	echo "--all				Clear, init and run bakcup with git dataset for both local and remote targets"
	echo ""
	echo "MODIFIERS"
	echo "--git				Use git dataset (multiple version benchmark)"
	echo "--local				Execute locally (works for --clear-repos, --init-repos, --benchmark*)"
	echo "--remote				Execute remotely (works for --clear-repos, --init-repos, --benchmark*)"
	echo ""
	echo "After some benchmarks, you might want to remove earlier data from repositories."
	echo "--clear-repos	       		Removes data from local (or remote with --remote) repositories"
	echo ""
	echo "DEBUG commands"
	echo "--setup-root-access       Manually setup root access (executed on target)"
	exit 128
}

## SCRIPT ENTRY POINT

self_setup

if [ "$#" -eq 0 ]
then
	usage
fi

cmd=""
REMOTELY=false
USE_GIT_VERSIONS=false
ALL=false

for i in "${@}"; do
	case "$i" in
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
		--all)
		ALL=true
		;;
		*)
		usage
		;;
	esac
done
if [ "${ALL}" == true ]; then
	# prepare repos and run all tests locally and remotely
	clear_repositories
	init_repositories false true
	benchmarks false true
	clear_repositories true
	init_repositories true rtue
	benchmarks true true
else
	full_cmd="$cmd $REMOTELY $USE_GIT_VERSIONS"
	Logger "Running: ${full_cmd}" "DEBUG"
	eval "$full_cmd"
fi

CleanUp