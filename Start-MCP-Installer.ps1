#Requires -Version 5.1
<#
.SYNOPSIS
    Opens the MCP Installer Hub selection window.

.DESCRIPTION
    This launcher only orchestrates installers that live beside it. Each selected
    installer runs in its own PowerShell window so its download, prerequisite,
    elevation, and verification output stays visible.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSCommandPath
$ghidraInstaller = Join-Path $root 'Setup-GhidraMCP-Codex-Dynamic-v7.ps1'
$visualStudioInstaller = Join-Path $root 'Setup-Visual-Studio-MCP.ps1'

foreach ($installer in @($ghidraInstaller, $visualStudioInstaller)) {
    if (-not (Test-Path -LiteralPath $installer)) {
        [Windows.Forms.MessageBox]::Show("Required installer is missing:`r`n$installer", 'MCP Installer Hub', 'OK', 'Error') | Out-Null
        exit 1
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = 'MCP Installer Hub'
$form.Size = New-Object Drawing.Size(590, 480)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

# --- Per-client "already installed" detection --------------------------------
# File-based checks look for the bridge entry and confirm the referenced path
# exists. CLI probes (codex/claude) are only used by the on-demand Refresh
# button so opening the Hub stays instant even when a CLI is slow or missing.
function Invoke-HubCliProbe {
    param([Parameter(Mandatory)][string]$CommandName, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 6)

    try {
        $command = Get-Command $CommandName -ErrorAction Stop | Select-Object -First 1
        $commandPath = $command.Source
        if ([string]::IsNullOrWhiteSpace($commandPath)) { $commandPath = $command.Path }
        if ([string]::IsNullOrWhiteSpace($commandPath)) { return $null }
    } catch {
        return $null
    }

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $extension = [System.IO.Path]::GetExtension($commandPath).ToLowerInvariant()
        if ($extension -eq '.cmd' -or $extension -eq '.bat') {
            $quoted = @('"' + ($commandPath -replace '"', '""') + '"')
            foreach ($argValue in $Arguments) { $quoted += ('"' + ($argValue -replace '"', '""') + '"') }
            $proc = Start-Process -FilePath "$env:ComSpec" -ArgumentList @('/d', '/s', '/c', ($quoted -join ' ')) `
                -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        } else {
            $proc = Start-Process -FilePath $commandPath -ArgumentList $Arguments `
                -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        }
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch {}
            return $null
        }
        $output = ''
        if (Test-Path -LiteralPath $stdoutFile) { $output += (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path -LiteralPath $stderrFile) { $output += "`n" + (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue) }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $output }
    } catch {
        return $null
    } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-HubGhidraFileEntry {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$ServersProperty)

    if (-not (Test-Path -LiteralPath $ConfigPath)) { return 'missing' }
    try {
        $raw = [IO.File]::ReadAllText($ConfigPath)
        if ([string]::IsNullOrWhiteSpace($raw)) { return 'missing' }
        if ($ConfigPath -like '*opencode.json') {
            $raw = [regex]::Replace($raw, '(?m)(?<!https:)(?<!http:)//.*$', '')
            $raw = [regex]::Replace($raw, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        }
        $root = $raw | ConvertFrom-Json
        $candidates = @()
        if ($ServersProperty -eq 'mcpServers') {
            $serversProp = $root.PSObject.Properties['mcpServers']
            if ($null -ne $serversProp -and $null -ne $serversProp.Value) {
                $entry = $serversProp.Value.PSObject.Properties['ghidra']
                if ($null -ne $entry -and $null -ne $entry.Value) { $candidates += $entry.Value }
            }
        } else {
            $mcpProp = $root.PSObject.Properties['mcp']
            if ($null -ne $mcpProp -and $null -ne $mcpProp.Value) {
                $flat = $mcpProp.Value.PSObject.Properties['ghidra']
                if ($null -ne $flat -and $null -ne $flat.Value) { $candidates += $flat.Value }
                $serversProp = $mcpProp.Value.PSObject.Properties['servers']
                if ($null -ne $serversProp -and $null -ne $serversProp.Value) {
                    $nested = $serversProp.Value.PSObject.Properties['ghidra']
                    if ($null -ne $nested -and $null -ne $nested.Value) { $candidates += $nested.Value }
                }
            }
        }
        foreach ($candidate in $candidates) {
            $text = ($candidate | ConvertTo-Json -Depth 10 -Compress)
            if ($text -match 'bridge-mcp-ghidra') { return 'installed' }
        }
        return 'missing'
    } catch {
        return 'unknown'
    }
}

function Test-HubVsBridgeFileEntry {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$Kind)

    if (-not (Test-Path -LiteralPath $ConfigPath)) { return 'missing' }
    try {
        $raw = [IO.File]::ReadAllText($ConfigPath)
        if ([string]::IsNullOrWhiteSpace($raw)) { return 'missing' }
        if ($Kind -eq 'codex-toml') {
            if ($raw -match '(?s)\[mcp_servers\.vs-ide-bridge\].*?mcp-server') { return 'installed' }
            return 'missing'
        }
        if ($ConfigPath -like '*opencode.json') {
            $raw = [regex]::Replace($raw, '(?m)(?<!https:)(?<!http:)//.*$', '')
            $raw = [regex]::Replace($raw, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        }
        $root = $raw | ConvertFrom-Json
        $candidates = @()
        if ($Kind -eq 'antigravity') {
            $serversProp = $root.PSObject.Properties['mcpServers']
            if ($null -ne $serversProp -and $null -ne $serversProp.Value) {
                $entry = $serversProp.Value.PSObject.Properties['vs-ide-bridge']
                if ($null -ne $entry -and $null -ne $entry.Value) { $candidates += $entry.Value }
            }
        } else {
            $mcpProp = $root.PSObject.Properties['mcp']
            if ($null -ne $mcpProp -and $null -ne $mcpProp.Value) {
                $flat = $mcpProp.Value.PSObject.Properties['vs-ide-bridge']
                if ($null -ne $flat -and $null -ne $flat.Value) { $candidates += $flat.Value }
                $serversProp = $mcpProp.Value.PSObject.Properties['servers']
                if ($null -ne $serversProp -and $null -ne $serversProp.Value) {
                    $nested = $serversProp.Value.PSObject.Properties['vs-ide-bridge']
                    if ($null -ne $nested -and $null -ne $nested.Value) { $candidates += $nested.Value }
                }
            }
        }
        foreach ($candidate in $candidates) {
            $text = ($candidate | ConvertTo-Json -Depth 10 -Compress)
            if ($text -match 'VsIdeBridgeService' -and $text -match 'mcp-server') { return 'installed' }
        }
        return 'missing'
    } catch {
        return 'unknown'
    }
}

function Get-HubOpenCodeConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_CONFIG)) {
        $custom = $env:OPENCODE_CONFIG.Trim().Trim('"')
        if (Test-Path -LiteralPath $custom -PathType Container) { return (Join-Path $custom 'opencode.json') }
        return $custom
    }
    return (Join-Path $env:USERPROFILE '.config\opencode\opencode.json')
}

