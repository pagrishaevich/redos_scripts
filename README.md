# redos_scripts

Utility scripts for RED OS 8 administration.

## Included scripts

- `mount_folders_redos8.sh` - creates local bind mounts and persists them in `/etc/fstab`.

## Usage

1. Edit mount pairs in `MOUNTS` inside `mount_folders_redos8.sh`.
2. Run with root privileges:

```bash
sudo ./mount_folders_redos8.sh
```

The script creates a timestamped backup of `/etc/fstab`, updates missing mount entries, mounts folders immediately, and validates configuration via `mount -a`.

## Notes

- Test on a non-production host first.
- Keep a console session open while applying mount changes.
- If needed, restore backup from `/etc/fstab.bak.YYYY-MM-DD_HH-MM-SS`.
