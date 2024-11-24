#!/usr/bin/env bash

# This script is a (very) simple backup benchmark for the following backup programs:
# bupstash
# borg
# kopia
# restic
# rustic
# duplicacy

# It (should) allow to produce reproductible results, and give an idea of what program is the fastest and creates the smallest backups
# Results can be found in /var/log as pseudo-CSV file
# Should be executed together with a monitoring system that matches cpu/ram/io usage against the running backup solution (disclaimer: I use netdata)

# Script tested on RHEL 8 & RHEL 9 (would probably work on DEB based distros too)
# requires bash >=4.2, and yum or apt

# So why do we have multiple functions that could be factored into one ? Because each backup program might get different settings at some time, so it's easier to have one function per program

PROGRAM="backup-bench"
AUTHOR="(C) 2022-2024 by Orsiris de Jong"
PROGRAM_BUILD=2024112301

function self_setup {
	echo "Setting up ofunctions"
	ofunctions_path="/tmp/ofunctions.sh"

	# Download copy of ofunctions.sh so we get Logger and ExecTasks functions
	[ ! -f "${ofunctions_path}" ] && curl -L https://raw.githubusercontent.com/deajan/ofunctions/main/ofunctions.sh -o "${ofunctions_path}"
	source "${ofunctions_path}" || exit 99
	# Don't polluate RUN_DIR since we won't need alerts
	_LOGGER_WRITE_PARTIAL_LOGS=false
}

function download_prerequisites {
	local nodeps="${1:-false}"

	local result=true  # did we succeed in installing our stuff

	if command dnf > /dev/null 2>&1; then
		Logger "Installing packages tar, bzip2, git using dnf" "NOTICE"
		dnf install -y tar bzip2 git || result=false

		# bupstash specific since we need to build it from source
		dnf install -y rust cargo pkgconfig libsodium-devel || result=false

	elif command apt > /dev/null 2>&1; then
		Logger "Installing packages tar, bzip2, git  using apt" "NOTICE"
		apt install -y tar bzip2 git || result=false

		# bupstash specific since we need to build it from source
		apt install -y rustc cargo pkgconf libsodium-dev || result=false
	else
		result=false
	fi

	# Detect selinux and install semanage
	if type -p getenforce > /dev/null 2>&1; then
		# Is Selinux enabled
		if [ "$(getenforce)" == "Enforcing" ]; then
			Logger "Installing SELinux package policycoreutils-python-utils using dnf" "NOTICE"
			dnf install -y policycoreutils-python-utils || result=false
		else
			Logger "Skipping SELinux setup since it's disabled or permissive" "NOTICE"
		fi
	fi

	if [ "${result}" == false ]; then
		if [ "${nodeps}" == false ]; then
			Logger "Could not install required packages. We need the following: tar, bzip2, . You can bypass required packages install by specifying --no-deps" "NOTICE"
		else
			Logger "Required packages install bypassed" "NOTICE"
		fi
	else
		Logger "Successfully installed required packages." "NOTICE"
	fi
}

