# Restore (or roll back) the godot-bridge 3D patch in the installed plugin.
#
# Reboot / shutdown does NOT touch any of this - it is all plain files on disk.
# The one thing that DOES wipe the patch is a plugin update or reinstall
# (`dsh plugin ... add/update godot-bridge`, npm/pnpm install, a fresh profile
# install): that rewrites node_modules and the new commands disappear.
# After such an update, run this script to put the patch back:
#
#   powershell -NoProfile -File restore.ps1              # re-apply the patch
#   powershell -NoProfile -File restore.ps1 -Rollback    # go back to upstream 0.2.0
#
# It always saves the files it is about to overwrite into
# before-restore-<timestamp>\ first, then runs the self check.
param(
  [string]$Install = "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\godot-bridge",
  [string]$PatchDir = (Split-Path -Parent $PSCommandPath),
  [switch]$Rollback
)
$ErrorActionPreference = 'Stop'
$src = if ($Rollback) { Join-Path $PatchDir 'pristine-0.2.0\plugin' } else { Join-Path $PatchDir 'applied\plugin' }
$dst = Join-Path $Install 'plugin'
$files = @('mcp_interaction_server.gd', 'godot_operations.gd', 'godot-bridge.mjs')

Write-Host ("mode   : {0}" -f $(if ($Rollback) { 'ROLLBACK to upstream 0.2.0' } else { 'apply the 3D patch' })) -ForegroundColor Cyan
Write-Host "from   : $src"
Write-Host "into   : $dst"
if (-not (Test-Path $src)) { Write-Host "source not found: $src" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $dst)) { Write-Host "install dir not found: $dst" -ForegroundColor Red; exit 1 }

$bak = Join-Path $PatchDir ("before-restore-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $bak -Force | Out-Null
foreach ($f in $files) {
  $target = Join-Path $dst $f
  if (Test-Path $target) { Copy-Item $target (Join-Path $bak $f) -Force }
  Copy-Item (Join-Path $src $f) $target -Force
  Write-Host ("  copied {0}" -f $f) -ForegroundColor Green
}
Write-Host "previous files backed up to: $bak"
Write-Host ""
& (Join-Path $PatchDir 'verify-patch.ps1') -Install $Install
Write-Host ""
Write-Host 'If you re-applied the patch after a plugin update, restart DSH once so the' -ForegroundColor Cyan
Write-Host 'new command / op names get registered again.' -ForegroundColor Cyan
