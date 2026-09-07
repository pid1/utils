# uConsole setup

Provisioning for a **ClockworkPi uConsole (CM4 Lite)** running **Rex's Debian
Bookworm image**, with the **HackerGadgets AIO v2** extension board.

```bash
curl -fsSL pid1.space/cpi | sudo bash
```

<details>
<summary>If the short URL is down</summary>

`pid1.space/cpi` is a mirror of `uconsole/setup.sh`, republished to
`pid1.github.io` by [`publish-cpi.yml`](../.github/workflows/publish-cpi.yml)
on every change to this script. It can lag by a minute or two while Pages
rebuilds, and it depends on that workflow having run. This repo is always the
source of truth, so the raw URL is the fallback and is never stale:

```bash
curl -fsSL https://raw.githubusercontent.com/pid1/utils/main/uconsole/setup.sh | sudo bash
```

Both take the same flags. Substitute either URL wherever this README says
`pid1.space/cpi`.
</details>

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
| `base` | Timezone (America/Chicago), hushlogin, sshd enabled, GitHub-backed `authorized_keys` sync, the `maint` maintenance command, hardware group membership |
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
curl -fsSL pid1.space/cpi | sudo bash -s -- --dry-run
curl -fsSL pid1.space/cpi | sudo bash -s -- --only sdr --skip lora
```

`sudo` scrubs the environment, so `TS_AUTHKEY` must be set **after** `sudo`:

```bash
curl -fsSL pid1.space/cpi | sudo TS_AUTHKEY=tskey-auth-... bash -s -- --only tailscale
```

---

## Routine maintenance

```bash
sudo maint
```

One command, installed by the `base` section:

1. `apt update`, `apt full-upgrade`, `apt autoremove --purge`
2. re-fetches and re-applies `setup.sh` — idempotent, so only drift and newly
   added configuration change
3. reports whether a reboot is pending, and which packages want one

Arguments pass through, so `sudo maint --dry-run` previews the configuration
half without touching anything, and `sudo maint --only sdr` narrows it.

Kernel updates arrive here too — Rex ships `clockworkpi-kernel` through his
repo, so `full-upgrade` picks them up and the reboot notice will say so.

It fetches from `pid1.space/cpi`, falling back to the raw URL, and downloads to
a file rather than piping — a truncated transfer is then caught by the same
checks the publish workflow uses (`bash -n`, shebang, and the trailing
`main "$@"` without which the script would parse cleanly and do nothing).

---

## SSH

Enabled and listening on 22 by the `base` section. pi-gen's stage2 contains
both `systemctl enable ssh` and `systemctl disable ssh` behind a build-time
condition, so the image's state is not assumable either way.

`authorized_keys` is refreshed from `github.com/pid1.keys` every 5 minutes for
both `root` and the desktop user, via `/usr/local/sbin/sync-github-keys`. It
fetches to a temp file, requires the result to be non-empty and to parse as SSH
public keys, and only then swaps it in atomically — a GitHub outage can never
empty the file and lock you out. It also only rewrites when the content
actually changed, which matters against an SD card.

**Password authentication is still on.** Once you have confirmed key login
works, turn it off:

```bash
sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
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

## Power rails

AIO v2 gates each subsystem behind a GPIO-switched rail — nothing on the board
responds until its rail is driven high. This is the main difference from V1,
which had no such gating.

| Rail | GPIO | At boot |
|---|---|---|
| `SDR` | 7 | **on** |
| `USB` (internal hub) | 23 | **on** |
| `GPS` | 27 | off |
| `LORA` | 16 | off |

**SDR and USB come up together on purpose.** The RTL-SDR is an internal USB
device behind the AIO's hub, so powering the SDR rail alone will not make it
enumerate — `rtl_test` would report no supported devices found.

GPS and LoRa stay off: they draw continuously for hardware most sessions don't
use. Everything else for them *is* configured — overlays, `gpsd`,
`meshtasticd` — so they need only power.

### Turning one on for this session

```bash
sudo aiov2_ctl GPS on          # or LORA, SDR, USB
sudo aiov2_ctl GPS off
```

Without the vendor tool, the fallback installed here does the same:

```bash
sudo uconsole-aio-rails GPS on
sudo uconsole-aio-rails            # just the boot set (SDR + USB)
```

### Making it persistent

Edit `BOOT_RAILS` near the top of `setup.sh` and re-run `--only aio`:

```bash
local BOOT_RAILS=(SDR USB GPS)
```

A re-run never forces GPS or LoRa *off*, so a rail you switched on by hand
survives until you reboot.

### Empty waterfall in SDR++

A working device and a dead one look the same in SDR++, so check in this order:

1. **Gain starts at 0.** This is the usual cause. Raise the gain slider.
2. **Press play.** A stopped SDR++ shows an empty waterfall, not an error.
3. **Source → RTL-SDR → Refresh**, then select the device. It will not
   auto-select one that appeared after launch.
4. **Test on a strong FM broadcast** (88–108 MHz) before anything weak.
5. Check the waterfall **min/max dB** sliders have not collapsed together.

Prove the hardware independently of SDR++ first:

```bash
rtl_test -t                     # tuner type, and that the device opens
timeout 10 rtl_test -s 2400000  # sample rate; watch for "lost at least N bytes"
```

Sample loss points at USB rather than software — the dongle sits behind the
AIO's internal hub, so lower the sample rate rather than chasing SDR++
settings. The antenna belongs on the pad marked **SDR**; the GPS pad is a
separate path and will not feed the dongle.

### Checking

```bash
rtl_test -t                   # SDR enumerated
pinctrl get 7                 # rail state directly
cgps -s                       # GPS, once its rail is on
```

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
rtl_test -t                           # SDR enumerated (its rail is on by default)
sudo aiov2_ctl GPS on && cgps -s      # GPS rail is OFF by default
claude                                # log in via browser prompt
ssh jroemer@clockworkpi.local         # from another machine
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
