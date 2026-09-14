#Requires -Version 5.1
<#
.SYNOPSIS
    One-click Windows installer/updater for:
      - Chocolatey
      - Git
      - Python 3.12 (Python 3.10+ required by ghidra-mcp)
      - Maven 3.9+
      - Microsoft OpenJDK 21
      - uv
      - OpenAI Codex CLI (when selected)
      - Claude Code (when selected)
      - latest published stable bethington/ghidra-mcp release
      - the exact official Ghidra release required by that ghidra-mcp release

.DESCRIPTION
    The important compatibility rule is:
      1. Find the latest published ghidra-mcp release.
      2. Clone/update ghidra-mcp to that release tag.
      3. Read <ghidra.version> from that checked-out pom.xml.
      4. Download the matching official NSA Ghidra release ZIP.
      5. Build/deploy ghidra-mcp against that exact Ghidra version.
      6. Register the stdio bridge with the selected MCP clients.
      7. Write instructions using the ACTUAL versions/paths installed.

    This avoids installing "latest Ghidra" independently when ghidra-mcp
    requires a different version.

    Safe to rerun. Existing compatible Ghidra releases are reused. Existing
    ghidra-mcp clones are updated only when their working tree is clean.

.NOTES
    Default install root: C:\Tools
    The script relaunches itself as Administrator when needed.
#>

[CmdletBinding()]
param(
    [string]$ToolsRoot = "C:\Tools",
    [switch]$UseMcpDefaultBranch,
    [string[]]$Client = @('Codex')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$McpRepoOwner = "bethington"
$McpRepoName  = "ghidra-mcp"
$McpRepoUrl   = "https://github.com/$McpRepoOwner/$McpRepoName.git"

$GhidraRepoOwner = "NationalSecurityAgency"
$GhidraRepoName  = "ghidra"

$McpPath          = Join-Path $ToolsRoot "ghidra-mcp"
$InstructionsPath = Join-Path $ToolsRoot "GHIDRA_MCP_CODEX_INSTRUCTIONS.txt"
$LogPath          = Join-Path $ToolsRoot "GHIDRA_MCP_SETUP.log"

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
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-WarnMsg {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Refresh-Environment {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")

    $parts = @()
    if ($machinePath) { $parts += $machinePath }
    if ($userPath)    { $parts += $userPath }

    # Keep useful process-only additions such as uv if already present.
    if ($env:Path) { $parts += $env:Path }

    $env:Path = (($parts -join ";").Split(";") |
        Where-Object { $_ -and $_.Trim() } |
        Select-Object -Unique) -join ";"

    foreach ($name in @("JAVA_HOME", "M2_HOME", "MAVEN_HOME")) {
        $machineValue = [Environment]::GetEnvironmentVariable($name, "Machine")
        $userValue    = [Environment]::GetEnvironmentVariable($name, "User")
        if ($machineValue) {
            Set-Item -Path "Env:$name" -Value $machineValue
        } elseif ($userValue) {
            Set-Item -Path "Env:$name" -Value $userValue
        }
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Description,
        [int[]]$SuccessCodes = @(0)
    )

    Write-Step $Description
    & $FilePath @Arguments
    $code = $LASTEXITCODE

    if ($SuccessCodes -notcontains $code) {
        throw "$Description failed with exit code $code."
    }
}

function Invoke-GitHubApi {
    param([Parameter(Mandatory)][string]$Uri)

    $headers = @{
        "User-Agent" = "Ghidra-MCP-Codex-Setup"
        "Accept"     = "application/vnd.github+json"
    }

    # Allow an optional token to avoid unauthenticated GitHub API rate limits.
    if ($env:GITHUB_TOKEN) {
        $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"
    }

    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Install-ChocoPackageIfMissing {
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Command
    )

    Refresh-Environment
    if (Test-Command $Command) {
        Write-Ok "$Command is already available."
        return
    }

    Invoke-Native `
        -FilePath "choco" `
        -Arguments @("install", $Package, "-y", "--no-progress") `
        -Description "Installing Chocolatey package '$Package'" `
        -SuccessCodes @(0, 1641, 3010)

    Refresh-Environment

    if (-not (Test-Command $Command)) {
        throw "Chocolatey installed '$Package', but '$Command' is still unavailable in PATH."
    }
}

function Get-PythonVersion {
    try {
        $raw = (& python --version 2>&1 | Out-String).Trim()
        if ($raw -match 'Python\s+(\d+)\.(\d+)(?:\.(\d+))?') {
            $patch = if ($Matches[3]) { $Matches[3] } else { "0" }
            return [version]"$($Matches[1]).$($Matches[2]).$patch"
        }
    } catch {}
    return $null
}

function Get-MavenVersion {
    try {
        $raw = (& mvn -version 2>&1 | Out-String)
        if ($raw -match 'Apache Maven\s+(\d+\.\d+(?:\.\d+)?)') {
            return [version]$Matches[1]
        }
    } catch {}
    return $null
}

function Get-JavaVersionInfo {
    param(
        [string]$JavaExe = "java"
    )

    # java -version intentionally writes its version text to STDERR.
    # In Windows PowerShell 5.1, with $ErrorActionPreference = "Stop",
    # directly piping `java -version 2>&1` can become a terminating
    # NativeCommandError even though Java executed successfully.
    #
    # Capture stdout/stderr using Start-Process instead so version detection
    # is independent of PowerShell's native-stderr behavior.
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process `
            -FilePath $JavaExe `
            -ArgumentList @("-version") `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $raw = ""
        if (Test-Path $stdoutFile) {
            $raw += (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
        }
        if (Test-Path $stderrFile) {
            $raw += "`n" + (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }

        if ($raw -match 'version\s+"(\d+)(?:\.(\d+))?') {
            return [pscustomobject]@{
                Major    = [int]$Matches[1]
                Raw      = $raw.Trim()
                ExitCode = $process.ExitCode
                JavaExe  = $JavaExe
            }
        }

        return [pscustomobject]@{
            Major    = $null
            Raw      = $raw.Trim()
            ExitCode = $process.ExitCode
            JavaExe  = $JavaExe
        }
    } catch {
        return $null
    } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-JavaMajor {
    param(
        [string]$JavaExe = "java"
    )

    $info = Get-JavaVersionInfo -JavaExe $JavaExe
    if ($info) {
        return $info.Major
    }
    return $null
}

function Find-Jdk21 {
    # Do not use a local variable named $home here: PowerShell variable names
    # are case-insensitive, and $HOME is a built-in read-only variable.
    $candidateHomes = @()

    # Prefer JAVA_HOME if it already points to Java 21.
    if ($env:JAVA_HOME) {
        $candidateHomes += $env:JAVA_HOME
    }

    $machineJavaHome = [Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
    $userJavaHome = [Environment]::GetEnvironmentVariable("JAVA_HOME", "User")
    if ($machineJavaHome) { $candidateHomes += $machineJavaHome }
    if ($userJavaHome)    { $candidateHomes += $userJavaHome }

    $searchRoots = @(
        "C:\Program Files\Microsoft",
        "C:\Program Files\Eclipse Adoptium",
        "C:\Program Files\Java",
        "C:\Program Files\Amazon Corretto",
        "C:\Program Files\BellSoft",
        "C:\Program Files\Zulu"
    )

    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            $candidateHomes += Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName
        }
    }

    $candidateHomes = $candidateHomes |
        Where-Object { $_ } |
        Select-Object -Unique

    $valid = @()

    foreach ($jdkHome in $candidateHomes) {
        $javaExe = Join-Path $jdkHome "bin\java.exe"
        $javacExe = Join-Path $jdkHome "bin\javac.exe"

        # A JDK, not merely a JRE, is required.
        if ((Test-Path $javaExe) -and (Test-Path $javacExe)) {
            $info = Get-JavaVersionInfo -JavaExe $javaExe
            if ($info -and $info.Major -eq 21) {
                $valid += [pscustomobject]@{
                    Home    = $jdkHome
                    JavaExe = $javaExe
                    Info    = $info
                }
            }
        }
    }

    return $valid | Sort-Object Home -Descending | Select-Object -First 1
}

function Ensure-Java21Active {
    Refresh-Environment

    # If PATH already resolves to Java 21, still normalize JAVA_HOME when we can.
    $pathJavaInfo = Get-JavaVersionInfo -JavaExe "java"
    if ($pathJavaInfo -and $pathJavaInfo.Major -eq 21) {
        Write-Ok "Java 21 already resolves from PATH."
    }

    Write-Step "Locating an installed JDK 21"
    $jdk = Find-Jdk21

    if (-not $jdk) {
        throw "A usable JDK 21 installation could not be located."
    }

    # Validate the selected executable DIRECTLY before changing environment.
    if ((Get-JavaMajor -JavaExe $jdk.JavaExe) -ne 21) {
        throw "The selected JDK did not validate as Java 21: $($jdk.JavaExe)"
    }

    # JAVA_HOME is the important setting for Maven/Ghidra build tooling.
    [Environment]::SetEnvironmentVariable("JAVA_HOME", $jdk.Home, "Machine")
    $env:JAVA_HOME = $jdk.Home

    # Make this exact JDK first for the CURRENT installer process.
    $jdkBin = Join-Path $jdk.Home "bin"
    $env:Path = "$jdkBin;$env:Path"

    # Validate both the exact executable and PATH resolution using the robust
    # Start-Process based version reader.
    $directMajor = Get-JavaMajor -JavaExe $jdk.JavaExe
    $pathMajor   = Get-JavaMajor -JavaExe "java"

    if ($directMajor -ne 21) {
        throw "Direct Java 21 validation failed for $($jdk.JavaExe)."
    }

    if ($pathMajor -ne 21) {
        # Do not fail merely because Windows has another global Java shim.
        # Maven and the build will use JAVA_HOME, and we can invoke this JDK
        # directly when needed.
        Write-WarnMsg "Another Java is still globally preferred by Windows PATH, but JAVA_HOME is now pinned to JDK 21 for this setup."
    }

    Write-Ok "JAVA_HOME set to $($jdk.Home)."
    Write-Ok "Validated Java 21 directly at $($jdk.JavaExe)."
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Write-WarnMsg "Download attempt $attempt failed. Retrying..."
            Start-Sleep -Seconds 2
        }
    }
}

