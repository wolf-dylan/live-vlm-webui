param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs
)

$ProjectDir = Split-Path -Parent $PSScriptRoot
$WslProjectDir = (wsl.exe wslpath -a "$ProjectDir").Trim()

if (-not $WslProjectDir) {
    throw "Failed to resolve the project path inside WSL."
}

wsl.exe --cd $WslProjectDir ./scripts/stop_wsl.sh @ScriptArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
