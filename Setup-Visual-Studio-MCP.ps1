<#
.SYNOPSIS
Installs VS IDE Bridge under C:\tools and configures selected MCP clients to use it over STDIO.

.DESCRIPTION
The script:
  - downloads the latest VS IDE Bridge GitHub release;
  - verifies the release asset against GitHub's SHA-256 digest;
  - checks for a supported Visual Studio installation;
  - installs the extension, Windows service, and managed Python runtime;
  - optionally clones the matching source tag under C:\tools;
  - replaces any old Codex HTTP entry with a reliable STDIO entry;
  - performs a real MCP initialize handshake.

Visual Studio must be closed while the installer runs. The script elevates itself
through UAC because the upstream installer creates a Windows service.
#>

[CmdletBinding()]
param(
    [string]$ToolsRoot = 'C:\tools',
    [string]$CodexHome = '',
    [string[]]$Client = @('Codex'),
    [switch]$SkipSourceClone,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryUrl = 'https://github.com/RenegadeRiff86/Visual-Studio-MCP.git'
$ReleaseApiUrl = 'https://api.github.com/repos/RenegadeRiff86/Visual-Studio-MCP/releases/latest'
$MinimumVisualStudioVersion = [Version]'17.14'
$DownloadRetryCount = 3

function Test-SelectedClient {
    param([Parameter(Mandatory)][string]$Name)

    $selectedClients = @($Client | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return $selectedClients -contains $Name -or
        ($Name -in @('Codex', 'Antigravity') -and $selectedClients -contains 'Both') -or
        $selectedClients -contains 'All'
}

function Assert-SelectedClients {
    $validClients = @('Codex', 'Antigravity', 'ClaudeCode', 'Both', 'All')
    $requestedClients = @($Client | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($requestedClients.Count -eq 0) {
        throw 'Choose at least one client: Codex, Antigravity, or ClaudeCode.'
    }
    $invalidClients = @($requestedClients |
        Where-Object { $_ -and $_ -notin $validClients })
    if ($invalidClients.Count -gt 0) {
        throw "Unknown client selection: $($invalidClients -join ', '). Choose Codex, Antigravity, ClaudeCode, or All."
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Show-Usage {
    @'
VS IDE Bridge setup for Codex, Antigravity CLI, and Claude Code

Usage:
  .\Setup-Visual-Studio-MCP.ps1
  .\Setup-Visual-Studio-MCP.ps1 -Client Antigravity
  .\Setup-Visual-Studio-MCP.ps1 -Client Codex,ClaudeCode
  .\Setup-Visual-Studio-MCP.ps1 -Client All
  .\Setup-Visual-Studio-MCP.ps1 -SkipSourceClone
  .\Setup-Visual-Studio-MCP.ps1 -ToolsRoot D:\tools

Defaults:
  Runtime:  C:\tools\VsIdeBridge
  Source:   C:\tools\Visual-Studio-MCP
  Setup:    C:\tools\Visual-Studio-MCP-setup
  Config:   %USERPROFILE%\.codex\config.toml
  Antigravity config: %USERPROFILE%\.gemini\config\mcp_config.json
  Claude Code: user-scoped MCP configuration managed by the claude CLI

Close Visual Studio before running. Approve the UAC prompt when requested.
'@ | Write-Host
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevated {
    param(
        [string]$ScriptPath,
        [string]$ResolvedToolsRoot,
        [string]$ResolvedCodexHome,
        [string[]]$SelectedClient,
        [bool]$ShouldSkipSourceClone
    )

    Write-Step 'Requesting administrator access'

    $hostExecutable = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($hostExecutable)) {
        $hostExecutable = 'powershell.exe'
    }

    $captureId = [Guid]::NewGuid().ToString('N')
    $standardOutputPath = Join-Path ([IO.Path]::GetTempPath()) ("vs-ide-bridge-setup-$captureId.log")
    $childStandardOutputPath = $standardOutputPath + '.stdout'
    $childStandardErrorPath = $standardOutputPath + '.stderr'
    $payloadObject = [ordered]@{
        ScriptPath = $ScriptPath
        ToolsRoot = $ResolvedToolsRoot
        CodexHome = $ResolvedCodexHome
        Client = $SelectedClient
        SkipSourceClone = $ShouldSkipSourceClone
        OutputPath = $standardOutputPath
        ChildStandardOutputPath = $childStandardOutputPath
        ChildStandardErrorPath = $childStandardErrorPath
        HostExecutable = $hostExecutable
    }
    $payloadJson = $payloadObject | ConvertTo-Json -Compress
    $payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))

    $bootstrapTemplate = @'
$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__'))
$data = $json | ConvertFrom-Json
$innerTemplate = @(
    '$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''__INNER_PAYLOAD__''))',
    '$data = $json | ConvertFrom-Json',
    '$childParameters = @{ ToolsRoot = [string]$data.ToolsRoot; CodexHome = [string]$data.CodexHome; Client = @($data.Client | ForEach-Object { [string]$_ }) }',
    'if ([bool]$data.SkipSourceClone) { $childParameters.SkipSourceClone = $true }',
    '& ([string]$data.ScriptPath) @childParameters'
) -join [Environment]::NewLine
$innerCommand = $innerTemplate.Replace('__INNER_PAYLOAD__', '__PAYLOAD__')
$innerEncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($innerCommand))
try {
    $child = Start-Process -FilePath ([string]$data.HostExecutable) -ArgumentList (
        '-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $innerEncodedCommand
    ) -RedirectStandardOutput ([string]$data.ChildStandardOutputPath) `
      -RedirectStandardError ([string]$data.ChildStandardErrorPath) `
      -WindowStyle Hidden -Wait -PassThru
    $combined = ''
    if ([IO.File]::Exists([string]$data.ChildStandardOutputPath)) {
        $combined += [IO.File]::ReadAllText([string]$data.ChildStandardOutputPath)
    }
    if ($child.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($combined) -and `
        [IO.File]::Exists([string]$data.ChildStandardErrorPath)) {
        $errorText = [IO.File]::ReadAllText([string]$data.ChildStandardErrorPath)
        if ($errorText.StartsWith('#< CLIXML')) {
            try {
                $serialized = $errorText.Substring($errorText.IndexOf([Environment]::NewLine) + [Environment]::NewLine.Length)
                $records = @([System.Management.Automation.PSSerializer]::Deserialize($serialized))
                $readableRecords = @($records | Where-Object {
                    $_ -is [string] -or $_ -is [Management.Automation.ErrorRecord]
                } | ForEach-Object { $_.ToString() })
                if ($readableRecords.Count -gt 0) {
                    $errorText = ($readableRecords -join [Environment]::NewLine)
                }
            }
            catch {}
        }
        $combined += $errorText
    }
    [IO.File]::WriteAllText([string]$data.OutputPath, $combined, [Text.Encoding]::UTF8)
    exit $child.ExitCode
}
catch {
    [IO.File]::WriteAllText([string]$data.OutputPath, ($_ | Out-String), [Text.Encoding]::UTF8)
    exit 1
}
'@
    $bootstrap = $bootstrapTemplate.Replace('__PAYLOAD__', $payloadBase64)
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

    # Capture the elevated child's output and replay it in the original console.
    # Without this, a short-lived UAC console can close before the user sees the
    # download destination or the actual error.
    try {
        $elevatedExitCode = 1
        $process = Start-Process -FilePath $hostExecutable -Verb RunAs -ArgumentList (
            '-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand
        ) -WindowStyle Hidden -Wait -PassThru

        if (Test-Path -LiteralPath $standardOutputPath) {
            $capturedOutput = [IO.File]::ReadAllText($standardOutputPath)
            if (-not [string]::IsNullOrWhiteSpace($capturedOutput)) {
                Write-Host $capturedOutput.TrimEnd()
            }
        }
        $elevatedExitCode = $process.ExitCode
        if ($elevatedExitCode -ne 0 -and (-not (Test-Path -LiteralPath $standardOutputPath) -or [string]::IsNullOrWhiteSpace($capturedOutput))) {
            Write-Host 'The elevated setup failed before it produced diagnostics.' -ForegroundColor Red
            Write-Host 'Right-click Install-Visual-Studio-MCP.cmd, choose Run as administrator, and retry.' -ForegroundColor Yellow
        }
        exit $process.ExitCode
    }
    finally {
        if ($elevatedExitCode -eq 0) {
            foreach ($capturePath in @($standardOutputPath, $childStandardOutputPath, $childStandardErrorPath)) {
                if (Test-Path -LiteralPath $capturePath) {
                    Remove-Item -LiteralPath $capturePath -Force
                }
            }
        }
        else {
            Write-Host "Elevation diagnostics were retained at: $standardOutputPath" -ForegroundColor Yellow
        }
    }
}

function Normalize-SetupPaths {
    $script:ToolsRoot = [IO.Path]::GetFullPath($script:ToolsRoot).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($script:ToolsRoot)) {
        throw 'ToolsRoot must not be empty.'
    }

    $driveRoot = [IO.Path]::GetPathRoot($script:ToolsRoot).TrimEnd('\')
    if ($script:ToolsRoot.TrimEnd('\') -eq $driveRoot) {
        throw 'ToolsRoot must be a directory below the drive root, such as C:\tools.'
    }

    if ([string]::IsNullOrWhiteSpace($script:CodexHome)) {
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            $script:CodexHome = $env:CODEX_HOME
        }
        else {
            $script:CodexHome = Join-Path $env:USERPROFILE '.codex'
        }
    }

    $script:CodexHome = [IO.Path]::GetFullPath($script:CodexHome).TrimEnd('\')
    $script:InstallRoot = Join-Path $script:ToolsRoot 'VsIdeBridge'
    $script:SourceRoot = Join-Path $script:ToolsRoot 'Visual-Studio-MCP'
    $script:SetupRoot = Join-Path $script:ToolsRoot 'Visual-Studio-MCP-setup'
}

function Get-VsWherePath {
    $candidates = New-Object System.Collections.Generic.List[string]
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $candidates.Add((Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'))
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'vswhere.exe was not found. Install Visual Studio 2022 17.14+ or Visual Studio 2026 first.'
}

function Assert-SupportedVisualStudio {
    Write-Step 'Checking Visual Studio'
    $vswhere = Get-VsWherePath
    $json = & $vswhere -all -prerelease -products '*' -requires Microsoft.VisualStudio.Component.CoreEditor -format json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($json -join ''))) {
        throw 'Unable to query installed Visual Studio instances.'
    }

    $instances = @($json | ConvertFrom-Json)
    $supported = @($instances | Where-Object {
        try { [Version]$_.installationVersion -ge $MinimumVisualStudioVersion }
        catch { $false }
    })

    if ($supported.Count -eq 0) {
        throw 'VS IDE Bridge requires Visual Studio 2022 17.14+ or Visual Studio 2026.'
    }

    foreach ($instance in $supported) {
        Write-Host ("Found: {0} ({1})" -f $instance.displayName, $instance.installationVersion)
    }

    $visualStudioProcesses = @(Get-Process devenv -ErrorAction SilentlyContinue)
    if ($visualStudioProcesses.Count -gt 0) {
        foreach ($visualStudioProcess in $visualStudioProcesses) {
            $windowTitle = $visualStudioProcess.MainWindowTitle
            if ([string]::IsNullOrWhiteSpace($windowTitle)) {
                $windowTitle = '<background process>'
            }
            Write-Host ("Running devenv.exe: PID {0}, {1}" -f $visualStudioProcess.Id, $windowTitle) -ForegroundColor Yellow
        }
        throw 'Visual Studio is running. Close every Visual Studio window and remaining devenv.exe process, then retry.'
    }
}

function Get-LatestRelease {
    Write-Step 'Finding the latest VS IDE Bridge release'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'VS-IDE-Bridge-Codex-Setup' }
    $release = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri $ReleaseApiUrl
    $asset = @($release.assets | Where-Object {
        $_.name -match '^vs-ide-bridge-setup-.+\.exe$'
    } | Select-Object -First 1)

    if ($asset.Count -ne 1) {
        throw 'The latest GitHub release does not contain a VS IDE Bridge setup executable.'
    }

    $digestProperty = $asset[0].PSObject.Properties['digest']
    if ($null -eq $digestProperty -or [string]::IsNullOrWhiteSpace([string]$digestProperty.Value)) {
        throw 'GitHub did not provide a SHA-256 digest for the release asset; refusing an unverified install.'
    }

    $digestText = [string]$digestProperty.Value
    if ($digestText -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        throw "Unexpected GitHub release digest format: $digestText"
    }

    return [pscustomobject]@{
        Tag = [string]$release.tag_name
        Name = [string]$asset[0].name
        Url = [string]$asset[0].browser_download_url
        Sha256 = $Matches[1].ToLowerInvariant()
    }
}

function Get-VerifiedInstaller {
    param($Release)

    Write-Step ("Downloading and verifying {0}" -f $Release.Tag)
    New-Item -ItemType Directory -Path $SetupRoot -Force | Out-Null
    $installerPath = Join-Path $SetupRoot $Release.Name
    Write-Host ("Source:      {0}" -f $Release.Url)
    Write-Host ("Destination: {0}" -f $installerPath)

    if (Test-Path -LiteralPath $installerPath) {
        $existingHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingHash -eq $Release.Sha256) {
            Write-Host 'The verified installer is already downloaded.'
            return $installerPath
        }
        Write-Warning 'The existing installer has the wrong digest and will be replaced.'
    }

    $partialPath = $installerPath + '.download'
    if (Test-Path -LiteralPath $partialPath) {
        Remove-Item -LiteralPath $partialPath -Force
    }

    try {
        $downloaded = $false
        for ($attempt = 1; $attempt -le $DownloadRetryCount; $attempt++) {
            try {
                Write-Host ("Download attempt {0} of {1}..." -f $attempt, $DownloadRetryCount)
                Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent' = 'VS-IDE-Bridge-Codex-Setup' } `
                    -Uri $Release.Url -OutFile $partialPath -TimeoutSec 120
                $downloaded = $true
                break
            }
            catch {
                if (Test-Path -LiteralPath $partialPath) {
                    Remove-Item -LiteralPath $partialPath -Force
                }
                if ($attempt -eq $DownloadRetryCount) {
                    throw "Unable to download the installer after $DownloadRetryCount attempts: $($_.Exception.Message)"
                }
                Write-Warning ("Download attempt {0} failed: {1}" -f $attempt, $_.Exception.Message)
                Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 5))
            }
        }
        if (-not $downloaded) {
            throw 'The installer download did not complete.'
        }

        $downloadedBytes = (Get-Item -LiteralPath $partialPath).Length
        if ($downloadedBytes -le 0) {
            throw 'The downloaded installer is empty.'
        }
        Write-Host ("Downloaded:  {0:N0} bytes" -f $downloadedBytes)
        $actualHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $Release.Sha256) {
            throw "SHA-256 mismatch. Expected $($Release.Sha256), received $actualHash."
        }

        Move-Item -LiteralPath $partialPath -Destination $installerPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $partialPath) {
            Remove-Item -LiteralPath $partialPath -Force
        }
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        Write-Warning ("Installer Authenticode status is {0}; the published GitHub SHA-256 digest did match." -f $signature.Status)
    }
    else {
        Write-Host ("Authenticode signer: {0}" -f $signature.SignerCertificate.Subject)
    }

    Write-Host ("Verified SHA-256: {0}" -f $Release.Sha256)
    return $installerPath
}