function Get-XmlElementValue {
    param(
        [Parameter(Mandatory)][string]$XmlPath,
        [Parameter(Mandatory)][string]$LocalName
    )

    [xml]$xml = Get-Content -LiteralPath $XmlPath -Raw
    $node = $xml.SelectSingleNode("//*[local-name()='$LocalName']")

    if (-not $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) {
        return $null
    }

    return $node.InnerText.Trim()
}

function Get-McpTarget {
    if ($UseMcpDefaultBranch) {
        Write-Step "Resolving ghidra-mcp default branch"
        $repo = Invoke-GitHubApi "https://api.github.com/repos/$McpRepoOwner/$McpRepoName"
        return [pscustomobject]@{
            Mode = "branch"
            Ref  = $repo.default_branch
            Name = "default branch '$($repo.default_branch)'"
        }
    }

    Write-Step "Resolving latest published stable ghidra-mcp release"

    try {
        $release = Invoke-GitHubApi "https://api.github.com/repos/$McpRepoOwner/$McpRepoName/releases/latest"

        if ($release -and $release.tag_name) {
            return [pscustomobject]@{
                Mode = "tag"
                Ref  = [string]$release.tag_name
                Name = "release $($release.tag_name)"
            }
        }
    } catch {
        Write-WarnMsg "No usable published ghidra-mcp release was returned; falling back to the repository default branch."
    }

    $repo = Invoke-GitHubApi "https://api.github.com/repos/$McpRepoOwner/$McpRepoName"
    return [pscustomobject]@{
        Mode = "branch"
        Ref  = $repo.default_branch
        Name = "default branch '$($repo.default_branch)'"
    }
}

