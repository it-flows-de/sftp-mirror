# Installation

Step-by-step setup of `sftp-mirror` on a Debian server. Work as a normal user, `sudo` is used wherever root is needed. The script itself runs as root.

Paths below use the defaults and the example values from `sftp-mirror.config.example`. Adjust them if your config differs.

1. [Requirements](#1-requirements)
2. [Files and directories](#2-files-and-directories)
3. [Config and secrets](#3-config-and-secrets)
4. [Log rotation](#4-log-rotation)
5. [Test](#5-test)
6. [Scheduling](#6-scheduling)
7. [Monitoring](#7-monitoring)
8. [Troubleshooting](#troubleshooting)

---

## 1. Requirements

```bash
sudo apt install sshfs fuse3 rsync
which sshfs fusermount3 rsync flock mountpoint timeout
```

## 2. Files and directories

### Script directory

`/usr/local/scripts` is handed to your normal user once per server. Everything you create in it belongs to you and needs no `sudo`:

```bash
sudo mkdir -p /usr/local/scripts
sudo chown "$USER": /usr/local/scripts
```

Note: the script runs as root (cron). Whoever can write to this directory can have code executed as root. On servers with other users, check that this is acceptable.

### Script files

```bash
mkdir -p /usr/local/scripts/sftp-mirror
cd /usr/local/scripts/sftp-mirror
touch sftp-mirror.sh sftp-mirror.config.example sftp-mirror.secrets.example .gitignore README.md INSTALL.md
chmod 755 sftp-mirror.sh
```

Then fill the files with the content from this repository.

### Other directories

The mount point and the mirror directory are deliberately **not** created by the script. If the backup disk is not mounted, the script would otherwise fill the wrong disk. Check first that the parent path is the right disk:

```bash
findmnt /mnt/backup
sudo mkdir -p /mnt/backup/remote /mnt/backup/mirror
```

The mount point must stay empty. Log and secrets directories:

```bash
sudo mkdir -p /var/log/sftp-mirror /root/.secrets
sudo chmod 700 /root/.secrets
```

## 3. Config and secrets

### Config

```bash
cd /usr/local/scripts/sftp-mirror
cp sftp-mirror.config.example sftp-mirror.config
vi sftp-mirror.config
chmod 660 sftp-mirror.config
```

Set at least the required values in block 1 (`REMOTE_HOST`, `REMOTE_PATH`, `MOUNT_POINT`, `MIRROR_DIR`, `SANITY_CHECK_PATH`). The file explains every parameter. Everything else can stay at the default.

### Secrets

The secrets file lives in the root directory and is owned by root. The file is read with `source`, so put each value in single quotes. A single quote inside a value is written as `'\''`:

```bash
sudo cp sftp-mirror.secrets.example /root/.secrets/sftp-mirror.secrets
sudo vi /root/.secrets/sftp-mirror.secrets
sudo chown root:root /root/.secrets/sftp-mirror.secrets
sudo chmod 600 /root/.secrets/sftp-mirror.secrets
```

The path of the secrets file comes from `SECRETS_FILE` in the config.

## 4. Log rotation

Create `/etc/logrotate.d/sftp-mirror`:

```bash
sudo vi /etc/logrotate.d/sftp-mirror
```

```
/var/log/sftp-mirror/sftp-mirror.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 660 root adm
}
```

Set the rights and test (dry run, changes nothing):

```bash
sudo chown root:root /etc/logrotate.d/sftp-mirror
sudo chmod 644 /etc/logrotate.d/sftp-mirror
sudo logrotate -d /etc/logrotate.d/sftp-mirror
```

The script appends every run to one log file. logrotate rotates it daily and keeps 30 generations.

## 5. Test

The script runs as root, also when started by hand.

### Help and dry run

```bash
/usr/local/scripts/sftp-mirror/sftp-mirror.sh --help
sudo /usr/local/scripts/sftp-mirror/sftp-mirror.sh --dry-run
echo "Exit: $?"
sudo tail -n 30 /var/log/sftp-mirror/sftp-mirror.log
```

Expected: `Exit: 0`. The log shows `START`, `Mounting ...`, `Dry run: the mirror will not be changed`, `OK` and `END (exit 0)`. No `last-successful` file is created.

Check that nothing stays mounted:

```bash
mount | grep sshfs
```

Expected: no output.

### Real run

The first run transfers everything and can take a while, depending on the size of the source.

```bash
sudo /usr/local/scripts/sftp-mirror/sftp-mirror.sh
echo "Exit: $?"
sudo tail -n 30 /var/log/sftp-mirror/sftp-mirror.log
cat /usr/local/scripts/sftp-mirror/last-successful
```

Expected: `Exit: 0` and a timestamp in `last-successful`.

### Error case (optional)

```bash
# Config with wrong rights: exit 3
chmod 664 /usr/local/scripts/sftp-mirror/sftp-mirror.config
sudo /usr/local/scripts/sftp-mirror/sftp-mirror.sh --dry-run; echo "Exit: $?"
chmod 660 /usr/local/scripts/sftp-mirror/sftp-mirror.config
```

## 6. Scheduling

Add the entry to the root crontab. **Do not run at midnight**, logrotate runs then:

```bash
sudo crontab -e
```

```
# sftp-mirror: daily at 02:30
30 2 * * * /usr/local/scripts/sftp-mirror/sftp-mirror.sh >> /var/log/sftp-mirror/sftp-mirror.log 2>&1
```

The redirect catches errors that happen before the config is loaded (missing config, wrong rights). At that point `LOG_FILE` is not known yet and the script writes to stderr. If you change `LOG_FILE` in the config, adjust the path here as well.

## 7. Monitoring

Monitor the age of `/usr/local/scripts/sftp-mirror/last-successful`, for example with an RMM check. Maximum age: run interval plus a margin (for a daily run, e.g. 26 to 30 hours).

---

## Troubleshooting

| Exit | Cause                                                                                                                                     | What to do                                                                   |
|------|-------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| 3    | Config or secrets missing, wrong rights, wrong owner of the secrets file, wrong `CONFIG_VERSION`, mount point or mirror directory missing | Read the message in the log, run `ls -l` on the file it names                |
| 4    | Another instance is running                                                                                                               | `pgrep -af sftp-mirror`, end a hanging run                                   |
| 5    | Mount failed                                                                                                                              | Check credentials, host, port; the sshfs error message is in the log         |
| 6    | Source plausibility check failed                                                                                                          | `SANITY_CHECK_PATH` is wrong or the source is empty; **nothing** was deleted |
| 7    | rsync error or `MAX_DELETE` reached                                                                                                       | Read the log; if many deletions are intended, raise `MAX_DELETE` once        |

A stale mount after a crash is cleaned up by the next run. By hand:

```bash
sudo fusermount3 -uz /mnt/backup/remote
```