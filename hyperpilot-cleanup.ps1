<#/
hyperpilot-cleanup.ps1

Safely remove Hyper-V VMs (created by Hyper Pilot) and their VHD/VHDX files.

Features:
- Auto-promotes to PowerShell 7 and elevates to Administrator
- Scans for .vhd/.vhdx files (default: C:\HyperPilot\Virtual Hard Disks)
- Guided workflow: power off VMs > remove from Hyper-V > delete disk files
- Supports `-DryRun` to preview actions and `-LogPath` for logging

Usage examples:
PowerShell:
  .\hyperpilot-cleanup.ps1
  .\hyperpilot-cleanup.ps1 -SearchFolder 'C:\HyperPilot\Virtual Hard Disks' -DryRun
#>

param(
    [string]$SearchFolder = 'C:\HyperPilot\Virtual Hard Disks',
    [switch]$DryRun,
    [string]$LogPath = (Join-Path (Split-Path -Parent $PSCommandPath) 'hyperpilot-cleanup.log')
)

# ========================= UI Helpers =========================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $logLine = "[$ts] [$Level] $Message"
    try { $logLine | Out-File -FilePath $LogPath -Append -Encoding utf8 } catch {}
}

function Write-Status {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Log $Message $Level
    switch ($Level) {
        'ERROR' { Write-Host "  ❌ $Message" -ForegroundColor Red }
        'WARN'  { Write-Host "  ⚠️ $Message" -ForegroundColor Yellow }
        'OK'    { Write-Host "  ✅ $Message" -ForegroundColor Green }
        'LOAD'  { Write-Host "  🔄 $Message" -ForegroundColor Cyan -NoNewline }
        default { Write-Host "    $Message" -ForegroundColor DarkGray }
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  $('─' * $Title.Length)" -ForegroundColor DarkGray
}

function Read-Selection([string]$prompt, [string[]]$options) {
    Write-Host ""
    for ($i = 0; $i -lt $options.Length; $i++) {
        Write-Host "  ► " -ForegroundColor Yellow -NoNewline
        Write-Host "$($i+1)) $($options[$i])" -ForegroundColor White
    }
    Write-Host ""
    do {
        Write-Host "  $prompt " -ForegroundColor DarkGray -NoNewline
        $sel = Read-Host
        if ($sel -match '^[Aa]$') { return 'ALL' }
        if ($sel -match '^[Qq]$') { return 'QUIT' }
        $nums = $sel -split '[, ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        if ($nums.Count -gt 0 -and ($nums | Where-Object { $_ -ge 1 -and $_ -le $options.Length }).Count -eq $nums.Count) { return $nums }
        Write-Host "  ⚠️ Enter numbers (e.g. 1,3), A for all, or Q to quit." -ForegroundColor Yellow
    } while ($true)
}

function Read-Confirm([string]$prompt) {
    Write-Host ""
    Write-Host "  $prompt " -ForegroundColor Yellow -NoNewline
    Write-Host "(press Enter to confirm) " -ForegroundColor DarkGray -NoNewline
    $answer = Read-Host
    return ($answer -eq '')
}

# ========================= Banner =========================

Write-Host ""
Write-Host "  [ H Y P E R   P I L O T ]" -ForegroundColor Magenta -NoNewline
Write-Host "  Cleanup" -ForegroundColor DarkGray
Write-Host ""

if ($DryRun) {
    Write-Host "  ⚠️ DRY RUN — no changes will be made" -ForegroundColor Magenta
    Write-Host ""
}

# ========================= PowerShell 7 Promotion =========================

# Build relaunch args
$argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
if ($SearchFolder) { $argLine += " -SearchFolder `"$SearchFolder`"" }
if ($DryRun)       { $argLine += ' -DryRun' }
if ($LogPath)      { $argLine += " -LogPath `"$LogPath`"" }

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needsPS7 = $PSVersionTable.PSVersion.Major -lt 7
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue

if ($needsPS7 -or -not $isAdmin) {
    if ($needsPS7 -and -not $pwshCmd) {
        Write-Status 'PowerShell 7 not found — install from https://aka.ms/powershell' 'WARN'
    } else {
        $exe = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
        if (-not $exe) { Write-Status 'No PowerShell executable found.' 'ERROR'; exit 1 }

        if (-not $isAdmin) {
            Write-Status 'Launching PowerShell 7 as Administrator...' 'WARN'
            Start-Process -FilePath $exe -ArgumentList $argLine -Verb RunAs
        } else {
            Write-Status 'Relaunching in PowerShell 7...' 'WARN'
            Start-Process -FilePath $exe -ArgumentList $argLine
        }
        exit 0
    }
}

# ========================= Initialize =========================

try { Import-Module Hyper-V -ErrorAction Stop } catch {
    Write-Status 'Hyper-V module not available. Run on a Hyper-V host.' 'ERROR'; exit 1
}

if (-not (Test-Path $SearchFolder)) {
    Write-Status "Folder not found: $SearchFolder" 'ERROR'; exit 1
}

# ========================= Scan =========================

$vhdFiles = Get-ChildItem -Path $SearchFolder -Recurse -Include *.vhd,*.vhdx -File -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

if (-not $vhdFiles) {
    Write-Status "No VHD/VHDX files found." 'WARN'; exit 0
}

$vmMatches = @()
foreach ($vm in Get-VM) {
    $drives = Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
        if ($d.Path -and ($d.Path -like "$SearchFolder*" -or $vhdFiles -contains $d.Path)) {
            $vmMatches += [PSCustomObject]@{ VMName = $vm.Name; DiskPath = $d.Path; State = $vm.State }
        }
    }
}

$grouped = $vmMatches | Group-Object VMName
if (-not $grouped) {
    Write-Status "No VMs reference this folder." 'WARN'
}

# VM selection menu
$selectedVMs = @()

if (-not $grouped) {
    Write-Status "No VMs found to remove." 'WARN'; exit 0
}

$vmOptions = @()
foreach ($g in $grouped) { $vmOptions += $g.Name }
$vmOptions += "Remove all"
$vmOptions += "Quit"

Write-Section "Select VMs to Remove"
$choice = Read-Selection -prompt "Enter selection (1,2,...), Q=quit:" -options $vmOptions
if ($choice -eq 'QUIT') { Write-Status "Aborted." 'INFO'; exit 0 }

if ($choice -eq 'ALL') {
    $selectedVMs = $grouped | ForEach-Object { $_.Name }
} else {
    foreach ($n in $choice) {
        $idx = $n - 1
        if ($idx -lt $grouped.Count) {
            $selectedVMs += $grouped[$idx].Name
        } elseif ($idx -eq $grouped.Count) {
            $selectedVMs = $grouped | ForEach-Object { $_.Name }
        }
    }
}

if (-not $selectedVMs) {
    Write-Status "Nothing selected." 'INFO'; exit 0
}

# ========================= Step 2: Power Off VMs =========================

if ($selectedVMs) {
    Write-Section "Power Off VMs"

    foreach ($vmName in $selectedVMs) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($vm.State -eq 'Running') {
            Write-Host "  ⚠️ " -ForegroundColor Yellow -NoNewline
            Write-Host "$vmName " -ForegroundColor White -NoNewline
            Write-Host "Running" -ForegroundColor Yellow
        } else {
            Write-Host "  ✅ " -ForegroundColor Green -NoNewline
            Write-Host "$vmName " -ForegroundColor White -NoNewline
            Write-Host "$($vm.State)" -ForegroundColor DarkGray
        }
    }

    $runningVMs = $selectedVMs | Where-Object { (Get-VM -Name $_ -ErrorAction SilentlyContinue).State -eq 'Running' }

    if ($runningVMs) {
        if (-not $DryRun) {
            if (-not (Read-Confirm "Shut down $($runningVMs.Count) running VM(s)?")) {
                Write-Status "Canceled." 'INFO'; exit 0
            }
        }

        foreach ($vmName in $runningVMs) {
            if (-not $DryRun) {
                Write-Host ""
                try { Stop-VMGuest -VMName $vmName -Force -ErrorAction SilentlyContinue } catch {}

                $timeout = 60; $elapsed = 0
                $barWidth = 30
                while (((Get-VM -Name $vmName).State -eq 'Running') -and $elapsed -lt $timeout) {
                    $pct = [math]::Min([math]::Round(($elapsed / $timeout) * 100), 100)
                    $filled = [math]::Round(($pct / 100) * $barWidth)
                    $empty = $barWidth - $filled
                    $bar = ("█" * $filled) + ("░" * $empty)
                    Write-Host "`r  ⏳ Shutting down $vmName  $bar $pct%" -ForegroundColor Cyan -NoNewline
                    Start-Sleep -Seconds 2; $elapsed += 2
                }

                if ((Get-VM -Name $vmName).State -eq 'Running') {
                    Write-Host ""
                    Write-Status "Graceful shutdown failed, forcing stop..." 'WARN'
                    Stop-VM -Name $vmName -Force -ErrorAction SilentlyContinue
                }

                Write-Host "`r  ✅ $vmName powered off.".PadRight([Console]::WindowWidth - 1) -ForegroundColor Green
                Write-Log "$vmName powered off." 'INFO'
            } else {
                Write-Host "    [DRY RUN] Would shut down: $vmName" -ForegroundColor DarkGray
                Write-Log "[DRY RUN] Would shut down: $vmName" 'INFO'
            }
        }
    } else {
        Write-Status "All selected VMs are already stopped." 'OK'
    }
}