function Sync-McpRepository {
    param([Parameter(Mandatory)]$Target)

    if (-not (Test-Path $McpPath)) {
        if ($Target.Mode -eq "tag") {
            Invoke-Native `
                -FilePath "git" `
                -Arguments @("clone", "--branch", $Target.Ref, "--depth", "1", $McpRepoUrl, $McpPath) `
                -Description "Cloning ghidra-mcp $($Target.Name) into $McpPath"
        } else {
            Invoke-Native `
                -FilePath "git" `
                -Arguments @("clone", "--branch", $Target.Ref, "--single-branch", $McpRepoUrl, $McpPath) `
                -Description "Cloning ghidra-mcp $($Target.Name) into $McpPath"
        }

        return [pscustomobject]@{
            Dirty         = $false
            UpdateSkipped = $false
            ReuseExisting = $false
            FreshClone    = $true
        }
    }

    if (-not (Test-Path (Join-Path $McpPath ".git"))) {
        throw "$McpPath already exists but is not a Git repository. Rename/delete that folder and rerun."
    }

    Push-Location $McpPath
    try {
        $dirtyText = (& git status --porcelain | Out-String).Trim()

        if (-not [string]::IsNullOrWhiteSpace($dirtyText)) {
            Write-WarnMsg "Local modifications were detected in $McpPath."
            Write-WarnMsg "The updater will NOT overwrite them. The current checkout will be reused."
            Write-WarnMsg "Automatic update to $($Target.Name) is skipped for this run."

            return [pscustomobject]@{
                Dirty         = $true
                UpdateSkipped = $true
                ReuseExisting = $false
                FreshClone    = $false
                DirtySummary  = $dirtyText
            }
        }

        # A previous successful run may already have the requested release
        # checked out. Reuse it before fetching or checking out again: this
        # keeps reruns offline-friendly and avoids an unnecessary tag checkout
        # failure when the installed files already match the selected release.
        if ($Target.Mode -eq 'tag') {
            $headCommit = (& git rev-parse --verify --quiet 'HEAD^{commit}' 2>$null | Out-String).Trim()
            $targetCommit = (& git rev-parse --verify --quiet "refs/tags/$($Target.Ref)^{commit}" 2>$null | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($headCommit) -and $headCommit -eq $targetCommit) {
                Write-Ok "Existing ghidra-mcp checkout already matches $($Target.Name); reusing installed files."
                return [pscustomobject]@{
                    Dirty         = $false
                    UpdateSkipped = $true
                    ReuseExisting = $true
                    FreshClone    = $false
                }
            }
        }

        Invoke-Native `
            -FilePath "git" `
            -Arguments @("fetch", "--tags", "--prune", "origin") `
            -Description "Fetching current ghidra-mcp refs"

        if ($Target.Mode -eq "tag") {
            $targetCommit = (& git rev-parse --verify --quiet "refs/tags/$($Target.Ref)^{commit}" 2>$null | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($targetCommit)) {
                throw "Git fetch completed, but release tag '$($Target.Ref)' is not available in the local ghidra-mcp checkout."
            }
            Invoke-Native `
                -FilePath "git" `
                -Arguments @("checkout", "--detach", "--force", $targetCommit) `
                -Description "Checking out ghidra-mcp $($Target.Name)"
        } else {
            & git show-ref --verify --quiet "refs/heads/$($Target.Ref)"
            if ($LASTEXITCODE -eq 0) {
                Invoke-Native `
                    -FilePath "git" `
                    -Arguments @("checkout", $Target.Ref) `
                    -Description "Checking out ghidra-mcp branch $($Target.Ref)"
            } else {
                Invoke-Native `
                    -FilePath "git" `
                    -Arguments @("checkout", "-B", $Target.Ref, "origin/$($Target.Ref)") `
                    -Description "Creating local ghidra-mcp branch $($Target.Ref)"
            }

            Invoke-Native `
                -FilePath "git" `
                -Arguments @("reset", "--hard", "origin/$($Target.Ref)") `
                -Description "Updating ghidra-mcp branch $($Target.Ref)"
        }

        return [pscustomobject]@{
            Dirty         = $false
            UpdateSkipped = $false
            ReuseExisting = $false
            FreshClone    = $false
        }
    } finally {
        Pop-Location
    }
}

function Get-CurrentMcpCheckoutIdentity {
    Push-Location $McpPath
    try {
        $commit = (& git rev-parse HEAD | Out-String).Trim()

        $exactTag = (& git describe --tags --exact-match HEAD 2>$null | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($exactTag)) {
            return [pscustomobject]@{
                Ref         = $exactTag
                Description = "existing checkout tag $exactTag"
                Commit      = $commit
            }
        }

        $branch = (& git branch --show-current 2>$null | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($branch)) {
            return [pscustomobject]@{
                Ref         = $branch
                Description = "existing checkout branch '$branch'"
                Commit      = $commit
            }
        }

        return [pscustomobject]@{
            Ref         = $commit
            Description = "existing checkout commit $commit"
            Commit      = $commit
        }
    } finally {
        Pop-Location
    }
}

function Test-ExistingMcpDeployment {
    param(
        [Parameter(Mandatory)][string]$GhidraPath,
        [Parameter(Mandatory)][string]$GhidraVersion,
        [Parameter(Mandatory)][string]$McpVersion
    )

    $archive = Get-ChildItem `
        -Path (Join-Path $GhidraPath "Extensions\Ghidra\GhidraMCP-$McpVersion.zip") `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $wheel = Get-ChildItem `
        -Path (Join-Path $GhidraPath "ghidra_mcp_bridge-$McpVersion-*.whl") `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $userExtension = Join-Path `
        ([Environment]::GetFolderPath("ApplicationData")) `
        "ghidra\ghidra_${GhidraVersion}_PUBLIC\Extensions\GhidraMCP"

    return [bool](
        $archive -and
        $wheel -and
        (Test-Path $userExtension)
    )
}

function Get-GhidraReleaseForVersion {
    param([Parameter(Mandatory)][string]$RequiredVersion)

    Write-Step "Finding official Ghidra $RequiredVersion release"

    $page = 1
    $matchingRelease = $null

    while ($page -le 5 -and -not $matchingRelease) {
        $releases = Invoke-GitHubApi "https://api.github.com/repos/$GhidraRepoOwner/$GhidraRepoName/releases?per_page=100&page=$page"

        if (-not $releases -or $releases.Count -eq 0) {
            break
        }

        $matchingRelease = $releases |
            Where-Object { $_.tag_name -eq "Ghidra_${RequiredVersion}_build" } |
            Select-Object -First 1

        if ($releases.Count -lt 100) {
            break
        }

        $page++
    }

    if (-not $matchingRelease) {
        throw "Could not find the official GitHub release tag Ghidra_${RequiredVersion}_build."
    }

    $asset = $matchingRelease.assets |
        Where-Object {
            $_.name -match "^ghidra_$([regex]::Escape($RequiredVersion))_PUBLIC_\d+\.zip$"
        } |
        Select-Object -First 1

    if (-not $asset) {
        # Fallback for future official naming changes while still avoiding source archives.
        $asset = $matchingRelease.assets |
            Where-Object {
                $_.name -like "ghidra_${RequiredVersion}_PUBLIC_*.zip"
            } |
            Select-Object -First 1
    }

    if (-not $asset) {
        throw "Official Ghidra $RequiredVersion release found, but no prebuilt PUBLIC ZIP asset was found."
    }

    $sha256 = $null

    if ($asset.PSObject.Properties.Name -contains "digest" -and $asset.digest) {
        $digest = [string]$asset.digest
        if ($digest -match '^sha256:([a-fA-F0-9]{64})$') {
            $sha256 = $Matches[1].ToLowerInvariant()
        }
    }

    if (-not $sha256 -and $matchingRelease.body) {
        $body = [string]$matchingRelease.body
        if ($body -match '(?i)SHA-?256[^a-fA-F0-9]*([a-fA-F0-9]{64})') {
            $sha256 = $Matches[1].ToLowerInvariant()
        }
    }

    return [pscustomobject]@{
        Release = $matchingRelease
        Asset   = $asset
        Sha256  = $sha256
    }
}

function Ensure-GhidraInstalled {
    param(
        [Parameter(Mandatory)][string]$RequiredVersion,
        [Parameter(Mandatory)]$ReleaseInfo
    )

    $ghidraPath = Join-Path $ToolsRoot "ghidra_${RequiredVersion}_PUBLIC"
    $launcher   = Join-Path $ghidraPath "ghidraRun.bat"

    if (Test-Path $launcher) {
        Write-Ok "Compatible Ghidra $RequiredVersion already exists at $ghidraPath."
        return $ghidraPath
    }

    if (Test-Path $ghidraPath) {
        throw @"
$ghidraPath exists but does not contain ghidraRun.bat.
Rename/delete that incomplete directory and rerun the installer.
"@
    }

    $zipPath = Join-Path $ToolsRoot $ReleaseInfo.Asset.name

    Write-Step "Downloading official Ghidra $RequiredVersion release: $($ReleaseInfo.Asset.name)"

    if (Test-Path $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Download-File `
        -Uri $ReleaseInfo.Asset.browser_download_url `
        -Destination $zipPath

    if ($ReleaseInfo.Sha256) {
        Write-Step "Verifying official Ghidra SHA-256"
        $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($actualHash -ne $ReleaseInfo.Sha256) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            throw "Ghidra SHA-256 mismatch. Expected $($ReleaseInfo.Sha256), got $actualHash."
        }

        Write-Ok "Ghidra SHA-256 verified."
    } else {
        Write-WarnMsg "The GitHub release metadata did not expose a SHA-256 value. The ZIP will be extracted without an automated checksum comparison."
    }

    Write-Step "Extracting Ghidra $RequiredVersion into $ToolsRoot"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $ToolsRoot -Force
    Remove-Item -LiteralPath $zipPath -Force

    if (-not (Test-Path $launcher)) {
        throw "Ghidra extraction finished, but $launcher was not found."
    }

    Write-Ok "Ghidra $RequiredVersion installed at $ghidraPath."
    return $ghidraPath
}

function Invoke-GhidraMcpDeploy {
    param(
        [Parameter(Mandatory)][string]$GhidraPath,
        [Parameter(Mandatory)][string]$McpVersion
    )

    Write-Step "Deploying ghidra-mcp to Ghidra $requiredGhidraVersion"

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $proc = Start-Process `
            -FilePath "python" `
            -ArgumentList @(
                "-m", "tools.setup",
                "deploy",
                "--ghidra-path", $GhidraPath
            ) `
            -WorkingDirectory $McpPath `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $stdout = ""
        $stderr = ""

        if (Test-Path $stdoutFile) {
            $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path $stderrFile) {
            $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        }

        if ($stdout) { Write-Host $stdout.TrimEnd() }
        if ($stderr) { Write-Host $stderr.TrimEnd() }

        if ($proc.ExitCode -eq 0) {
            Write-Ok "ghidra-mcp deployment completed successfully."
            return [pscustomobject]@{
                FullyReady = $true
                NeedsProject = $false
                ExitCode = 0
            }
        }

        $combined = "$stdout`n$stderr"

        # tools.setup deploy performs TWO jobs:
        #   1. installs/copies the extension and bridge artifacts
        #   2. starts Ghidra and waits for an open project so it can run live checks
        #
        # On a brand-new installation there is naturally no project yet. In that
        # specific case the files can be correctly installed even though deploy
        # returns exit code 1 while waiting for a project. We verify the installed
        # artifacts before treating this as a soft-success.
        $userExtension = Join-Path `
            ([Environment]::GetFolderPath("ApplicationData")) `
            "ghidra\ghidra_${requiredGhidraVersion}_PUBLIC\Extensions\GhidraMCP"

        $installArchivePattern = Join-Path `
            $GhidraPath `
            "Extensions\Ghidra\GhidraMCP-*.zip"

        $bridgeWheelPattern = Join-Path `
            $GhidraPath `
            "ghidra_mcp_bridge-*.whl"

        $archiveFound = $null -ne (Get-ChildItem -Path $installArchivePattern -ErrorAction SilentlyContinue | Select-Object -First 1)
        $wheelFound   = $null -ne (Get-ChildItem -Path $bridgeWheelPattern -ErrorAction SilentlyContinue | Select-Object -First 1)
        $userExtFound = Test-Path $userExtension

        $isNoProjectOnly = (
            $combined -match '(?i)No project is currently open' -or
            $combined -match '(?i)Ghidra project did not become ready'
        )

        if ($isNoProjectOnly -and $archiveFound -and $wheelFound -and $userExtFound) {
            Write-WarnMsg "The extension and bridge were installed successfully, but Ghidra has no project open yet."
            Write-WarnMsg "This is normal on a fresh setup. Setup will continue and Codex will be registered."
            Write-WarnMsg "Create/open a Ghidra project, import your EXE, then start/validate GhidraMCP."

            return [pscustomobject]@{
                FullyReady = $false
                NeedsProject = $true
                ExitCode = $proc.ExitCode
            }
        }

        throw "Deploying ghidra-mcp failed with exit code $($proc.ExitCode). This was not the expected fresh-install 'no project open' condition."
    } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-CmdQuotedArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    # Quote for cmd.exe. Double any embedded quotes and protect cmd metacharacters
    # by keeping the entire argument quoted.
    return '"' + ($Value -replace '"', '""') + '"'
}