function Install-SourceSnapshot {
    param($Release)

    if ($SkipSourceClone) {
        Write-Host 'Skipping the optional source checkout.'
        return
    }

    Write-Step 'Preparing the source checkout'
    if (Test-Path -LiteralPath $SourceRoot) {
        if (Test-Path -LiteralPath (Join-Path $SourceRoot '.git')) {
            Write-Host "Existing source checkout left untouched: $SourceRoot"
        }
        else {
            Write-Warning "Source path already exists and is not a Git checkout; leaving it untouched: $SourceRoot"
        }
        return
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-Warning 'Git is not installed; skipping the optional source checkout. The bridge runtime will still work.'
        return
    }

    & $git.Source clone --depth 1 --branch $Release.Tag $RepositoryUrl $SourceRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Git failed to clone the VS IDE Bridge source checkout.'
    }
}

function Install-Bridge {
    param(
        [string]$InstallerPath,
        [string]$ReleaseTag
    )

    Write-Step ("Installing VS IDE Bridge {0}" -f $ReleaseTag)
    $logPath = Join-Path $SetupRoot ("install-{0}.log" -f $ReleaseTag.TrimStart('v'))
    $installerArguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="{0}" /TASKS="service,startservice" /LOG="{1}"' -f `
        $InstallRoot.Replace('"', '""'), $logPath.Replace('"', '""')

    $process = Start-Process -FilePath $InstallerPath -ArgumentList $installerArguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "VS IDE Bridge installer exited with code $($process.ExitCode). See $logPath"
    }

    $serviceExecutable = Join-Path $InstallRoot 'service\VsIdeBridgeService.exe'
    $vsix = Join-Path $InstallRoot 'vsix\VsIdeBridge.vsix'
    $managedPython = Join-Path $InstallRoot 'python\managed-runtime\python.exe'

    foreach ($requiredPath in @($serviceExecutable, $vsix, $managedPython)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Installation completed but a required file is missing: $requiredPath"
        }
    }

    $service = Get-Service -Name 'VsIdeBridgeService' -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        throw 'Installation copied the runtime but did not register the VsIdeBridgeService Windows service.'
    }
    Write-Host ("Windows service: {0} ({1})" -f $service.Name, $service.Status)

    return $serviceExecutable
}

