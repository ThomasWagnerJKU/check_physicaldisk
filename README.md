# check_physicaldisk

A Nagios/Icinga plugin for Windows that checks the health of a server's
physical disks with Windows' own storage cmdlets (`Get-PhysicalDisk`,
`Get-StorageReliabilityCounter`). PowerShell 5.1, no extra software; runs via
SNClient/NSClient++ as LocalSystem.

For every physical disk it checks the health and operational status Windows
reports and, where the disk provides them, temperature, wear (SSD/NVMe) and
uncorrected read/write errors.

## Usage

```
check_physicaldisk.ps1
check_physicaldisk.ps1 55 65
check_physicaldisk.ps1 60 70 80 90 "1,3"
```

```
OK - all healthy [4 disk(s): 0 BROADCOM MR9580-8i8e [RAID], 1 BROADCOM MR9580-8i8e [RAID], 2 Samsung SSD 990 PRO 1TB, 3 Samsung SSD 990 PRO 1TB] | disks=4 'disk2_temp'=44;60;70 'disk2_wear'=0%;80;90;0;100 'disk3_temp'=45;60;70 'disk3_wear'=0%;80;90;0;100
```

Parameters, in this order:

| Parameter | Meaning |
|---|---|
| `TempWarn` | Disk temperature warning in °C (default: 60) |
| `TempCrit` | Disk temperature critical in °C (default: 70) |
| `WearWarn` | SSD/NVMe wear warning, in percent of rated endurance used (default: 80) |
| `WearCrit` | SSD/NVMe wear critical (default: 90) |
| `Exclude` | Comma-separated disk numbers (DeviceId) to skip, e.g. `"1,3"` (default: none) |

SNClient passes arguments quoted, so named parameters (`-TempWarn 55`) don't
bind there; give them positionally. An empty argument (`""`) doesn't survive
SNClient's quoting, so to set `Exclude`, give all four thresholds before it.

With SNClient, put the script into `scripts\autoinclude\`, where it is
registered automatically. Reading the reliability counters needs
administrator rights (SNClient's default LocalSystem is fine).

### Disks behind a hardware RAID controller

Windows only sees a RAID controller's virtual disks (bus type `RAID`), not the
drives behind them. They are listed with `[RAID]` and only their health and
operational status are checked; monitor the real drives with the controller's
tool, e.g. [check_storcli](https://github.com/ThomasWagnerJKU/check_storcli)
for Broadcom/LSI MegaRAID.

## States

- **CRITICAL**: a disk's health is `Unhealthy`; its operational status is
  `Predictive Failure`, `Lost Communication`, `No Contact`, `Error`,
  `Non-Recoverable Error`, `Not Ready`, `Aborted` or `Removing`; its
  temperature or wear is at or above the critical threshold
- **WARNING**: a disk's health is `Warning`; any other operational status
  than `OK` (e.g. `Degraded`, `Stressed`, `In Maintenance`); uncorrected read
  or write errors; temperature or wear at or above the warning threshold
- **UNKNOWN**: health `Unknown`, no disks found, `Get-PhysicalDisk` fails, or
  an argument is invalid

Problems are listed in the output, worst state wins (UNKNOWN ranks between
WARNING and CRITICAL). The plugin prints exactly one line.

### Performance data

- `disks`: number of disks checked
- `diskN_temp`: temperature in °C, with the thresholds
- `diskN_wear`: wear in percent (not for HDDs), with the thresholds
- `diskN_read_err`, `diskN_write_err`: uncorrected read/write errors

A value the disk doesn't report is left out.

## Tests

None automated: the plugin depends on Windows' storage cmdlets.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
