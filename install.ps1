# Copies the mod into BeamNG's unpacked mods folder. Re-run after changing anything in mod\.
# In game, Ctrl+L reloads Lua and Ctrl+R reloads the vehicle to pick up changes.
$src = Join-Path $PSScriptRoot 'mod'
$dst = Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive\current\mods\unpacked\tuning_telemetry'
robocopy $src $dst /MIR /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
Write-Host "Installed to $dst"
exit 0 # robocopy returns 1 for "files copied", which is success
