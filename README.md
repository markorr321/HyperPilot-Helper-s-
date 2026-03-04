# HyperPilot Helper

A companion toolset for [HyperPilot](https://hyperpilot.getrubix.com/) that automates VM lifecycle management for Windows Autopilot deployments. Prepare VMs for Autopilot provisioning and clean them up afterwards — all from a single script.

## What is HyperPilot?

[HyperPilot](https://hyperpilot.getrubix.com/) is a platform that automates Windows virtual machine creation and Microsoft Autopilot enrollment. It turns what is traditionally a complex, multi-step process into a simplified three-click workflow — creating Hyper-V VMs with TPM, BitLocker-ready images, and MSAL-based Autopilot registration built in.

**HyperPilot Helper** picks up where HyperPilot leaves off. After a VM is created, this toolset handles the remaining prep work — configuring networking, enabling clipboard integration, copying the Autopilot import script into the VM, and launching the console — so you can go from a freshly created VM to an Autopilot-enrolled device without manual steps. When you're done testing, the cleanup mode tears everything down safely.

## Features

### Autopilot-Prep Mode
- Configures VM networking (creates/connects external switch with fallback to Default Switch)
- Enables Enhanced Session Mode and Guest Services for clipboard support
- Starts the VM and waits for a heartbeat
- Copies the Autopilot setup script (`API.bat`) into the VM
- Launches the VM console via `vmconnect.exe`

### VM-Cleanup Mode
- Scans a folder for VHD/VHDX files and identifies associated VMs
- Gracefully shuts down running VMs (with timeout fallback to hard stop)
- Removes VMs from Hyper-V and deletes their disk files
- Supports **dry-run mode** to preview changes safely

## Requirements

- **Windows** with Hyper-V enabled
- **PowerShell 7+** (the script auto-promotes from earlier versions)
- **Administrator privileges** (the script auto-elevates)
- Internet connection (for Autopilot provisioning via `API.bat`)

## Usage

```powershell
# Interactive — choose a mode from the menu
.\HyperPilot.ps1

# Autopilot preparation
.\HyperPilot.ps1 -Mode Autopilot-Prep

# VM cleanup
.\HyperPilot.ps1 -Mode VM-Cleanup

# VM cleanup with dry-run (preview only)
.\HyperPilot.ps1 -Mode VM-Cleanup -DryRun
```

### Parameters

| Parameter       | Default                                  | Description                          |
|-----------------|------------------------------------------|--------------------------------------|
| `-Mode`         | *(prompted)*                             | `Autopilot-Prep` or `VM-Cleanup`    |
| `-BatPath`      | `.\API.bat`                              | Path to the Autopilot setup script   |
| `-SearchFolder` | `C:\HyperPilot\Virtual Hard Disks`       | Folder to scan for VHD/VHDX files    |
| `-DryRun`       | `$false`                                 | Preview changes without executing    |
| `-LogPath`      | `.\hyperpilot.log`                       | Custom log file path                 |

### Standalone Scripts

The two modes are also available as independent scripts:

```powershell
.\HyperpilotPrep.ps1       # Autopilot preparation only
.\hyperpilot-cleanup.ps1   # VM cleanup only
```

## Project Structure

```
├── HyperPilot.ps1           # Main combined script (both modes)
├── HyperpilotPrep.ps1       # Standalone prep script
├── hyperpilot-cleanup.ps1   # Standalone cleanup script
└── API.bat                  # Autopilot provisioning installer
```

## API.bat

A batch script that is copied into the VM during Autopilot-Prep to bootstrap the Autopilot enrollment process. It installs and launches [AutoPilot_Import_GUI](https://github.com/ugurkocde/AutoPilot_Import_GUI) by Ugur Koc — a PowerShell-based GUI that simplifies importing devices into Windows Autopilot with support for Group Tags, automatic reboots, and network connectivity checks.

The script handles:

1. Setting the PowerShell execution policy
2. Installing the NuGet package provider
3. Configuring the PowerShell Gallery
4. Installing the AutoPilot Import GUI module
5. Launching the GUI

Includes TLS 1.2 fallback and alternative installation methods.

## Logging

All operations are logged with timestamps to a UTF-8 log file (`hyperpilot.log` by default). Dry-run actions are also logged for audit purposes.