function Get-HubClientStatus {
    param([Parameter(Mandatory)][string]$ClientName)

    $antigravityConfig = Join-Path $env:USERPROFILE '.gemini\config\mcp_config.json'
    $openCodeConfig = Get-HubOpenCodeConfigPath
    $codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $codexConfig = Join-Path $codexHome 'config.toml'

    $ghidra = 'missing'
    $vsBridge = 'missing'

    switch ($ClientName) {
        'Codex' {
            $probe = Invoke-HubCliProbe -CommandName 'codex' -Arguments @('mcp', 'get', 'ghidra', '--json')
            if ($null -eq $probe) { $ghidra = 'unknown' }
            elseif ($probe.ExitCode -eq 0 -and $probe.Output -match 'bridge-mcp-ghidra') { $ghidra = 'installed' }
            $vsBridge = Test-HubVsBridgeFileEntry -ConfigPath $codexConfig -Kind 'codex-toml'
        }
        'Antigravity' {
            $ghidra = Test-HubGhidraFileEntry -ConfigPath $antigravityConfig -ServersProperty 'mcpServers'
            $vsBridge = Test-HubVsBridgeFileEntry -ConfigPath $antigravityConfig -Kind 'antigravity'
        }
        'ClaudeCode' {
            $ghidraProbe = Invoke-HubCliProbe -CommandName 'claude' -Arguments @('mcp', 'get', 'ghidra')
            if ($null -eq $ghidraProbe) { $ghidra = 'unknown' }
            elseif ($ghidraProbe.ExitCode -eq 0 -and $ghidraProbe.Output -match 'bridge-mcp-ghidra') { $ghidra = 'installed' }
            $vsProbe = Invoke-HubCliProbe -CommandName 'claude' -Arguments @('mcp', 'get', 'vs-ide-bridge')
            if ($null -eq $vsProbe) { $vsBridge = 'unknown' }
            elseif ($vsProbe.ExitCode -eq 0 -and $vsProbe.Output -match 'mcp-server') { $vsBridge = 'installed' }
        }
        'OpenCode' {
            $ghidra = Test-HubGhidraFileEntry -ConfigPath $openCodeConfig -ServersProperty 'mcp'
            $vsBridge = Test-HubVsBridgeFileEntry -ConfigPath $openCodeConfig -Kind 'opencode'
        }
    }

    return [pscustomobject]@{ Ghidra = $ghidra; VsBridge = $vsBridge }
}

