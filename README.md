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
| **Reliability**                    | Continue restore on bad blocks in repository                             | ?                     | ?              | Yes (can ignore errors when restoring)     | No                    | Yes, [erasure coding](https://forum.duplicacy.com/t/new-feature-erasure-coding/4168)|
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
| **Misc**                           | Does the backup sofware provide a crypto benchmark ?                     | No, available in beta | No             | Yes                                        | Undocumented          | No, [generic benchmark](https://forum.duplicacy.com/t/benchmark-command-details/1078)|
| **Misc**                           | Can a repo be synchronized to another repo ?                             | ?                     | ?              | Yes                                        | Yes                   | Yes           |

- (1) SFTP/S3/Wasabi/B2/Aliyun/Swift/Azure/Google Cloud
- (2) SFTP/Google Cloud/S3 and S3-compatible storage like Wasabi/B2/Azure/WebDav/rclone*
- (3) see https://bford.info/cachedir/
- (4) For bupstash, CRIME/BREACH style attacks are mitigated if you disable read access for backup clients, and keep decryption keys off server.


# Results

## 2022-10-02

### Used system specs

- Source system: Xeon E3-1275, 64GB RAM, 2x SSD 480GB (for git dataset and local target), 2x4TB disks 7.2krpm (for bigger dataset), using XFS, running AlmaLinux 8.6
- Remote target system: AMD Turion(tm) II Neo N54L Dual-Core Processor (yes, this is old), 6GB RAM, 2x4TB WD RE disks 7.2krpm using ZFS 2.1.5, 1x 1TB WD Blue using XFS, running AlmaLinux 8.6

- Target system has a XFS filesystem as target for the linux kernel backup tests
- Target system has a ZFS filesystem as target for the qemu backup tests (not published yet). ZFS has been configured as follows:
    - `zfs set xattr=off backup`
	- `zfs set compression=off backup`  # Since we already compress, we don't want to add another layer here
	- `zfs set atime=off backup`
	- `zfs set recordsize=1M backup`    # This could be tuned as per backup program...


#### source data

Linux kernel sources, initial git checkout v5.19, then changed to v5.18, 4.18 and finally v3.10 for the last run.
Initial git directory totals 4.1GB, for 5039 directories and 76951 files. Using `env GZIP=-9 tar cvzf kernel.tar.gz /opt/backup_test/linux` produced a 2.8GB file. Again, using "best" compression with `tar cf - /opt/backup_test/linux | xz -9e -T4 -c - > kernel.tar.bz` produces a 2.6GB file, so there's probably big room for deduplication in the source files, even without running multiple consecutive backups on different points in time of the git repo.

Note: I removed restic_beta benchmark since restic 0.14.0 with compression support is officially released.

#### backup multiple git repo versions to local repositories

![image](https://user-images.githubusercontent.com/4681318/193457878-3f9816d0-9853-42bf-a9f7-59c0560b9fe4.png)

Numbers:
| Operation      | bupstash 0.11.1 | borg 1.2.2 | borg\_beta 2.0.0b2 | kopia 0.12.0 | restic 0.14.0 | duplicacy 2.7.2 |
| -------------- | --------------- | ---------- | ------------------ | ------------ | ------------- | --------------- |
| backup 1st run | 9               | 41         | 55                 | 10           | 23            | 32              |
| backup 2nd run | 11              | 22         | 25                 | 4            | 8             | 13              |
| backup 3rd run | 7               | 28         | 39                 | 7            | 17            | 23              |
| backup 4th run | 5               | 20         | 29                 | 6            | 13            | 16              |
| restore        | 4               | 16         | 17                 | 5            | 9             | 11              |
| size 1st run   | 213268          | 257300     | 265748             | 259780       | 260520        | 360200          |
| size 2nd run   | 375776          | 338760     | 348248             | 341088       | 343060        | 480600          |
| size 3rd run   | 538836          | 527732     | 543432             | 529812       | 531892        | 722176          |
| size 4th run   | 655836          | 660812     | 680092             | 666408       | 668404        | 894984          |

Remarks:
 - kopia was the best allround performer on local backups when it comes to speed, but is quite CPU intensive.
 - bupstash was the most space efficient tool and is not CPU hungry.
 - For the next instance, I'll need to post CPU / Memory / Disk IO usage graphs from my Prometheus instance.
 
#### backup multiple git repo versions to remote repositories

- Remote repositories are SSH (+ binary) for bupstash and burp.
- Remote repository is SFTP for duplicacy.
- Remote repository is HTTPS for kopia (kopia server with 2048 bit RSA certificate)
- Remote repository is HTTPS for restic (rest-server 0.11.0 with 2048 bit RSA certificate)

![image](https://user-images.githubusercontent.com/4681318/193457882-7228cba5-5ed3-4ffa-b2e0-4b863ef78df0.png)

Numbers:

| Operation      | bupstash 0.11.1 | borg 1.2.2 | borg\_beta 2.0.0b2 | kopia 0.12.0 | restic 0.14.0 | duplicacy 2.7.2 |
| -------------- | --------------- | ---------- | ------------------ | ------------ | ------------- | --------------- |
| backup 1st run | 10              | 47         | 67                 | 72           | 24            | 32              |
| backup 2nd run | 12              | 25         | 30                 | 32           | 10            | 15              |
| backup 3rd run | 9               | 36         | 47                 | 54           | 19            | 23              |
| backup 4th run | 7               | 31         | 50                 | 46           | 21            | 23              |
| restore        | 170             | 244        | 243                | 258          | 28            | 940             |
| size 1st run   | 213240          | 257288     | 265716             | 255852       | 260608        | 360224          |
| size 2nd run   | 375720          | 338720     | 348260             | 336440       | 342848        | 480856          |
| size 3rd run   | 538780          | 527620     | 543204             | 522512       | 531820        | 722448          |
| size 4th run   | 655780          | 660708     | 679868             | 657196       | 668436        | 895248          |

Remarks:
- With restic's recent release 0.14.0, the remote speeds using rest-server increased dramatically and are onpar with local backup results.
- All other programs take about 5-10x more time to restore than the initial backup, except for duplicacy, which has a 30x factor which is really bad
- Since [last benchmark series](RESULTS-20220906.md), kopia 0.2.0 was released which resolves the [remote bottleneck](https://github.com/kopia/kopia/issues/2372)
- I finally switchted from ZFS to XFS remote filesystem so we have comparable file sizes between local and remote backups

As I did the backup benchmarks, I computed the average size of the files in each repository using
```
find /path/to/repository -type f -printf '%s\n' | awk '{s+=$0}
  END {printf "Count: %u\nAverage size: %.2f\n", NR, s/NR}'
```

Results for the linux kernel sources backups:
| Software | Original sizes | bupstash 0.11.1 | borg 1.2.2 | borg\_beta 2.0.0b2 | kopia 0.12 | restic 0.14.0 | duplicacy 2.7.2 |
| File count | 61417 | 2727 | 12 | 11 | 23 | 14 | 89 |
| Avg file size (kb) | 62 | 42 | 12292 | 13839 | 6477 | 10629 | 2079 |

I also computed the average file siezs in each repository for my private qemu images which I backup with all the tools using backup-bench.

Results for the qemu images backups:
| Software | Original sizes | bupstash 0.11.1 | borg 1.2.2 | borg\_beta 2.0.0b2 | kopia 0.12 | restic 0.14.0 | duplicacy 2.7.2 |
| File count | 15 | 136654 | 239 | 267 | 6337 | 66000 | 41322 |
| Avg file size (kb) | 26177031 | 850 | 468088 | 469933 | 22030 | 17344875 | 3838 |

Interesting enough, bupstash is the only software that produces sub megabyte chunks. Of the above 136654 files, only 39443 files weight more than 1MB.
The qemu disk images are backed up to a ZFS filesystem with recordsize=1M.
In order to measure the size difference, I created a ZFS filesystem with a 128k recordsize, and copied the bupstash repo to that filesystem.
This resulted in bupstash repo size being 12% smaller.

I'll publish the results the benchmark results of my qemu disk image backup benchmarks in next round.

## EARLIER RESULTS

- [2022-09-06](RESULTS-20220906.md)
- [2022-08-19](RESULTS-20220819.md)
 
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
