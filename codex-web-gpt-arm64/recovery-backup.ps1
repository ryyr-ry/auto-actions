# Windows 11 recovery backup for Codex Web GPT x64/ARM64.
# This script NEVER deletes or modifies original data. Run after closing
# Codex Web GPT and the official Codex application.
param([string] $Destination)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($Destination)) {
  $base = [Environment]::GetFolderPath('MyDocuments')
  $Destination = Join-Path $base ("CodexWebGPT-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
if (Test-Path -LiteralPath $Destination) {
  throw "Backup destination exists. Choose a new empty destination: $Destination"
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$locations = [ordered]@{
  "bridge"      = Join-Path $HOME ".codex-chatgpt-web"
  "launcher"    = Join-Path $env:APPDATA "Codex Web GPT"
  "codex"       = Join-Path $HOME ".codex"
}
$problems = @()
foreach ($entry in $locations.GetEnumerator()) {
  $name = $entry.Key
  $source = $entry.Value
  if (!(Test-Path -LiteralPath $source -PathType Container)) {
    Write-Host "$name does not exist; skipped"
    continue
  }
  $target = Join-Path $Destination $name
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  Write-Host "Copying $name; original data will not be modified."
  & robocopy.exe $source $target /E /XJ /R:2 /W:1 /COPY:DAT /DCOPY:DAT /NFL /NDL /NP
  $code = $LASTEXITCODE
  if ($code -ge 8) {
    $problems += "$($name): robocopy exit code $code"
    Write-Warning "Some files in $name could not be copied (exit code $code)"
  }
}
$registry = "HKCU\Software\d1a6026a-6210-588e-9a2b-da3936f94e02"
& reg.exe query $registry *> $null
if ($LASTEXITCODE -eq 0) {
  & reg.exe export $registry (Join-Path $Destination "installer-registry.reg") /y | Out-Null
}
if ($problems.Count) {
  Write-Warning "INCOMPLETE BACKUP. Do not uninstall, reset, or delete any source folders."
  $problems | ForEach-Object { Write-Warning $_ }
  throw "Backup incomplete. Original files are untouched. Review the warnings."
}
Write-Host "BACKUP COMPLETE: $Destination"
Write-Warning "This backup includes ChatGPT session cookies, Tunnel keys, and possibly Codex tokens. Keep it private. Never upload it to GitHub or a public issue."