# ========================= Step 3: Remove VMs from Hyper-V =========================

if ($selectedVMs) {
    Write-Section "Remove VMs from Hyper-V"

    foreach ($vmName in $selectedVMs) {
        Write-Host "    $vmName" -ForegroundColor White
    }

    if (-not $DryRun) {
        if (-not (Read-Confirm "Remove $($selectedVMs.Count) VM(s) from Hyper-V?")) {
            Write-Status "Canceled." 'INFO'; exit 0
        }

        foreach ($vmName in $selectedVMs) {
            Write-Status "Removing $vmName..." 'LOAD'
            try {
                Remove-VM -Name $vmName -Force -Confirm:$false -ErrorAction Stop
                Write-Host " ✅" -ForegroundColor Green
                Write-Log "$vmName removed." 'INFO'
            } catch {
                Write-Host ""
                Write-Status ("Failed to remove {0}: {1}" -f $vmName, $_) 'ERROR'
            }
        }
    } else {
        foreach ($vmName in $selectedVMs) {
            Write-Host "    [DRY RUN] Would remove: $vmName" -ForegroundColor DarkGray
            Write-Log "[DRY RUN] Would remove: $vmName" 'INFO'
        }
    }
}

# ========================= Step 4: Delete Disk Files =========================

$disksToDelete = @()
foreach ($vmName in $selectedVMs) {
    $matched = $vmMatches | Where-Object { $_.VMName -eq $vmName } | Select-Object -ExpandProperty DiskPath
    if ($matched) { $disksToDelete += $matched }
}
$disksToDelete = $disksToDelete | Sort-Object -Unique

