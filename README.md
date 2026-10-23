# sftp-mirror

Mirrors a remote SFTP location (for example a web space) to a local directory. The remote side is mounted read-only via `sshfs` and synchronized with `rsync`. Files that were deleted on the remote side are deleted in the mirror as well, protected by a plausibility check of the source and a limit on the number of deletions.

Typical use: a regular local backup of a hosted web space.

## How it works

1. Reads `sftp-mirror.config` and the secrets file, and checks their permissions (and the owner of the secrets file, which must be `root:root`) and the config version.
2. Takes a lock, so only one run is active at a time.
3. Mounts the remote directory read-only with `sshfs` (unless it is already mounted).
4. Checks that the source looks sane (a configured directory exists, or the source is not empty). If not, nothing is deleted and the run fails.
5. Runs `rsync` with `--delete` and a limit (`MAX_DELETE`).
6. Unmounts what it mounted and writes the marker file `last-successful` only if everything succeeded.

## Requirements

- Debian (current release), run as root (cron)
- `sshfs`, `fuse3`, `rsync`, `util-linux` (`flock`, `mountpoint`), `findutils`, `coreutils` (`timeout`)

```bash
sudo apt install sshfs fuse3 rsync
```

## Installation

Installation, configuration, log rotation, scheduling and a test run are described step by step in [INSTALL.md](INSTALL.md).

## Configuration

All settings are in `sftp-mirror.config`. The example file explains every parameter. The main ones:

| Parameter                                   | Meaning                                       | Default                                |
|---------------------------------------------|-----------------------------------------------|----------------------------------------|
| `CONFIG_VERSION`                            | Config format version, must match the script  | `1`                                    |
| `LOG_FILE`                                  | Log file                                      | `/var/log/sftp-mirror/sftp-mirror.log` |
| `MARKER_FILE`                               | Marker file for monitoring                    | `<script dir>/last-successful`         |
| `LOCK_FILE`                                 | Lock file                                     | `/run/lock/sftp-mirror.lock`           |
| `SECRETS_FILE`                              | Secrets file                                  | `/root/.secrets/sftp-mirror.secrets`   |
| `REMOTE_HOST`, `REMOTE_PORT`, `REMOTE_PATH` | SFTP server, port, directory to mirror        | `-`, `22`, `/`                         |
| `SSH_KEY_FILE`                              | Private key for key authentication (optional) | empty                                  |
| `SSHFS_OPTIONS`                             | Options for `sshfs`                           | read-only, reconnect, keepalive        |
| `MOUNT_POINT`                               | Local mount point for the remote side         | `-`                                    |
| `MIRROR_DIR`                                | Local mirror directory                        | `-`                                    |
| `SANITY_CHECK_PATH`                         | Directory that must exist on the remote side  | empty (source must not be empty)       |
| `MAX_DELETE`                                | Maximum deletions per run                     | `500`                                  |
| `RSYNC_TIMEOUT`                             | rsync I/O timeout in seconds                  | `300`                                  |
| `RSYNC_EXCLUDES`                            | Paths that are not mirrored (bash array)      | empty                                  |

Credentials (`REMOTE_USER`, `REMOTE_PASSWORD`) live in the secrets file, never in the config. The config and secrets files are ignored by Git (see `.gitignore`).

## Usage

```
sftp-mirror.sh [--dry-run] [--help]
```

- `--dry-run`: runs the mount, the checks and `rsync --dry-run`. The mirror is not changed and no marker file is written.
- `--help`: shows the usage text.

The log contains one line per event with timestamp and level, a `START` line with the script version and an `END (exit N)` line for every run. The per-file lines written by `rsync` itself have rsync's own timestamp format.

## Exit codes

| Code | Meaning                                                                                         |
|------|-------------------------------------------------------------------------------------------------|
| 0    | Success                                                                                         |
| 1    | General error                                                                                   |
| 2    | Wrong command line option                                                                       |
| 3    | Config or secrets error (missing, wrong permissions, wrong `CONFIG_VERSION`, missing directory) |
| 4    | Already running (lock)                                                                          |
| 5    | Mount failed                                                                                    |
| 6    | Source plausibility check failed                                                                |
| 7    | rsync failed (including reaching `MAX_DELETE`)                                                  |

rsync exit code 24 (files vanished during the run) counts as success and is logged as a warning.

## Monitoring

After every fully successful run the script overwrites the marker file `last-successful` (default: next to the script) with a timestamp. It is never written after a failure or a dry run. Monitor the age of this file, for example with an RMM check, and raise an alarm when it is older than the expected interval plus a margin.