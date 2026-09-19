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
$form.Size = New-Object Drawing.Size(590, 410)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

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
$clients.Text = 'Client platform'
$clients.Location = New-Object Drawing.Point(24, 228)
$clients.Size = New-Object Drawing.Size(540, 72)
$form.Controls.Add($clients)

$codex = New-Object Windows.Forms.CheckBox
$codex.Text = 'Codex'
$codex.AutoSize = $true
$codex.Location = New-Object Drawing.Point(18, 30)
$codex.Checked = $true
$clients.Controls.Add($codex)

$antigravity = New-Object Windows.Forms.CheckBox
$antigravity.Text = 'Antigravity CLI'
$antigravity.AutoSize = $true
$antigravity.Location = New-Object Drawing.Point(120, 30)
$clients.Controls.Add($antigravity)

$claudeCode = New-Object Windows.Forms.CheckBox
$claudeCode.Text = 'Claude Code'
$claudeCode.AutoSize = $true
$clients.Controls.Add($claudeCode)
$claudeCode.Location = New-Object Drawing.Point(280, 30)

$openCode = New-Object Windows.Forms.CheckBox
$openCode.Text = 'OpenCode'
$openCode.AutoSize = $true
$openCode.Location = New-Object Drawing.Point(420, 30)
$clients.Controls.Add($openCode)

$install = New-Object Windows.Forms.Button
$install.Text = 'Run selected installers'
$install.Size = New-Object Drawing.Size(190, 38)
$install.Location = New-Object Drawing.Point(374, 320)
$install.DialogResult = [Windows.Forms.DialogResult]::OK
$form.AcceptButton = $install
$form.Controls.Add($install)

$cancel = New-Object Windows.Forms.Button
$cancel.Text = 'Cancel'
$cancel.Size = New-Object Drawing.Size(100, 38)
$cancel.Location = New-Object Drawing.Point(260, 320)
$cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
$form.CancelButton = $cancel
$form.Controls.Add($cancel)

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
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Client)
    $clientArguments = ($Client | ForEach-Object { "'$_'" }) -join ','
    $command = "& '$Path' -Client $clientArguments"
    Start-Process -FilePath $powerShell -ArgumentList @('-NoExit', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-Command', $command) -WorkingDirectory $root
}

if ($ghidra.Checked) { Start-InstallerConsole -Path $ghidraInstaller -Client $selectedClients }
if ($vs.Checked) { Start-InstallerConsole -Path $visualStudioInstaller -Client $selectedClients }