function Set-CodexBridgeConfiguration {
    param([string]$ServiceExecutable)

    Write-Step 'Configuring Codex STDIO transport'
    New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
    $configPath = Join-Path $CodexHome 'config.toml'
    $existing = ''
    if (Test-Path -LiteralPath $configPath) {
        $existing = [IO.File]::ReadAllText($configPath)
    }

    $newline = "`r`n"
    if ($existing.Contains("`n") -and -not $existing.Contains("`r`n")) {
        $newline = "`n"
    }

    $tomlPath = $ServiceExecutable.Replace('\', '\\').Replace('"', '\"')
    $blockLines = @(
        '[mcp_servers.vs-ide-bridge]',
        ('command = "{0}"' -f $tomlPath),
        'args = ["mcp-server"]',
        'enabled = true'
    )

    $inputLines = @()
    if (-not [string]::IsNullOrEmpty($existing)) {
        $inputLines = @([regex]::Split($existing, '\r?\n'))
    }

    $outputLines = New-Object System.Collections.Generic.List[string]
    $found = $false
    $skippingCurrentTable = $false
    foreach ($line in $inputLines) {
        if ($line -match '^\s*\[mcp_servers\.(?:vs-ide-bridge|"vs-ide-bridge"|''vs-ide-bridge'')\]\s*$') {
            if (-not $found) {
                foreach ($blockLine in $blockLines) {
                    $outputLines.Add($blockLine)
                }
                $found = $true
            }
            $skippingCurrentTable = $true
            continue
        }

        if ($skippingCurrentTable -and $line -match '^\s*\[') {
            $skippingCurrentTable = $false
        }

        if (-not $skippingCurrentTable) {
            $outputLines.Add($line)
        }
    }

    if (-not $found) {
        while ($outputLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($outputLines[$outputLines.Count - 1])) {
            $outputLines.RemoveAt($outputLines.Count - 1)
        }
        if ($outputLines.Count -gt 0) {
            $outputLines.Add('')
        }
        foreach ($blockLine in $blockLines) {
            $outputLines.Add($blockLine)
        }
    }

    $updated = ($outputLines -join $newline).TrimEnd("`r", "`n") + $newline
    if ($updated -ne $existing) {
        if (Test-Path -LiteralPath $configPath) {
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = $configPath + '.backup-' + $timestamp
            Copy-Item -LiteralPath $configPath -Destination $backupPath
            Write-Host "Backed up the previous Codex config to $backupPath"
        }
        $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
        $temporaryConfigPath = $configPath + '.new-' + [Guid]::NewGuid().ToString('N')
        try {
            [IO.File]::WriteAllText($temporaryConfigPath, $updated, $utf8WithoutBom)
            Move-Item -LiteralPath $temporaryConfigPath -Destination $configPath -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporaryConfigPath) {
                Remove-Item -LiteralPath $temporaryConfigPath -Force
            }
        }
    }

    Write-Host "Codex config: $configPath"
    return $configPath
}

