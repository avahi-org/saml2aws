<#
.SYNOPSIS
    Stages the Playwright driver saml2aws needs, for the current user only.
    No administrator rights required.

.DESCRIPTION
    Self-service companion to saml2aws for unmanaged / BYOD machines, where
    Intune cannot reach the device and nobody can assume local admin.

    Why this is needed at all: saml2aws' "Browser" provider drives Playwright,
    and saml2aws 2.36.x still fetches its Playwright driver from
    playwright.azureedge.net, which Microsoft retired. Every host it knows now
    returns 404, so on a fresh machine the Browser provider dies with:

        could not install driver: got non 200 status code: 404 (404 Not Found)

    This script assembles the driver the way current playwright-go does -- the
    playwright-core npm package plus a matching Node.js binary -- and puts it
    somewhere a standard user can write.

    Everything is user-scoped:
        driver  -> %LOCALAPPDATA%\saml2aws\playwright-driver
        env var -> PLAYWRIGHT_DRIVER_PATH at User scope, not Machine

    The ms-playwright-go\<version> nesting is not optional. playwright-go appends
    it to whatever base directory it is handed, so the layout must end up as:

        <BaseDir>\ms-playwright-go\<PlaywrightVersion>\node.exe
        <BaseDir>\ms-playwright-go\<PlaywrightVersion>\package\cli.js

.PARAMETER PlaywrightVersion
    Playwright CLI version your saml2aws build pins. This MUST match or
    playwright-go rejects the driver. If a future saml2aws build disagrees, read
    the wanted version out of the 404 URL it prints:

        saml2aws login -a <account> --verbose

.PARAMETER NodeVersion
    Node.js version supplying node.exe. Any modern LTS works.

.PARAMETER BaseDir
    Where to stage the driver. Defaults under %LOCALAPPDATA% so no admin is
    needed.

.PARAMETER SkipEnvironmentVariable
    Skip setting PLAYWRIGHT_DRIVER_PATH. Use this if you already run your own
    Playwright projects and would rather not have a global driver path: the
    script then prints the browser_driver_dir line to add to your ~/.saml2aws
    profile instead, which affects saml2aws only.

.PARAMETER Force
    Re-download and re-stage even if a valid driver is already present.

.EXAMPLE
    .\Install-Saml2awsPlaywrightDriver-User.ps1

.EXAMPLE
    .\Install-Saml2awsPlaywrightDriver-User.ps1 -SkipEnvironmentVariable
    Stage the driver but leave the environment alone.

.NOTES
    Windows PowerShell 5.1 compatible. No admin rights. Exit 0 = success.

    Needs about 120 MB of temporary download and roughly 200 MB staged. On a
    metered connection, be aware it pulls Node.js (~28 MB) and playwright-core.