function Invoke-CommandCapture {
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $command = Get-Command $CommandName -ErrorAction Stop | Select-Object -First 1
        $commandPath = $command.Source

        if ([string]::IsNullOrWhiteSpace($commandPath)) {
            $commandPath = $command.Path
        }

        if ([string]::IsNullOrWhiteSpace($commandPath)) {
            throw "The '$CommandName' command was found, but its executable/script path could not be resolved."
        }

        $extension = [System.IO.Path]::GetExtension($commandPath).ToLowerInvariant()

        if ($extension -eq ".cmd" -or $extension -eq ".bat") {
            # npm installs many CLIs on Windows as a .cmd shim. Start-Process cannot
            # execute that shim directly when output redirection is enabled, so
            # invoke it through cmd.exe.
            $parts = @((ConvertTo-CmdQuotedArgument $commandPath))
            foreach ($argValue in $Arguments) {
                $parts += (ConvertTo-CmdQuotedArgument $argValue)
            }

            $commandLine = $parts -join " "

            $proc = Start-Process `
                -FilePath "$env:ComSpec" `
                -ArgumentList @("/d", "/s", "/c", $commandLine) `
                -NoNewWindow `
                -Wait `
                -PassThru `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile
        }
        elseif ($extension -eq ".ps1") {
            # Some npm/PowerShell installations expose codex.ps1 instead.
            $psArgs = @(
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy", "Bypass",
                "-File", $commandPath
            ) + $Arguments

            $proc = Start-Process `
                -FilePath "powershell.exe" `
                -ArgumentList $psArgs `
                -NoNewWindow `
                -Wait `
                -PassThru `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile
        }
        else {
            # Native executable case.
            $proc = Start-Process `
                -FilePath $commandPath `
                -ArgumentList $Arguments `
                -NoNewWindow `
                -Wait `
                -PassThru `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile
        }

        $stdout = ""
        $stderr = ""

        if (Test-Path $stdoutFile) {
            $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        }

        if (Test-Path $stderrFile) {
            $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        }

        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
            Command  = $commandPath
        }
    } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CodexCapture {
    param([Parameter(Mandatory)][string[]]$Arguments)
    return Invoke-CommandCapture -CommandName 'codex' -Arguments $Arguments
}

function Invoke-ClaudeCapture {
    param([Parameter(Mandatory)][string[]]$Arguments)
    return Invoke-CommandCapture -CommandName 'claude' -Arguments $Arguments
}

function Test-CodexMcpRegistration {
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $result = Invoke-CodexCapture -Arguments @("mcp", "get", $Name, "--json")

    if ($result.ExitCode -eq 0) {
        return $true
    }

    $combined = "$($result.StdOut)`n$($result.StdErr)"

    if ($combined -match "(?i)No MCP server named") {
        return $false
    }

    throw "Could not determine whether Codex MCP server '$Name' exists. Exit code $($result.ExitCode). Output: $combined"
}

