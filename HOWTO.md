# How to setup backup-bench.sh yourself

The backup-bench script supposes you have a source system with a RHEL 8/9 clone installed (PRs for other systems are welcome).
The default configuration will delete and create the following folders:

 - /opt/backup_test as the git dataset download folder
 - /backup-bench-repos as the folder which will contain backup repositories (local or on remote target)
 - /tmp/backup-bench-restore as the folder where backup restoration tests happen

You can customize those settings in `backup-bench.conf` file.

## Local benchmarks

The script must prepare your machine by installing the requested backup software. You can do so with:

```
./backup-bench. --setup-source
```

It can run as local backup benchmark solution only, in that case you should run the following commands:
```
./backup-bench.sh --clear-repos
./backup-bench.sh --init-repos
./backup-bench.sh --benchmarks
```

You might want to run multiple iterations of backups.
In that case, you can run the following

```
./backup-bench.sh --clear-repos
./backup-bench.sh --init-repos --git
./backup-bench.sh --benchmarks --git
```

Results can be found in `/var/log/backup-bench.log` and `/var/log/backup-bench.results.csv`.

Moreever, backup solution log files can be found in `/var/log/backup-bench.[BACKUP SOLUTION].log`

## Remote benchmarks using SSH / SFTP backends

Remote benchmarks assume you have a second (target) machine.
Both source and target machines must be reachable via SSH.

After having setup the necessary FQDN and ports in `backup-bench.conf`, you can initialize the target with:

```
./backup-bench. --setup-target
```

The target machine will connect to your source server to upload the ssh keys necessary for the source machine to connect to your target. This requires you to enter the password once.
Once this is setup, the target cannot connect to source anymore.

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
> duplicity benchmarks will fail if you do initialize repositories locally and try remote backup benchmarks or vice verca.

## Remote benchmarks using alternative backends

There is a work in progress to support restic and kopia http servers, which have not been tested yet.
You're welcome to help to automate those.
Script will assume restic http, restic_beta http and kopia http ports are reachable from source to target. As of today, no auth mechanism is used in script, so please make sure you know what you're doing when using http backends.