#>
[CmdletBinding()]
param(
    [string] $PlaywrightVersion = '1.47.2',
    [string] $NodeVersion       = '20.17.0',
    [string] $BaseDir           = (Join-Path $env:LOCALAPPDATA 'saml2aws\playwright-driver'),
    [switch] $SkipEnvironmentVariable,
    [switch] $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Older PowerShell hosts still default to TLS 1.0, which npm and nodejs.org refuse.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$driverDir = Join-Path $BaseDir "ms-playwright-go\$PlaywrightVersion"
$nodeExe   = Join-Path $driverDir 'node.exe'
$cliJs     = Join-Path $driverDir 'package\cli.js'
$staging   = Join-Path $env:TEMP ('saml2aws-pwdriver-' + [guid]::NewGuid().Guid)

function Write-Step    { param([string] $Message) Write-Host "  $Message" }
function Write-Good    { param([string] $Message) Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn    { param([string] $Message) Write-Host "  $Message" -ForegroundColor Yellow }
function Write-Problem { param([string] $Message) Write-Host "  $Message" -ForegroundColor Red }

# Mirrors playwright-go's own validation: it shells out to "node cli.js --version"
# and insists on the pinned version. Testing for file existence is not enough --
# a truncated download would pass that and then fail at login time.
function Test-Driver {
    if (-not (Test-Path -LiteralPath $nodeExe)) { return $false }
    if (-not (Test-Path -LiteralPath $cliJs))   { return $false }
    try {
        $reported = & $nodeExe $cliJs --version 2>&1
        return ($reported -match [regex]::Escape($PlaywrightVersion))
    }
    catch { return $false }
}

try {
    Write-Host ''
    Write-Host 'saml2aws Playwright driver setup (current user, no admin needed)' -ForegroundColor Cyan
    Write-Host ''

    # A managed machine may already have this staged device-wide. Setting a User
    # variable would quietly shadow the Machine one, so say so rather than
    # creating two competing driver paths.
    $machineVar = [Environment]::GetEnvironmentVariable('PLAYWRIGHT_DRIVER_PATH', 'Machine')
    if ($machineVar) {
        Write-Warn "This device already has a machine-wide driver path set:"
        Write-Warn "    $machineVar"
        Write-Warn 'That usually means IT already staged the driver. A user-scoped'
        Write-Warn 'variable would override it. Continuing, but you may not need this.'
        Write-Host ''
    }

    if ((Test-Driver) -and -not $Force) {
        Write-Good "Driver v$PlaywrightVersion is already staged and working:"
        Write-Step  "    $driverDir"
    }
    else {
        New-Item -ItemType Directory -Path $driverDir -Force | Out-Null
        New-Item -ItemType Directory -Path $staging   -Force | Out-Null

        # 1. playwright-core from npm. The tarball nests everything under
        #    "package/", which is exactly the shape playwright-go wants, so it
        #    extracts straight into the driver root.
        $tgzUrl = "https://registry.npmjs.org/playwright-core/-/playwright-core-$PlaywrightVersion.tgz"
        $tgz    = Join-Path $staging 'playwright-core.tgz'
        Write-Step "Downloading playwright-core $PlaywrightVersion"
        Invoke-WebRequest -Uri $tgzUrl -OutFile $tgz -UseBasicParsing

        Write-Step 'Extracting playwright-core'
        & tar.exe -xzf $tgz -C $driverDir
        if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to extract playwright-core (exit $LASTEXITCODE)." }
        if (-not (Test-Path -LiteralPath $cliJs)) { throw "cli.js missing after extraction: $cliJs" }

        # 2. node.exe from nodejs.org. Only the single binary is kept.
        $nodeDir = "node-v$NodeVersion-win-x64"
        $nodeUrl = "https://nodejs.org/dist/v$NodeVersion/$nodeDir.zip"
        $nodeZip = Join-Path $staging 'node.zip'
        Write-Step "Downloading Node.js $NodeVersion (about 28 MB)"
        Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeZip -UseBasicParsing

        Write-Step 'Extracting node.exe'
        Expand-Archive -LiteralPath $nodeZip -DestinationPath $staging -Force
        $extractedNode = Join-Path $staging "$nodeDir\node.exe"
        if (-not (Test-Path -LiteralPath $extractedNode)) { throw "node.exe missing after extraction: $extractedNode" }
        Copy-Item -LiteralPath $extractedNode -Destination $nodeExe -Force

        # 3. Validate exactly the way playwright-go will at login time.
        if (-not (Test-Driver)) {
            throw "Driver staged but the version check failed. Expected v$PlaywrightVersion in $driverDir."
        }

        Write-Good "Driver v$PlaywrightVersion staged and verified:"
        Write-Step  "    $driverDir"
    }

    Write-Host ''

    # playwright-go treats PLAYWRIGHT_DRIVER_PATH as a BASE directory and appends
    # ms-playwright-go\<version> itself, so this gets $BaseDir, never $driverDir.
    if ($SkipEnvironmentVariable) {
        Write-Step 'Skipping PLAYWRIGHT_DRIVER_PATH, as requested.'
        Write-Host ''
        Write-Step 'Add this to the account section of your ~\.saml2aws instead:'
        Write-Host ''
        Write-Host "      browser_driver_dir = $BaseDir" -ForegroundColor White
    }
    else {
        $current = [Environment]::GetEnvironmentVariable('PLAYWRIGHT_DRIVER_PATH', 'User')
        if ($current -eq $BaseDir) {
            Write-Good 'PLAYWRIGHT_DRIVER_PATH already set for your account.'
        }
        else {
            [Environment]::SetEnvironmentVariable('PLAYWRIGHT_DRIVER_PATH', $BaseDir, 'User')
            $verify = [Environment]::GetEnvironmentVariable('PLAYWRIGHT_DRIVER_PATH', 'User')
            if ($verify -ne $BaseDir) { throw "Failed to set PLAYWRIGHT_DRIVER_PATH (got '$verify')." }
            Write-Good 'Set PLAYWRIGHT_DRIVER_PATH for your account.'
        }
        # Make it usable in this session too, so the reader can test immediately.
        $env:PLAYWRIGHT_DRIVER_PATH = $BaseDir
    }

    # --- prerequisites the driver cannot supply -----------------------------
    Write-Host ''
    Write-Host 'Checking the rest of the prerequisites' -ForegroundColor Cyan

    $saml2aws = Get-Command 'saml2aws.exe' -ErrorAction SilentlyContinue
    if ($saml2aws) { Write-Good "saml2aws found: $($saml2aws.Source)" }
    else {
        Write-Problem 'saml2aws was NOT found on your PATH.'
        Write-Step    'The driver is staged, but you still need the saml2aws CLI itself.'
    }

    # browser_type=chrome resolves the installed Google Chrome; Playwright browsers
    # are not part of the driver, so Chrome genuinely has to be there.
    $chromePaths = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    $chrome = $chromePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($chrome) { Write-Good "Google Chrome found: $chrome" }
    else {
        Write-Warn 'Google Chrome was NOT found.'
        Write-Step 'saml2aws profiles using browser_type=chrome need it. Either install'
        Write-Step 'Chrome or change browser_type in your ~\.saml2aws profile.'
    }

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
    Write-Host ''
    Write-Step 'Open a NEW terminal before running saml2aws -- environment variable'
    Write-Step 'changes do not reach shells that are already open.'
    Write-Host ''
    exit 0
}
catch {
    Write-Host ''
    Write-Problem "Setup failed: $($_.Exception.Message)"
    Write-Host ''
    Write-Step 'Common causes: no internet access, or a proxy blocking'
    Write-Step 'registry.npmjs.org or nodejs.org. Re-run once connected.'
    Write-Host ''
    exit 1
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}