function Set-AntigravityBridgeConfiguration {
    param([string]$ServiceExecutable)

    Write-Step 'Configuring Antigravity CLI STDIO transport'
    $antigravityConfigDirectory = Join-Path $env:USERPROFILE '.gemini\config'
    $configPath = Join-Path $antigravityConfigDirectory 'mcp_config.json'
    New-Item -ItemType Directory -Path $antigravityConfigDirectory -Force | Out-Null

    $root = $null
    if (Test-Path -LiteralPath $configPath) {
        $existing = [IO.File]::ReadAllText($configPath)
        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            try {
                $root = $existing | ConvertFrom-Json
            }
            catch {
                throw "Antigravity MCP config is not valid JSON and was left unchanged: $configPath. $($_.Exception.Message)"
            }
        }
    }
    if ($null -eq $root) {
        $root = New-Object PSObject
    }
    if ($root -is [Array] -or $root -is [string] -or $root -is [ValueType]) {
        throw "Antigravity MCP config must contain a JSON object and was left unchanged: $configPath"
    }

    $mcpServersProperty = $root.PSObject.Properties['mcpServers']
    if ($null -eq $mcpServersProperty -or $null -eq $mcpServersProperty.Value) {
        $mcpServers = New-Object PSObject
        $root | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value $mcpServers -Force
    }
    else {
        $mcpServers = $mcpServersProperty.Value
        if ($mcpServers -is [Array] -or $mcpServers -is [string] -or $mcpServers -is [ValueType]) {
            throw "Antigravity mcpServers must be a JSON object and was left unchanged: $configPath"
        }
    }

    $bridgeEntry = [ordered]@{
        command = $ServiceExecutable
        args = @('mcp-server')
    }
    $mcpServers | Add-Member -MemberType NoteProperty -Name 'vs-ide-bridge' `
        -Value ([pscustomobject]$bridgeEntry) -Force

    $updated = ($root | ConvertTo-Json -Depth 30) + "`r`n"
    if (-not (Test-Path -LiteralPath $configPath) -or [IO.File]::ReadAllText($configPath) -ne $updated) {
        if (Test-Path -LiteralPath $configPath) {
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = $configPath + '.backup-' + $timestamp
            Copy-Item -LiteralPath $configPath -Destination $backupPath
            Write-Host "Backed up the previous Antigravity config to $backupPath"
        }

        $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
        $temporaryConfigPath = $configPath + '.new-' + [Guid]::NewGuid().ToString('N')
        try {
            [IO.File]::WriteAllText($temporaryConfigPath, $updated, $utf8WithoutBom)
            Move-Item -LiteralPath $temporaryConfigPath -Destination $configPath -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporaryConfigPath) {
                Remove-Item -LiteralPath $temporaryConfigPath -Force
            }
        }
    }

    # Read the result back so a write or serialization failure is caught now.
    $readback = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $bridgeReadback = $readback.mcpServers.PSObject.Properties['vs-ide-bridge']
    if ($null -eq $bridgeReadback -or $bridgeReadback.Value.command -ne $ServiceExecutable -or `
        @($bridgeReadback.Value.args).Count -ne 1 -or $bridgeReadback.Value.args[0] -ne 'mcp-server') {
        throw 'Antigravity configuration readback did not contain the expected VS IDE Bridge entry.'
    }

    Write-Host "Antigravity config: $configPath"
    return $configPath
}

