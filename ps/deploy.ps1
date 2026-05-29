param(
    [string]$BoardIP   = "192.168.2.99",
    [string]$BoardUser = "xilinx",
    [string]$Dest      = "/home/xilinx/jupyter_notebooks/pynq-ecg-demo"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Deploying to ${BoardUser}@${BoardIP}:${Dest} ===" -ForegroundColor Cyan

# Create destination directories on board
Write-Host "Creating directories on board..."
ssh "$BoardUser@$BoardIP" "mkdir -p $Dest/ps"

# Copy all files in ps/ individually
Write-Host "Copying ps/ files..."
$psDir = Join-Path $PSScriptRoot "."
Get-ChildItem -Path $psDir -File | ForEach-Object {
    Write-Host "  -> $($_.Name)"
    scp $_.FullName "${BoardUser}@${BoardIP}:${Dest}/ps/$($_.Name)"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "On board, run:  sudo python3 $Dest/ps/quick_test.py"
