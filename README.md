# mac-edid-override

Unlock high refresh rates (100Hz/110Hz) on external displays connected to Apple Silicon Macs by injecting a custom EDID at runtime. No paid software needed.

## The Problem

Some external monitors support refresh rates above 60Hz, but macOS on Apple Silicon doesn't offer those options in System Settings. This is because the monitor's factory EDID doesn't include the right timing parameters for macOS to recognize the higher refresh rates.

Tools like [BetterDisplay](https://github.com/waydabber/BetterDisplay) Pro can fix this, but the high-refresh feature requires a $18 paid license.

This tool does the same thing for free.

## Tested On

- **Monitor:** Dell U4025QW (5120x2160 ultrawide)
- **Mac:** MacBook Pro M1 Max
- **macOS:** Tahoe 26 (macOS 26)
- **Result:** 110Hz at native 5120x2160 (up from 60Hz)

> **Note:** This has only been tested on the above configuration. It may work on other Apple Silicon Macs and external displays, but your mileage may vary. The included EDIDs are specifically tuned for the Dell U4025QW. See [Using with Other Monitors](#using-with-other-monitors) below.

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4 series)
- macOS 15 or later
- Xcode Command Line Tools (`xcode-select --install`)
- External display connected via Thunderbolt/USB-C

## Quick Start

### 1. Clone this repo

```bash
git clone https://github.com/YOUR_USERNAME/mac-edid-override.git
cd mac-edid-override
```

### 2. Run the installer

```bash
./install.sh
```

This installs the default EDID (5120x2160 with 110Hz support). To install a specific EDID variant:

```bash
./install.sh edids/dell-u4025qw-3840x1620.bin
```

The EDID override will auto-apply on every login and after sleep/wake.

> **Note:** Your screen will briefly flicker after install, on each login, and after waking from sleep — this is normal. The display is rebuilding its mode table with the new refresh rate timings.

### 3. Select your refresh rate

Open **System Settings > Displays** and select **110 Hertz** (or 100 Hertz) from the refresh rate dropdown. macOS will remember this choice across reboots.

### 4. Verify

Or run the diagnostic tool:

```bash
~/.config/edid-override/edid_check
```

You should see output like:
```
Display 1 (ID=5) EXTERNAL: 600 modes, curMode=473
  Current: 5120x2160 @110.0Hz
  Refresh rates: 24 25 30 50 60 70 75 100 110 Hz
```

## Available EDIDs

| File | Resolution | Refresh Rates | Notes |
|------|-----------|---------------|-------|
| `edids/dell-u4025qw.bin` | 5120x2160 (native) | 30/60/100/110 Hz | Default. Full resolution with highest refresh rates. |
| `edids/dell-u4025qw-3840x1620.bin` | 5120x2160 + 3840x1620 | 30/60/100/110 Hz | Adds 3840x1620 timing descriptors for the scaled mode. |

### A Note on 3840x1620 Scaled Mode

Many users prefer the 3840x1620 "More Space" scaling option for better UI sizing on the U4025QW. With the EDID override, this scaled mode gets **100Hz** (up from 60Hz).

**110Hz is not available at 3840x1620** — this is a macOS limitation, not a hardware one. When you select 3840x1620 in Display settings, macOS still drives the panel at 5120x2160 internally and applies UI scaling. macOS restricts the refresh rate options available for scaled modes, capping at 100Hz regardless of what the EDID advertises.

Your options:
- **3840x1620 @ 100Hz** — best balance of UI scaling and refresh rate
- **5120x2160 @ 110Hz** — maximum refresh rate at native resolution ("More Space" setting)
- **BetterDisplay** — can create a real 3840x1620 output mode (not scaled) which may allow 110Hz

## How It Works

1. The tool calls `IOAVServiceSetVirtualEDIDMode`, a private IOKit API, to inject a modified EDID (Extended Display Identification Data) into the display pipeline
2. The DCP (Display Coprocessor) on Apple Silicon reads the new EDID and rebuilds the display mode table with the additional refresh rate timings
3. macOS sees the new modes and makes them available in System Settings
4. A background daemon runs via LaunchAgent — it injects the EDID at login, watches for display changes (sleep/wake, plug/unplug) via `CGDisplayRegisterReconfigurationCallback`, and also checks every 30 seconds as a safety net

The modified EDID adds DisplayID Type I Detailed Timing descriptors for 100Hz and 110Hz with timing parameters that the M1 Max GPU can drive (pixel clock under ~1.33 GHz).

## Commands

```bash
# Check current display status
~/.config/edid-override/edid_check

# Manually inject EDID
~/.config/edid-override/edid_override

# Inject a specific EDID file
~/.config/edid-override/edid_override /path/to/custom_edid.bin

# Clear the EDID override (revert to factory)
~/.config/edid-override/edid_override --reset

# Check if override is active
~/.config/edid-override/edid_override --status
```

## Uninstall

```bash
./uninstall.sh
```

This removes the LaunchAgent, clears the EDID override, and deletes the installed files. You may need to restart or replug your display cable for the factory EDID to take effect.

## Troubleshooting

**"No external display found"**
- Make sure your external monitor is connected and recognized by macOS (it should appear in System Settings > Displays, even at 60Hz)

**EDID injects successfully but refresh rate doesn't change**
- Open System Settings > Displays and manually select the higher refresh rate
- If no new refresh rates appear, the EDID timings may not be compatible with your GPU. Check `edid_check` output for mode count — it should jump from ~396 to ~600 modes

**Display goes black or looks wrong**
- Run `~/.config/edid-override/edid_override --reset` to clear the override
- Or replug your display cable to reset to factory EDID

**Screen flickers on login or after waking from sleep**
- This is normal. The EDID injection causes the display to rebuild its mode table, which triggers a brief flicker. It only lasts a second or two. The daemon automatically re-injects the EDID after sleep/wake.

**Display is at 60Hz after reboot instead of 110Hz**
- Open System Settings > Displays and select 110Hz. macOS should remember this choice for future reboots.

**Doesn't work after reboot or sleep**
- Check that the daemon is running: `ps aux | grep edid_override`
- Check that the LaunchAgent is loaded: `launchctl list | grep edid`
- Check the log: `cat /tmp/edid-override.log`
- Try reinstalling: `./uninstall.sh && ./install.sh`

## Using with Other Monitors

The included EDIDs in `edids/` are specific to the Dell U4025QW. For other monitors, you'll need a custom EDID with appropriate timing parameters for your display's native resolution and desired refresh rate.

To create a custom EDID:

1. Dump your monitor's current EDID:
   ```bash
   # Build and use the tools
   ./install.sh
   ~/.config/edid-override/edid_override --status
   ```

2. Use a tool like [AW EDID Editor](https://www.analogway.com/apac/products/software-tools/aw-edid-editor/) or manually craft DisplayID Type I Detailed Timing descriptors with your target refresh rate

3. Key constraints for Apple Silicon:
   - **M1 Max:** Max pixel clock ~1.33 GHz (`MaxActivePixelRate`)
   - **Timing formula:** `pixel_clock = h_total * v_total * refresh_rate`
   - Higher `vblank` values (100-120 lines) work better than minimal ones

4. Save as a 384-byte binary and install:
   ```bash
   ./install.sh /path/to/your/custom_edid.bin
   ```

## How This Was Built

This project was reverse-engineered from BetterDisplay's approach by:
1. Discovering the private `IOAVServiceSetVirtualEDIDMode(IOAVServiceRef, uint32_t mode, CFDataRef edid)` API
2. Capturing BetterDisplay's working EDID while running at 110Hz
3. Determining that EDID injection alone triggers the DCP to rebuild the display mode table
4. Finding that macOS remembers the refresh rate preference, so only injection is needed (no explicit mode switch)
5. Adding a daemon mode with `CGDisplayRegisterReconfigurationCallback` to automatically re-inject after sleep/wake

## License

MIT
