<#/
HyperpilotPrep.ps1

Prepare a Hyper-V VM for Hyper Pilot deployment.

Features:
- Auto-promotes to PowerShell 7 and elevates to Administrator
- Lists all Hyper-V VMs and lets you select one
- Enables clipboard (copy/paste) via Guest Services
- Copies API.bat to the VM root (C:\)
- Starts and connects to the VM

Usage:
  .\HyperpilotPrep.ps1
  .\HyperpilotPrep.ps1 -BatPath 'C:\Projects\Hyper-Pilot-Helper\API.bat'
#>

param(
    [string]$BatPath = 'C:\Projects\Hyper-Pilot-Helper\API.bat',
    [string]$LogPath = (Join-Path (Split-Path -Parent $PSCommandPath) 'hyperpilot-prep.log')
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
        if ($sel -match '^[Qq]$') { return 'QUIT' }
        $nums = $sel -split '[, ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        if ($nums.Count -eq 1 -and $nums[0] -ge 1 -and $nums[0] -le $options.Length) { return $nums[0] }
        Write-Host "  ⚠️ Enter a number or Q to quit." -ForegroundColor Yellow
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
Write-Host "  Prep" -ForegroundColor DarkGray
Write-Host ""

# ========================= PowerShell 7 Promotion =========================

# Build relaunch args
$argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
if ($BatPath) { $argLine += " -BatPath `"$BatPath`"" }
if ($LogPath) { $argLine += " -LogPath `"$LogPath`"" }

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

if (-not (Test-Path $BatPath)) {
    Write-Status "API.bat not found: $BatPath" 'ERROR'; exit 1
}

# ========================= Select VM =========================

$allVMs = Get-VM | Sort-Object Name
if (-not $allVMs) {
    Write-Status "No VMs found." 'WARN'; exit 0
}

$vmOptions = @()
foreach ($vm in $allVMs) {
    $state = if ($vm.State -eq 'Running') { 'Running' } else { 'Off' }
    $vmOptions += "$($vm.Name)  [$state]"
}
$vmOptions += "Quit"

Write-Section "Select a VM"
$choice = Read-Selection -prompt "Enter selection, Q=quit:" -options $vmOptions
if ($choice -eq 'QUIT') { Write-Status "Aborted." 'INFO'; exit 0 }

$selectedVM = $allVMs[$choice - 1]
$vmName = $selectedVM.Name

Write-Host ""
Write-Status "Selected: $vmName" 'OK'

# ========================= Network =========================

Write-Section "Network"

$switchName = $null

# Prefer an existing External Switch
$extSwitch = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' } | Select-Object -First 1
if ($extSwitch) {
    $switchName = $extSwitch.Name
    Write-Status "Found external switch: $switchName" 'OK'
} else {
    # Create an External Switch using the first active physical NIC
    $physNIC = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($physNIC) {
        Write-Status "Creating External Switch on $($physNIC.Name)..." 'LOAD'
        try {
            New-VMSwitch -Name 'External Switch' -NetAdapterName $physNIC.Name -AllowManagementOS $true -ErrorAction Stop | Out-Null
            Write-Host " ✅" -ForegroundColor Green
            Write-Log "Created External Switch on $($physNIC.Name)." 'INFO'
            $switchName = 'External Switch'
        } catch {
            Write-Host ""
            Write-Status "Failed to create External Switch: $_" 'WARN'
        }
    }

    # Fall back to Default Switch
    if (-not $switchName) {
        $defaultSwitch = Get-VMSwitch | Where-Object { $_.Name -eq 'Default Switch' } | Select-Object -First 1
        if ($defaultSwitch) {
            Restart-Service hns -ErrorAction SilentlyContinue
            $switchName = 'Default Switch'
            Write-Status "Falling back to Default Switch." 'WARN'
        } else {
            Write-Status "No usable virtual switch found." 'ERROR'
        }
    }
}

# Connect VM to the selected switch
if ($switchName) {
    $vmNIC = Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue
    if (-not $vmNIC) {
        Write-Status "Adding network adapter..." 'LOAD'
        try {
            Add-VMNetworkAdapter -VMName $vmName -SwitchName $switchName -ErrorAction Stop
            Write-Host " ✅" -ForegroundColor Green
            Write-Log "Added network adapter connected to $switchName." 'INFO'
        } catch {
            Write-Host ""
            Write-Status "Failed to add network adapter: $_" 'ERROR'
        }
    } elseif ($vmNIC.SwitchName -ne $switchName) {
        Write-Status "Connecting to $switchName..." 'LOAD'
        try {
            $vmNIC | Select-Object -First 1 | Connect-VMNetworkAdapter -SwitchName $switchName -ErrorAction Stop
            Write-Host " ✅" -ForegroundColor Green
            Write-Log "Connected to $switchName." 'INFO'
        } catch {
            Write-Host ""
            Write-Status "Failed to connect: $_" 'ERROR'
        }
    } else {
        Write-Status "Connected to $switchName." 'OK'
    }
}

# ========================= Enable Copy/Paste =========================

Write-Section "Enable Clipboard"

# Enable Enhanced Session Mode on the host
$hostSettings = Get-VMHost
if (-not $hostSettings.EnableEnhancedSessionMode) {
    Write-Status "Enabling Enhanced Session Mode on host..." 'LOAD'
    try {
        Set-VMHost -EnableEnhancedSessionMode $true
        Write-Host " ✅" -ForegroundColor Green
        Write-Log "Enhanced Session Mode enabled on host." 'INFO'
    } catch {
        Write-Host ""
        Write-Status "Failed to enable Enhanced Session Mode: $_" 'ERROR'
    }
} else {
    Write-Status "Enhanced Session Mode already enabled on host." 'OK'
}

# Enable Guest Services integration on the VM (required for Copy-VMFile)
$guestSvc = Get-VMIntegrationService -VMName $vmName | Where-Object { $_.Name -eq 'Guest Service Interface' }
if ($guestSvc -and -not $guestSvc.Enabled) {
    Write-Status "Enabling Guest Services on $vmName..." 'LOAD'
    try {
        Enable-VMIntegrationService -VMName $vmName -Name 'Guest Service Interface'
        Write-Host " ✅" -ForegroundColor Green
        Write-Log "Guest Services enabled on $vmName." 'INFO'
    } catch {
        Write-Host ""
        Write-Status "Failed to enable Guest Services: $_" 'ERROR'
    }
} elseif ($guestSvc -and $guestSvc.Enabled) {
    Write-Status "Guest Services already enabled on $vmName." 'OK'
} else {
    Write-Status "Guest Service Interface not found on $vmName." 'WARN'
}

# ========================= Start VM =========================

Write-Section "Start VM"

if ($selectedVM.State -ne 'Running') {
    Write-Status "Starting $vmName..." 'LOAD'
    try {
        Start-VM -Name $vmName -ErrorAction Stop
        Write-Host " ✅" -ForegroundColor Green
        Write-Log "$vmName started." 'INFO'
    } catch {
        Write-Host ""
        Write-Status "Failed to start VM: $_" 'ERROR'; exit 1
    }

    # Wait for VM to be ready (heartbeat)
    Write-Host ""
    $timeout = 120; $elapsed = 0
    $barWidth = 30
    while ($elapsed -lt $timeout) {
        $hb = (Get-VMIntegrationService -VMName $vmName | Where-Object { $_.Name -eq 'Heartbeat' }).PrimaryStatusDescription
        if ($hb -eq 'OK') { break }

        $pct = [math]::Min([math]::Round(($elapsed / $timeout) * 100), 100)
        $filled = [math]::Round(($pct / 100) * $barWidth)
        $empty = $barWidth - $filled
        $bar = ("█" * $filled) + ("░" * $empty)
        Write-Host "`r  ⏳ Waiting for $vmName to boot  $bar $pct%" -ForegroundColor Cyan -NoNewline
        Start-Sleep -Seconds 2; $elapsed += 2
    }
    Write-Host "`r  ✅ $vmName is running.".PadRight([Console]::WindowWidth - 1) -ForegroundColor Green
    Write-Log "$vmName is running." 'INFO'
} else {
    Write-Status "$vmName is already running." 'OK'
}

# ========================= Copy API.bat =========================

Write-Section "Copy API.bat"

$fileName = Split-Path $BatPath -Leaf
Write-Status "Copying $fileName to C:\\ on $vmName..." 'LOAD'
try {
    Copy-VMFile -Name $vmName -SourcePath $BatPath -DestinationPath "C:\$fileName" -FileSource Host -CreateFullPath -Force -ErrorAction Stop
    Write-Host " ✅" -ForegroundColor Green
    Write-Log "Copied $fileName to $vmName." 'INFO'
} catch {
    Write-Host ""
    Write-Status "Failed to copy file: $_" 'ERROR'
    Write-Status "Make sure the VM is fully booted and Guest Services are running." 'WARN'
}

# ========================= Connect to VM =========================

Write-Section "Connect"

Write-Status "Launching VM connection..." 'OK'
Write-Log "Launching vmconnect for $vmName." 'INFO'
Start-Process -FilePath "vmconnect.exe" -ArgumentList "localhost", "`"$vmName`""

# ========================= Done =========================

Write-Host ""
Write-Status "Prep complete." 'OK'
Write-Host ""
