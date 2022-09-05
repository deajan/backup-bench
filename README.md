# backup-bench
Quick and dirty backup tool benchmark with reproductible results

** This is a one page entry with benchmarks (see below), previous versions are available via git versionning.**

## What

This repo aims to compare different backup solutions among:

 - [borg backup](https://www.borgbackup.org)
 - [bupstash](https://bupstash.io)
 - [restic](https://restic.net)
 - [kopia](https://www.kopia.io)
 - [duplicacy](https://duplicacy.com)
 - your tool (PRs to support new backup tools are welcome)
 
 The idea is to have a script that executes all backup programs on the same datasets.
 
 We'll use a quite big (and popular) git repo as first dataset so results can be reproduced by checking out branches (and igoring .git directory).
 I'll also use another (not public) dataset which will be some qcow2 files which are in use.
 
 Time spent by the backup program is measured by the script so we get as accurate as possible results (time is measured from process beginning until process ends, with a 1 second granularity).

 While backups are done, cpu/memory/disk metrics are saved so we know how "ressource hungry" a backup program can be.
 
All backup programs are setup to use SSH in order to compare their performance regardless of the storage backend.

When available, we'll tune the encryption algorithm depending on the results of a benchmark. For instance, kopia has a `kopia benchmark compression --data-file=/some/big/data/file` option to find out which compression / crypto works best on the current architecture.
This is *A REALLY NICE TO HAVE* when choices need to be made, aware of current architecture.
As of the current tests, Borg v2.0.0-b1 also has a `borg benchmark cpu` option.

## Why

I am currently using multiple backup programs to achieve my needs. As of today, I use Graham Keeling's burp https://github.com/grke/burp to backup windows machines, and borg backup to backup QEMU VM images. Graham decided to remove it's deduplication (protocol 2) and stick with rsync based backups (protocol 1), which isn't compatible with my backup strategies.
I've also tried out bupstash which I found to be quite quick, but which produces bigger backups remotely when dealing with small files (probably because of the chunk size?).

Anyway, I am searching for a good allrounder, so I decided to give all the deduplication backup solutions a try, and since I am configuring them all, I thought why not make my results available to anyone, with a script so everything can be reproduced easily.

As of today I use the script on my lab hypervisor, which runs AlmaLinux 8.6, so my script has not been tailored to fit other distros (help is welcome).

I'll try to be as least biased as possible in order to make my backup tests.
If you feel that I didn't give a specific program enough attention, feel free to open an issue.

# In depth comparaison of backup solutions

Last update: 19 Aug 2022

|Backup software|Version|
|------------------|--------|
|borg|1.2.1|
|borg beta|2.0.0b1|
|restic|0.13.1|
|restic beta|0.13.1-dev|
|kopia|0.11.3|
|bupstash|0.11.0|
|duplicacy|2.7.2|

The following list is my personal shopping list when it comes to backup solutions, and might not be complete, you're welcome to provide PRs to update it ;)

|Goal|Functionality|borg|restic|kopia|bupstash|duplicacy|
|-----|---------------|-----|------|------|----------|-------|
|Reliability|Redundant index copies| ?|?|Yes|?|?|
|Reliability|Continue restore on bad blocks|?|?|?|?|?|
|Reliability|Data checksumming|Yes (CRC & HMAC)|?|?|?|?|
|Reliability|Language memory safety|No (python)|No (go)|No (go)|Yes (rust)|No (go)|
|Restoring Data|Backup mounting as filesystem|Yes|Yes|Yes|No|?|
|File management|File includes / excludes bases on regexes|?|?|?|?|?|
|File management|Supports backup XATTRs|Yes|?|No|Yes|?|
|File management|Supports backup ACLs|Yes|?|No|Yes|?|
|File management|Automatically excludes CACHEDIR.TAG(3) directories|No|Yes|Yes|No|?|
|Dedup & compression efficience|Is data compressed|Yes|No, available beta|Yes|Yes|
|Dedup & compression efficience|Uses newer compression algorithms (ie zstd)|Yes|No, available in beta|Yes|Yes|Yes|
|Dedup & compression efficience|Can files be excluded from compression|?|No|Yes|No|No|
|Dedup & compression efficience|Is data deduplicated|Yes|No, available beta|Yes|Yes|
|Platform support|Unix Prebuilt binaries|Yes|Yes|Yes|No|Yes|
|Platform support|Windows support|Yes (WSL)|Yes|Yes|No|Yes|
|Platform support|Windows first class support (PE32 binary)|No|Yes|Yes|No|Yes|
|Platform support|Unix snapshot support where snapshot path prefix is removed|?|?|?|?|?|
|Platform support|Windows VSS snapshot support where snapshot path prefix is removed|No|Yes|No, but pre-/post hook VSS script provided|No|Yes|
|WAN Support|Can backups be sent to a remote destination without keeping a local copy|Yes|Yes|Yes|Yes|Yes|
|WAN Support|What other remote backends are supported ?|rclone|(1)|(2)|None|(1)|
|WAN Support|Can the protocol pass UTM firewall appliances with layer 7 filter|Yes|Yes|Yes|Yes|Yes|
|Security|Are encryption protocols sure (AES-256-GCM / PolyChaCha) ?|Yes|?|?|Yes|?|
|Security|Can encrypted / compressed data be guessed (CRIME/BREACH style attacks)?|?|?|?|?|?|
|Security|Can a compromised client delete backups?|No (append mode)|?|?|No|?|
|Security|Can a compromised client restore encrypted data?|Yes|?|?|No|Yes|
|Security|Are pull backup scenarios possible?|Yes|No|?|?|?|
|Misc|Does the backup software support pre/post execution hooks?|?|?|Yes|No|?|
|Misc|Does the backup software provide an API ?|Yes (JSON cmd)|Yes (REST API)|?|No|No|
|Misc|Does the backup sofware provide an automatic GFS system ?|Yes|No|Yes|No|?|
|Misc|Does the backup sofware provide a crypto benchmark ?|No, available in beta|No|Yes|No|No|

(1) SFTP/S3/Wasabi/B2/Aliyun/Swift/Azure/Google
(2) SFTP/Google/S3/B2/rclone*
(3) see https://bford.info/cachedir/

# Results

## 2022-08-19

### Source system: Xeon E3-1275, 64GB RAM, 2x SSD 480GB (for git dataset and local target), 2x4TB disks 7.2krpm (for bigger dataset), using XFS, running AlmaLinux 8.6
### Target system: AMD Turion(tm) II Neo N54L Dual-Core Processor (yes, this is old), 6GB RAM, 2x4TB WD RE disks 7.2krpm, using ZFS 2.1.5, running AlmaLinux 8.6

#### source data

Linux kernel sources, initial git checkout v5.19, then changed to v5.18, 4.18 and finally v3.10 for the last run.
Initial git directory totals 4.1GB, for 5039 directories and 76951 files. Using `env GZIP=-9 tar cvzf kernel.tar.gz /opt/backup_test/linux` produced a 2.8GB file. Again, using "best" compression with `tar cf - /opt/backup_test/linux | xz -9e -T4 -c - > kernel.tar.bz` produces a 2.6GB file, so there's probably big room for deduplication in the source files, even without running multiple consecutive backups on different points in time of the git repo.

#### backup multiple git repo versions to local repositories
![image](https://user-images.githubusercontent.com/4681318/185691430-d597ecd1-880e-474b-b015-27ed6a02c7ea.png)

Numbers:
| Operation      | bupstash 0.11.0 | borg 1.2.1 | borg\_beta 2.0.0b1 | kopia 0.11.3 | restic 0.13.1 | restic\_beta 0.13.1-dev | duplicacy 2.7.2 |
| -------------- | --------------- | ---------- | ------------------ | ------------ | ------------- | ----------------------- | --------------- |
| backup 1st run | 9               | 38         | 54                 | 9            | 22            | 24                      | 30              |
| backup 2nd run | 13              | 19         | 23                 | 4            | 8             | 9                       | 12              |
| backup 3rd run | 8               | 25         | 37                 | 7            | 16            | 17                      | 21              |
| backup 4th run | 6               | 18         | 26                 | 6            | 13            | 13                      | 16              |
| restore        | 3               | 15         | 17                 | 6            | 7             | 9                       | 17              |
| size 1st run   | 213208          | 257256     | 259600             | 259788       | 1229540       | 260488                  | 360244          |
| size 2nd run   | 375680          | 338796     | 341488             | 341088       | 1563592       | 343036                  | 480888          |
| size 3rd run   | 538724          | 527808     | 532256             | 529804       | 2256348       | 532512                  | 723556          |
| size 4th run   | 655712          | 660896     | 665864             | 666408       | 2732740       | 669124                  | 896312          |

Remarks:
- It seems that current stable restic version (without compression) uses huge amounts of disk space, hence the test with current restic beta that supports compression.
- kopia was the best allround performer on local backups when it comes to speed
- bupstash was the most space efficient tool (beats borg beta by about 1MB)

#### backup multiple git repo versions to remote repositories
![image](https://user-images.githubusercontent.com/4681318/185691444-b57ec8dc-9221-46d4-bbb6-94e1f6471d9e.png)

Remote repositories are SSH (+ binary) for bupstash and burp.
Remote repositories are SFTP for kopia, restic and duplicacy.

Numbers:
| Operation      | bupstash 0.11.0 | borg 1.2.1 | borg\_beta 2.0.0b1 | kopia 0.11.3 | restic 0.13.1 | restic\_beta 0.13.1-dev | duplicacy 2.7.2 |
| -------------- | --------------- | ---------- | ------------------ | ------------ | ------------- | ----------------------- | --------------- |
| backup 1st run | 22              | 44         | 63                 | 101          | 764           | 86                      | 116             |
| backup 2nd run | 15              | 22         | 30                 | 59           | 229           | 33                      | 42              |
| backup 3rd run | 16              | 32         | 47                 | 61           | 473           | 76                      | 76              |
| backup 4th run | 13              | 25         | 35                 | 68           | 332           | 55                      | 53              |
| restore        | 172             | 251        | 256                | 749          | 1451          | 722                     | 1238            |
| size 1st run   | 250098          | 257662     | 259710             | 268300       | 1256836       | 262960                  | 378792          |
| size 2nd run   | 443119          | 339276     | 341836             | 352507       | 1607666       | 346000                  | 505072          |
| size 3rd run   | 633315          | 528738     | 532970             | 547279       | 2312586       | 536675                  | 756943          |
| size 4th run   | 770074          | 661848     | 666848             | 688184       | 2801249       | 674189                  | 936291          |

Remarks:
- Very bad restore results can be observed across all backup solutions, we'll need to investigate this:
    - Both links are monitored by dpinger, which shows no loss
    - Target server, although being (really) old, has no observed bottlenecks (monitored, no iowait, disk usage nor cpu is skyrocketing)
- kopia, restic and duplicacy seem to not cope well SFTP, whereas borg and bupstash are advantaged since they run a ssh deamon on the target
    - I have chosen to use SFTP to make sure ssh overhead is similar between all solutions
    - It would be a good idea to setup kopia and restic HTTP servers and redo the remote repository tests
- Strangely, the repo sizes of bupstash and duplicacy are quite larger than local repos for the same data, probably because of some chunking algorithm that changes chuck sizes depending on transfer rate or so ? That could be discussed by the solution's developers.

#### Notes
Disclaimers:
- The script has run on a lab server that hold about 10VMs. I've made sure that CPU/MEM/DISK WAIT stayed the same between all backup tests, nevertheless, some deviances may have occured while measuring.
- Bandwidth between source and target is 1Gbit/s theoretically. Nevertheless, I've made a quick iperf3 test to make sure that bandwidth is available between both servers.

`iperf3 -c targetfqdn` results
```
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.00  sec   545 MBytes   457 Mbits/sec   23             sender
[  5]   0.00-10.04  sec   544 MBytes   455 Mbits/sec                  receiver
```
`iperf3 -c targetfqdn -R` results
```
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.04  sec   530 MBytes   443 Mbits/sec  446             sender
[  5]   0.00-10.00  sec   526 MBytes   442 Mbits/sec                  receiver
```
- Deterministic results cannot be achieved since too much external parameters come in when running the benchmarks. Nevertheless, the systems are monitored, and the tests were done when no cpu/ram/io spikes where present, and no bandwidth problem was detected.

#### Other stuff

Getting restic SFTP to work with a different SSH port made me roam restic forums and try various setups. Didn't succeed in getting RESTIC_REPOSITORY variable to work with that configuration.
On a personal note, I didn't really enjoy duplicacy because it tampers with the data to backup (adds .duplicacy folder) which has to be excluded from all other tools.
The necessity to cd to the directory to backup/restore doesn't really enchant me to write scripts. Also, configuring one active repo wasn't easy to deal within the script.
It has needed some good debugging time to get duplicacy to play nice with the rest of the script.

