# version 2022090601

- Converted restic HTTP backend to HTTPS

# version 2022090501

- Improved bupstash, borg, kopia, restic and duplicacy install process by downloading github releases instead of various installation scenarios
- Removed restic_beta since new restic release 0.14.0 now has compression support
- Added kopia HTTPS backend
  - Added RSA certificate generator
- Added restic HTTP backend
- Added new --config parameter to load different config files
- Increased backup benchmark timeout from 5 to 10 hours
- Added new --stop-http-serve parameter to kill kopia and restic servers
- Lots of small fixes

What isn't tested:
- Failed commands that should stop execution (failed SSH copies, failed repo inits)

What could be improved:
- Check for SELinux labels before relabeling so we don't get errors (cosmetic only)
- Check for existing user directories before creating them so we don't get errors (cosmetic only)

# version 2022081901

- Initial version
