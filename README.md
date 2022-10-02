# backup-bench
Quick and dirty backup tool benchmark with reproducible results

** This is a one page entry with benchmarks (see below), previous versions are available via git versioning.**

## What

This repo aims to compare different backup solutions among:

 - [borg backup](https://www.borgbackup.org)
 - [bupstash](https://bupstash.io)
 - [restic](https://restic.net)
 - [kopia](https://www.kopia.io)
 - [duplicacy](https://duplicacy.com)
 - your tool (PRs to support new backup tools are welcome)
 
 The idea is to have a script that executes all backup programs on the same datasets.
 
 We'll use a quite big (and popular) git repo as first dataset so results can be reproduced by checking out branches (and ignoring .git directory).
 I'll also use another (not public) dataset which will be some qcow2 files which are in use.
 
 Time spent by the backup program is measured by the script so we get as accurate as possible results (time is measured from process beginning until process ends, with a 1 second granularity).

 While backups are done, cpu/memory/disk metrics are saved so we know how "resource hungry" a backup program can be.
 
All backup programs are setup to use SSH in order to compare their performance regardless of the storage backend.

When available, we'll tune the encryption algorithm depending on the results of a benchmark. For instance, kopia has a `kopia benchmark compression --data-file=/some/big/data/file` option to find out which compression / crypto works best on the current architecture.
This is *REALLY NICE TO HAVE* when choices need to be made, aware of current architecture.
As of the current tests, Borg v2.0.0-b1 also has a `borg benchmark cpu` option.

## Why

I am currently using multiple backup programs to achieve my needs. As of today, I use Graham Keeling's burp https://github.com/grke/burp to backup windows machines, and borg backup to backup QEMU VM images. Graham decided to remove its deduplication (protocol 2) and stick with rsync based backups (protocol 1), which isn't compatible with my backup strategies.
I've also tried out bupstash which I found to be quite quick, but which produces bigger backups remotely when dealing with small files (probably because of the chunk size?).

Anyway, I am searching for a good allrounder, so I decided to give all the deduplicating backup solutions a try, and since I am configuring them all, I thought why not make my results available to anyone, with a script so everything can be reproduced easily.

As of today I use the script on my lab hypervisor, which runs AlmaLinux 8.6. The script should run on other distros, although I didn't test it.

I'll try to be as little biased as possible when doing my backup tests.
If you feel that I didn't give a specific program enough attention, feel free to open an issue.

# In depth comparison of backup solutions

Last update: 02 October 2022

|Backup software|Version|
|------------------|--------|
|borg|1.2.2|
|borg beta|2.0.0b2|
|restic|0.14.0|
|kopia|0.12.0|
|bupstash|0.11.1|
|duplicacy|2.7.2|

The following list is my personal shopping list when it comes to backup solutions, and might not be complete, you're welcome to provide PRs to update it. ;)

| **Goal**                           | **Functionality**                                                        | **borg**              | **restic**     | **kopia**                                  | **bupstash**          | **duplicacy** |
|------------------------------------|--------------------------------------------------------------------------|-----------------------|----------------|--------------------------------------------|-----------------------|---------------|
| **Reliability**                    | Redundant index copies                                                   | ?                     | ?              | Yes                                        | yes, redundant + sync | No indexes used|
| **Reliability**                    | Continue restore on bad blocks in repository                             | ?                     | ?              | Yes (can ignore errors when restoring)     | No                    | Yes, [erasure coding](https://forum.duplicacy.com/t/new-feature-erasure-coding/4168]|
| **Reliability**                    | Data checksumming                                                        | Yes (CRC & HMAC)      | ?              | No (Reed–Solomon in the works)             | HMAC                  | Yes           |
| **Restoring Data**                 | Backup mounting as filesystem                                            | Yes                   | Yes            | Yes                                        | No                    | No            |
| **File management**                | File includes / excludes bases on regexes                                | Yes                   | ?              | ?                                          | ?                     | Yes           |
| **File management**                | Supports backup XATTRs                                                   | Yes                   | ?              | No                                         | Yes                   | ?             |
| **File management**                | Supports backup ACLs                                                     | Yes                   | ?              | No                                         | Yes                   | ?             |
| **File management**                | Supports hardlink identification (no multiple stored hardlinked files    | No ([borg2 will](https://github.com/borgbackup/borg/issues/2379) | [Yes](https://forum.restic.net/t/trying-to-understand-how-hard-links-are-handled-by-restic/3785) |  [No](https://github.com/kopia/kopia/issues/544#issuecomment-988329366)  | [Yes](https://github.com/deajan/backup-bench/issues/13#issue-1363979532)                  | [No](https://forum.duplicacy.com/t/hard-links-not-properly-restored/962/3)             |
| **File management**                | Supports sparse files (thin provisionned files on disk)                  | [Yes](https://github.com/borgbackup/borg/pull/5561) | [Yes](https://github.com/restic/restic/pull/3854)              | [Yes](https://github.com/kopia/kopia/pull/1823)                                          | [Yes](https://bupstash.io/doc/man/bupstash-restore.html)                   | ?              |
| **File management**                | Can exclude CACHEDIR.TAG(3) directories                                  | Yes                   | Yes            | Yes                                        | No                    | No            |
| **Dedup & compression efficiency** | Is data compressed                                                       | Yes                   | Yes            | Yes                                        | Yes                   | Yes           |
| **Dedup & compression efficiency** | Uses newer compression algorithms (ie zstd)                              | Yes                   | Yes            | Yes                                        | Yes                   | Yes           |
| **Dedup & compression efficiency** | Can files be excluded from compression by extension                      | ?                     | No             | Yes                                        | No                    | No            |
| **Dedup & compression efficiency** | Is data deduplicated                                                     | Yes                   | Yes            | Yes                                        | Yes                   | Yes           |
| **Platform support**               | Programming lang                                                         | Python                | Go             | Go                                         | Rust                  | Go            |
| **Platform support**               | Unix Prebuilt binaries                                                   | Yes                   | Yes            | Yes                                        | No                    | Yes           |
| **Platform support**               | Windows support                                                          | Yes (WSL)             | Yes            | Yes                                        | No                    | Yes           |
| **Platform support**               | Windows first class support (PE32 binary)                                | No                    | Yes            | Yes                                        | No                    | Yes           |
| **Platform support**               | Unix snapshot support where snapshot path prefix is removed              | ?                     | ?              | ?                                          | ?                     | ?             |
| **Platform support**               | Windows VSS snapshot support where snapshot path prefix is removed       | No                    | Yes            | No, but pre-/post hook VSS script provided | No                    | Yes           |
| **WAN Support**                    | Can backups be sent to a remote destination without keeping a local copy | Yes                   | Yes            | Yes                                        | Yes                   | Yes           |
| **WAN Support**                    | What other remote backends are supported ?                               | rclone                | (1)            | (2)                                        | None                  | (1)           |
| **Security**                       | Are encryption protocols secure (AES-256-GCM / PolyChaCha / etc ) ?      | Yes, AES-256-GCM      | Yes, AES-256   | Yes, AES-256-GCM or Chacha20Poly1305       | Yes, Chacha20Poly1305 | Yes, AES-256-GCM|
| **Security**                       | Are metadatas encrypted too ?                                            | ?                     | ?              | ?                                          | Yes                   | Yes           |
| **Security**                       | Can encrypted / compressed data be guessed (CRIME/BREACH style attacks)? | [No](https://github.com/borgbackup/borg/issues/3687)                    | ?              | ?                                          | No (4)                | ?             |
| **Security**                       | Can a compromised client delete backups?                                 | No (append mode)      | ?              | Supports optional object locking           | No (ssh restriction ) | No [pubkey](https://forum.duplicacy.com/t/new-feature-rsa-encryption/2662) + immutable targets|
| **Security**                       | Can a compromised client restore encrypted data?                         | Yes                   | ?              | ?                                          | No                    | No [pubkey](https://forum.duplicacy.com/t/new-feature-rsa-encryption/2662)           |
| **Security**                       | Are pull backup scenarios possible?                                      | Yes                   | No             | No                                         | No, planned           | ?             |
| **Misc**                           | Does the backup software support pre/post execution hooks?               | ?                     | ?              | Yes                                        | No                    | ?             |
| **Misc**                           | Does the backup software provide an API for their client ?               | Yes (JSON cmd)        | No, but REST API on server | No, but REST API on server     | No                    | No            |
| **Misc**                           | Does the backup sofware provide an automatic GFS system ?                | Yes                   | No             | Yes                                        | No                    | ?             |
| **Misc**                           | Does the backup sofware provide a crypto benchmark ?                     | No, available in beta | No             | Yes                                        | Undocumented          | No, (generic benchmark)[https://forum.duplicacy.com/t/benchmark-command-details/1078|
| **Misc**                           | Can a repo be synchronized to another repo ?                             | ?                     | ?              | Yes                                        | Yes                   | Yes           |

- (1) SFTP/S3/Wasabi/B2/Aliyun/Swift/Azure/Google Cloud
- (2) SFTP/Google Cloud/S3 and S3-compatible storage like Wasabi/B2/Azure/WebDav/rclone*
- (3) see https://bford.info/cachedir/
- (4) For bupstash, CRIME/BREACH style attacks are mitigated if you disable read access for backup clients, and keep decryption keys off server.


# Results

## 2022-09-06

### Source system: Xeon E3-1275, 64GB RAM, 2x SSD 480GB (for git dataset and local target), 2x4TB disks 7.2krpm (for bigger dataset), using XFS, running AlmaLinux 8.6
### Target system: AMD Turion(tm) II Neo N54L Dual-Core Processor (yes, this is old), 6GB RAM, 2x4TB WD RE disks 7.2krpm, using ZFS 2.1.5, running AlmaLinux 8.6

#### source data

Linux kernel sources, initial git checkout v5.19, then changed to v5.18, 4.18 and finally v3.10 for the last run.
Initial git directory totals 4.1GB, for 5039 directories and 76951 files. Using `env GZIP=-9 tar cvzf kernel.tar.gz /opt/backup_test/linux` produced a 2.8GB file. Again, using "best" compression with `tar cf - /opt/backup_test/linux | xz -9e -T4 -c - > kernel.tar.bz` produces a 2.6GB file, so there's probably big room for deduplication in the source files, even without running multiple consecutive backups on different points in time of the git repo.

Note: I removed restic_beta benchmark since restic 0.14.0 with compression support is officially released.

#### backup multiple git repo versions to local repositories

![image](https://user-images.githubusercontent.com/4681318/188726855-2813d297-3349-4849-9ac7-c58caa58a72d.png)

Numbers:
| Operation      | bupstash 0.11.0 | borg 1.2.2 | borg\_beta 2.0.0b1 | kopia 0.11.3 | restic 0.14.0 | duplicacy 2.7.2 |
| -------------- | --------------- | ---------- | ------------------ | ------------ | ------------- | --------------- |
| backup 1st run | 9               | 38         | 54                 | 9            | 23            | 30              |
| backup 2nd run | 13              | 21         | 25                 | 4            | 9             | 14              |
| backup 3rd run | 9               | 29         | 39                 | 7            | 18            | 24              |
| backup 4th run | 6               | 21         | 29                 | 5            | 13            | 16              |
| restore        | 3               | 17         | 16                 | 6            | 10            | 16              |
| size 1st run   | 213220          | 257224     | 259512             | 259768       | 260588        | 360160          |
| size 2nd run   | 375712          | 338792     | 341096             | 341060       | 343356        | 480392          |
| size 3rd run   | 538768          | 527716     | 531980             | 529788       | 532216        | 722420          |
| size 4th run   | 655764          | 660808     | 665692             | 666396       | 668840        | 895192          |

Remarks:
 - kopia was the best allround performer on local backups when it comes to speed, but is quite CPU intensive.
 - bupstash was the most space efficient tool (beats borg beta by about 1MB), and is not CPU hungry.
 - For the next instance, I'll need to post CPU / Memory / Disk IO usage graphs.
 
#### backup multiple git repo versions to remote repositories

- Remote repositories are SSH (+ binary) for bupstash and burp.
- Remote repositories is SFTP for duplicacy.
- Remote repository is HTTPS for kopia (kopia server with 2048 bit RSA certificate)
- Remote repository is HTTP for restic (rest-server 0.11.0)
- [Update] I've also redone the same tests in HTTPS with `--insecure-tls` which is documented on restic docs but not visible when using `restic --help`.

![image](https://user-images.githubusercontent.com/4681318/188742959-cb114ccd-0f03-47df-a07c-1d31ae8853a7.png)

Numbers:

| Operation      | bupstash 0.11.0 | borg 1.2.2 | borg\_beta 2.0.0b1 | kopia 0.11.3 | restic 0.14.0 | duplicacy 2.7.2 |
| -------------- | --------------- | ---------- | ------------------ | ------------ | ------------- | --------------- |
| backup 1st run | 23              | 62         | 64                 | 1186         | 17            | 107             |
| backup 2nd run | 16              | 25         | 29                 | 292          | 9             | 44              |
| backup 3rd run | 19              | 37         | 48                 | 904          | 14            | 60              |
| backup 4th run | 15              | 29         | 36                 | 800          | 11            | 47              |
| restore        | 161             | 255        | 269                | 279          | 20            | 1217            |
| size 1st run   | 250012          | 257534     | 260090             | 257927       | 262816        | 382572          |
| size 2nd run   | 443008          | 339276     | 341704             | 339181       | 346264        | 508655          |
| size 3rd run   | 633083          | 528482     | 532710             | 526723       | 536403        | 761362          |
| size 4th run   | 769681          | 661720     | 666588             | 662558       | 673989        | 941247          |

Remarks:
- Very bad restore results can be observed across all backup solutions (except restic), we'll need to investigate this:
    - Both links are monitored by dpinger, which shows no loss.
    - Target server, although being (really) old, has no observed bottlenecks (monitored, no iowait, disk usage nor cpu is skyrocketing)
- Since [last benchmark series](RESULTS-20220819.md), I changed Kopia's backend from SFTP to HTTPS. There must be a bottlebeck since backup times are really bad, but restore times improved.
    - I opened an issue at https://github.com/kopia/kopia/issues/2372 to see whether I configured kopia poorly.
	- CPU usage on target is quite intensive when backing up via HTTPS contrary to SFTP backend. I need to investigate.
- Since last benchmark series, I changed restic's backend from SFTP to HTTP. There's a *REALLY* big speed improvement, and numbers are comparable to local repositories.
    - I must add HTTPS encryption so we can compare what's comparable. [UPDATE]: Done, same results + or - a couple of seconds, table and image is updated
    - Indeed I checked that those numbers are really bound to remote repository, I can confirm, restic with rest-server is an all over winner when dealing with remote repositories.
- Strangely, the repo sizes of bupstash and duplicacy are quite larger than local repos for the same data, I discussed the subject at https://github.com/andrewchambers/bupstash/issues/26 .
    - I think this might be ZFS related. The remote target has a default recordsize of 128KB. I think I need to redo a next series of benchmarks with XFS as remote filesystem for repositories.


## EARLIER RESULTS

[2022-08-19](RESULTS-20220819.md)
 
#### Other stuff

- Getting restic SFTP to work with a different SSH port made me roam restic forums and try various setups. Didn't succeed in getting RESTIC_REPOSITORY variable to work with that configuration.
- duplicacy wasn't as easy to script as the other tools, since it modifies the source directory (by adding .duplicacy folder) so I had to exclude that one from all the other backup tools.
- The necessity for duplicacy to cd into the directory to backup/restore doesn't feel natural to me.

## Links

As of 6 September 2022, I've posted an issue to every backup program's git asking if they could review this benchmark repo:

- bupstash: https://github.com/andrewchambers/bupstash/issues/335
- restic: https://github.com/restic/restic/issues/3917
- borg: https://github.com/borgbackup/borg/issues/7007
- duplicacy: https://github.com/gilbertchen/duplicacy/issues/635
- kopia: https://github.com/kopia/kopia/issues/2375
