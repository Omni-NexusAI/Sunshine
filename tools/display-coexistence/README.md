# Windows streaming display coexistence

This opt-in package lets idle Moonlight virtual monitors yield to Virtual Desktop without a manual display-profile switch. Sunshine stays available and activates its configured capture monitor when a Moonlight session starts. The controller preserves active streams and the last available desktop.

The fork starts from **Sunshine v2026.914.233613**, upstream commit `63d35f702ee9e362e43263742981836ec0710384`. Windows builds include this directory under `tools/display-coexistence`; installing Sunshine by itself does not activate the controller. A separate small ZIP is built by the **Windows display coexistence package** workflow. This ZIP is a companion installer, not a rebuilt Sunshine executable.

The workflow also produces a Windows AMD64 bundle containing the **unmodified official stable Sunshine MSI**, verified against the release's SHA-256 digest, alongside this fork's companion installer. Install the MSI first on a new host; an already working host can use only the companion ZIP. Native compilation of the fork remains a separate build, with the installer scripts included by CMake.

## Supported hosts

- Windows with an existing Sunshine installation and the **MikeTheTech** display driver (`Root\MttVDD`, MTT1337 monitors).
- Virtual Desktop's own driver (`Root\Vdvmd`) is optional; when present it supplies the preferred headless desktop after Moonlight disconnects.
- Physical GPUs, installation paths, provider instance IDs and Sunshine ports are discovered. No device ID, user account or GPU from the development desktop is copied to another host.
- Meta, Parsec, physical monitors, existing driver modes and pairing data are preserved. This package does not install competing drivers or claim automatic ownership support for every virtual-display provider.

## Install or restore

1. Extract the companion ZIP, or open this directory from the fork's Windows build.
2. Run **Inspect.cmd**. Planning is read-only and lists blocking conditions, detected providers, GPUs and capture targets.
3. Close Moonlight. Run **Install.cmd** for a compatible, already configured Sunshine host. One Windows administrator approval installs protected code and the logon task; normal streaming transitions do not request approval.
4. Open Moonlight XR or Virtual Desktop normally. Use the installed GPU selector only when deliberately changing the streaming GPU.

If planning requires capture configuration, use an administrator PowerShell with explicit options. Capture IDs must correspond to an MTT1337 display in Sunshine's complete logged enumeration; physical and other virtual targets are rejected.

```powershell
.\Install-DisplayCoexistence.ps1 -Plan -CaptureDisplayId '{UUID from the logged MTT display}'
.\Install-DisplayCoexistence.ps1 -Install -ConfigureSunshine -CaptureDisplayId '{validated UUID}'
# Replace the older Moonlight Headless controller only when explicitly requested.
.\Install-DisplayCoexistence.ps1 -Install -MigrateLegacy
```

Different installation paths or provider instances can be supplied explicitly. Multiple installed MTT adapters are blocked even with an explicit ID because this preview's native helper identifies their outputs by provider EDID. A missing driver, unsupported provider, incomplete enumeration, disabled capture driver or ambiguous target also blocks installation. Resolution and frame-rate matching remain Sunshine/Moonlight settings and depend on modes advertised by the installed driver.

## Runtime and recovery

Code and host configuration are installed in `%ProgramFiles%\Sunshine Display Coexistence`. Status and recovery inputs live in `%ProgramData%\Sunshine Display Coexistence`. Administrators and SYSTEM own these files; ordinary users can read them but cannot substitute code or rollback configuration. The task uses Windows-owned PowerShell in the logged-in desktop session, starts at sign-in and grants only read/execute control to that account.

The controller tracks complete Sunshine client events incrementally. Missing, incomplete, replaced or truncated history preserves displays. Startup and RTSP checks guard capture preparation; RTSP is not treated as the streaming transport. Idle parking waits for a grace period and rechecks session state before each destructive transition.

When MikeTheTech supplies the only desktop and Virtual Desktop is connected, the controller briefly disables the managed adapter so Virtual Desktop can create its own monitor, then re-enables the adapter and parks its unused outputs. Failed takeover restores desktop availability. Activation retries if a driver is enabled but no desktop appears. If another desktop already exists, only unused MTT paths are removed. `-ObserveOnly` changes no display or driver state.

```powershell
# From the installed directory; no administrator prompt is needed.
.\Control-DisplayCoexistence.ps1 -Action Pause
.\Control-DisplayCoexistence.ps1 -Action Resume
# Administrator-only removal; recovery evidence is retained.
.\Uninstall-DisplayCoexistence.ps1 -Uninstall
```

Pausing lasts until the next sign-in. Shutdown/reload acquires the same lock as handoff and GPU changes before stopping the task. Deliberate GPU changes require an alternate active desktop, idle Sunshine and the existing MikeTheTech GPU settings XML. They coordinate the driver's renderer and Sunshine's adapter with protected rollback copies. GPU names must be unique.

Driver restarts can change native topology identities. Recovery retains an available desktop but cannot promise every former coordinate. Error reports may describe an earlier failed attempt after recovery; compare their timestamps with current state. Installation rollback and uninstall retain snapshots.

## Evidence and limits

The original desktop passed user-observed **Virtual Desktop → Moonlight XR → Virtual Desktop** switching with the physical monitor off, without a manual selector or recurring administrator dialog. Moonlight used RTX 3070 HEVC at 2560×1440 / 120 Hz with 120 FPS requested; Virtual Desktop subsequently used its own display, including the user's 3840×2160 / 72 Hz mode. The user confirmed faster transitions after timing adjustments.

Those results belong to the original controller and one host. This discovered-host package is a preview until installation and the full headset cycle have been tested. Reboot recovery, simultaneous streams, other GPU vendors and other virtual-display implementations require separate validation. Earlier Sunshine logs contained encoder timeout/reinitialization events; display ownership success is not proof of sustained encoding performance.

Offline tests exercise history, display decisions, malformed recovery inputs, script parsing and provider discovery without mutating the active desktop. Run the scripts under `tests/`; build the ZIP with `Build-Package.ps1 -OutputDirectory <new-directory>`. Package hashes are emitted beside it. Administrative checks drain at most 16 MiB of retained log history; larger or uncertain histories block changes conservatively.

The package uses Sunshine's GNU GPL v3 license, included as `LICENSE`. Corresponding source is in [this fork](https://github.com/Omni-NexusAI/Sunshine/tree/feat/windows-display-coexistence/tools/display-coexistence); the bundled official MSI's source is pinned by `upstream.json`.

Sources: [upstream stable release](https://github.com/LizardByte/Sunshine/releases/tag/v2026.914.233613), [Sunshine restoration settings](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html#dd_config_revert_on_disconnect), [Windows task security](https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks).
