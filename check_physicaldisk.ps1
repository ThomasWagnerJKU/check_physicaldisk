# Nagios/Icinga plugin (Windows, e.g. via SNClient/NSClient++) to check the health of
# a server's physical disks with Windows' own storage cmdlets.
#
# Copyright (C) 2026 Thomas Wagner <thomas.wagner@jku.at>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
  Nagios/snclient check for physical disk health (Get-PhysicalDisk, Get-StorageReliabilityCounter).

.DESCRIPTION
  For every physical disk Windows sees: health status, operational status and, where
  the disk reports them, temperature, wear (SSD/NVMe) and uncorrected read/write errors.
  Disks behind a hardware RAID controller (bus type RAID) are the controller's virtual
  disks; they are listed, but only their health/operational status is checked
  (monitor the real disks with the controller's own tool, e.g. check_storcli).

  Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN

  SNClient passes arguments quoted, so named parameters don't bind; give them
  positionally in the order below, e.g. check_physicaldisk.ps1 55 65.

.PARAMETER TempWarn / TempCrit
  Disk temperature thresholds in degrees C (default 60 / 70).

.PARAMETER WearWarn / WearCrit
  SSD/NVMe wear (percentage of rated endurance used) thresholds (default 80 / 90).

.PARAMETER Exclude
  Comma-separated DeviceIds (disk numbers) to skip, e.g. "1,3". Empty = none.
#>
param(
    [string]$TempWarn = "60",
    [string]$TempCrit = "70",
    [string]$WearWarn = "80",
    [string]$WearCrit = "90",
    [string]$Exclude = ""
)

$ErrorActionPreference = "Stop"

$OK = 0; $WARNING = 1; $CRITICAL = 2; $UNKNOWN = 3

# Writes to the console directly: Write-Output inside a function whose result is
# assigned ($x = Some-Function) would be captured into the variable and lost on exit.
function Exit-Unknown([string]$msg) {
    [Console]::Out.WriteLine("UNKNOWN - $msg")
    exit $UNKNOWN
}

# Validate arguments here rather than with typed parameters, so a bad value gives
# UNKNOWN instead of a PowerShell binding error.
$limits = @{}
foreach ($n in "TempWarn", "TempCrit", "WearWarn", "WearCrit") {
    $v = 0
    if (-not [int]::TryParse((Get-Variable $n -ValueOnly), [ref]$v) -or $v -lt 0) {
        Exit-Unknown "invalid value '$(Get-Variable $n -ValueOnly)' for $n (must be a whole number)"
    }
    $limits[$n] = $v
}
$excluded = @()
foreach ($e in ($Exclude -split ",")) {
    $e = $e.Trim()
    if ($e -eq "") { continue }
    if ($e -notmatch "^\d+$") { Exit-Unknown "invalid disk number '$e' in exclude list" }
    $excluded += $e
}

# Severity order: OK < WARNING < UNKNOWN < CRITICAL
$script:Rank = @{ 0 = 0; 1 = 1; 3 = 2; 2 = 3 }
$script:State = $OK
$script:Problems = New-Object System.Collections.Generic.List[string]
$script:Perf = New-Object System.Collections.Generic.List[string]

function Raise([int]$s, [string]$msg) {
    if ($script:Rank[$s] -gt $script:Rank[$script:State]) { $script:State = $s }
    $script:Problems.Add($msg)
}

# Operational status values that mean the disk is failing or gone
$criticalOpStatus = @("Predictive Failure", "Lost Communication", "No Contact", "Error",
                      "Non-Recoverable Error", "Not Ready", "Aborted", "Removing")

try {
    $disks = @(Get-PhysicalDisk | Sort-Object { [int]$_.DeviceId })
} catch {
    Exit-Unknown "Get-PhysicalDisk failed: $($_.Exception.Message)"
}

$checked = 0
$names = New-Object System.Collections.Generic.List[string]

foreach ($d in $disks) {
    $id = [string]$d.DeviceId
    if ($excluded -contains $id) { continue }
    $checked++
    $model = ([string]$d.FriendlyName).Trim()
    $label = "disk$id"
    $what = "disk $id ($model)"
    $isRaid = [string]$d.BusType -eq "RAID"
    $names.Add("$id $model" + $(if ($isRaid) { " [RAID]" } else { "" }))

    # Health status: Healthy, Warning, Unhealthy, Unknown
    switch ([string]$d.HealthStatus) {
        "Healthy"   { }
        "Warning"   { Raise $WARNING "$what health Warning" }
        "Unhealthy" { Raise $CRITICAL "$what health Unhealthy" }
        default     { Raise $UNKNOWN "$what health $($d.HealthStatus)" }
    }

    # Operational status: an array, e.g. "OK" or "Predictive Failure", "OK"
    foreach ($os in @($d.OperationalStatus)) {
        $s = [string]$os
        if ($s -eq "OK" -or $s -eq "") { continue }
        if ($criticalOpStatus -contains $s) { Raise $CRITICAL "$what $s" }
        else { Raise $WARNING "$what $s" }
    }

    if ($isRaid) { continue }

    # Reliability counters; not every disk/bus reports them, and none is required
    $rc = $null
    try { $rc = $d | Get-StorageReliabilityCounter } catch { }
    if ($null -eq $rc) { continue }

    $temp = $rc.Temperature
    if ($null -ne $temp -and $temp -gt 0) {
        if ($temp -ge $limits.TempCrit) { Raise $CRITICAL "$what temperature ${temp}C" }
        elseif ($temp -ge $limits.TempWarn) { Raise $WARNING "$what temperature ${temp}C" }
        $script:Perf.Add("'${label}_temp'=$temp;$($limits.TempWarn);$($limits.TempCrit)")
    }

    $wear = $rc.Wear
    if ($null -ne $wear -and [string]$d.MediaType -ne "HDD") {
        if ($wear -ge $limits.WearCrit) { Raise $CRITICAL "$what wear ${wear}%" }
        elseif ($wear -ge $limits.WearWarn) { Raise $WARNING "$what wear ${wear}%" }
        $script:Perf.Add("'${label}_wear'=$wear%;$($limits.WearWarn);$($limits.WearCrit);0;100")
    }

    $rErr = $rc.ReadErrorsUncorrected
    $wErr = $rc.WriteErrorsUncorrected
    if ($null -ne $rErr) {
        if ($rErr -gt 0) { Raise $WARNING "$what $rErr uncorrected read errors" }
        $script:Perf.Add("'${label}_read_err'=${rErr}c")
    }
    if ($null -ne $wErr) {
        if ($wErr -gt 0) { Raise $WARNING "$what $wErr uncorrected write errors" }
        $script:Perf.Add("'${label}_write_err'=${wErr}c")
    }
}

if ($checked -eq 0) { Exit-Unknown "no physical disks found" }

$labelText = @("OK", "WARNING", "CRITICAL", "UNKNOWN")[$script:State]
$summary = "$checked disk(s): $($names -join ', ')"
if ($script:Problems.Count -gt 0) {
    $msg = "$labelText - $($script:Problems -join ', ') [$summary]"
} else {
    $msg = "$labelText - all healthy [$summary]"
}
$script:Perf.Insert(0, "disks=$checked")
Write-Output "$msg | $($script:Perf -join ' ')"
exit $script:State