function Ensure-CodexMcpRegistration {
    Write-Step "Registering ghidra MCP bridge with Codex"

    $exists = Test-CodexMcpRegistration -Name "ghidra"

    if ($exists) {
        Write-Step "Removing existing Codex MCP registration named 'ghidra'"

        $removeResult = Invoke-CodexCapture -Arguments @("mcp", "remove", "ghidra")

        if ($removeResult.ExitCode -ne 0) {
            $combined = "$($removeResult.StdOut)`n$($removeResult.StdErr)"
            throw "Could not remove existing Codex MCP registration 'ghidra'. Output: $combined"
        }

        Write-Ok "Existing Codex MCP registration removed."
    } else {
        Write-Ok "No existing Codex MCP registration named 'ghidra' was found."
    }

    $addResult = Invoke-CodexCapture -Arguments @(
        "mcp", "add", "ghidra", "--",
        "uv", "run",
        "--directory", $McpPath,
        "bridge-mcp-ghidra"
    )

    if ($addResult.StdOut) { Write-Host $addResult.StdOut.TrimEnd() }
    if ($addResult.StdErr) { Write-Host $addResult.StdErr.TrimEnd() }

    if ($addResult.ExitCode -ne 0) {
        throw "Adding Codex MCP registration 'ghidra' failed with exit code $($addResult.ExitCode)."
    }

    Write-Step "Reading back Codex MCP registration"

    $verifyResult = Invoke-CodexCapture -Arguments @("mcp", "get", "ghidra", "--json")

    if ($verifyResult.StdOut) {
        Write-Host $verifyResult.StdOut.TrimEnd()
    }

    if ($verifyResult.StdErr) {
        Write-Host $verifyResult.StdErr.TrimEnd()
    }

    if ($verifyResult.ExitCode -ne 0) {
        throw "Codex MCP registration was added, but could not be read back."
    }

    Write-Ok "Codex MCP registration verified."
}

function Ensure-ClaudeCodeMcpRegistration {
    Write-Step "Registering ghidra MCP bridge with Claude Code"

    $existing = Invoke-ClaudeCapture -Arguments @('mcp', 'get', 'ghidra')
    if ($existing.ExitCode -eq 0) {
        $remove = Invoke-ClaudeCapture -Arguments @('mcp', 'remove', 'ghidra', '--scope', 'user')
        if ($remove.ExitCode -ne 0) {
            throw "Could not remove existing Claude Code MCP registration 'ghidra'. Output: $($remove.StdOut)`n$($remove.StdErr)"
        }
    }

    $add = Invoke-ClaudeCapture -Arguments @(
        'mcp', 'add', 'ghidra', '--scope', 'user', '--',
        'uv', 'run', '--directory', $McpPath, 'bridge-mcp-ghidra'
    )
    if ($add.ExitCode -ne 0) {
        throw "Adding Claude Code MCP registration 'ghidra' failed. Output: $($add.StdOut)`n$($add.StdErr)"
    }

    $readback = Invoke-ClaudeCapture -Arguments @('mcp', 'get', 'ghidra')
    if ($readback.ExitCode -ne 0) {
        throw "Claude Code MCP registration was added, but could not be read back. Output: $($readback.StdOut)`n$($readback.StdErr)"
    }
    if ($readback.StdOut) { Write-Host $readback.StdOut.TrimEnd() }
    Write-Ok 'Claude Code MCP registration verified at user scope.'
}