function get_lastest_git_release {
	local org="${1}"
	local repo="${2}"

	LASTEST_VERSION=$(curl -s https://api.github.com/repos/${org}/${repo}/releases/latest | grep "tag_name" | cut -d'"' -f4)
	echo ${LASTEST_VERSION}
}

function get_remote_certificate_fingerprint {
	# Used for kopia server certificate authentication
	local fqdn="${1}"
	local port="${2}"

	echo $(openssl s_client -connect ${fqdn}:${port} < /dev/null 2>/dev/null | openssl x509 -fingerprint -sha256 -noout -in /dev/stdin | cut -d'=' -f2 | tr -d ':')
}

function get_certificate_fingerprint {
	local file="${1}"

	echo $(openssl x509 -fingerprint -sha256 -noout -in "${file}" | cut -d'=' -f2 | tr -d ':')
}

function create_certificate {
	# Create a RSA certificate for kopia
	local name="${1}"

	openssl req -nodes -new -x509 -days 7300 -newkey rsa:2048 -keyout "${HOME}/${name}.key" -subj "/C=FR/O=SOMEORG/CN=FQDN/OU=RD/L=City/ST=State/emailAddress=contact@example.tld" -out "${HOME}/${name}.crt"
}

function clear_users {
	# clean users on target system when using remote repositories
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		userdel -r "${backup_software}"_user
	done
}

function setup_root_access {
	# Quick and dirty ssh root setup on target sysetem when using remote repositories
	# This allows the source machine to access target
	ssh-keygen -b 2048 -t rsa -f /root/.ssh/backup-bench.rsa -q -N ""
	cat /root/.ssh/backup-bench.rsa.pub > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
	type -p semanage > /dev/null 2>&1 && semanage fcontext -a -t ssh_home_t /root/.ssh/authorized_keys
	type -p restorecon > /dev/null 2>&1 && restorecon -v /root/.ssh/authorized_keys

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
			zfs set xattr=off backup/"${backup_software}"
			zfs set atime=off backup/"${backup_software}"
			# The following setting is targeted at qcow file backups
			# bupstash tends to create smaller files than others
			# We might want to set recordsize=128k for linux kernel benchmarks
			zfs set recordsize=1M backup/"${backup_software}"
		else
			mkdir -p ${TARGET_ROOT} || exit 127
		fi
		useradd -d ${TARGET_ROOT}/"${backup_software}" -m -r -U "${backup_software}"_user
		mkdir -p ${TARGET_ROOT}/"${backup_software}"/data
		mkdir -p ${TARGET_ROOT}/"${backup_software}"/.ssh && chmod 700 ${TARGET_ROOT}/"${backup_software}"/.ssh
		ssh-keygen -b 2048 -t rsa -f ${TARGET_ROOT}/"${backup_software}"/.ssh/"${backup_software}".rsa -q -N ""
		cat ${TARGET_ROOT}/"${backup_software}"/.ssh/"${backup_software}".rsa.pub > ${TARGET_ROOT}/"${backup_software}"/.ssh/authorized_keys && chmod 600 ${TARGET_ROOT}/"${backup_software}"/.ssh/authorized_keys
		chown "${backup_software}"_user -R ${TARGET_ROOT}/"${backup_software}"
		type -p semanage > /dev/null 2>&1 && semanage fcontext -a -t ssh_home_t ${TARGET_ROOT}/"${backup_software}"/.ssh/authorized_keys
		type -p restorecon > /dev/null 2>&1 && restorecon -v ${TARGET_ROOT}/"${backup_software}"/.ssh/authorized_keys
	done
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		Logger "Copying RSA key for ${backup_software} to source into [${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key]" "NOTICE"
		cat "${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa" | ssh ${SOURCE_USER}@${SOURCE_FQDN} -p ${SOURCE_SSH_PORT} -o ControlMaster=auto -o ControlPersist=yes -o ControlPath=/tmp/$PROGRAM.ctrlm.%r@%h.$$ "cat > ${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key; chmod 600 ${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key"
		if [ "$?" != 0 ]; then
			echo "Failed to copy ssh key to source system"
			echo "Please copy file \"${TARGET_ROOT}/${backup_software}/.ssh/${backup_software}.rsa\" to source system in \"${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key\" and execute chmod 600 \"${SOURCE_USER_HOMEDIR}/.ssh/${backup_software}.key\""
		else
			rm -f /tmp/$PROGRAM.ctrlm.%r@%h.$$
		fi
	done
}

function install_bupstash {
	ORG=andrewchambers
	REPO=bupstash
	lastest_version=$(get_lastest_git_release $ORG $REPO)

	Logger "Installing bupstash ${lastest_version}" "NOTICE"
	#dnf install -y rust cargo pkgconfig libsodium-devel tar  # now installed in specific function
	mkdir -p /opt/bupstash/bupstash-"${lastest_version}" && cd /opt/bupstash/bupstash-"${lastest_version}" || exit 127
	curl -OL https://github.com/$ORG/$REPO/releases/download/"${lastest_version}"/bupstash-"${lastest_version}"-src+deps.tar.gz
	tar xvf bupstash-"${lastest_version}"-src+deps.tar.gz
	cargo build --release
	cp target/release/bupstash /usr/local/bin/

	Logger "Installed bupstash $(get_version_bupstash)" "NOTICE"
}

function get_version_bupstash {
	echo "$(bupstash --version | awk -F'-' '{print $2}')"
}

function setup_ssh_bupstash_server {
	echo "$(echo -n "command=\"cd ${TARGET_ROOT}/bupstash; bupstash serve ${TARGET_ROOT}/bupstash/data\",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc "; cat ${TARGET_ROOT}/bupstash/.ssh/authorized_keys)" > ${TARGET_ROOT}/bupstash/.ssh/authorized_keys
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

	# bupstash expects the directory to not already exist in order to server it bia bupstash / or even just to make an init since v0.12
	Logger "Clearing bupstash repository. Remote: ${remotely}." "NOTICE"
	cmd="rm -rf \"${TARGET_ROOT:?}/bupstash\"; mkdir ${TARGET_ROOT:?}/bupstash; if getent passwd | grep bupstash_user > /dev/null; then chown bupstash_user \"${TARGET_ROOT}/bupstash\"; fi"
	if [ "${remotely}" == true ]; then
		$REMOTE_SSH_RUNNER $cmd
	else
		eval "${cmd}"
	fi
}

function install_borg {
	ORG=borgbackup
	REPO=borg
	lastest_version=$(get_lastest_git_release $ORG $REPO)

	Logger "Installing borg ${lastest_version}" "NOTICE"

	# Earlier borg backup install commands
	#dnf install -y libacl-devel openssl-devel gcc-c++
	#dnf -y install python39 python39-devel
	#python3.9 -m pip install --upgrade pip setuptools wheel
	#python3.9 -m pip install borgbackup

	# borg-linuxnew64 uses GLIBC 2.39 as of 20220905 whereas RHEL9 uses GLIBC 2.34
	curl -o /usr/local/bin/borg -L https://github.com/$ORG/$REPO/releases/download/${lastest_version}/borg-linux-glibc231 && chmod 755 /usr/local/bin/borg

	Logger "Installed borg $(get_version_borg)" "NOTICE"
}

function get_version_borg {
	echo "$(borg --version | awk '{print $2}')"
}

function install_borg_beta {
	Logger "Installing borg beta" "NOTICE"
	curl -L https://github.com/borgbackup/borg/releases/download/2.0.0b14/borg-linux-glibc231 -o /usr/local/bin/borg_beta && chmod 755 /usr/local/bin/borg_beta
	Logger "Installed borg_beta $(get_version_borg_beta)" "NOTICE"
}