if ($disksToDelete.Count -eq 0) {
    Write-Status "No disk files to delete." 'INFO'; exit 0
}

Write-Section "Delete Disk Files"

foreach ($f in $disksToDelete) {
    $fileName = Split-Path $f -Leaf
    $sizeMB = if (Test-Path $f) { [math]::Round((Get-Item $f).Length / 1MB, 1) } else { '?' }
    Write-Host "    $fileName " -ForegroundColor White -NoNewline
    Write-Host "${sizeMB} MB" -ForegroundColor DarkGray
}

if (-not $DryRun) {
    if (-not (Read-Confirm "Delete $($disksToDelete.Count) file(s)?")) {
        Write-Status "Skipped file deletion." 'INFO'; exit 0
    }

    foreach ($f in $disksToDelete) {
        $fileName = Split-Path $f -Leaf
        if (Test-Path $f) {
            try {
                Remove-Item -Path $f -Force -ErrorAction Stop
                Write-Status "Deleted $fileName" 'OK'
            } catch {
                Write-Status ("Failed to delete {0}: {1}" -f $fileName, $_) 'ERROR'
            }
        } else {
            Write-Status "Not found: $fileName" 'WARN'
        }
    }
} else {
    foreach ($f in $disksToDelete) {
        $fileName = Split-Path $f -Leaf
        Write-Host "    [DRY RUN] Would delete: $fileName" -ForegroundColor DarkGray
        Write-Log "[DRY RUN] Would delete: $f" 'INFO'
    }
}

# ========================= Done =========================

Write-Host ""
Write-Status "Cleanup complete." 'OK'
Write-Host ""