function Format-HubStatusText {
    param($Status)

    $parts = @()
    $parts += ('Ghidra {0}' -f $(if ($Status.Ghidra -eq 'installed') { 'installed' } elseif ($Status.Ghidra -eq 'unknown') { '?' } else { 'not installed' }))
    $parts += ('VS {0}' -f $(if ($Status.VsBridge -eq 'installed') { 'installed' } elseif ($Status.VsBridge -eq 'unknown') { '?' } else { 'not installed' }))
    return ($parts -join ' · ')
}

$title = New-Object Windows.Forms.Label
$title.Text = 'Choose MCP integrations and the clients to configure'
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(24, 22)
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 13)
$form.Controls.Add($title)

$hint = New-Object Windows.Forms.Label
$hint.Text = 'Each installer opens separately and displays its own verification results.'
$hint.AutoSize = $true
$hint.Location = New-Object Drawing.Point(26, 55)
$form.Controls.Add($hint)

$projects = New-Object Windows.Forms.GroupBox
$projects.Text = 'MCP projects'
$projects.Location = New-Object Drawing.Point(24, 92)
$projects.Size = New-Object Drawing.Size(540, 120)
$form.Controls.Add($projects)

$ghidra = New-Object Windows.Forms.CheckBox
$ghidra.Text = 'Ghidra MCP'
$ghidra.AutoSize = $true
$ghidra.Location = New-Object Drawing.Point(18, 30)
$ghidra.Checked = $true
$projects.Controls.Add($ghidra)

$ghidraInfo = New-Object Windows.Forms.Label
$ghidraInfo.Text = 'Installs the matching Ghidra release and bethington/ghidra-mcp bridge.'
$ghidraInfo.AutoSize = $true
$ghidraInfo.Location = New-Object Drawing.Point(38, 54)
$projects.Controls.Add($ghidraInfo)

$vs = New-Object Windows.Forms.CheckBox
$vs.Text = 'Visual Studio IDE Bridge'
$vs.AutoSize = $true
$vs.Location = New-Object Drawing.Point(18, 80)
$projects.Controls.Add($vs)

$clients = New-Object Windows.Forms.GroupBox
$clients.Text = 'Client platform (only checked clients are touched)'
$clients.Location = New-Object Drawing.Point(24, 228)
$clients.Size = New-Object Drawing.Size(540, 104)
$form.Controls.Add($clients)

$statusFont = New-Object Drawing.Font('Segoe UI', 8)

$codex = New-Object Windows.Forms.CheckBox
$codex.Text = 'Codex'
$codex.AutoSize = $true
$codex.Location = New-Object Drawing.Point(18, 28)
$codex.Checked = $true
$clients.Controls.Add($codex)

$codexStatus = New-Object Windows.Forms.Label
$codexStatus.Text = 'status: not checked'
$codexStatus.AutoSize = $true
$codexStatus.Font = $statusFont
$codexStatus.ForeColor = [Drawing.Color]::Gray
$codexStatus.Location = New-Object Drawing.Point(20, 52)
$clients.Controls.Add($codexStatus)

$antigravity = New-Object Windows.Forms.CheckBox
$antigravity.Text = 'Antigravity CLI'
$antigravity.AutoSize = $true
$antigravity.Location = New-Object Drawing.Point(150, 28)
$clients.Controls.Add($antigravity)

$antigravityStatus = New-Object Windows.Forms.Label
$antigravityStatus.Text = 'status: not checked'
$antigravityStatus.AutoSize = $true
$antigravityStatus.Font = $statusFont
$antigravityStatus.ForeColor = [Drawing.Color]::Gray
$antigravityStatus.Location = New-Object Drawing.Point(152, 52)
$clients.Controls.Add($antigravityStatus)

$claudeCode = New-Object Windows.Forms.CheckBox
$claudeCode.Text = 'Claude Code'
$claudeCode.AutoSize = $true
$clients.Controls.Add($claudeCode)
$claudeCode.Location = New-Object Drawing.Point(300, 28)

$claudeCodeStatus = New-Object Windows.Forms.Label
$claudeCodeStatus.Text = 'status: not checked'
$claudeCodeStatus.AutoSize = $true
$claudeCodeStatus.Font = $statusFont
$claudeCodeStatus.ForeColor = [Drawing.Color]::Gray
$claudeCodeStatus.Location = New-Object Drawing.Point(302, 52)
$clients.Controls.Add($claudeCodeStatus)

$openCode = New-Object Windows.Forms.CheckBox
$openCode.Text = 'OpenCode'
$openCode.AutoSize = $true
$openCode.Location = New-Object Drawing.Point(430, 28)
$clients.Controls.Add($openCode)

$openCodeStatus = New-Object Windows.Forms.Label
$openCodeStatus.Text = 'status: not checked'
$openCodeStatus.AutoSize = $true
$openCodeStatus.Font = $statusFont
$openCodeStatus.ForeColor = [Drawing.Color]::Gray
$openCodeStatus.Location = New-Object Drawing.Point(432, 52)
$clients.Controls.Add($openCodeStatus)