function Invoke-ClaudeCapture {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $claudeCommand = Get-Command claude -ErrorAction Stop | Select-Object -First 1
    $claudePath = if ($claudeCommand.Source) { $claudeCommand.Source } else { $claudeCommand.Path }
    if ([string]::IsNullOrWhiteSpace($claudePath)) {
        throw "The 'claude' command was found, but its executable/script path could not be resolved."
    }

    # Windows PowerShell turns a native command's redirected stderr into a terminating
    # NativeCommandError while $ErrorActionPreference is 'Stop'. 'claude mcp get' writes to
    # stderr and exits non-zero whenever the server is not registered yet, which is the normal
    # first-run state, so the probe has to stay non-terminating and be judged by its exit code.
    # The assignment is function scoped; the script-wide 'Stop' preference is unaffected.
    $ErrorActionPreference = 'Continue'

    $output = & $claudePath @Arguments 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ } } |
        Out-String
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
        Command = $claudePath
    }
}

function Set-ClaudeCodeBridgeConfiguration {
    param([string]$ServiceExecutable)

    Write-Step 'Configuring Claude Code STDIO transport'
    if ($null -eq (Get-Command claude -ErrorAction SilentlyContinue)) {
        throw "Claude Code is not available in PATH. Install it first, then rerun with -Client ClaudeCode. See https://docs.anthropic.com/en/docs/claude-code/getting-started"
    }

    # An existing registration can live in any scope, so a user-scope removal is allowed to
    # fail: the add below rewrites the user-scope entry and the readback proves the final state.
    $existing = Invoke-ClaudeCapture -Arguments @('mcp', 'get', 'vs-ide-bridge')
    if ($existing.ExitCode -eq 0) {
        $remove = Invoke-ClaudeCapture -Arguments @('mcp', 'remove', 'vs-ide-bridge', '--scope', 'user')
        if ($remove.ExitCode -ne 0) {
            Write-Warning "Could not remove the existing 'vs-ide-bridge' registration at user scope; it may belong to a project or local scope. Output: $($remove.Output.Trim())"
        }
    }

    $add = Invoke-ClaudeCapture -Arguments @(
        'mcp', 'add', 'vs-ide-bridge', '--scope', 'user', '--',
        $ServiceExecutable, 'mcp-server'
    )
    if ($add.ExitCode -ne 0) {
        throw "Adding Claude Code MCP registration 'vs-ide-bridge' failed. Output: $($add.Output)"
    }

    $readback = Invoke-ClaudeCapture -Arguments @('mcp', 'get', 'vs-ide-bridge')
    if ($readback.ExitCode -ne 0) {
        throw "Claude Code MCP registration was added, but could not be read back. Output: $($readback.Output)"
    }
    if ($readback.Output -notmatch [regex]::Escape($ServiceExecutable)) {
        throw "Claude Code resolves 'vs-ide-bridge' to a different command than the one just installed; a project or local scope entry is probably shadowing it. Output: $($readback.Output)"
    }

    Write-Host $readback.Output.TrimEnd()
    Write-Host 'Claude Code MCP registration verified at user scope.'
    return 'Claude Code user MCP configuration'
}