function get_version_borg_beta {
	echo "$(borg_beta --version | awk '{print $2}')"
}

function setup_ssh_borg_server {
	echo "$(echo -n "command=\"cd ${TARGET_ROOT}/borg/data; borg serve --restrict-to-path ${TARGET_ROOT}/borg/data\",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc "; cat ${TARGET_ROOT}/borg/.ssh/authorized_keys)" > ${TARGET_ROOT}/borg/.ssh/authorized_keys
}

function setup_ssh_borg_beta_server {
	echo "$(echo -n "command=\"cd ${TARGET_ROOT}/borg_beta/data; borg_beta serve --restrict-to-path ${TARGET_ROOT}/borg_beta/data\",no-port-forwarding,no-x11-forwarding,no-agent-forwarding,no-pty,no-user-rc "; cat ${TARGET_ROOT}/borg_beta/.ssh/authorized_keys)" > ${TARGET_ROOT}/borg_beta/.ssh/authorized_keys
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
		borg_beta --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key -p ${REMOTE_TARGET_SSH_PORT} -o StrictHostKeyChecking=accept-new" repo-create --encryption=repokey-aes-ocb
	else
		export BORG_REPO="$BORG_BETA_REPO_LOCAL"
		borg_beta repo-create --encryption=repokey-aes-ocb
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
	cmd="rm -rf \"${TARGET_ROOT:?}/borg/data\"; mkdir -p \"${TARGET_ROOT}/borg/data\"; if getent passwd | grep borg_user > /dev/null; then chown borg_user \"${TARGET_ROOT}/borg/data\"; fi"
	if [ "${remotely}" == true ]; then
		$REMOTE_SSH_RUNNER $cmd
	else
		eval "${cmd}"
	fi
}

function clear_borg_beta_repository {
	local remotely="${1:-false}"

	Logger "Clearing borg_beta repository. Remote: ${remotely}." "NOTICE"
	# borg expects the data directory to already exist in order to serve it via borg --serve
	cmd="rm -rf \"${TARGET_ROOT:?}/borg_beta/data\"; mkdir -p \"${TARGET_ROOT}/borg_beta/data\"; if getent passwd | grep borg_beta_user > /dev/null; then chown borg_beta_user \"${TARGET_ROOT}/borg_beta/data\"; fi"
	if [ "${remotely}" == true ]; then
		$REMOTE_SSH_RUNNER $cmd
	else
		eval "${cmd}"
	fi

}

function install_kopia {
	ORG=kopia
	REPO=kopia
	lastest_version=$(get_lastest_git_release $ORG $REPO)

	Logger "Installing kopia" "NOTICE"

#	Former kopia install instructions
#	rpm --import https://kopia.io/signing-key
#	cat <<EOF | sudo tee /etc/yum.repos.d/kopia.repo
#[Kopia]
#name=Kopia
#baseurl=http://packages.kopia.io/rpm/stable/\$basearch/
#gpgcheck=1
#enabled=1
#gpgkey=https://kopia.io/signing-key
#EOF
#
#	dnf install -y kopia

	curl -OL https://github.com/$ORG/$REPO/releases/download/${lastest_version}/kopia-${lastest_version:1}-linux-x64.tar.gz
	tar xvf kopia-${lastest_version:1}-linux-x64.tar.gz
	cp kopia-${lastest_version:1}-linux-x64/kopia /usr/local/bin/kopia
	chmod +x /usr/local/bin/kopia

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
		# As per https://github.com/kopia/kopia/issues/2375, we'll set compression to s2-default

		if [ "${KOPIA_USE_HTTP}" == true ]; then
			# When using HTTP, remote repository needs to exist before launching the server, hence it is created by serve_http function
			export KOPIA_PASSWORD=  # We need to clean KOPIA_PASSWORD else policy set will fail
			kopia repository connect server --url=https://${REMOTE_TARGET_FQDN}:${KOPIA_HTTP_PORT} --server-cert-fingerprint=$(get_remote_certificate_fingerprint ${REMOTE_TARGET_FQDN} ${KOPIA_HTTP_PORT}) -p ${KOPIA_HTTP_PASSWORD}  --override-username=${KOPIA_HTTP_USERNAME} --override-hostname=backup-bench-source
			kopia policy set ${KOPIA_HTTP_USERNAME}@backup-bench-source --compression zstd
			kopia policy set ${KOPIA_HTTP_USERNAME}@backup-bench-source --add-ignore '.git' --add-ignore '.duplicacy'
		else
			kopia repository create sftp --path=${TARGET_ROOT}/kopia/data --host=${REMOTE_TARGET_FQDN} --port ${REMOTE_TARGET_SSH_PORT} --keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key --username=kopia_user --known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts --block-hash=BLAKE3-256 --encryption=AES256-GCM-HMAC-SHA256
			kopia policy set --global --compression zstd
			kopia policy set --global --add-ignore '.git' --add-ignore '.duplicacy'
		fi
	else
		kopia repository create filesystem --path=${TARGET_ROOT}/kopia/data
		# Set default zstd compression for *ALL* non kopia server repositories (needs to be done serverside). Can be overrided.
		kopia policy set --global --compression zstd
		kopia policy set --global --add-ignore '.git' --add-ignore '.duplicacy'
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
		exit 125
	fi
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
	ORG=restic
	REPO=restic
	lastest_version=$(get_lastest_git_release $ORG $REPO)

	Logger "Installing restic ${lastest_version}" "NOTICE"

	# Former restic install instructions
	#dnf install -y epel-release
	#dnf install -y restic
	#dnf install -y bzip2 # now installed in specific function

	echo curl -OL https://github.com/$ORG/$REPO/releases/download/${lastest_version}/restic_${lastest_version:1}_linux_amd64.bz2
	curl -OL https://github.com/$ORG/$REPO/releases/download/${lastest_version}/restic_${lastest_version:1}_linux_amd64.bz2
	bzip2 -d restic_${lastest_version:1}_linux_amd64.bz2
	alias cp=cp; cp restic_${lastest_version:1}_linux_amd64 /usr/local/bin/restic
	chmod +x /usr/local/bin/restic


	Logger "Installed restic $(get_version_restic)" "NOTICE"
}