$refreshHint = New-Object Windows.Forms.Label
$refreshHint.Text = 'Tip: check only Claude Code to add an existing Ghidra install to it; Refresh shows per-client status.'
$refreshHint.AutoSize = $true
$refreshHint.Font = $statusFont
$refreshHint.ForeColor = [Drawing.Color]::Gray
$refreshHint.Location = New-Object Drawing.Point(20, 76)
$clients.Controls.Add($refreshHint)

$forceReinstall = New-Object Windows.Forms.CheckBox
$forceReinstall.Text = 'Force reinstall client registrations (rewrite entries that already look correct)'
$forceReinstall.AutoSize = $true
$forceReinstall.Location = New-Object Drawing.Point(26, 342)
$form.Controls.Add($forceReinstall)

$refresh = New-Object Windows.Forms.Button
$refresh.Text = 'Refresh status'
$refresh.Size = New-Object Drawing.Size(130, 38)
$refresh.Location = New-Object Drawing.Point(24, 372)
$form.Controls.Add($refresh)

$install = New-Object Windows.Forms.Button
$install.Text = 'Run selected installers'
$install.Size = New-Object Drawing.Size(190, 38)
$install.Location = New-Object Drawing.Point(374, 372)
$install.DialogResult = [Windows.Forms.DialogResult]::OK
$form.AcceptButton = $install
$form.Controls.Add($install)

$cancel = New-Object Windows.Forms.Button
$cancel.Text = 'Cancel'
$cancel.Size = New-Object Drawing.Size(100, 38)
$cancel.Location = New-Object Drawing.Point(260, 372)
$cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
$form.CancelButton = $cancel
$form.Controls.Add($cancel)

function Update-HubStatusLabel {
    param($Label, $Status)

    $Label.Text = 'status: ' + (Format-HubStatusText -Status $Status)
    if ($Status.Ghidra -eq 'installed' -or $Status.VsBridge -eq 'installed') {
        $Label.ForeColor = [Drawing.Color]::DarkGreen
    } elseif ($Status.Ghidra -eq 'unknown' -or $Status.VsBridge -eq 'unknown') {
        $Label.ForeColor = [Drawing.Color]::DarkGoldenrod
    } else {
        $Label.ForeColor = [Drawing.Color]::Gray
    }
}

$refresh.Add_Click({
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        Update-HubStatusLabel -Label $codexStatus -Status (Get-HubClientStatus -ClientName 'Codex')
        Update-HubStatusLabel -Label $antigravityStatus -Status (Get-HubClientStatus -ClientName 'Antigravity')
        Update-HubStatusLabel -Label $claudeCodeStatus -Status (Get-HubClientStatus -ClientName 'ClaudeCode')
        Update-HubStatusLabel -Label $openCodeStatus -Status (Get-HubClientStatus -ClientName 'OpenCode')
    } finally {
        $form.Cursor = [Windows.Forms.Cursors]::Default
    }
})

if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { exit 0 }
if (-not $ghidra.Checked -and -not $vs.Checked) {
    [Windows.Forms.MessageBox]::Show('Choose at least one MCP project.', 'MCP Installer Hub', 'OK', 'Warning') | Out-Null
    exit 1
}

$selectedClients = @()
if ($codex.Checked) { $selectedClients += 'Codex' }
if ($antigravity.Checked) { $selectedClients += 'Antigravity' }
if ($claudeCode.Checked) { $selectedClients += 'ClaudeCode' }
if ($openCode.Checked) { $selectedClients += 'OpenCode' }
if ($selectedClients.Count -eq 0) {
    [Windows.Forms.MessageBox]::Show('Choose at least one client platform.', 'MCP Installer Hub', 'OK', 'Warning') | Out-Null
    exit 1
}
$powerShell = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($powerShell)) { $powerShell = 'powershell.exe' }

function Start-InstallerConsole {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Client, [switch]$ForceClientRegistration)
    $clientArguments = ($Client | ForEach-Object { "'$_'" }) -join ','
    $command = "& '$Path' -Client $clientArguments"
    if ($ForceClientRegistration) { $command += ' -ForceClientRegistration' }
    Start-Process -FilePath $powerShell -ArgumentList @('-NoExit', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-Command', $command) -WorkingDirectory $root
}

$forceClientRegistration = $forceReinstall.Checked
if ($ghidra.Checked) { Start-InstallerConsole -Path $ghidraInstaller -Client $selectedClients -ForceClientRegistration:$forceClientRegistration }
if ($vs.Checked) { Start-InstallerConsole -Path $visualStudioInstaller -Client $selectedClients -ForceClientRegistration:$forceClientRegistration }