function Set-AntigravityGhidraConfiguration {
    Write-Step 'Registering ghidra MCP bridge with Antigravity CLI'

    $configDirectory = Join-Path $env:USERPROFILE '.gemini\config'
    $configPath = Join-Path $configDirectory 'mcp_config.json'
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null

    $root = $null
    if (Test-Path -LiteralPath $configPath) {
        $existing = [IO.File]::ReadAllText($configPath)
        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            try { $root = $existing | ConvertFrom-Json }
            catch { throw "Antigravity MCP config is not valid JSON and was left unchanged: $configPath. $($_.Exception.Message)" }
        }
    }
    if ($null -eq $root) { $root = New-Object PSObject }
    if ($root -is [Array] -or $root -is [string] -or $root -is [ValueType]) {
        throw "Antigravity MCP config must contain a JSON object and was left unchanged: $configPath"
    }

    $serversProperty = $root.PSObject.Properties['mcpServers']
    if ($null -eq $serversProperty -or $null -eq $serversProperty.Value) {
        $servers = New-Object PSObject
        $root | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value $servers -Force
    } else {
        $servers = $serversProperty.Value
        if ($servers -is [Array] -or $servers -is [string] -or $servers -is [ValueType]) {
            throw "Antigravity mcpServers must be a JSON object and was left unchanged: $configPath"
        }
    }

    $servers | Add-Member -MemberType NoteProperty -Name 'ghidra' -Value ([pscustomobject][ordered]@{
        command = 'uv'
        args = @('run', '--directory', $McpPath, 'bridge-mcp-ghidra')
    }) -Force

    $updated = ($root | ConvertTo-Json -Depth 30) + "`r`n"
    if (-not (Test-Path -LiteralPath $configPath) -or [IO.File]::ReadAllText($configPath) -ne $updated) {
        if (Test-Path -LiteralPath $configPath) {
            $backupPath = $configPath + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $configPath -Destination $backupPath
            Write-Host "Backed up the previous Antigravity config to $backupPath"
        }
        $temporaryPath = $configPath + '.new-' + [Guid]::NewGuid().ToString('N')
        try {
            [IO.File]::WriteAllText($temporaryPath, $updated, (New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $temporaryPath -Destination $configPath -Force
        } finally {
            if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        }
    }

    $readback = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $entry = $readback.mcpServers.PSObject.Properties['ghidra']
    if ($null -eq $entry -or $entry.Value.command -ne 'uv' -or @($entry.Value.args).Count -ne 4) {
        throw 'Antigravity configuration readback did not contain the expected ghidra entry.'
    }
    Write-Ok "Antigravity MCP registration verified: $configPath"
}


function Write-DynamicInstructions {
    param(
        [Parameter(Mandatory)][string]$McpTargetDescription,
        [Parameter(Mandatory)][string]$McpRef,
        [Parameter(Mandatory)][string]$McpCommit,
        [Parameter(Mandatory)][string]$McpProjectVersion,
        [Parameter(Mandatory)][string]$GhidraVersion,
        [Parameter(Mandatory)][string]$GhidraPath,
        [Parameter(Mandatory)][string]$GhidraAssetName,
        [Parameter(Mandatory)][bool]$NeedsProject
    )

    $guide = @"
GHIDRA MCP + CODEX SETUP
========================
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

THIS FILE IS GENERATED FROM WHAT THE INSTALLER ACTUALLY INSTALLED.
Do not substitute a different Ghidra version unless ghidra-mcp's pom.xml
requires that version.


INSTALLED / SELECTED VERSIONS
-----------------------------
ghidra-mcp selection:
$McpTargetDescription

ghidra-mcp ref:
$McpRef

ghidra-mcp commit:
$McpCommit

ghidra-mcp project version:
$McpProjectVersion

Ghidra version required by this ghidra-mcp checkout:
$GhidraVersion

Official Ghidra release asset used:
$GhidraAssetName

Deployment state:
$(if ($NeedsProject) { "Extension installed; Ghidra needs a project opened before live MCP validation." } else { "Extension installed and live deployment checks completed." })


INSTALLED PATHS
---------------
Ghidra application:
$GhidraPath

Ghidra launcher:
$GhidraPath\ghidraRun.bat

ghidra-mcp:
$McpPath

Setup log:
$LogPath


WHAT THE INSTALLER ALREADY DID
------------------------------
1. Installed/validated Chocolatey.
2. Installed/validated Git.
3. Installed/validated Python 3.10+.
4. Installed/validated Maven 3.9+.
5. Installed/located OpenJDK 21 and pinned JAVA_HOME to the exact JDK used.
6. Installed/validated uv.
7. Installed/validated the selected MCP client CLIs.
8. Selected $McpTargetDescription.
9. Checked out ghidra-mcp ref '$McpRef'.
10. Read Ghidra version '$GhidraVersion' from:
    $McpPath\pom.xml
11. Downloaded/reused the matching official Ghidra release.
12. Ran:
    python -m tools.setup preflight --ghidra-path "$GhidraPath"
    python -m tools.setup ensure-prereqs --ghidra-path "$GhidraPath"
    python -m tools.setup build
    python -m tools.setup deploy --ghidra-path "$GhidraPath"
13. Registered this stdio bridge with the selected clients:
    uv run --directory "$McpPath" bridge-mcp-ghidra

$(if ($NeedsProject) {
@" 
IMPORTANT: The extension files are installed, but the automatic deploy command
could not finish its live project check because this is a fresh Ghidra install
with no project open yet. This is expected.

Continue with the project-creation steps below. You do NOT need to rebuild the
plugin first.
"@
} else { "" })


CREATE A GHIDRA PROJECT FOR A WINDOWS GAME EXE
----------------------------------------------
1. Start Ghidra if it is not already running:

   "$GhidraPath\ghidraRun.bat"

2. In the Ghidra project window choose:
   File > New Project

3. Choose:
   Non-Shared Project

4. Pick a project folder and project name.

5. Import the game:
   File > Import File

6. Select the game's .exe.

7. For a normal Windows executable, Ghidra should detect Portable Executable
   (PE). Keep the detected format unless you know the file needs something
   different.

8. Double-click the imported EXE to open it in CodeBrowser.

9. When asked whether to analyze the program, choose Yes.
   Default analyzers are a sensible starting point.

10. If Ghidra reports newly installed plugins and asks whether to configure
    them, choose Yes.

11. Make sure GhidraMCP is enabled:
    File > Configure > Configure All Plugins
    Search for:
    GhidraMCP
    Enable it if it is not already enabled.

12. With the project/program open, use the Ghidra window containing the menu:
    Tools > GhidraMCP > Start MCP Server


VALIDATE THE GHIDRA-SIDE SERVER
-------------------------------
Do this only AFTER:
- a Ghidra project exists,
- your game EXE is imported/open in CodeBrowser, and
- GhidraMCP is enabled/started.

Keep Ghidra open with the game loaded.

In PowerShell:

curl.exe http://127.0.0.1:8089/check_connection

A healthy response should indicate that GhidraMCP is running and identify the
open program.

Optional version check:

curl.exe http://127.0.0.1:8089/get_version


VALIDATE THE MCP CLIENT REGISTRATION
-----------------------------------
In PowerShell:

$(if (Test-SelectedClient -Name 'Codex') { 'codex mcp list' })

Then:

$(if (Test-SelectedClient -Name 'Codex') { 'codex mcp get ghidra --json' })
$(if ((Test-SelectedClient -Name 'Codex') -and (Test-SelectedClient -Name 'ClaudeCode')) { "`r`nOr, for Claude Code:" })
$(if (Test-SelectedClient -Name 'ClaudeCode') { 'claude mcp get ghidra' })

The registered command should resolve to the ghidra-mcp checkout at:

$McpPath


USE GHIDRA FROM YOUR SELECTED CLIENT
---------------------
1. Keep Ghidra open.
2. Keep the game EXE open in Ghidra.
3. Make sure the GhidraMCP server is started.
4. Start your selected client, for example:

$(if (Test-SelectedClient -Name 'Codex') { '   codex' })
$(if (Test-SelectedClient -Name 'ClaudeCode') { '   claude' })

5. First read-only test prompt:

   Using the Ghidra MCP server, list the currently open programs and identify
   the active program. Do not modify anything.

6. Second read-only test prompt:

   Using Ghidra, report the active program's name, executable format,
   processor architecture, image base, and entry point. Do not modify anything.


IMPORTANT SAFETY NOTE
---------------------
Ghidra MCP exposes write-capable operations too. Depending on the tool call,
Codex can rename functions, add comments, change types, and perform other
changes.

Until you intentionally want write operations, include:

Do not rename, modify, patch, or write anything.

Keep Ghidra MCP bound to localhost. Do not expose ports 8089 or 8081 directly
to the public internet.


UPDATING LATER
--------------
Rerun the SAME installer script.

On each rerun it will:
1. Ask GitHub for the latest published stable ghidra-mcp release.
2. Update the ghidra-mcp checkout to that release when the working tree is clean.
   If local modifications exist, preserve them and reuse the current checkout.
3. Read the Ghidra version required by the checkout actually being used from pom.xml.
4. Download that matching official Ghidra release if it is not already in
   C:\Tools.
5. Rebuild/redeploy the plugin.
6. Refresh the Codex MCP registration.
7. Rewrite this instruction file using the versions actually selected.

This means a future ghidra-mcp update can move to a newer Ghidra version
without hard-coded instructions becoming stale.


TROUBLESHOOTING
---------------
Check versions:

python --version
java -version
mvn -version
git --version
uv --version
codex --version

Check Ghidra MCP:

curl.exe http://127.0.0.1:8089/check_connection

Check Codex registration:

codex mcp list
codex mcp get ghidra --json

If 'ghidra' is not registered yet, that is not an installation error; the installer will add it.`nOn Windows, npm may expose Codex through codex.cmd/codex.ps1; the installer handles those shims automatically.

Manual bridge launch:

cd "$McpPath"
uv run bridge-mcp-ghidra

Repository-supported setup checks:

cd "$McpPath"
python -m tools.setup preflight --strict --ghidra-path "$GhidraPath"

Full setup log:

$LogPath
"@

    Set-Content -LiteralPath $InstructionsPath -Value $guide -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Administrator relaunch
# ---------------------------------------------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Administrator rights are required. Windows will show a UAC prompt." -ForegroundColor Yellow

    $relaunchArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath),
        "-ToolsRoot", ('"{0}"' -f $ToolsRoot)
    )

    if ($UseMcpDefaultBranch) {
        $relaunchArgs += "-UseMcpDefaultBranch"
    }
    $relaunchArgs += "-Client", ('"{0}"' -f ($Client -join ','))

    Start-Process powershell.exe -Verb RunAs -ArgumentList $relaunchArgs
    exit
}

Assert-SelectedClients
New-Item -ItemType Directory -Path $ToolsRoot -Force | Out-Null

try {
    Start-Transcript -LiteralPath $LogPath -Append | Out-Null
} catch {
    Write-WarnMsg "Could not start transcript logging: $($_.Exception.Message)"
}

try {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " Dynamic Ghidra + ghidra-mcp + Codex Setup" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Install root: $ToolsRoot"

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # STEP 1 - Chocolatey
    Refresh-Environment
    if (-not (Test-Command choco)) {
        Write-Step "Installing Chocolatey"

        Set-ExecutionPolicy Bypass -Scope Process -Force
        $chocoInstall = (New-Object Net.WebClient).DownloadString(
            "https://community.chocolatey.org/install.ps1"
        )
        Invoke-Expression $chocoInstall
        Refresh-Environment

        if (-not (Test-Command choco)) {
            throw "Chocolatey installation finished, but choco.exe is unavailable."
        }
    }
    Write-Ok "Chocolatey is available."

    # STEP 2 - Git
    Install-ChocoPackageIfMissing -Package "git" -Command "git"

    # STEP 3 - Select/sync latest stable ghidra-mcp now that Git is available.
    $mcpTarget = Get-McpTarget
    $mcpSync = Sync-McpRepository -Target $mcpTarget

    if (-not (Test-Path (Join-Path $McpPath "pom.xml"))) {
        throw "The ghidra-mcp checkout is missing pom.xml."
    }

    $currentCheckout = Get-CurrentMcpCheckoutIdentity
    $mcpCommit = $currentCheckout.Commit

    if ($mcpSync.ReuseExisting) {
        $effectiveMcpDescription = "$($currentCheckout.Description) (reused because it already matches the selected release)"
        $effectiveMcpRef = $currentCheckout.Ref
    } elseif ($mcpSync.UpdateSkipped) {
        $effectiveMcpDescription = "$($currentCheckout.Description) (automatic update skipped because local modifications are present)"
        $effectiveMcpRef = $currentCheckout.Ref
    } else {
        $effectiveMcpDescription = $mcpTarget.Name
        $effectiveMcpRef = $mcpTarget.Ref
    }

    $requiredGhidraVersion = Get-XmlElementValue `
        -XmlPath (Join-Path $McpPath "pom.xml") `
        -LocalName "ghidra.version"

    $mcpProjectVersion = Get-XmlElementValue `
        -XmlPath (Join-Path $McpPath "pom.xml") `
        -LocalName "version"

    if ([string]::IsNullOrWhiteSpace($requiredGhidraVersion)) {
        throw "Could not read <ghidra.version> from $McpPath\pom.xml."
    }

    if ([string]::IsNullOrWhiteSpace($mcpProjectVersion)) {
        $mcpProjectVersion = "(not detected)"
    }

    Write-Ok "Using ghidra-mcp $effectiveMcpDescription."
    Write-Ok "ghidra-mcp commit: $mcpCommit"
    Write-Ok "ghidra-mcp requires Ghidra $requiredGhidraVersion."

    # STEP 4 - Python >= 3.10
    $pythonVersion = Get-PythonVersion
    if (($null -eq $pythonVersion) -or ($pythonVersion -lt [version]"3.10")) {
        Invoke-Native `
            -FilePath "choco" `
            -Arguments @("install", "python312", "-y", "--no-progress") `
            -Description "Installing stable Python 3.12" `
            -SuccessCodes @(0, 1641, 3010)

        Refresh-Environment
        $pythonVersion = Get-PythonVersion
    }

    if (($null -eq $pythonVersion) -or ($pythonVersion -lt [version]"3.10")) {
        throw "Python 3.10+ is required, but the active python.exe is missing or too old."
    }
    Write-Ok "Python $pythonVersion is active."

    # STEP 5 - Maven >= 3.9
    $mavenVersion = Get-MavenVersion
    if (($null -eq $mavenVersion) -or ($mavenVersion -lt [version]"3.9")) {
        Invoke-Native `
            -FilePath "choco" `
            -Arguments @("upgrade", "maven", "-y", "--no-progress") `
            -Description "Installing/upgrading Maven to 3.9+" `
            -SuccessCodes @(0, 1641, 3010)

        Refresh-Environment
        $mavenVersion = Get-MavenVersion
    }

    if (($null -eq $mavenVersion) -or ($mavenVersion -lt [version]"3.9")) {
        throw "Maven 3.9+ is required, but the active mvn is missing or too old."
    }
    Write-Ok "Maven $mavenVersion is active."

    # STEP 6 - Java 21
    # Detect a real JDK 21 directly. Do not rely on whichever `java.exe`
    # happens to be first in the machine PATH.
    $existingJdk21 = Find-Jdk21

    if (-not $existingJdk21) {
        Invoke-Native `
            -FilePath "choco" `
            -Arguments @("install", "microsoft-openjdk-21", "-y", "--no-progress") `
            -Description "Installing Microsoft OpenJDK 21" `
            -SuccessCodes @(0, 1641, 3010)

        Refresh-Environment
    } else {
        Write-Ok "JDK 21 is already installed at $($existingJdk21.Home)."
    }

    Ensure-Java21Active

    # STEP 7 - uv
    if (-not (Test-Command uv)) {
        Write-Step "Installing uv"

        $uvInstaller = Invoke-RestMethod "https://astral.sh/uv/install.ps1"
        Invoke-Expression $uvInstaller

        $uvCandidates = @(
            (Join-Path $env:USERPROFILE ".local\bin"),
            (Join-Path $env:USERPROFILE ".cargo\bin")
        )

        foreach ($candidate in $uvCandidates) {
            if (Test-Path $candidate) {
                $env:Path = "$candidate;$env:Path"

                $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if (-not $currentUserPath) { $currentUserPath = "" }

                if ($currentUserPath -notlike "*$candidate*") {
                    [Environment]::SetEnvironmentVariable(
                        "Path",
                        (($currentUserPath.TrimEnd(";") + ";" + $candidate).Trim(";")),
                        "User"
                    )
                }
            }
        }

        if (-not (Test-Command uv)) {
            throw "uv installation finished, but uv.exe is unavailable."
        }
    }
    Write-Ok "uv is available."

    # STEP 8 - MCP client CLIs (only needed for selected CLI-managed clients).
    if ((Test-SelectedClient -Name 'Codex') -and -not (Test-Command codex)) {
        Install-ChocoPackageIfMissing -Package "nodejs-lts" -Command "npm"

        Invoke-Native `
            -FilePath "npm" `
            -Arguments @("install", "-g", "@openai/codex") `
            -Description "Installing OpenAI Codex CLI"

        Refresh-Environment

        if (-not (Test-Command codex)) {
            # npm global command folder can occasionally require an explicit PATH refresh.
            $npmPrefix = (& npm prefix -g 2>$null | Out-String).Trim()
            if ($npmPrefix -and (Test-Path $npmPrefix)) {
                $env:Path = "$npmPrefix;$env:Path"
            }
        }

        if (-not (Test-Command codex)) {
            throw "Codex CLI installation succeeded, but 'codex' is still unavailable in PATH."
        }
    }
    if (Test-SelectedClient -Name 'Codex') {
        Write-Ok "Codex CLI is available."
    }
    if ((Test-SelectedClient -Name 'ClaudeCode') -and -not (Test-Command claude)) {
        Install-ChocoPackageIfMissing -Package "nodejs-lts" -Command "npm"
        Invoke-Native `
            -FilePath "npm" `
            -Arguments @("install", "-g", "@anthropic-ai/claude-code") `
            -Description "Installing Anthropic Claude Code"
        Refresh-Environment
        if (-not (Test-Command claude)) {
            $npmPrefix = (& npm prefix -g 2>$null | Out-String).Trim()
            if ($npmPrefix -and (Test-Path $npmPrefix)) {
                $env:Path = "$npmPrefix;$env:Path"
            }
        }
        if (-not (Test-Command claude)) {
            throw "Claude Code installation succeeded, but 'claude' is still unavailable in PATH."
        }
    }
    if (Test-SelectedClient -Name 'ClaudeCode') {
        Write-Ok "Claude Code is available."
    }

    # STEP 9 - Download/reuse EXACT Ghidra version required by pom.xml.
    $ghidraReleaseInfo = Get-GhidraReleaseForVersion -RequiredVersion $requiredGhidraVersion
    $ghidraPath = Ensure-GhidraInstalled `
        -RequiredVersion $requiredGhidraVersion `
        -ReleaseInfo $ghidraReleaseInfo

    $existingDeploymentComplete = Test-ExistingMcpDeployment `
        -GhidraPath $ghidraPath `
        -GhidraVersion $requiredGhidraVersion `
        -McpVersion $mcpProjectVersion

    # STEP 10 - Repository-supported preflight/prerequisite/build/deploy workflow.
    $deployResult = $null
    if (($mcpSync.UpdateSkipped -or $mcpSync.ReuseExisting) -and $existingDeploymentComplete) {
        if ($mcpSync.ReuseExisting) {
            Write-Ok "The matching Ghidra extension and bridge are already installed; skipping the rebuild."
        } else {
            Write-WarnMsg "ghidra-mcp has local modifications, but the matching Ghidra extension and bridge are already installed."
        }
        Write-Ok "Reusing the existing deployment instead of rebuilding or overwriting the local checkout."

        $deployResult = [pscustomobject]@{
            FullyReady  = $false
            NeedsProject = $true
            ExitCode    = 0
            Reused      = $true
        }
    } else {
        Push-Location $McpPath
        try {
            Invoke-Native `
                -FilePath "python" `
                -Arguments @(
                    "-m", "tools.setup",
                    "preflight",
                    "--ghidra-path", $ghidraPath
                ) `
                -Description "Running ghidra-mcp preflight"

            Invoke-Native `
                -FilePath "python" `
                -Arguments @(
                    "-m", "tools.setup",
                    "ensure-prereqs",
                    "--ghidra-path", $ghidraPath
                ) `
                -Description "Installing ghidra-mcp runtime/build prerequisites"

            Invoke-Native `
                -FilePath "python" `
                -Arguments @(
                    "-m", "tools.setup",
                    "build"
                ) `
                -Description "Building ghidra-mcp"

            $deployResult = Invoke-GhidraMcpDeploy `
                -GhidraPath $ghidraPath `
                -McpVersion $mcpProjectVersion
        } finally {
            Pop-Location
        }
    }

    # STEP 11 - Register the selected MCP clients.
    if (Test-SelectedClient -Name 'Codex') {
        Ensure-CodexMcpRegistration
    }
    if (Test-SelectedClient -Name 'Antigravity') {
        Set-AntigravityGhidraConfiguration
    }
    if (Test-SelectedClient -Name 'ClaudeCode') {
        Ensure-ClaudeCodeMcpRegistration
    }

    # STEP 12 - Final verification of paths/files before calling setup complete.
    $requiredPaths = @(
        (Join-Path $McpPath ".git"),
        (Join-Path $McpPath "pom.xml"),
        (Join-Path $ghidraPath "ghidraRun.bat")
    )

    foreach ($requiredPath in $requiredPaths) {
        if (-not (Test-Path $requiredPath)) {
            throw "Final verification failed. Required path is missing: $requiredPath"
        }
    }

    # STEP 13 - Write guide from ACTUAL selected versions.
    Write-DynamicInstructions `
        -McpTargetDescription $effectiveMcpDescription `
        -McpRef $effectiveMcpRef `
        -McpCommit $mcpCommit `
        -McpProjectVersion $mcpProjectVersion `
        -GhidraVersion $requiredGhidraVersion `
        -GhidraPath $ghidraPath `
        -GhidraAssetName $ghidraReleaseInfo.Asset.name `
        -NeedsProject ([bool]($deployResult -and $deployResult.NeedsProject))

    Write-Host "`n============================================================" -ForegroundColor Green
    Write-Host " SETUP COMPLETE" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "ghidra-mcp:   $effectiveMcpDescription"
    Write-Host "MCP commit:   $mcpCommit"
    Write-Host "Ghidra:       $requiredGhidraVersion"
    Write-Host "Ghidra path:  $ghidraPath"
    Write-Host "MCP path:     $McpPath"
    try {
        $codexResolved = Get-Command codex -ErrorAction Stop | Select-Object -First 1
        Write-Host "Codex cmd:    $($codexResolved.Source)"
    } catch {}
    try {
        $claudeResolved = Get-Command claude -ErrorAction Stop | Select-Object -First 1
        Write-Host "Claude cmd:   $($claudeResolved.Source)"
    } catch {}
    if ($deployResult -and $deployResult.NeedsProject) {
        Write-Host "Next action:  Create/open a Ghidra project and import your EXE." -ForegroundColor Yellow
    }
    Write-Host "Instructions: $InstructionsPath"
    Write-Host "Log:          $LogPath"

    Start-Process notepad.exe -ArgumentList @($InstructionsPath)

    # tools.setup deploy currently starts Ghidra itself. This is only a fallback
    # in case Ghidra is no longer running by the time setup reaches this point.
    if (-not (Get-Process -Name "javaw" -ErrorAction SilentlyContinue)) {
        $launcher = Join-Path $ghidraPath "ghidraRun.bat"
        if (Test-Path $launcher) {
            Start-Process -FilePath $launcher
        }
    }

} catch {
    $message = $_.Exception.Message

    Write-Host "`nSETUP FAILED" -ForegroundColor Red
    Write-Host $message -ForegroundColor Red
    Write-Host "Log: $LogPath" -ForegroundColor Yellow

    try {
        $failureText = @"
GHIDRA MCP + CODEX INSTALLER FAILED
===================================
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Error:
$message

Log:
$LogPath

The installer is designed to be rerun. Correct the problem and run the same
script again.

Important:
- Local modifications inside $McpPath are preserved.
- If a matching deployment already exists, a dirty checkout is reused rather
  than treated as an installation failure.
- Existing complete Ghidra releases under C:\Tools are reused.
- Version selection is derived from the ghidra-mcp checkout's pom.xml.
"@
        Set-Content -LiteralPath $InstructionsPath -Value $failureText -Encoding UTF8
        Start-Process notepad.exe -ArgumentList @($InstructionsPath)
    } catch {}

    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
