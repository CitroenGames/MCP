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
| Ghidra MCP | Official Ghidra version matched to `bethington/ghidra-mcp`, its extension, and the local stdio bridge | Codex, Antigravity CLI, or both |
| Visual Studio IDE Bridge | The current `Visual-Studio-MCP` release, Visual Studio extension, and Windows bridge service | Codex, Antigravity CLI, or both |

Each selected installer opens in a separate PowerShell window. Leave those windows open until they report their final verification result. The installers request UAC only when their underlying dependency requires it.

## Requirements

- Windows 10 or Windows 11, 64-bit
- Internet access
- Administrator approval when an installer asks for it
- For Visual Studio IDE Bridge: Visual Studio 2022 17.14+ or Visual Studio 2026, closed during setup

## What the installers configure

Codex registrations use the Codex CLI and are read back after setup. Antigravity registrations are written into `%USERPROFILE%\.gemini\config\mcp_config.json`; an existing valid file is backed up before it changes.

The Ghidra installer uses `C:\Tools` by default. The Visual Studio bridge uses `C:\tools` by default. Both installers accept a `-ToolsRoot` argument when run directly.

## Run one project without the UI

```powershell
# Ghidra for both clients
.\Setup-GhidraMCP-Codex-Dynamic-v7.ps1 -Client Both

# Visual Studio bridge for Antigravity only
.\Setup-Visual-Studio-MCP.ps1 -Client Antigravity
```

## Add another MCP project

Keep the installer in this folder and add one checkbox plus its launch entry in `Start-MCP-Installer.ps1`. The installer should accept the shared `-Client Codex|Antigravity|Both` convention, preserve unrelated MCP entries, and verify its final configuration.
