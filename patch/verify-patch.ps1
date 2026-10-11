# godot-bridge 3D patch - self check (no Godot, no DSH restart needed).
# Usage (run in any PowerShell - this machine runs Windows PowerShell 5.1):
#   powershell -NoProfile -File verify-patch.ps1
#   powershell -NoProfile -File verify-patch.ps1 -Install "C:\path\to\godot-bridge"
# Or without a new process:  & "C:\Users\openAI\Desktop\godot-bridge-3d-patch\verify-patch.ps1"
param(
  [string]$Install = "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\godot-bridge",
  [string]$PatchDir = (Split-Path -Parent $PSCommandPath)
)
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host ("  [OK]   {0}{1}" -f $name, $(if ($detail) { "  ($detail)" } else { '' })) -ForegroundColor Green }
  else { $script:fail++; Write-Host ("  [FAIL] {0}{1}" -f $name, $(if ($detail) { "  ($detail)" } else { '' })) -ForegroundColor Red }
}

Write-Host "godot-bridge 3D patch self check" -ForegroundColor Cyan
Write-Host "install : $Install"
Write-Host "patchdir: $PatchDir"
Write-Host ""

$files = @('mcp_interaction_server.gd', 'godot_operations.gd', 'godot-bridge.mjs')
$plugin = Join-Path $Install 'plugin'
$applied = Join-Path $PatchDir 'applied\plugin'
$pristine = Join-Path $PatchDir 'pristine-0.2.0\plugin'

Write-Host '1) patched files are installed (byte identical)'
foreach ($f in $files) {
  $a = Join-Path $plugin $f; $b = Join-Path $applied $f
  if ((Test-Path $a) -and (Test-Path $b)) { Check $f ((Get-FileHash $a).Hash -eq (Get-FileHash $b).Hash) }
  else { Check $f $false 'missing file' }
}

Write-Host '2) rollback set matches upstream 0.2.0 (byte identical)'
$repo = 'C:\dsh\ghcache\godot-bridge\godot-bridge-main\plugin'
foreach ($f in $files) {
  $a = Join-Path $pristine $f; $b = Join-Path $repo $f
  if ((Test-Path $a) -and (Test-Path $b)) { Check $f ((Get-FileHash $a).Hash -eq (Get-FileHash $b).Hash) }
  elseif (Test-Path $a) { Check $f $true 'upstream cache not present, skipped compare' }
  else { Check $f $false 'missing file' }
}

Write-Host '3) no BOM, LF only'
foreach ($f in $files) {
  $p = Join-Path $plugin $f
  if (Test-Path $p) {
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $txt = [System.Text.Encoding]::UTF8.GetString($bytes)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $cr = ([regex]::Matches($txt, "`r")).Count
    Check $f ((-not $bom) -and ($cr -eq 0)) ("BOM=$bom CR=$cr")
  } else { Check $f $false 'missing' }
}

Write-Host '4) mjs syntax'
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  & node --check (Join-Path $plugin 'godot-bridge.mjs') 2>$null
  Check 'node --check godot-bridge.mjs' ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE")
} else { Check 'node --check' $false 'node not on PATH' }

Write-Host '5) new command / op names registered exactly once (inside their own array)'
$mjs = Get-Content (Join-Path $plugin 'godot-bridge.mjs') -Raw
function ArrayBody([string]$text, [string]$constName) {
  $i = $text.IndexOf("const $constName = [")
  if ($i -lt 0) { return '' }
  $j = $text.IndexOf(']', $i)
  if ($j -lt 0) { return '' }
  return $text.Substring($i, $j - $i)
}
# count inside the array only: a name may legitimately exist in BOTH arrays
# (instantiate_scene is an upstream *command* and also a new *op*).
$cmdBody = ArrayBody $mjs 'COMMANDS'
$opBody = ArrayBody $mjs 'HEADLESS_OPS'
$commands = @('render_camera', 'mesh_collision', 'csg_bake', 'get_material_state', 'unwrap_lightmap_uv2', 'build_occluder', 'lightmap_check', 'compare_images')
$ops = @('import_info', 'instantiate_scene', 'list_subresources', 'class_api', 'scan_dependencies', 'audit_scene')
foreach ($n in $commands) { $c = ([regex]::Matches($cmdBody, [regex]::Escape("'$n'"))).Count; Check "command $n" ($c -eq 1) "occurrences=$c" }
foreach ($n in $ops) { $c = ([regex]::Matches($opBody, [regex]::Escape("'$n'"))).Count; Check "op $n" ($c -eq 1) "occurrences=$c" }
Check 'run_headless mode flag' ((Select-String -Path (Join-Path $plugin 'godot-bridge.mjs') -Pattern 'IMP_MODE' -Quiet) -eq $true)
Check 'run_project write_movie param' ((Select-String -Path (Join-Path $plugin 'godot-bridge.mjs') -Pattern 'write_movie' -Quiet) -eq $true)

Write-Host '6) upstream plugin contract check'
$checker = 'C:\dsh\ghcache\godot-bridge\godot-bridge-main\scripts\check-plugin-contract.mjs'
if (Test-Path $checker) {
  $out = & node $checker --root $Install 2>&1 | Out-String
  Check 'plugin contract OK' ($out -match 'plugin contract OK') ($out.Trim().Split("`n")[0])
} else { Check 'plugin contract check' $false 'checker not found (cache cleaned?)' }

Write-Host ''
Write-Host ("result: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
Write-Host 'AFTER a DSH restart, the live smoke test is (run these three):' -ForegroundColor Cyan
Write-Host '  godot_headless_op operation=class_api params={"class_name":"LightmapGI","max_items":5}'
Write-Host '  godot_run_project project_path=<your godot project>'
Write-Host '  godot_command   command=environment params={"volumetric_fog_enabled":true}   # expect non_default_extra'
exit $fail