function get_version_restic {
	echo "$(restic version | awk '{print $2}')"
}

function install_restic_rest_server {
	lastest_version=$(get_lastest_git_release restic rest-server)

	Logger "Installing restic rest-server ${lastest_version}" "NOTICE"
	curl -o /tmp/rest-server.tar.gz -L https://github.com/restic/rest-server/releases/download/${lastest_version}/rest-server_${lastest_version:1}_linux_amd64.tar.gz
	tar xvf /tmp/rest-server.tar.gz --wildcards --no-anchored --transform='s/.*\///' -C /usr/local/bin 'rest-server'
	chmod +x /usr/local/bin/rest-server
}

function init_restic_repository {
	local remotely="${1:-false}"

	Logger "Initializing restic repository. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		# This should be executed on the source system
		if [ "${RESTIC_USE_HTTP}" == true ]; then
			restic --insecure-tls -r rest:https://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/ init --repository-version 2
		else
			restic -r sftp::${TARGET_ROOT}/restic/data -o sftp.command="ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp" init --repository-version 2
		fi
	else
		restic -r ${TARGET_ROOT}/restic/data init --repository-version 2
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

function install_rustic {
	ORG=rustic-rs
	REPO=rustic
	lastest_version=$(get_lastest_git_release $ORG $REPO)

	Logger "Installing rustic ${lastest_version}" "NOTICE"

	# As of 2023-03-29, gnu build requires glibc 2.35 whereas RHEL9 has glibc 2.34
	# musl build works
	echo curl -o /tmp/rustic.tar.gz -L https://github.com/$ORG/$REPO/releases/download/${lastest_version}/rustic-${lastest_version}-x86_64-unknown-linux-musl.tar.gz
	curl -o /tmp/rustic.tar.gz -L https://github.com/$ORG/$REPO/releases/download/${lastest_version}/rustic-${lastest_version}-x86_64-unknown-linux-musl.tar.gz
	tar xvf /tmp/rustic.tar.gz --wildcards --no-anchored --transform='s/.*\///' -C /usr/local/bin 'rustic'
	chmod +x /usr/local/bin/rustic


	Logger "Installed rustic $(get_version_rustic)" "NOTICE"
}

function get_version_rustic {
	echo "$(rustic --version | awk '{print $2}')"
}

function init_rustic_repository {
	local remotely="${1:-false}"

	Logger "Initializing rustic repository. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		# This should be executed on the source system
		if [ "${RESTIC_USE_HTTP}" == true ]; then
			# By default, rustic always initialises repo format version 2 with compression enabled, so no need to specify --set-version 2
			rustic --insecure-tls -r rest:https://${REMOTE_TARGET_FQDN}:${RUSTIC_HTTP_PORT}/ init
		else
			rustic -r sftp::${TARGET_ROOT}/rustic/data -o sftp.command="ssh rustic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/rustic.key -p ${REMOTE_TARGET_SSH_PORT} -s sftp"
		fi
	else
		rustic -r ${TARGET_ROOT}/rustic/data init
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
		exit 125
	fi
}

function clear_rustic_repository {
	local remotely="${1:-false}"

	Logger "Clearing rustic repository. Remote: ${remotely}." "NOTICE"
	cmd="rm -rf \"${TARGET_ROOT:?}/rustic/data\""
	if [ "${remotely}" == true ]; then
		$REMOTE_SSH_RUNNER $cmd
	else
		eval "${cmd}"
	fi
}

function install_duplicacy {
	ORG=gilbertchen
	REPO=duplicacy
	lastest_version=$(get_lastest_git_release $ORG $REPO)

	Logger "Installing duplicacy ${lastest_version}" "NOTICE"
	curl -L -o /usr/local/bin/duplicacy https://github.com/$ORG/$REPO/releases/download/${lastest_version}/duplicacy_linux_x64_"${lastest_version:1}"
	chmod +x /usr/local/bin/duplicacy
	Logger "Installed duplicacy $(get_version_duplicacy)" "NOTICE"
}

function get_version_duplicacy {
	echo "$(duplicacy | grep -A1 "VERSION" | tail -n 1 | awk '{print $1}')"
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
		cmd="rm -rf \"${TARGET_ROOT:?}/duplicacy/data\" && mkdir -p \"${TARGET_ROOT}/duplicacy/data\" && chown duplicacy_user \"${TARGET_ROOT}/duplicacy/data\""
		$REMOTE_SSH_RUNNER $cmd
	else
		cmd="rm -rf \"${TARGET_ROOT:?}/duplicacy/data\" && mkdir -p \"${TARGET_ROOT}/duplicacy/data\""
		eval "${cmd}"
	fi
	# We also need to delete .duplicacy folder in source
	rm -rf "${BACKUP_ROOT}/.duplicacy"
}

function setup_git_dataset {
	#dnf install -y git # now installed in specific function
	# We'll assume that BACKUP_ROOT will be a git root, so we need to git clone in parent directory
	git_parent_dir="$(dirname ${BACKUP_ROOT:?})"
	[ ! -d "${git_parent_dir}" ] && mkdir -p "${git_parent_dir}"
	cd "${git_parent_dir}" || exit 127

	[ -d "${GIT_ROOT_DIRECTORY}" ] && rm -rf "${GIT_ROOT_DIRECTORY}"
	git clone ${GIT_DATASET_REPOSITORY}
}

function backup_bupstash {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Launching bupstash backup. Remote: ${remotely}." "NOTICE"
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

	Logger "Launching bupstash restore. Remote: ${remotely}." "NOTICE"
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

	Logger "Launching borg backup. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		export BORG_REPO="$BORG_STABLE_REPO_REMOTE"
		borg create --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg.key $SSH_OPTS -p ${REMOTE_TARGET_SSH_PORT}" --compression zstd,3 --exclude 're:\.git/.*$' --exclude 're:\.duplicacy/.*$' --stats --verbose ${BORG_REPO}::"${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.borg_tests.log 2>&1
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

	Logger "Launching borg restore. Remote: ${remotely}." "NOTICE"
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

	Logger "Launching borg_beta backup. Remote: ${remotely}." "NOTICE"
	if [ "${remotely}" == true ]; then
		export BORG_REPO="$BORG_BETA_REPO_REMOTE"
		borg_beta create --rsh "ssh -i ${SOURCE_USER_HOMEDIR}/.ssh/borg_beta.key $SSH_OPTS -p ${REMOTE_TARGET_SSH_PORT}" --compression zstd,3 --exclude 're:\.git/.*$' --exclude 're:\.duplicacy/.*$' --stats --verbose "${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.borg_beta_tests.log 2>&1
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

	Logger "Launching borg_beta restore. Remote: ${remotely}." "NOTICE"
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

	Logger "Launching kopia backup. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		if [ "${KOPIA_USE_HTTP}" == true ]; then
			kopia repository connect server --url=https://${REMOTE_TARGET_FQDN}:${KOPIA_HTTP_PORT} --server-cert-fingerprint=$(get_remote_certificate_fingerprint ${REMOTE_TARGET_FQDN} ${KOPIA_HTTP_PORT}) -p ${KOPIA_HTTP_PASSWORD} --override-username=${KOPIA_HTTP_USERNAME} --override-hostname=backup-bench-source
			export KOPIA_PASSWORD= # if not cleaned, kopia snapshot will fail
		else
			kopia repository connect sftp --path=${TARGET_ROOT}/kopia/data --host=${REMOTE_TARGET_FQDN} --port ${REMOTE_TARGET_SSH_PORT} --keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key --username=kopia_user --known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts
		fi
	else
		kopia repository connect filesystem --path=${TARGET_ROOT}/kopia/data
	fi
	kopia snapshot create --parallel 8 --tags BACKUPID:"${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.kopia_test.log 2>&1
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
	# We can check the exclusion patterns with kopia snapshot estimate

}

function restore_kopia {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Launching kopia restore. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		if [ "${KOPIA_USE_HTTP}" == true ]; then
			kopia repository connect server --url=https://${REMOTE_TARGET_FQDN}:${KOPIA_HTTP_PORT} --server-cert-fingerprint=$(get_remote_certificate_fingerprint ${REMOTE_TARGET_FQDN} ${KOPIA_HTTP_PORT}) -p ${KOPIA_HTTP_PASSWORD} --override-username=${KOPIA_HTTP_USERNAME} --override-hostname=backup-bench-source
			export KOPIA_PASSWORD= # if not cleaned, kopia restore will fail
		else
			kopia repository connect sftp --path=${TARGET_ROOT}/kopia/data --host=${REMOTE_TARGET_FQDN} --port ${REMOTE_TARGET_SSH_PORT} --keyfile=${SOURCE_USER_HOMEDIR}/.ssh/kopia.key --username=kopia_user --known-hosts=${SOURCE_USER_HOMEDIR}/.ssh/known_hosts
		fi
	else
		kopia repository connect filesystem --path=${TARGET_ROOT}/kopia/data
	fi
	id="$(kopia snapshot list --tags BACKUPID:${backup_id} | awk '{print $4}')"
	kopia restore --parallel 8 --skip-owners --skip-permissions ${id} "${RESTORE_DIR}"  >> /var/log/${PROGRAM}.kopia_test.log 2>&1
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function backup_restic {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Launching restic backup. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		if [ "${RESTIC_USE_HTTP}" == true ]; then
			restic --insecure-tls -r rest:https://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/ backup --verbose --exclude=".git" --exclude=".duplicacy" --tag="${backup_id}" --compression=auto "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
		else
			restic -r sftp::${TARGET_ROOT}/restic/data -o sftp.command="ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key $SSH_OPTS -p ${REMOTE_TARGET_SSH_PORT} -s sftp" backup --verbose --exclude=".git" --exclude=".duplicacy" --tag="${backup_id}" --compression=auto "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
		fi
	else
		restic -r ${TARGET_ROOT}/restic/data backup --verbose --exclude=".git" --exclude=".duplicacy" --tag="${backup_id}" --compression=auto "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function restore_restic {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Launching restic restore. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		if [ "${RESTIC_USE_HTTP}" == true ]; then
			id=$(restic --insecure-tls -r rest:https://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/ snapshots | grep "${backup_id}" | awk '{print $1}')
			restic --insecure-tls -r rest:https://${REMOTE_TARGET_FQDN}:${RESTIC_HTTP_PORT}/ restore "$id" --target "${RESTORE_DIR}" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
		else
			id=$(restic -r sftp::${TARGET_ROOT}/restic/data -o sftp.command="ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key $SSH_OPTS -p ${REMOTE_TARGET_SSH_PORT} -s sftp" snapshots | grep "${backup_id}" | awk '{print $1}')
			restic -r sftp::${TARGET_ROOT}/restic/data -o sftp.command="ssh restic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/restic.key $SSH_OPTS -p ${REMOTE_TARGET_SSH_PORT} -s sftp" restore "$id" --target "${RESTORE_DIR}" >> /var/log/${PROGRAM}.restic_tests.log 2>&1
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

function backup_rustic {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Launching rustic backup. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		if [ "${RESTIC_USE_HTTP}" == true ]; then
			rustic --insecure-tls -r rest:https://${REMOTE_TARGET_FQDN}:${RUSTIC_HTTP_PORT}/ backup --glob="!.git" --glob="!.duplicacy" --tag="${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.rustic_tests.log 2>&1
		else
			rustic -r sftp::${TARGET_ROOT}/rustic/data -o sftp.command="ssh rustic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/rustic.key $SSH_OPTS -p ${REMOTE_TARGET_SSH_PORT} -s sftp" backup --verbose --glob="!.git" --glob="!.duplicacy" --tag="${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.rustic_tests.log 2>&1
		fi
	else
		rustic -r ${TARGET_ROOT}/rustic/data backup --glob="!.git" --glob="!.duplicacy" --tag="${backup_id}" "${BACKUP_ROOT}/" >> /var/log/${PROGRAM}.rustic_tests.log 2>&1
	fi
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function restore_rustic {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Launching rustic restore. Remote: ${remotely}." "NOTICE"

	if [ "${remotely}" == true ]; then
		if [ "${RUSTIC_USE_HTTP}" == true ]; then
			id=$(rustic --insecure-tls -r rest:https://${REMOTE_TARGET_FQDN}:${RUSTIC_HTTP_PORT}/ snapshots | grep "${backup_id}" | awk '{print $2}')
			rustic --insecure-tls -r rest:https://${REMOTE_TARGET_FQDN}:${RUSTIC_HTTP_PORT}/ restore "$id" "${RESTORE_DIR}" >> /var/log/${PROGRAM}.rustic_tests.log 2>&1
		else
			id=$(rustic -r sftp::${TARGET_ROOT}/rustic/data -o sftp.command="ssh rustic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/rustic.key $SSH_OPTS -p ${REMOTE_TARGET_SSH_PORT} -s sftp" snapshots | grep "${backup_id}" | awk '{print $2}')
			rustic -r sftp::${TARGET_ROOT}/rustic/data -o sftp.command="ssh rustic_user@${REMOTE_TARGET_FQDN} -i ${SOURCE_USER_HOMEDIR}/.ssh/rustic.key $SSH_OPTS -p ${REMOTE_TARGET_SSH_PORT} -s sftp" restore "$id" "${RESTORE_DIR}" >> /var/log/${PROGRAM}.rustic_tests.log 2>&1
		fi
	else
		id=$(rustic -r ${TARGET_ROOT}/rustic/data snapshots | grep "${backup_id}" | awk '{print $2}')
		rustic -r ${TARGET_ROOT}/rustic/data restore "$id" "${RESTORE_DIR}" >> /var/log/${PROGRAM}.rustic_tests.log 2>&1
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

	Logger "Launching duplicacy backup. Remote: ${remotely}." "NOTICE"

	# Added -threads 8 according to https://github.com/deajan/backup-bench/issues/14

	duplicacy backup -t "${backup_id}" --stats -threads 8 >> /var/log/${PROGRAM}.duplicacy_tests.log 2>&1
	result=$?
	if [ "${result}" -ne 0 ]; then
		Logger "Failure with exit code $result" "CRITICAL"
	fi
}

function restore_duplicacy {
	local remotely="${1}"
	local backup_id="${2}"

	Logger "Launching duplicacy restore. Remote: ${remotely}." "NOTICE"

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

	# Added -threads 8 according to https://github.com/deajan/backup-bench/issues/14

	duplicacy restore -r ${revision} -threads 8 >> /var/log/${PROGRAM}.duplicacy_tests.log 2>&1
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

function install_backup_programs {
	local is_remote="${1:-false}"

	# bupstash, borg and kopia need to be installed on both source and targets
	# restic and duplicity don't need to be installed on target
	# restic rest server only needs to be installed on target

	install_bupstash
	install_borg
	install_borg_beta
	install_kopia

	[ "$is_remote" == false ] && install_restic
	[ "$is_remote" == false ] && install_rustic
	[ "$is_remote" == true ] && install_restic_rest_server
	[ "$is_remote" == false ] && install_duplicacy
}

function setup_source {
	local remotely="${1:-false}"

	Logger "Setting up source server" "NOTICE"
	download_prerequisites ${NODEPS}

	install_backup_programs false

	if [ "${remotely}" == false ]; then
		Logger "Setting up local target" "NOTICE"
		setup_target_local_repos
	fi

	# Specific setup for bupstash where key is stored as file instead of env variable
	[ ! -f "${SOURCE_USER_HOMEDIR}/bupstash.master.key" ] && bupstash new-key -o ${SOURCE_USER_HOMEDIR}/bupstash.master.key
	[ ! -f "${SOURCE_USER_HOMEDIR}/bupstash.store.key" ] && bupstash new-sub-key -k ${SOURCE_USER_HOMEDIR}/bupstash.master.key --put --list -o ${SOURCE_USER_HOMEDIR}/bupstash.store.key

}

function setup_remote_target {
	local remotely="${1:-false}" # Has no use here obviously, but we'll keep it since remotely argument is passed

	Logger "Setting up remote target server" "NOTICE"

	setup_root_access
	download_prerequisites ${NODEPS}

	install_backup_programs true

	clear_users
	setup_target_remote_repos

	setup_ssh_bupstash_server

	setup_ssh_borg_server
	setup_ssh_borg_beta_server

	create_certificate https_backup-bench
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

	# The only reason we need to setup our dataset before being able to init the backup repositories is because duplicacy needs an existing source dir to init it's repo...
	[ "${git}" == true ] && setup_git_dataset

	if [ ! -d "${BACKUP_ROOT}" ]; then
		Logger "Backup root ${BACKUP_ROOT} does not exist. Either create it and add test content, or use --git to initialize it." "CRITICAL"
		exit 3
	fi

	Logger "Initializing reposiories. Remote: ${remotely}." "NOTICE"
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		init_"${backup_software}"_repository "${remotely}"
	done
	Logger "Initialization done." "NOTICE"
}

function serve_http_targets {
	[ ! -f "${TARGET_ROOT}/kopia/data/kopia.repository.f" ] && kopia repository create filesystem --path=${TARGET_ROOT}/kopia/data
	cmd="kopia server start --address 0.0.0.0:${KOPIA_HTTP_PORT} --no-ui --tls-cert-file=\"${HOME}/https_backup-bench.crt\" --tls-key-file=\"${HOME}/https_backup-bench.key\""
	Logger "Running kopia server with following command:\n$cmd" "NOTICE"
	eval $cmd &
	pid=$!
	# add acls for user
	cmd="kopia server users add ${KOPIA_HTTP_USERNAME}@backup-bench-source --user-password=${KOPIA_HTTP_PASSWORD}"
	eval $cmd
	Logger "Adding kopia user woth following command:\n$cmd" "NOTICE"
	# reload server
	cmd="kopia server refresh --address https://localhost:${KOPIA_HTTP_PORT} --server-cert-fingerprint=$(get_certificate_fingerprint "${HOME}/https_backup-bench.crt")  --server-control-username=${KOPIA_SERVER_CONTROL_USER} --server-control-password=${KOPIA_SERVER_CONTROL_PASSWORD}"
	Logger "Running kopia refresh with following command:\n$cmd" "NOTICE"
	sleep 2 # arbitrary wait time
	eval $cmd &
	Logger "Serving kopia on http port ${KOPIA_HTTP_PORT} using pid $pid." "NOTICE"
	rest-server --no-auth --listen 0.0.0.0:${RESTIC_HTTP_PORT} --path ${TARGET_ROOT}/restic/data --tls --tls-cert="${HOME}/https_backup-bench.crt" --tls-key="${HOME}/https_backup-bench.key" &
	pid=$!
	Logger "Serving rest-serve for restic on http port ${RESTIC_HTTP_PORT} using pid $pid." "NOTICE"
	Logger "Stop servers using $0 --stop-http-targets" "NOTICE"

	rest-server --no-auth --listen 0.0.0.0:${RUSTIC_HTTP_PORT} --path ${TARGET_ROOT}/rustic/data --tls --tls-cert="${HOME}/https_backup-bench.crt" --tls-key="${HOME}/https_backup-bench.key" &
	pid=$!
	Logger "Serving rest-serve for rustic on http port ${RUSTIC_HTTP_PORT} using pid $pid." "NOTICE"
	Logger "Stop servers using $0 --stop-http-targets" "NOTICE"
	echo ""  # Just clear the line at the end
}

function stop_serve_http_targets {
	for i in $(pgrep kopia); do kill $i; done
	for i in $(pgrep rest-server); do kill $i; done
}

function benchmark_backup_standard {
	local remotely="${1}"
	local backup_id="${2:-defaultid}"

	CSV_BACKUP_EXEC_TIME="backup(s),"

	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		CSV_HEADER="${CSV_HEADER}${backup_software},"
		echo 3 > /proc/sys/vm/drop_caches       # Make sure we drop caches (including zfs arc cache before every backup)
		[ "${remotely}" == true ] && $REMOTE_SSH_RUNNER "echo 3 > /proc/sys/vm/drop_caches"
		Logger "Starting backup bench of ${backup_software} name=${backup_id}" "NOTICE"
		seconds_begin=$SECONDS
		# Launch backup software from function "name"_backup as background so we keep control
		backup_"${backup_software}" "${remotely}" "${backup_id}" &
		ExecTasks "$!" "${backup_software}_bench" false 3600 36000 3600 36000
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
	local backup_id_timestamp="${3:-false}"

	echo "# $PROGRAM $PROGRAM_BUILD $(date) Remote: ${remotely}, Git: ${git}" >> "${CSV_RESULT_FILE}"
	CSV_HEADER=","

	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		CSV_HEADER="${CSV_HEADER}${backup_software} $(get_version_${backup_software}),"
	done
	echo "${CSV_HEADER}" >> "${CSV_RESULT_FILE}"

	if [ "${git}" == true ]; then
		benchmark_backup_git "${remotely}"
	else
		if [ "$backup_id_timestamp" == true ]; then
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

	CSV_RESTORE_EXEC_TIME="restoration(s),"

	# Restore last snapshot and compare with actual kernel
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		echo 3 > /proc/sys/vm/drop_caches       # Make sure we drop caches (including zfs arc cache before every backup)
		[ "${remotely}" == true ] && $REMOTE_SSH_RUNNER "echo 3 > /proc/sys/vm/drop_caches"

		[ -d "${RESTORE_DIR}" ] && rm -rf "${RESTORE_DIR:?}"
		mkdir -p "${RESTORE_DIR}"

		Logger "Starting restore bench of ${backup_software} name=${backup_id}" "NOTICE"
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
		if [ "${backup_software}" == "borg" ] || [ "${backup_software}" == "borg_beta" ] || [ "${backup_software}" == "restic" ] || [ "${backup_software}" == "rustic" ]; then
			restored_path="${RESTORE_DIR}"/"${BACKUP_ROOT}/"
		else
			restored_path="${RESTORE_DIR}"
		fi
		diff -x .git -x .duplicacy -qr "${restored_path}" "${BACKUP_ROOT}/"
		result=$?
		if [ "${result}" -ne 0 ]; then
			Logger "Failure with exit code $result for restore comparaison." "CRITICAL"
		else
			Logger "Restored files match source." "NOTICE"
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
	local backup_id_timestamp="${3:-false}"

	if [ "${git}" == true ]; then
		benchmark_restore_git "${remotely}"
	else
		if [ "$backup_id_timestamp" == true ]; then
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
	for backup_software in "${BACKUP_SOFTWARES[@]}"; do
		version=$(get_version_${backup_software})
		echo "${backup_software} $version"
	done
}

function usage {
	echo "$PROGRAM $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo ""
	echo "Please setup your config file (defaults to backup-bench.conf"
	echo "Once you've setup the configuration, you may use it to initialize target, then source."
	echo "After initialization, benchmarks may run"
	echo ""
	echo "--config=/path/to/file.conf       Alternative configuration file"
	echo "--setup-remote-target	     	Install backup programs and setup SSH access (executed on target)"
	echo "--setup-source            	Install backup programs and setup local (or remote with --remote) repositories (executed on source)"
	echo "--init-repos	        	Reinitialize local (or remote with --remote) repositories after clearing. Must be used with --git if multiple version benchmarks is used) (executed on source)"
	echo "--serve-http-targets              Launch http servers for kopia and restic manually"
	echo "--stop-http-targets               Stop http servers for kopia and restic"
	echo "--benchmark-backup		Run backup benchmarks using local (or remote with --remote) repositories"
	echo "--benchmark-restore		Run restore benchmarks using local (or remote with --remote) repositories, restores to local restore path"
	echo "--benchmarks	        	Run both backup and restore benchmark using local (or remote with --remote) repositories and local restore path"
	echo "--all				Clear, init and run bakcup with git dataset for both local and remote targets"
	echo ""
	echo "MODIFIERS"
	echo "--git				Use git dataset (multiple version benchmark)"
	echo "--local				Execute locally (works for --clear-repos, --init-repos, --benchmark*)"
	echo "--remote				Execute remotely (works for --clear-repos, --init-repos, --benchmark*)"
	echo "--backup-id-timestamp             Add a timestamp as backup id when doing using --git. If this option is disabled, backupid will be \"defaultid\". There cannot be multiple backups with the same id"
	echo ""
	echo "After some benchmarks, you might want to remove earlier data from repositories"
	echo "--clear-repos	       		Removes data from local (or remote with --remote) repositories"
	echo ""
	echo "DEBUG commands"
	echo "--setup-root-access               Manually setup root access (executed on target)"
	echo "--no-deps                         Do not install dependencies. This requires you to have them installed manually"
	echo "--install-backup-programs         Locally install / upgrade backup programs into /usr/local/bin. If launched with --remote, it will install only remote target required programs"
	echo "--versions                        Show versions of all installed backup programs"
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
CONFIG_FILE="backup-bench.conf"
NODEPS=false
BACKUP_ID_TIMESTAMP=false

for i in "${@}"; do
	case "$i" in
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
		usage
		;;
	esac
done

# Load configuration file
Logger "Using configuration file ${CONFIG_FILE}" "NOTICE"
source "${CONFIG_FILE}"


if [ "${ALL}" == true ]; then
	# prepare repos and run all tests locally and remotely
	clear_repositories
	init_repositories false true
	benchmarks false true
	clear_repositories true
	init_repositories true rtue
	benchmarks true true $BACKUP_ID_TIMESTAMP
else
	full_cmd="$cmd $REMOTELY $USE_GIT_VERSIONS $BACKUP_ID_TIMESTAMP"
	Logger "Running: ${full_cmd}" "DEBUG"
	eval "$full_cmd"
fi

CleanUp
