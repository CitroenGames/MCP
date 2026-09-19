# MCP Installer Hub

One folder for installing and configuring MCP integrations on Windows. Choose one or more projects, then choose the client platform that should receive each MCP registration.

## Start the installer UI

To download and launch the UI from GitHub, run this in PowerShell:

```powershell
$zip = Join-Path $env:TEMP 'mcp-installer-hub.zip'; $destination = Join-Path $env:TEMP 'mcp-installer-hub'; irm https://github.com/CitroenGames/MCP/archive/refs/heads/master.zip -OutFile $zip; Expand-Archive -LiteralPath $zip -DestinationPath $destination -Force; & (Join-Path $destination 'MCP-master\Install-MCP-Hub.cmd')
```

If you already cloned or downloaded this repository, run:

```powershell
.\Install-MCP-Hub.cmd
```

The UI lets you select:

| MCP project | What it installs | Supported client platforms |
| --- | --- | --- |
| Ghidra MCP | `CitroenGames/ghidra-mcp`, its matching official Ghidra version, extension, and local stdio bridge | Codex, Antigravity CLI, Claude Code, and/or OpenCode |
| Visual Studio IDE Bridge | The current `Visual-Studio-MCP` release, Visual Studio extension, and Windows bridge service | Codex, Antigravity CLI, Claude Code, and/or OpenCode |

Each selected installer opens in a separate PowerShell window. Leave those windows open until they report their final verification result. The installers request UAC only when their underlying dependency requires it.

## Requirements

- Windows 10 or Windows 11, 64-bit
- Internet access
- Administrator approval when an installer asks for it
- For Visual Studio IDE Bridge: Visual Studio 2022 17.14+ or Visual Studio 2026, closed during setup

## What the installers configure

Codex registrations use its CLI and are read back after setup. Antigravity registrations are written into `%USERPROFILE%\.gemini\config\mcp_config.json`; an existing valid file is backed up before it changes. Claude Code registrations use `claude mcp` at user scope and are read back after setup. OpenCode registrations are written into `%USERPROFILE%\.config\opencode\opencode.json` (or `$env:OPENCODE_CONFIG` when set) as a local stdio entry under both `mcp.<name>` and `mcp.servers.<name>` for v1/v2 compatibility; an existing file is backed up before it changes and the result is read back after setup.

The Ghidra installer uses `C:\Tools` by default. The Visual Studio bridge uses `C:\tools` by default. Both installers accept a `-ToolsRoot` argument when run directly.

## Already-installed detection

Detection is per client, not per machine. If Ghidra MCP is already installed for Codex but not for Claude Code, run the installer with only Claude Code checked (or `-Client ClaudeCode`): the Codex registration is left untouched, and only Claude Code is added.

Before rewriting a registration, each installer checks whether that client's entry already points at the bridge being installed:

- Codex / Claude Code: probed through `codex mcp get` / `claude mcp get` and compared against the current install path.
- Antigravity / OpenCode: the JSON config entry is compared against the current install path.

An entry that already matches is verified and skipped (`already installed`), anything missing or pointing elsewhere is (re)registered, and the final summary reports `already installed` vs `newly registered` per client. Only checked/selected clients are ever touched. To force a rewrite of entries that already look correct, pass `-ForceClientRegistration` (Hub: tick "Force reinstall client registrations") or click "Refresh status" in the Hub to see the per-client state before installing.

## Run one project without the UI

```powershell
# Ghidra for Codex and Claude Code
.\Setup-GhidraMCP-Codex-Dynamic-v7.ps1 -Client Codex,ClaudeCode

# Visual Studio bridge for Antigravity only
.\Setup-Visual-Studio-MCP.ps1 -Client Antigravity

# Either project for OpenCode only
.\Setup-GhidraMCP-Codex-Dynamic-v7.ps1 -Client OpenCode
.\Setup-Visual-Studio-MCP.ps1 -Client OpenCode
```

## Add another MCP project

Keep the installer in this folder and add one checkbox plus its launch entry in `Start-MCP-Installer.ps1`. The installer should accept the shared `-Client Codex,Antigravity,ClaudeCode,OpenCode` convention (or `-Client All`), preserve unrelated MCP entries, and verify its final configuration.
