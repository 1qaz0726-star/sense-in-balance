[CmdletBinding()]
param(
    [ValidateSet('Native', 'PC', 'Driver')][string]$Mode = 'Native',
    [string]$DeviceUrl = 'ws://10.0.2.2:8767/repair'
)
& (Join-Path $PSScriptRoot 'build-hybrid-v3.ps1') -Mode $Mode -Coordination -DeviceUrl $DeviceUrl
