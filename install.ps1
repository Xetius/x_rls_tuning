# Copies the mod into BeamNG's unpacked mods folder. Re-run after changing anything in mod\.
# In game, Ctrl+L reloads Lua and Ctrl+R reloads the vehicle to pick up changes.
$src = Join-Path $PSScriptRoot 'mod'
$mods = Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive\current\mods\unpacked'
$dst = Join-Path $mods 'x_rls_tuning'
# the mod was called tuning_telemetry before; remove that copy so it doesn't load twice
$old = Join-Path $mods 'tuning_telemetry'
if (Test-Path $old) {
    Remove-Item $old -Recurse -Force
    Write-Host "Removed old copy $old"
}
robocopy $src $dst /MIR /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
Write-Host "Installed to $dst"
exit 0 # robocopy returns 1 for "files copied", which is success