function Test-StdioHandshake {
    param([string]$ServiceExecutable)

    Write-Step 'Testing the MCP STDIO handshake'
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ServiceExecutable
    $startInfo.Arguments = 'mcp-server'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'The MCP process did not start.'
        }

        $request = @{
            jsonrpc = '2.0'
            id = 1
            method = 'initialize'
            params = @{
                protocolVersion = '2025-03-26'
                capabilities = @{}
                clientInfo = @{ name = 'vs-bridge-setup-check'; version = '1.0' }
            }
        } | ConvertTo-Json -Depth 8 -Compress

        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Flush()
        $readTask = $process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait(10000)) {
            throw 'Timed out waiting for the MCP initialize response.'
        }

        $responseLine = $readTask.Result
        if ([string]::IsNullOrWhiteSpace($responseLine)) {
            throw 'The MCP process returned an empty initialize response.'
        }
        $response = $responseLine | ConvertFrom-Json
        if ($null -eq $response.result -or $response.result.serverInfo.name -ne 'vs_ide_bridge') {
            throw 'The MCP initialize response did not identify VS IDE Bridge.'
        }

        $initialized = @{
            jsonrpc = '2.0'
            method = 'notifications/initialized'
        } | ConvertTo-Json -Compress
        $listTools = @{
            jsonrpc = '2.0'
            id = 2
            method = 'tools/list'
            params = @{}
        } | ConvertTo-Json -Depth 4 -Compress
        $process.StandardInput.WriteLine($initialized)
        $process.StandardInput.WriteLine($listTools)
        $process.StandardInput.Flush()
        $toolsTask = $process.StandardOutput.ReadLineAsync()
        if (-not $toolsTask.Wait(10000)) {
            throw 'Initialize succeeded, but tools/list timed out.'
        }
        $toolsResponse = $toolsTask.Result | ConvertFrom-Json
        $toolCount = @($toolsResponse.result.tools).Count
        if ($toolsResponse.id -ne 2 -or $toolCount -eq 0) {
            throw 'Initialize succeeded, but VS IDE Bridge returned no MCP tools.'
        }

        Write-Host ("Handshake succeeded: {0}, protocol {1}, {2} tools" -f `
            $response.result.serverInfo.name, $response.result.protocolVersion, $toolCount)
    }
    finally {
        try { $process.StandardInput.Close() } catch {}
        try {
            if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
                $process.Kill()
            }
        }
        catch {}
        $process.Dispose()
    }
}

function Main {
    Assert-SelectedClients
    Normalize-SetupPaths

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'VS IDE Bridge requires 64-bit Windows.'
    }

    if (-not (Test-Administrator)) {
        Invoke-SelfElevated -ScriptPath $PSCommandPath -ResolvedToolsRoot $ToolsRoot `
            -ResolvedCodexHome $CodexHome -SelectedClient $Client `
            -ShouldSkipSourceClone ([bool]$SkipSourceClone)
    }

    New-Item -ItemType Directory -Path $ToolsRoot -Force | Out-Null

    $release = Get-LatestRelease
    $installerPath = Get-VerifiedInstaller -Release $release
    Write-Host "Verified installer saved at: $installerPath"

    # Download first so a missing VS prerequisite does not make the script appear
    # to have skipped the bridge download. Installation still stops safely until
    # a supported Visual Studio instance is present.
    Assert-SupportedVisualStudio
    Install-SourceSnapshot -Release $release
    $serviceExecutable = Install-Bridge -InstallerPath $installerPath -ReleaseTag $release.Tag
    $configuredClients = New-Object System.Collections.Generic.List[string]
    if (Test-SelectedClient -Name 'Codex') {
        $configPath = Set-CodexBridgeConfiguration -ServiceExecutable $serviceExecutable
        $configuredClients.Add("Codex: $configPath")
    }
    if (Test-SelectedClient -Name 'Antigravity') {
        $antigravityConfigPath = Set-AntigravityBridgeConfiguration -ServiceExecutable $serviceExecutable
        $configuredClients.Add("Antigravity CLI: $antigravityConfigPath")
    }
    if (Test-SelectedClient -Name 'ClaudeCode') {
        $claudeCodeConfig = Set-ClaudeCodeBridgeConfiguration -ServiceExecutable $serviceExecutable
        $configuredClients.Add("Claude Code: $claudeCodeConfig")
    }
    Test-StdioHandshake -ServiceExecutable $serviceExecutable

    $fileVersion = (Get-Item -LiteralPath $serviceExecutable).VersionInfo.FileVersion
    Write-Host "`nSetup complete." -ForegroundColor Green
    Write-Host "  Release:     $($release.Tag)"
    Write-Host "  Runtime:     $InstallRoot"
    if (-not $SkipSourceClone) {
        Write-Host "  Source:      $SourceRoot"
    }
    foreach ($configuredClient in $configuredClients) {
        Write-Host "  $configuredClient"
    }
    Write-Host "  File version: $fileVersion"
    Write-Host ''
    Write-Host 'Next: open a solution in Visual Studio, restart the selected client, and type /mcp to verify the connection.'
}

if ($Help) {
    Show-Usage
    exit 0
}

try {
    Main
    exit 0
}
catch {
    Write-Host "`nSetup failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
