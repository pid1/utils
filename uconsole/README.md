# uConsole setup

Provisioning for a **ClockworkPi uConsole (CM4 Lite)** running **Rex's Debian
Bookworm image**, with the **HackerGadgets AIO v2** extension board.

```bash
curl -fsSL https://raw.githubusercontent.com/pid1/utils/main/uconsole/setup.sh | sudo bash
```

Re-running is safe and is the intended way to use this — every step is
idempotent, and a run that changes nothing writes nothing.

---

## Getting the OS on first

**1. Download Rex's image**, `ClockworkPi-Bookworm-6.12.y.img.xz`.

Rex (`ak-rex`) publishes **no images on GitHub** — his GitHub holds only source
(pi-gen, the kernel tree, the apt repo). The images live on:

- <https://mega.nz/folder/LSInGD6J#0YezWX8xC4PkbyForgl1Hw>
- <https://drive.google.com/drive/folders/1tw2uPVPsFDhQ5Onx4mlllYexUDmDp0eK>
- <https://app.drime.cloud/drive/s/O3faUnk9ihg2vlrgek0LiaHRiU3fGb>

all linked from the [forum thread](https://forum.clockworkpi.com/t/bookworm-6-12-y-for-the-uconsole-and-devterm/15847),
which is also where the current release and any per-version caveats are posted.

**2. Write it with Raspberry Pi Imager** — *Choose OS → Use custom* → pick the
`.xz` directly, it decompresses on the fly. Balena Etcher works too. Use
Imager's advanced options to preset the Wi-Fi SSID/password; the uConsole
keyboard is a slow way to type a passphrase.

**3. Target is a microSD card.** A CM4 *with* eMMC has no SD lines wired up and
must be flashed over USB with `rpiboot`/`usbboot`. CM4 Lite uses SD.

**4. First boot** expands the filesystem and reboots itself, then runs a wizard
that creates your user account. The script does not create users — it expects
that account to exist, and takes `--user NAME` if it isn't `jroemer`.

---

## What it assumes

This targets Rex's image specifically:

- **His apt repo is already configured** (it appears as `ClockworkPi-apt`).
  That's where `sdrpp-brown`, `hackergadgets-uconsole-aio-board`, `pinctrl` and
  the rtlsdrblog `rtl-sdr` build come from rather than Debian. The script
  verifies it rather than adding a copy.
- **No games and no desktop.** True of both the Lite (stage2) and full (stage4)
  builds, so there is nothing to strip out.

---

## Sections

Every section is skippable with `--skip NAME`, or run alone with `--only NAME`.

| Section | What it does |
|---|---|
| `base` | Timezone (America/Chicago), hushlogin, SSH host keys, GitHub-backed `authorized_keys` sync, hardware group membership |
| `desktop` | X11 + i3, autologin on tty1, Alacritty, Atkinson fonts, PipeWire, blanking disabled |
| `claude` | Claude Code from Anthropic's signed apt repo |
| `aio` | HackerGadgets AIO v2 metapackage, GPIO power rails, boot overlays |
| `rtc` | PCF85063A over i2c, `fake-hwclock` disabled |
| `gps` | UART + PPS overlays, serial console removed, `gpsd` on `/dev/ttyS0` |
| `lora` | SPI overlays, `meshtasticd` with the SX1262 config |
| `sdr` | `sdrpp-brown`, `rtl-sdr`, DVB-T driver blacklisted, gqrx bookmarks migrated |
| `ham` | JS8Call + hamlib, GhostNet configuration |
| `tailscale` | Tailscale from its official repo |

### Flags

```
--dry-run           print every change without making one
--user NAME         target account (default: jroemer)
--only SECTION      run only these (repeatable)
--skip SECTION      skip these (repeatable)
```

Flags must go through `bash -s --`, since `| sudo bash --dry-run` hands the flag
to bash rather than to the script:

```bash
curl -fsSL <url> | sudo bash -s -- --dry-run
curl -fsSL <url> | sudo bash -s -- --only sdr --skip lora
```

`sudo` scrubs the environment, so `TS_AUTHKEY` must be set **after** `sudo`:

```bash
curl -fsSL <url> | sudo TS_AUTHKEY=tskey-auth-... bash -s -- --only tailscale
```

---

## Key bindings

**`$mod` is Alt.** The uConsole's CMD key is only reachable as `Fn`+`CMD` — a
two-key chord for every window operation — so Alt wins on ergonomics.

| | |
|---|---|
| `Alt + Return` | terminal (Alacritty) |
| `Alt + Shift + d` | dmenu |
| `Alt + Shift + q` | close window |
| `Alt + h/j/k/l` or arrows | focus |
| `Alt + Shift + h/j/k/l` or arrows | move window |
| `Alt + 1..9` | switch workspace |
| `Alt + Shift + 1..9` | move window to workspace |
| `Alt + Shift + b` / `v` | split horizontal / vertical |
| `Alt + Shift + f` | fullscreen |
| `Alt + Shift + w` / `s` / `e` | tabbed / stacking / toggle split |
| `Alt + r` | resize mode (`Escape` exits) |
| `Alt + Shift + c` / `r` | reload / restart i3 |
| `Alt + Shift + x` | exit i3 |
| `Alt + Shift + o` / `p` | backlight off / restore |

### Why window management sits on `Alt+Shift`

i3 grabs `$mod` combinations globally, so every plain `Alt`+letter binding is
taken away from the shell, where readline uses Meta for word motion. i3 claims
only `Alt+h/j/k/l`, `Alt+1..9`, `Alt+r` and `Alt+Return` — costing readline
`M-l`, `M-r` and `M-<digit>`, all rare.

**Still yours in the terminal:** `Alt+b`, `Alt+f`, `Alt+d`, `Alt+t`, `Alt+u`,
`Alt+p`, `Alt+y`, `Alt+.`, `Alt+Backspace`.

---

## Display and power

**Screen blanking, DPMS and idle actions are disabled at every layer** — Xorg
(`/etc/X11/xorg.conf.d/10-no-blanking.conf`), logind (`IdleAction=ignore`), the
kernel console (`consoleblank=0`) and `xset` in `.xinitrc`. Nothing locks or
blanks the screen.

This is not only a battery preference: the DSI panel **wakes from DPMS to a
solid grey screen** and needs a VT switch to repaint, so blanking is actively
harmful here. Use `Alt+Shift+o` to kill the backlight deliberately — that drives
`brightnessctl` and never touches DPMS.

**Rotation** is detected at X startup rather than hardcoded. The panel is
mounted rotated and presents portrait; some images already apply the transform
at the DRM level, and rotating twice leaves the display sideways. If it comes up
sideways, edit `~/.xinitrc`.

## Fonts

`monospace` → **Atkinson Hyperlegible Mono**, `serif` and `sans-serif` →
**Atkinson Hyperlegible Next**, via `/etc/fonts/local.conf`.

Neither is packaged in Debian (`fonts-atkinson-hyperlegible` is the *original*
family only), so both come from the upstream Google Fonts repos. The install
verifies with `fc-match` rather than assuming — a silent miss would just fall
back to DejaVu and look fine.

i3 uses Mono at 12pt. The panel is ~290 DPI, so raise it in
`~/.config/i3/config` if it reads small.

---

## After the first run

A reboot is **required** — RTC, GPS and LoRa are all boot overlays and do
nothing until then.

```bash
ls /dev/rtc* && dmesg | grep -i rtc   # RTC actually bound
sudo hwclock -w                       # seed it once, when NTP time is good
cgps -s                               # GPS (needs antenna + sky view)
aiov2_ctl GPS on                      # rails survived the reboot
claude                                # log in via browser prompt
sudo tailscale up                     # unless TS_AUTHKEY was passed
```

Three things the script deliberately leaves to you:

- **Meshtastic will not transmit** until a LoRa region is set:
  `meshtastic --set lora.region US`. Transmitting on the wrong region is a
  regulatory problem, not a config annoyance.
- **JS8Call audio and PTT** are not configured — they depend on the rig
  attached. Groups, grid, callsign and the 7.107 MHz dial *are* set.
- **`hwclock -r` alone can lie**, reporting plausible time sourced from
  elsewhere. Check `/dev/rtc*` and `dmesg`. No output at all usually means the
  CR1220 is in backwards.

## Bluetooth

`bluez` ships with the image; there's no GUI manager under i3.

```bash
sudo systemctl enable --now bluetooth
bluetoothctl
```

```
power on
agent on
default-agent
scan on                      # note the MAC
pair    AA:BB:CC:DD:EE:FF
trust   AA:BB:CC:DD:EE:FF    # without this it will not reconnect after reboot
connect AA:BB:CC:DD:EE:FF
scan off
```

`trust` is the one that matters — without it the device pairs but won't
reconnect, which reads like flaky Bluetooth. Bluetooth and Wi-Fi share one
antenna on the CM4, so expect input lag on 2.4 GHz when Wi-Fi is busy.

---

## Troubleshooting

**Grey screen after the panel powers off** — shouldn't happen now that blanking
is disabled everywhere. If it does: `Ctrl+Alt+F2` then `Ctrl+Alt+F1` forces a
repaint.

**i3 wedged, or you want the GUI off** — `Ctrl+Alt+F2` for another tty, then:

```bash
sudo rm /etc/systemd/system/getty@tty1.service.d/autologin.conf
```

**dpkg half-configured** — usually a postinst that needed hardware present:

```bash
sudo dpkg --configure -a
sudo apt --fix-broken install
```

**A section failed** — re-run just that one with `--only NAME` rather than the
whole script. Boot files always have a `.bak-<timestamp>` beside them (taken
once, on the first run — that copy is the pristine pre-script state).

**LoRa silent** — check `/etc/meshtasticd/config.d/uconsole-aio-v2.yaml` is
actually being read before debugging the radio. The drop-in only applies if the
packaged version supports `config.d`.
