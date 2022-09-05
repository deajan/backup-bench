# version 2022090501

- Improved bupstash, borg, kopia, restic and duplicacy install process by downloading github releases instead of various installation scenarios
- Removed restic_beta since new restic release 0.14.0 now has compression support
- Added kopia HTTP backend
  - Added RSA certificate generator
- Added restic HTTP backend
- Added new --config parameter to load different config files
- Increased backup benchmark timeout from 5 to 10 hours

# version 2022081901

- Initial version
