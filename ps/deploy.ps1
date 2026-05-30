param(
    [string]$BoardIP   = "192.168.2.99",
    [string]$BoardUser = "xilinx",
    [string]$Dest      = "/home/xilinx/jupyter_notebooks/pynq-ecg-demo"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Deploying to ${BoardUser}@${BoardIP}:${Dest} ===" -ForegroundColor Cyan

# Create destination directories on board
Write-Host "Creating directories on board..."
ssh "$BoardUser@$BoardIP" "mkdir -p $Dest/ps $Dest/verification"

# Copy all files in ps/ individually
Write-Host "Copying ps/ files..."
$psDir = Join-Path $PSScriptRoot "."
Get-ChildItem -Path $psDir -File | ForEach-Object {
    Write-Host "  -> ps/$($_.Name)"
    scp $_.FullName "${BoardUser}@${BoardIP}:${Dest}/ps/$($_.Name)"
}

# Copy verification/ subsystem checks (sibling of ps/)
$verDir = Join-Path $PSScriptRoot "..\verification"
if (Test-Path $verDir) {
    Write-Host "Copying verification/ files..."
    Get-ChildItem -Path $verDir -File | ForEach-Object {
        Write-Host "  -> verification/$($_.Name)"
        scp $_.FullName "${BoardUser}@${BoardIP}:${Dest}/verification/$($_.Name)"
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "On board (root + sourced env), run:"
Write-Host "  cd $Dest/verification && sudo bash -c 'source /etc/profile.d/pynq_venv.sh; source /etc/profile.d/xrt_setup.sh; python3 verify_dac_adc.py'"
