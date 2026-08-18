# How to setup backup-bench.sh yourself

The backup-bench script supposes you have a source system with a RHEL 9/10 clone installed (PRs for other systems are welcome).
RHEL 8 has been removed since its glibc version is too low for borg beta, and well, it's old ;)
Note that the borg beta binary needs glibc >= 2.39, so RHEL 10 is required to benchmark it.

The default configuration will delete and create the following folders:

 - /opt/backup_bench/backup_test as the git dataset download folder (only when `--git` is used)
 - /opt/backup_bench/backup-bench-repos as the folder which will contain backup repositories (local or on remote target)
 - /opt/backup_bench/tmp/backup-bench-restore as the folder where backup restoration tests happen

It also creates, but never deletes:

 - /opt/backup_bench/bin for the backup program binaries
 - /opt/backup_bench/logs/[date of run] for the logs and results of every run
 - /opt/backup_bench/duplicacy for duplicacy's repository metadata, kept out of the dataset

You can customize those settings in `backup-bench.conf` file.
When you update the script, update your configuration file too: the script refuses to run when `CONF_VERSION` is older than the version it needs.

> :warning:
> `--git` deletes and re-clones `BACKUP_ROOT`. Without `--git`, `BACKUP_ROOT` is treated as your own dataset and is never written to nor deleted.

## Local benchmarks

The script must prepare your machine by installing the requested backup software. You can do so with:

```
./backup-bench.sh --setup-source
```

It can run as local backup benchmark solution only, in that case you should run the following commands:
```
./backup-bench.sh --clear-repos
./backup-bench.sh --init-repos --git
./backup-bench.sh --benchmarks
```

The `--git` parameter for `--init-repos` command instructs the script to fetch the linux kernel source as backup source.
This allows to have the same datasets for different workloads.
You may also configure `BACKUP_ROOT` variable in `backup-bench.conf` to point to specific dataset and avoid using `--git` parameter.


You might want to run multiple iterations of backups.
In that case, you can run the following

```
./backup-bench.sh --clear-repos
./backup-bench.sh --init-repos --git
./backup-bench.sh --benchmarks --git
```

Results and logs of every run are kept together in `/opt/backup_bench/logs/[date of run]/`:

 - `backup-bench.log` is the log of the run
 - `backup-bench.results.csv` holds the timings and repository sizes
 - `backup-bench.[BACKUP SOLUTION].log` is the verbose output of one backup program

The path of the current run is printed when the script starts.

## Remote benchmarks using SSH / SFTP backends

Remote benchmarks assume you have a second (target) machine.
Both source and target machines must be reachable via SSH.

After having setup the necessary FQDN and ports in `backup-bench.conf`, you can initialize the target with:

```
./backup-bench.sh --setup-remote-target
```

The target machine will connect to your source server to upload the ssh keys necessary for the source machine to connect to your target. This requires you to enter the password once.
Once this is setup, the target cannot connect to source anymore.

Every backup program gets its own user, home directory and ssh key on the target, so one program cannot reach another one's repository.

Once this is done, the source machine can use the uploaded ssh keys to connect to the remote repositories on the target system.
You can then prepare the benchmarks with

```
./backup-bench.sh --clear-repos --remote
```

Optional step if using kopia / restic HTTP servers, on target:
```
./backup-bench.sh --serve-http-targets
```

On source
```
./backup-bench.sh --init-repos --remote
./backup-bench.sh --benchmarks --remote
```

Again, you can run multiple backup iterations with:
```
./backup-bench.sh --clear-repos --remote
```

Optional step if using kopia / restic HTTP servers, on target:
```
./backup-bench.sh --serve-http-targets
```

```
./backup-bench.sh --init-repos --remote --git
./backup-bench.sh --benchmarks --remote --git
```

> :warning:
> A duplicacy repository points at exactly one storage, and so does plakar's local configuration.
> Always re-run `--init-repos` when switching between local and remote benchmarks.

### plakar and ssh

plakar reaches remote repositories over SFTP through a store connector which is not part of the plakar binary, and which shells out to the `sftp` command.
`--setup-source` therefore does two extra things for plakar:

 - it runs `plakar pkg add sftp` to install that connector
 - it prepends a `Match host [target] user plakar_user` block to `~/.ssh/config`, holding the port and the private key to use, since the connector accepts neither

If you already maintain an `~/.ssh/config` with a `Host *` section setting `IdentityFile`, check that it does not shadow that block: ssh keeps the first value it finds for a given keyword.

## Remote benchmarks using alternative backends

There is a work in progress to support restic, rustic and kopia http servers, which have not been fully tested yet.
You're welcome to help to automate those.
Script will assume restic http, rustic http and kopia http ports are reachable from source to target. As of today, no auth mechanism is used in script for rest-server, so please make sure you know what you're doing when using http backends.

## Adding another backup program

`BACKUP_SOFTWARES` in the configuration file drives everything: the script derives the function names it calls from each program name.
The header of `backup-bench.sh` lists the six functions a new program needs, plus the two optional ones. PRs are welcome.
