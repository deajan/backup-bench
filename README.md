# backup-bench
Quick and dirty backup tool benchmark with reproductible results

## What

This repo aims to compare different backup solutions among:

 - borg backup
 - bupstash
 - restic
 - kopia
 - duplicacy
 - your tool (PRs to support new backup tools are welcome)
 
 The idea is to have a script that executes all backup programs on the same datasets.
 
 We'll use a quite big (and popular) git repo as first dataset so results can be reproduced by checking out branches (and igoring .git directory).
 I'll also use another (not public) dataset which will be some qcow2 files which are in use.
 
 Time spent by the backup program is measured by the script so we get as accurate as possible results (time is measured from process beginning until process ends, with a 1 second scale).
 
 While backups are done, cpu/memory/disk metrics are saved so we know how "ressource hungry" a backup program can be.
 
All backup programs are setup to use SSH in order to compare their performance regardless of the storage backend.

When available, we'll tune the encryption algorithm depending on the results of a benchmark. For instance, kopia has a `kopia benchmark compression --data-file=/some/big/data/file` option to find out which compression / crypto works best on the current architecture.
This is *A REALLY NICE TO HAVE* when choices need to be made, aware of current architecture.
As of the current tests, Borg v2.0.0-b4 also has a `borg benchmark cpu` option.

## Why

I am currently using multiple backup programs to achieve my needs. As of today, I use Graham Keeling's burp https://github.com/grke/burp to backup windows machines, and borg backup to backup QEMU VM images. Graham decided to remove it's deduplication (protocol 2) and stick with rsync based backups (protocol 1), which isn't compatible with my backup strategies.
I've also tried out bupstash which I found to be quite quick, but which produces bigger backups when dealing with small files (probably because of the chunk size?).

Anyway, I am searching for a good allrounder, so I decided to give all the deduplication backup solutions a try, and since I am configuring them all, I thought why not make my results available to anyone, with a script so everything can be reproduced easily.

As of today I use the script on my lab hypervisor, which runs AlmaLinux 8.6, so my script has not been tailored to fit other distros (help is welcome).

I'll try to be as least biased as possible in order to make my backup tests.
If you feel that I didn't give a specific program enough attention, feel free to open an issue.

# Results

## 2022-08-17

### Script revision 2022-08-17
### Source system: Xeon , 64GB RAM, 2x SSD 480GB (for dataset 1), 2x4TB disks 7.2krpm (for dataset 2), using XFS, running AlmaLinux 8.6
### Target system: AMD Turion(tm) II Neo N54L Dual-Core Processor (yes, this is old), 6GB RAM, 2x4TB WD RE disks 7.2krpm, using ZFS 2.1.5, running AlmaLinux 8.6
