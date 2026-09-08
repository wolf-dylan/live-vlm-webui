param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs
)

$ProjectDir = Split-Path -Parent $PSScriptRoot
$WslProjectDir = (wsl.exe wslpath -a "$ProjectDir").Trim()

if (-not $WslProjectDir) {
    throw "Failed to resolve the project path inside WSL."
}

# Pass each argument directly instead of composing a shell command. This keeps
# prompts, API URLs, and model names containing spaces or shell characters
# intact and avoids command-injection/quoting failures.
wsl.exe --cd $WslProjectDir ./scripts/start_wsl.sh @ScriptArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
