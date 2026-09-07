#!/usr/bin/env bash
#
# Provisioning for a ClockworkPi uConsole (CM4) on Rex's Debian Bookworm image
# with the HackerGadgets AIO v2 board. See README.md in this directory for
# what it installs, key bindings, and post-install steps.
#
#   curl -fsSL pid1.space/cpi | sudo bash        (mirror of this file)
#
# Flags must go through `bash -s --`; `| sudo bash --dry-run` hands the flag to
# bash instead of to this script:
#
#   ... | sudo bash -s -- --dry-run
#   ... | sudo bash -s -- --only sdr --skip lora
#   ... | sudo TS_AUTHKEY=tskey-auth-... bash -s -- --only tailscale
#
# Two constraints shape this file:
#
#   The body is wrapped in main() so a truncated download -- the pipe dropping
#   mid-transfer -- dies on an incomplete function definition instead of
#   executing half a script that rewrites config.txt.
#
#   stdin is the script itself, so nothing here may read from it. apt is fully
#   non-interactive; the escape hatch for a real prompt is `< /dev/tty`.
#
# Every step is idempotent: re-running is the intended way to use this as
# config management. A run that changes nothing writes nothing.

main() {
  set -euo pipefail

  # ------------------------------------------------------------------ config

  local GH_KEY_USER=pid1
  local DEFAULT_USER=jroemer
  local TIMEZONE=America/Chicago   # US/Central; America/Chicago is the canonical name
  local AIOV2_REPO=https://github.com/hackergadgets/aiov2_ctl.git
  local AIOV2_DIR=/opt/aiov2_ctl
  local MESHTASTIC_REPO=http://download.opensuse.org/repositories/network:/Meshtastic:/beta/Raspbian_12/
  # Rex (ak-rex) maintains the ClockworkPi apt repo that his Bookworm image
  # ships with. It is served straight out of a GitHub repo, and carries the
  # things Debian does not have: sdrpp, the hackergadgets AIO metapackage,
  # pinctrl, and the rtlsdrblog fork of rtl-sdr.
  # Anthropic's release signing key, per code.claude.com/docs/en/setup.
  local CLAUDE_KEY_URL=https://downloads.claude.ai/keys/claude-code.asc
  local CLAUDE_KEY=/etc/apt/keyrings/claude-code.asc
  local CLAUDE_KEY_FP=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
  local CLAUDE_LIST=/etc/apt/sources.list.d/claude-code.list

  # AIO v2 puts each subsystem behind a GPIO-switched power rail. Nothing on
  # the board responds until these are driven high. (V1 had no such gating.)
  local RAIL_GPS=27 RAIL_LORA=16 RAIL_SDR=7 RAIL_USB=23

  # Rails brought up at boot. SDR needs USB as well: the RTL-SDR is an
  # internal USB device behind the AIO hub, so powering the SDR rail alone
  # will not make it enumerate. GPS and LoRa are left off -- they draw
  # continuously for hardware most sessions do not use -- and the README
  # documents turning them on. Add GPS/LORA here to make them persistent.
  local BOOT_RAILS=(SDR USB)

  local BEGIN_MARK='# >>> uconsole-setup >>>'
  local END_MARK='# <<< uconsole-setup <<<'

  local ALL_SECTIONS=(base desktop claude aio rtc gps lora sdr ham tailscale)

  # Hardware groups. The account created by the image's first-boot wizard is
  # not in these, and no AIO peripheral works non-root without them.
  local HW_GROUPS=(dialout spi i2c gpio plugdev audio video netdev)

  # --------------------------------------------------------------- arg parse

  local DRY_RUN=false
  local DESKTOP_USER=""
  local -a ONLY=() SKIP=()

  while (( $# )); do
    case $1 in
      --dry-run)      DRY_RUN=true ;;
      --user)         DESKTOP_USER=${2:?--user needs a value}; shift ;;
      --user=*)       DESKTOP_USER=${1#*=} ;;
      --only)         ONLY+=("${2:?--only needs a section}"); shift ;;
      --only=*)       ONLY+=("${1#*=}") ;;
      --skip)         SKIP+=("${2:?--skip needs a section}"); shift ;;
      --skip=*)       SKIP+=("${1#*=}") ;;
      -h|--help)
        printf 'usage: setup.sh [--dry-run] [--user NAME] [--only SECTION]... [--skip SECTION]...\n'
        printf 'sections: %s\n' "${ALL_SECTIONS[*]}"
        return 0 ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done

  # ---------------------------------------------------------------- plumbing

  local -a NOTES=()

  log()     { printf '  %s\n' "$*"; }
  warn()    { printf '  !! %s\n' "$*" >&2; }
  die()     { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }
  section() { printf '\n== %s\n' "$*"; }
  note()    { NOTES+=("$*"); }

  run() {
    if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; return 0; fi
    "$@"
  }

  # write_file <path> [mode]; content on stdin. Writes via a same-directory
  # temp file so a failure part-way never leaves a truncated target.
  write_file() {
    local path=$1 mode=${2:-0644} content tmp
    content=$(cat)
    if $DRY_RUN; then
      printf '  [dry-run] write %s (mode %s):\n' "$path" "$mode"
      printf '%s\n' "$content" | sed 's/^/    | /'
      return 0
    fi
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "${path}.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path"
  }

  pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
  }

  pkg_available() {
    local cand
    cand=$(apt-cache policy "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2}')
    [[ -n $cand && $cand != '(none)' ]]
  }

  apt_install() { run apt-get install -y "$@"; }

  # For optional extras: warn rather than abort. A missing optional package
  # should not take down a whole provisioning run, and under set -e a plain
  # apt_install would.
  apt_install_opt() {
    run apt-get install -y "$@" || warn "optional install failed: $*"
    return 0
  }

  # apt refuses to update a repo whose Release metadata changed, until the
  # change is confirmed. Two benign ones show up here: Debian bumping Version
  # across point releases (12.13 -> 12.15), and Rex relabelling his repo. Both
  # are accepted narrowly by field.
  #
  # Origin, Codename and Suite are deliberately NOT accepted: those indicate
  # the repository is claiming to be something other than what it was, which is
  # the case apt-secure(8) actually exists to stop. Confirm those by hand.
  #
  # Non-fatal: one third-party repo failing should not abort provisioning, and
  # the error stays visible above the warning.
  # Reports apt's real exit status, so callers that need to roll back can.
  apt_update() {
    run apt-get update -y \
      --allow-releaseinfo-change-version \
      --allow-releaseinfo-change-label
  }

  # Never fatal: one third-party repo failing should not abort provisioning,
  # and apt's own error stays visible above the warning.
  apt_update_soft() {
    apt_update || warn "apt-get update reported errors (see above); continuing anyway"
    return 0
  }

  # Replace our marker-delimited block in a file, or append it if absent.
  apply_block() {
    local file=$1 content stripped
    content=$(cat)
    stripped=$(sed "\|^${BEGIN_MARK}\$|,\|^${END_MARK}\$|d" "$file")
    printf '%s\n\n%s\n%s\n%s\n' \
      "$stripped" "$BEGIN_MARK" "$content" "$END_MARK" | write_file "$file" 0644
  }

  # Rex's image ships his apt repo already configured (it appears as
  # ClockworkPi-apt), and that is where sdrpp-brown, the HackerGadgets AIO
  # metapackage, pinctrl and the rtlsdrblog rtl-sdr build come from. This
  # script targets that image, so it verifies the repo is there rather than
  # carrying the key-fetch and sources.list plumbing to install a second copy
  # of the same packages under a different name.
  local AKREX_CHECKED=false
  require_akrex_repo() {
    $AKREX_CHECKED && return 0
    AKREX_CHECKED=true
    pkg_available sdrpp-brown || pkg_available sdrpp || {
      warn "Rex's ClockworkPi apt repo does not look configured: no sdrpp package resolves."
      warn "This script targets Rex's image, which ships it. On another image, add it from"
      warn "  https://github.com/ak-rex/akrex-arm-repo   then re-run."
    }
    return 0
  }

  want() {
    local s=$1 x
    if (( ${#ONLY[@]} )); then
      for x in "${ONLY[@]}"; do [[ $x == "$s" ]] && return 0; done
      return 1
    fi
    for x in "${SKIP[@]}"; do [[ $x == "$s" ]] && return 1; done
    return 0
  }

  # --------------------------------------------------------------- preflight

  section "Preflight"

  (( EUID == 0 )) || die "must run as root (pipe to 'sudo bash', not 'bash')"

  local s known
  for s in "${ONLY[@]}" "${SKIP[@]}"; do
    known=false
    for x in "${ALL_SECTIONS[@]}"; do [[ $x == "$s" ]] && known=true; done
    $known || die "unknown section '$s' (valid: ${ALL_SECTIONS[*]})"
  done

  $DRY_RUN && log "DRY RUN — no changes will be made"

  # Bookworm moved the firmware partition; older images still use /boot.
  local BOOT_DIR
  if [[ -f /boot/firmware/config.txt ]]; then
    BOOT_DIR=/boot/firmware
  elif [[ -f /boot/config.txt ]]; then
    BOOT_DIR=/boot
  else
    die "cannot find config.txt in /boot/firmware or /boot — is this a Pi image?"
  fi
  log "boot dir: $BOOT_DIR"

  local OS_ID=debian OS_CODENAME=bookworm
  if [[ -r /etc/os-release ]]; then
    OS_ID=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
    OS_CODENAME=$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
  fi
  log "os: ${OS_ID} ${OS_CODENAME}"
  [[ $OS_CODENAME == bookworm ]] || warn "expected bookworm, found '${OS_CODENAME}' — continuing anyway"

  local MODEL="unknown"
  [[ -r /proc/device-tree/model ]] && MODEL=$(tr -d '\0' < /proc/device-tree/model)
  log "model: $MODEL"
  case $MODEL in
    *"Compute Module 4"*) ;;
    *) warn "this script targets CM4; overlays and device paths may be wrong on '$MODEL'" ;;
  esac

  # Resolve the desktop account. Never create it — the password policy and
  # sudo membership are decisions this script should not be making silently.
  [[ -n $DESKTOP_USER ]] || DESKTOP_USER=$DEFAULT_USER
  # Rex's Lite image runs a first-boot wizard that creates the user account, so
  # by the time this runs it should already exist.
  if ! id -u "$DESKTOP_USER" >/dev/null 2>&1; then
    if [[ -n ${SUDO_USER:-} ]] && id -u "$SUDO_USER" >/dev/null 2>&1; then
      warn "user '$DESKTOP_USER' does not exist; falling back to '\$SUDO_USER' ($SUDO_USER)"
      DESKTOP_USER=$SUDO_USER
    else
      die "user '$DESKTOP_USER' does not exist. Create it first:
    adduser $DESKTOP_USER && adduser $DESKTOP_USER sudo
  then re-run, or pass --user NAME for a different account."
    fi
  fi

  local USER_HOME USER_GROUP
  USER_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
  USER_GROUP=$(id -gn "$DESKTOP_USER")
  [[ -d $USER_HOME ]] || die "home directory '$USER_HOME' for '$DESKTOP_USER' does not exist"
  log "desktop user: $DESKTOP_USER ($USER_HOME)"

  # Back up the boot files once per run, before anything touches them.
  local STAMP; STAMP=$(date +%Y%m%d-%H%M%S)
  # Back up once, not per run: this script is meant to be re-runnable as
  # config management, and /boot/firmware is a small FAT partition that would
  # slowly fill with timestamped copies. The first backup is the pristine
  # pre-script state, which is the one worth keeping.
  local f
  for f in "$BOOT_DIR/config.txt" "$BOOT_DIR/cmdline.txt"; do
    [[ -f $f ]] || continue
    if compgen -G "${f}.bak-*" >/dev/null; then
      log "$(basename "$f"): pre-existing backup kept ($(basename "$(ls -1 "${f}".bak-* | head -1)"))"
    else
      run cp -a "$f" "${f}.bak-${STAMP}"
      log "$(basename "$f") backed up as .bak-${STAMP}"
    fi
  done

  export DEBIAN_FRONTEND=noninteractive
  apt_update_soft

  # -------------------------------------------------------------------- base

  if want base; then
    section "Base system"

    # US/Central. Also matters beyond the clock display: JS8Call and the RTC
    # both care, and gpsd/chrony will be feeding real time in shortly.
    if command -v timedatectl >/dev/null 2>&1; then
      local current_tz
      current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "")
      if [[ $current_tz == "$TIMEZONE" ]]; then
        log "timezone already $TIMEZONE"
      else
        run timedatectl set-timezone "$TIMEZONE"
        log "timezone set to $TIMEZONE (was ${current_tz:-unknown})"
      fi
    else
      warn "timedatectl not found — timezone unchanged"
    fi

    run touch /root/.hushlogin
    run install -o "$DESKTOP_USER" -g "$USER_GROUP" -m 0644 /dev/null "$USER_HOME/.hushlogin"
    log "hushlogin set for root and $DESKTOP_USER"

    # -A generates one host key per supported type, skipping any that exist.
    run ssh-keygen -A
    log "ssh host keys present"

    apt_install curl ca-certificates gnupg git

    # GitHub-backed authorized_keys sync. The original one-liner redirected
    # curl straight into authorized_keys, which truncates the file before
    # curl runs — a GitHub 503 or a dropped link would empty it and lock you
    # out of a device whose only other input is its own keyboard. This
    # fetches to a temp file, insists the result is non-empty and actually
    # parses as SSH public keys, and only then swaps it in atomically.
    write_file /usr/local/sbin/sync-github-keys 0755 <<'SYNCKEYS'
#!/bin/sh
# Managed by uconsole/setup.sh — refresh authorized_keys from GitHub.
set -eu

GH_USER="__GH_USER__"
URL="https://github.com/${GH_USER}.keys"

sync_for() {
    _user=$1
    _home=$2
    [ -d "$_home" ] || return 0

    _tmp=$(mktemp "${_home}/.ssh-keys.XXXXXX" 2>/dev/null) || return 0

    if ! curl -fsSL --max-time 20 "$URL" -o "$_tmp"; then
        rm -f "$_tmp"
        return 0
    fi
    # Empty response, or an HTML error page, must never reach authorized_keys.
    if [ ! -s "$_tmp" ] || ! ssh-keygen -l -f "$_tmp" >/dev/null 2>&1; then
        rm -f "$_tmp"
        return 0
    fi

    # Only rewrite when the content actually differs — this runs every 5
    # minutes against an SD card, and an unchanged key set is the normal case.
    if [ -f "${_home}/.ssh/authorized_keys" ] \
       && cmp -s "$_tmp" "${_home}/.ssh/authorized_keys"; then
        rm -f "$_tmp"
        return 0
    fi

    mkdir -p "${_home}/.ssh"
    chmod 700 "${_home}/.ssh"
    chown "$_user" "${_home}/.ssh"
    chmod 600 "$_tmp"
    chown "$_user" "$_tmp"
    mv -f "$_tmp" "${_home}/.ssh/authorized_keys"
}

sync_for root /root
sync_for "__DESKTOP_USER__" "__USER_HOME__"
SYNCKEYS

    if ! $DRY_RUN; then
      sed -i \
        -e "s|__GH_USER__|${GH_KEY_USER}|" \
        -e "s|__DESKTOP_USER__|${DESKTOP_USER}|" \
        -e "s|__USER_HOME__|${USER_HOME}|" \
        /usr/local/sbin/sync-github-keys
    fi

    write_file /etc/cron.d/keys 0644 <<'CRON'
# Managed by uconsole/setup.sh
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/5 * * * *   root   /usr/local/sbin/sync-github-keys
CRON

    # Seed immediately so the first login does not wait on cron.
    run /usr/local/sbin/sync-github-keys || warn "initial key sync failed (network?); cron will retry"
    log "github key sync installed (${GH_KEY_USER}, every 5 min)"

    # Hardware group membership — required for the AIO peripherals to be
    # usable without sudo. Only add groups that actually exist on this image.
    local g present=()
    for g in "${HW_GROUPS[@]}"; do
      getent group "$g" >/dev/null 2>&1 && present+=("$g")
    done
    if (( ${#present[@]} )); then
      local joined; joined=$(IFS=,; printf '%s' "${present[*]}")
      run usermod -aG "$joined" "$DESKTOP_USER"
      log "added $DESKTOP_USER to: ${present[*]}"
      note "Group changes need a full logout/login (or reboot) before they apply."
    fi
  fi

  # ----------------------------------------------------------------- desktop

  if want desktop; then
    section "Desktop (i3 + X11)"

    apt_install xserver-xorg xinit x11-xserver-utils \
                i3 i3status dmenu alacritty brightnessctl \
                fonts-dejavu-core fontconfig

    # A Lite image has no audio userland at all, and both JS8Call and SDR++
    # need one. clockworkpi-audio carries the device-specific config.
    apt_install pipewire pipewire-pulse wireplumber || warn "audio stack install failed"
    if pkg_available clockworkpi-audio; then
      apt_install clockworkpi-audio || warn "clockworkpi-audio failed"
    fi

    # A complete config we author, rather than Debian's shipped one with sed
    # patches on top. Patching left bindings in the file that this script did
    # not choose and could not reason about; owning it outright means every
    # key here is deliberate. It also avoids i3's interactive first-run config
    # wizard, which would block a headless boot.
    #
    # Note there is deliberately NO binding on a bare Return anywhere -- not
    # even to leave resize mode, where Debian's config uses one. Enter must
    # always just be Enter.
    #
    # This file is managed: local edits are overwritten on the next run.
    write_file "$USER_HOME/.config/i3/config" 0644 <<'I3CONF'
# Managed by uconsole/setup.sh -- edits here are overwritten on the next run.

# $mod is Alt (Mod1). The uConsole's CMD key is reachable only as Fn+CMD --
# a two-key chord for every window operation -- so Alt wins on ergonomics
# despite the cost below.
#
# The cost: i3 grabs $mod combinations globally, so every plain Alt+<letter>
# bound here is taken away from the shell, where readline uses Meta for word
# motion. The bindings are therefore arranged to keep the ones worth keeping:
#
#   still available to bash:  Alt+b Alt+f Alt+d Alt+t Alt+u Alt+p Alt+y Alt+.
#                             Alt+BackSpace  (word motion, kill-word, yank-arg)
#   taken by i3:              Alt+h/j/k/l (focus), Alt+1..9 (workspaces),
#                             Alt+r, Alt+Return
#
# That trades away readline's M-l (downcase-word), M-r (revert-line) and
# M-<digit> (digit-argument), which are rare, and keeps everything common.
# Window management otherwise lives on Alt+Shift.
set $mod Mod1

# 12pt is a starting point for the 5" 720p panel (~290 DPI); raise if small.
font pango:Atkinson Hyperlegible Mono 12

# --- launching --------------------------------------------------------------
bindsym $mod+Return       exec alacritty
bindsym $mod+Shift+Return exec alacritty
bindsym $mod+Shift+d      exec dmenu_run
bindsym $mod+Shift+q      kill

# --- focus ------------------------------------------------------------------
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left  focus left
bindsym $mod+Down  focus down
bindsym $mod+Up    focus up
bindsym $mod+Right focus right

# --- moving -----------------------------------------------------------------
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left  move left
bindsym $mod+Shift+Down  move down
bindsym $mod+Shift+Up    move up
bindsym $mod+Shift+Right move right

# --- layout -----------------------------------------------------------------
# The panel is wide and short, so default to side-by-side splits.
bindsym $mod+Shift+b split h
bindsym $mod+Shift+v split v
bindsym $mod+Shift+f fullscreen toggle
bindsym $mod+Shift+s layout stacking
bindsym $mod+Shift+w layout tabbed
bindsym $mod+Shift+e layout toggle split
bindsym $mod+Shift+space floating toggle
bindsym $mod+Shift+a focus parent

# --- workspaces -------------------------------------------------------------
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+6 workspace number 6
bindsym $mod+7 workspace number 7
bindsym $mod+8 workspace number 8
bindsym $mod+9 workspace number 9
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5
bindsym $mod+Shift+6 move container to workspace number 6
bindsym $mod+Shift+7 move container to workspace number 7
bindsym $mod+Shift+8 move container to workspace number 8
bindsym $mod+Shift+9 move container to workspace number 9

# --- session ----------------------------------------------------------------
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+x exec "i3-nagbar -t warning -m 'Exit i3?' -B 'Yes' 'i3-msg exit'"

# --- hardware keys ----------------------------------------------------------
bindsym XF86MonBrightnessUp   exec brightnessctl set +10%
bindsym XF86MonBrightnessDown exec brightnessctl set 10%-

# Automatic blanking is disabled (the panel does not survive DPMS), so this is
# the deliberate way to kill the backlight on battery. Brightness-up restores
# it; --save/--restore keeps the previous level.
bindsym $mod+Shift+o exec --no-startup-id brightnessctl --save set 0
bindsym $mod+Shift+p exec --no-startup-id brightnessctl --restore

bindsym XF86AudioRaiseVolume  exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bindsym XF86AudioLowerVolume  exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindsym XF86AudioMute         exec wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle

# --- resize -----------------------------------------------------------------
# Escape only. Debian's default also binds a bare Return here, which is
# exactly the kind of stray Enter binding this config avoids.
mode "resize" {
        bindsym h resize shrink width  10 px or 10 ppt
        bindsym j resize grow   height 10 px or 10 ppt
        bindsym k resize shrink height 10 px or 10 ppt
        bindsym l resize grow   width  10 px or 10 ppt
        bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

bar {
        status_command i3status
        position top
        tray_output primary
}
I3CONF
    log "wrote a managed i3 config (no bare Return bindings)"

    # Alacritty config, pulled from this same repo. Its theme import points at
    # cytracom_light.toml, which is in neither the upstream alacritty-theme
    # repo nor any local checkout, so the import is commented out and the
    # built-in default colours are used. Uncomment once the file exists.
    local aldir="$USER_HOME/.config/alacritty"
    run mkdir -p "$aldir"
    if $DRY_RUN; then
      log "[dry-run] fetch alacritty.toml into $aldir"
    elif curl -fsSL --max-time 20 \
           "https://raw.githubusercontent.com/${GH_KEY_USER}/utils/main/alacritty.toml" \
           -o "$aldir/alacritty.toml"; then
      sed -i 's|^\( *\)\("~/.*themes.*\.toml"\)|\1# \2  # uconsole-setup: no such file|' \
        "$aldir/alacritty.toml"
      log "installed alacritty.toml (theme import disabled, using defaults)"
    else
      warn "could not fetch alacritty.toml — using alacritty defaults"
    fi

    # Atkinson Hyperlegible Next and Mono. Debian's fonts-atkinson-hyperlegible
    # is the original family only; Next and Mono are separate newer families
    # and are not packaged, so take them from the upstream Google Fonts repos.
    # alacritty.toml asks for "Atkinson Hyperlegible Mono", which is the family
    # name shipped by the -next-mono repo.
    local fontdir=/usr/local/share/fonts frepo dest tmpd
    for frepo in atkinson-hyperlegible-next atkinson-hyperlegible-next-mono; do
      dest="$fontdir/$frepo"
      if [[ -d $dest ]]; then
        log "fonts: $frepo already present"
        continue
      fi
      if $DRY_RUN; then
        log "[dry-run] install fonts from googlefonts/$frepo"
        continue
      fi
      tmpd=$(mktemp -d)
      if git clone --depth 1 "https://github.com/googlefonts/$frepo" "$tmpd" >/dev/null 2>&1 \
         && compgen -G "$tmpd/fonts/otf/*.otf" >/dev/null; then
        mkdir -p "$dest"
        cp "$tmpd"/fonts/otf/*.otf "$dest"/
        chmod 0644 "$dest"/*.otf
        log "fonts: installed $frepo ($(ls "$dest" | wc -l | tr -d ' ') faces)"
      else
        warn "fonts: could not fetch googlefonts/$frepo"
      fi
      rm -rf "$tmpd"
    done
    # Point the generic families at Atkinson: Mono for monospace, Next for
    # both proportional families. <prefer> puts these at the head of the
    # substitution list without removing the existing fallbacks, so anything
    # they lack a glyph for still resolves.
    write_file /etc/fonts/local.conf 0644 <<'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- Managed by uconsole/setup.sh -->
<fontconfig>
  <alias>
    <family>monospace</family>
    <prefer><family>Atkinson Hyperlegible Mono</family></prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer><family>Atkinson Hyperlegible Next</family></prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer><family>Atkinson Hyperlegible Next</family></prefer>
  </alias>
</fontconfig>
FONTCONF

    if ! $DRY_RUN; then
      fc-cache -f >/dev/null 2>&1 || warn "fc-cache failed"
      # Confirm the aliases actually resolve; a silent miss here means every
      # generic-family lookup quietly falls back to DejaVu.
      local generic resolved
      for generic in monospace sans-serif serif; do
        resolved=$(fc-match "$generic" 2>/dev/null | head -1)
        case $resolved in
          *Atkinson*) log "font: $generic -> $resolved" ;;
          *) warn "font: $generic resolved to '$resolved', not Atkinson" ;;
        esac
      done
    fi

    # i3status: Debian's default shows "ethernet" and "battery all", neither of
    # which reports anything here -- there is no wired NIC, and the uConsole
    # battery is not exposed as a standard power_supply device. Replaced with
    # labelled CPU, RAM and temperature so the numbers are identifiable.
    write_file "$USER_HOME/.config/i3status/config" 0644 <<'I3STATUS'
# Managed by uconsole/setup.sh
general {
        colors = true
        interval = 5
}

order += "cpu_usage"
order += "memory"
order += "cpu_temperature 0"
order += "disk /"
order += "wireless _first_"
order += "tztime local"

cpu_usage {
        format = "CPU %usage"
}

memory {
        format = "RAM %used / %total"
        threshold_degraded = "10%"
        format_degraded = "RAM LOW %available"
}

cpu_temperature 0 {
        format = "TEMP %degrees°C"
        path = "/sys/class/thermal/thermal_zone0/temp"
}

disk "/" {
        format = "SD %avail"
}

wireless _first_ {
        format_up = "WIFI %quality %essid"
        format_down = "WIFI down"
}

tztime local {
        format = "%Y-%m-%d %H:%M"
}
I3STATUS
    log "wrote i3status config (CPU/RAM/temp/disk/wifi/clock)"

    # Start X on tty1 only. The panel is mounted rotated, so it comes up
    # portrait and needs a transform; detect at runtime rather than assume,
    # because some images already apply it at the DRM level and rotating a
    # second time leaves the display sideways.
    # Screen blanking and power management are disabled at every layer, not
    # just in X. This device is almost always on battery and the screen is
    # wanted on regardless; the DSI panel also wakes from DPMS to a grey
    # screen, so blanking is actively harmful here rather than merely unwanted.
    #
    # 1. Xorg itself, from server start. This is the durable one: it applies
    #    before any session script runs and survives anything that resets xset.
    write_file /etc/X11/xorg.conf.d/10-no-blanking.conf 0644 <<'XORGBLANK'
# Managed by uconsole/setup.sh
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection

Section "Extensions"
    Option "DPMS" "Disable"
EndSection
XORGBLANK

    # 2. logind, so no idle action fires at the seat level.
    write_file /etc/systemd/logind.conf.d/10-no-idle.conf 0644 <<'LOGIND'
# Managed by uconsole/setup.sh
[Login]
IdleAction=ignore
IdleActionSec=0
LOGIND

    # 3. The kernel framebuffer console, which blanks independently of X and
    #    is what you land on if X ever exits. consoleblank is a boot parameter,
    #    so this needs the reboot the overlays already require.
    if [[ -f $BOOT_DIR/cmdline.txt ]]; then
      if grep -q 'consoleblank=' "$BOOT_DIR/cmdline.txt"; then
        $DRY_RUN || sed -i 's/consoleblank=[0-9]*/consoleblank=0/' "$BOOT_DIR/cmdline.txt"
      else
        # cmdline.txt must stay exactly one line.
        $DRY_RUN || sed -i '1s/$/ consoleblank=0/' "$BOOT_DIR/cmdline.txt"
      fi
      log "console blanking disabled (consoleblank=0)"
    fi

    write_file "$USER_HOME/.xinitrc" 0755 <<'XINITRC'
#!/bin/sh
# Managed by uconsole/setup.sh
line=$(xrandr | grep -m1 ' connected')
out=${line%% *}
geom=$(printf '%s\n' "$line" | grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
w=${geom%%x*}
h=${geom#*x}; h=${h%%+*}
case "$w" in ''|*[!0-9]*) w=0 ;; esac
case "$h" in ''|*[!0-9]*) h=0 ;; esac
if [ -n "$out" ] && [ "$h" -gt "$w" ]; then
    xrandr --output "$out" --rotate right
fi

# Belt and braces. Xorg is already configured not to blank (see
# /etc/X11/xorg.conf.d/10-no-blanking.conf), but anything in a session can
# turn it back on at runtime, so assert it here too. The panel wakes from
# DPMS to a solid grey screen that needs a VT switch to clear, and this
# device is almost always on battery with the screen wanted on regardless.
xset s off
xset s noblank
xset -dpms

exec i3
XINITRC

    # Sourcing .profile keeps this from shadowing the shell's normal setup,
    # which bash would otherwise skip once .bash_profile exists.
    write_file "$USER_HOME/.bash_profile" 0644 <<'BASHPROF'
# Managed by uconsole/setup.sh
[ -f "$HOME/.profile" ] && . "$HOME/.profile"

# Deliberately not `exec startx`: with exec, a failing X replaces the login
# shell, the shell exits, getty respawns, autologin fires again -- an endless
# tty1 login loop with no prompt to debug from. This way a failure (or exiting
# i3) drops you at a shell on tty1 instead.
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    startx || echo "startx exited ($?); you are at a shell on tty1."
fi
BASHPROF

    write_file /etc/systemd/system/getty@tty1.service.d/autologin.conf 0644 <<AUTOLOGIN
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${DESKTOP_USER} --noclear %I \$TERM
AUTOLOGIN
    run systemctl daemon-reload

    run chown -R "${DESKTOP_USER}:${USER_GROUP}" \
      "$USER_HOME/.config" "$USER_HOME/.xinitrc" "$USER_HOME/.bash_profile"

    log "i3 + X11 configured, autologin on tty1 as $DESKTOP_USER"
    note "Desktop: tty1 autologins as $DESKTOP_USER and starts i3. Mod is ALT: Alt+Return for a terminal, Alt+Shift+d for dmenu, Alt+Shift+q to close. Window management sits on Alt+Shift so bash keeps Alt+b/f/d/. for word motion."
    note "i3status now shows labelled CPU, RAM, temperature, disk and wifi; ethernet and battery are gone. Config: ~/.config/i3status/config (Mod+Shift+r reloads i3)."
    note "Fonts: monospace -> Atkinson Hyperlegible Mono, serif/sans-serif -> Atkinson Hyperlegible Next, via /etc/fonts/local.conf. i3 uses Mono at 12pt (~/.config/i3/config); raise it if it reads small on the 5\" panel."
    note "Display: blanking and power management are off at every layer — Xorg (10-no-blanking.conf), logind (IdleAction=ignore), the kernel console (consoleblank=0, needs the reboot) and xset in .xinitrc. Nothing locks or blanks the screen. Mod+Shift+b kills the backlight deliberately, Mod+Shift+n restores it."
    note "Desktop: screen rotation is detected at X startup, so it is a no-op if the image already rotates the panel. If it lands sideways, edit ~/.xinitrc."
    note "Wi-Fi on a Lite image: 'sudo raspi-config' (System Options -> Wireless LAN), or nmtui if NetworkManager is in use."
  fi

  # ------------------------------------------------------------------ claude

  if want claude; then
    section "Claude Code"

    # The signed apt repo rather than the native curl|bash installer. That
    # installer puts everything under $HOME and explicitly refuses to run
    # under sudo -- here it would either abort or land in /root/.local/bin,
    # where the desktop user's shell would never find it. apt also makes this
    # step idempotent for free and folds updates into the normal upgrade path.
    if ! pkg_available claude-code; then
      apt_install curl gnupg
      if $DRY_RUN; then
        log "[dry-run] add downloads.claude.ai apt repo (key ${CLAUDE_KEY_FP})"
      else
        install -d -m 0755 /etc/apt/keyrings
        if curl -fsSL --max-time 30 "$CLAUDE_KEY_URL" -o "$CLAUDE_KEY"; then
          # Check the key is the expected one before trusting it. A truncated
          # or captive-portal-mangled download otherwise shows up much later
          # as an opaque NO_PUBKEY error, and a substituted key would be worse.
          local fp
          fp=$(gpg --show-keys --with-colons "$CLAUDE_KEY" 2>/dev/null \
               | awk -F: '/^fpr:/{print $10; exit}')
          if [[ $fp == "$CLAUDE_KEY_FP" ]]; then
            printf 'deb [signed-by=%s] https://downloads.claude.ai/claude-code/apt/stable stable main\n' \
              "$CLAUDE_KEY" > "$CLAUDE_LIST"
            apt_update_soft
            log "added the Claude Code apt repo (key verified)"
          else
            rm -f "$CLAUDE_KEY"
            warn "claude-code signing key fingerprint mismatch (got '${fp:-none}', expected $CLAUDE_KEY_FP) — repo NOT added"
          fi
        else
          warn "could not fetch the Claude Code signing key"
        fi
      fi
    fi

    if pkg_available claude-code || $DRY_RUN; then
      apt_install claude-code
      log "installed claude-code"
      note "Claude Code: run 'claude' to start; log in via the browser prompt. Needs a Pro/Max/Team/Enterprise or Console account (the free plan does not include it)."
      note "Claude Code installed from apt does not auto-update: 'sudo apt upgrade claude-code'."
    else
      warn "claude-code not available from apt"
      note "Claude Code was not installed. Fall back to the native installer, run as your own user and NOT with sudo: curl -fsSL https://claude.ai/install.sh | bash"
    fi
  fi

  # --------------------------------------------------------------- AIO board

  local AIO_VIA_PACKAGE=false
  if want aio; then
    section "HackerGadgets AIO v2 board"
    require_akrex_repo

    if pkg_available hackergadgets-uconsole-aio-board; then
      log "vendor metapackage available — using it"
      # Deliberately WITHOUT --install-recommends, despite the vendor guide
      # saying to use it. Its Recommends are tar1090, sdrpp-brown and
      # pygpsclient; tar1090 is an ADS-B stack that builds from source in its
      # postinst (it depends on gcc, make, git, lighttpd, tk-dev) and starts
      # readsb, which fails outright unless an RTL-SDR dongle is visible at
      # install time. That failure leaves dpkg half-configured and, via apt's
      # non-zero exit, aborted the whole run. Only Depends: rtl-sdr is needed.
      if run apt-get install -y --no-install-recommends hackergadgets-uconsole-aio-board; then
        AIO_VIA_PACKAGE=true
      else
        warn "hackergadgets-uconsole-aio-board failed to install — falling back to manual overlays"
        note "The AIO metapackage failed. Check 'sudo dpkg --configure -a' output; the boot overlays were written by hand instead."
      fi
    else
      log "vendor metapackage not in any configured repo — writing overlays by hand"
      note "hackergadgets-uconsole-aio-board was unavailable; boot config was written manually. If you later add Rex's ClockworkPi apt repo, the metapackage is the more maintainable path."
    fi

    # aiov2_ctl drives the v2 power rails and reapplies them at boot. Install
    # it regardless of which path above ran — the metapackage may or may not
    # include it, and the rails are what make the board respond at all.
    if command -v aiov2_ctl >/dev/null 2>&1; then
      log "aiov2_ctl already installed"
    else
      apt_install python3 python3-pyqt6
      if [[ -d $AIOV2_DIR/.git ]]; then
        run git -C "$AIOV2_DIR" pull --ff-only
      else
        run git clone --depth 1 "$AIOV2_REPO" "$AIOV2_DIR"
      fi
      if ! run python3 "$AIOV2_DIR/aiov2_ctl.py" --install; then
        warn "aiov2_ctl install failed — falling back to a plain pinctrl rail unit"
      fi
    fi

    if command -v aiov2_ctl >/dev/null 2>&1 || $DRY_RUN; then
      local rail
      local rail
      for rail in "${BOOT_RAILS[@]}"; do
        run aiov2_ctl "$rail" on || warn "aiov2_ctl $rail on failed"
      done
      # GPS and LoRa are deliberately not touched rather than forced off, so a
      # re-run does not undo a rail you switched on by hand.
      run systemctl enable aiov2-rails-boot.service \
        || warn "aiov2-rails-boot.service not found; rails may not persist across reboot"
      log "power rails on via aiov2_ctl: ${BOOT_RAILS[*]} (GPS/LORA left as-is)"
    else
      # Fallback: raw pinctrl plus our own oneshot, so the board still comes
      # up with its rails on even without the vendor tooling.
      apt_install pinctrl || apt_install raspi-utils || true
      write_file /usr/local/sbin/uconsole-aio-rails 0755 <<'RAILS'
#!/bin/sh
# Managed by uconsole/setup.sh — AIO v2 GPIO power rails.
#
#   usage: uconsole-aio-rails [on|off]           boot rails (SDR + USB hub)
#          uconsole-aio-rails <RAIL> [on|off]    one rail by name
#
# Rails: GPS LORA SDR USB. Only the boot set comes up automatically; the
# RTL-SDR needs USB too, being an internal USB device behind the AIO hub.
set -eu

rail_pin() {
    case "$1" in
        GPS)  echo __RAIL_GPS__ ;;
        LORA) echo __RAIL_LORA__ ;;
        SDR)  echo __RAIL_SDR__ ;;
        USB)  echo __RAIL_USB__ ;;
        *)    echo "unknown rail: $1 (GPS LORA SDR USB)" >&2; exit 2 ;;
    esac
}

level_for() {
    case "$1" in
        on)  echo dh ;;
        off) echo dl ;;
        *)   echo "usage: $0 [RAIL] [on|off]" >&2; exit 2 ;;
    esac
}

case "${1:-}" in
    GPS|LORA|SDR|USB)
        pin=$(rail_pin "$1")
        lvl=$(level_for "${2:-on}")
        pinctrl "$pin" op
        pinctrl "$pin" "$lvl"
        ;;
    *)
        lvl=$(level_for "${1:-on}")
        for r in __BOOT_RAILS__; do
            pin=$(rail_pin "$r")
            pinctrl "$pin" op
            pinctrl "$pin" "$lvl"
        done
        ;;
esac
RAILS
      if ! $DRY_RUN; then
        sed -i \
          -e "s|__RAIL_GPS__|${RAIL_GPS}|" \
          -e "s|__RAIL_LORA__|${RAIL_LORA}|" \
          -e "s|__RAIL_SDR__|${RAIL_SDR}|" \
          -e "s|__RAIL_USB__|${RAIL_USB}|" \
          -e "s|__BOOT_RAILS__|${BOOT_RAILS[*]}|" \
          /usr/local/sbin/uconsole-aio-rails
      fi
      write_file /etc/systemd/system/uconsole-aio-rails.service 0644 <<'UNIT'
[Unit]
Description=uConsole AIO v2 power rails
DefaultDependencies=no
After=sysinit.target
Before=basic.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/uconsole-aio-rails on

[Install]
WantedBy=sysinit.target
UNIT
      run systemctl daemon-reload
      run systemctl enable uconsole-aio-rails.service
      run /usr/local/sbin/uconsole-aio-rails on || warn "pinctrl rail enable failed (pinctrl missing?)"
      log "power rails on via pinctrl fallback unit: ${BOOT_RAILS[*]}"
    fi
  fi

  # ----------------------------------------------------- boot config (CM4)

  # Build the config.txt stanza from whichever sections are enabled. Skipped
  # entirely when the vendor metapackage is managing boot config, to avoid
  # duplicate overlay lines fighting each other.
  if ! $AIO_VIA_PACKAGE && { want rtc || want gps || want lora; }; then
    section "Boot configuration ($BOOT_DIR/config.txt)"

    # Leading [all] resets any conditional filter the file ended inside —
    # without it, appending after a trailing [cm4]/[pi4] section would scope
    # these overlays to that filter instead of applying unconditionally.
    local -a stanza=("[all]" "# HackerGadgets AIO v2 on uConsole CM4")

    if want rtc; then
      stanza+=("dtparam=i2c_arm=on" "dtoverlay=i2c-rtc,pcf85063a")
      log "rtc: pcf85063a over i2c"
    fi
    if want gps; then
      stanza+=("enable_uart=1" "dtoverlay=pps-gpio,gpiopin=6")
      log "gps: uart enabled, pps on gpio 6"
    fi
    if want lora; then
      stanza+=("dtparam=spi=on" "dtoverlay=spi1-1cs")
      log "lora: spi1 with one chip select"
    fi

    printf '%s\n' "${stanza[@]}" | apply_block "$BOOT_DIR/config.txt"
    note "Boot overlays changed — a reboot is required before RTC/GPS/LoRa work."
  fi

  # --------------------------------------------------------------------- rtc

  if want rtc; then
    section "Real-time clock"
    apt_install i2c-tools
    # With a real battery-backed RTC, fake-hwclock's saved timestamp will
    # fight it on boot. Disabled rather than purged so it is trivial to undo.
    if systemctl list-unit-files 2>/dev/null | grep -q '^fake-hwclock'; then
      run systemctl disable --now fake-hwclock || true
      log "fake-hwclock disabled in favour of the onboard PCF85063A"
    fi
    note "RTC, after reboot: confirm the chip is actually bound with 'ls /dev/rtc*' and 'dmesg | grep -i rtc' — 'hwclock -r' alone can report plausible time sourced from elsewhere."
    note "RTC: once the system clock is NTP-accurate, seed the chip once with: sudo hwclock -w   (it powers up holding garbage otherwise)"
    note "RTC: no output at all from 'hwclock -r' usually means the CR1220 is missing or in backwards."
  fi

  # --------------------------------------------------------------------- gps

  if want gps; then
    section "GPS"
    apt_install gpsd gpsd-clients pps-tools minicom

    # The kernel serial console owns /dev/ttyS0 and will fight gpsd for it.
    if [[ -f $BOOT_DIR/cmdline.txt ]] && grep -q 'console=serial0,115200' "$BOOT_DIR/cmdline.txt"; then
      if $DRY_RUN; then
        log "[dry-run] strip console=serial0,115200 from cmdline.txt"
      else
        sed -i 's/console=serial0,115200 *//' "$BOOT_DIR/cmdline.txt"
      fi
      log "removed serial console from cmdline.txt"
    fi
    run systemctl disable --now serial-getty@ttyS0.service 2>/dev/null || true

    write_file /etc/default/gpsd 0644 <<'GPSD'
# Managed by uconsole/setup.sh — AIO v2 GPS on the CM4 PL011 UART.
START_DAEMON="true"
USBAUTO="false"
DEVICES="/dev/ttyS0"
# -n polls the receiver without waiting for a client to connect.
GPSD_OPTIONS="-n -s 9600"
GPSD
    run systemctl enable gpsd.socket
    log "gpsd configured for /dev/ttyS0 @ 9600"
    note "GPS: the overlays and gpsd are configured, but the GPS power rail is OFF by default — nothing will decode until you turn it on: sudo aiov2_ctl GPS on (see the README to make it persistent)."
    note "For PPS-disciplined time, add to /etc/chrony/chrony.conf: refclock PPS /dev/pps0 refid PPS"
  fi

  # -------------------------------------------------------------------- lora

  if want lora; then
    section "LoRa / Meshtastic"
    require_akrex_repo

    apt_install libgpiod-dev libyaml-cpp-dev libbluetooth-dev libusb-1.0-0-dev \
                libi2c-dev openssl libssl-dev

    if ! pkg_available meshtasticd; then
      log "adding the Meshtastic apt repo"
      # The vendor guide wgets a pinned .deb that is long stale; the OBS repo
      # keeps meshtasticd updatable through normal apt upgrades.
      if $DRY_RUN; then
        log "[dry-run] fetch Meshtastic signing key and add ${MESHTASTIC_REPO}"
      else
        mkdir -p /etc/apt/keyrings
        if curl -fsSL --max-time 30 "${MESHTASTIC_REPO}Release.key" \
             | gpg --dearmor --yes -o /etc/apt/keyrings/meshtastic.gpg; then
          chmod 0644 /etc/apt/keyrings/meshtastic.gpg
          printf 'deb [signed-by=/etc/apt/keyrings/meshtastic.gpg] %s /\n' "$MESHTASTIC_REPO" \
            > /etc/apt/sources.list.d/meshtastic.list
          apt_update_soft
        else
          warn "could not fetch the Meshtastic signing key"
        fi
      fi
    fi

    if pkg_available meshtasticd || $DRY_RUN; then
      apt_install meshtasticd
    else
      warn "meshtasticd unavailable; install it by hand from https://github.com/meshtastic/firmware/releases"
      note "meshtasticd was not installed — the SPI overlays are in place, so the radio is ready once you do."
    fi

    # Current meshtasticd reads drop-ins from config.d. Only patch the
    # monolithic config.yaml path by hand if that directory is absent —
    # sed-ing structured YAML in place is a good way to break a config.
    if [[ -d /etc/meshtasticd/config.d ]] || $DRY_RUN; then
      write_file /etc/meshtasticd/config.d/uconsole-aio-v2.yaml 0644 <<'MESHYAML'
# Managed by uconsole/setup.sh — HackerGadgets AIO v2 (SX1262) on uConsole CM4.
Lora:
  Module: sx1262
  DIO2_AS_RF_SWITCH: true
  DIO3_TCXO_VOLTAGE: true
  IRQ: 26
  Busy: 24
  Reset: 25
  spidev: spidev1.0

GPS:
  SerialPath: /dev/ttyS0
MESHYAML
      log "wrote /etc/meshtasticd/config.d/uconsole-aio-v2.yaml"
    else
      warn "no /etc/meshtasticd/config.d — leaving config.yaml alone"
      note "Add the SX1262 block (Module sx1262, IRQ 26, Busy 24, Reset 25, spidev1.0) to /etc/meshtasticd/config.yaml by hand."
    fi

    if [[ -f /lib/systemd/system/meshtasticd.service || -f /etc/systemd/system/meshtasticd.service ]] || $DRY_RUN; then
      run systemctl daemon-reload
      run systemctl enable meshtasticd || warn "could not enable meshtasticd"
    fi

    # Deliberately not set: transmitting on the wrong region is a regulatory
    # problem, not a config annoyance.
    note "LoRa: the radio's power rail is OFF by default — turn it on with 'sudo aiov2_ctl LORA on' (see the README to make it persistent)."
    note "Meshtastic will not transmit until you set a LoRa region, e.g.: meshtastic --set lora.region US"
  fi

  # --------------------------------------------------------------------- sdr

  if want sdr; then
    section "SDR"
    require_akrex_repo
    apt_install rtl-sdr librtlsdr0

    # The DVB-T driver claims the dongle on plug-in and starves SDR software.
    write_file /etc/modprobe.d/blacklist-rtl8xxxu.conf 0644 <<'BLACKLIST'
# Managed by uconsole/setup.sh — keep the DVB-T driver off the RTL-SDR.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
BLACKLIST
    log "blacklisted the DVB-T kernel drivers"

    # SDR++Brown rather than mainline SDR++, chosen for this hardware. The
    # deciding factor is the waterfall: the fork does not re-upload a full
    # image to the GPU every frame, and its zoom/regeneration is vectorised
    # and multithreaded, which is where a CM4 actually hurts. It also adds
    # wideband + audio noise reduction (useful on HF), FT8/FT4 decode with PSK
    # reporter, a DSD decoder, and remote KiwiSDR. It is also simply newer
    # (1.2.1.1 vs 1.1.0).
    #
    # Its small-screen work is Android/touch-specific and does NOT apply here.
    #
    # Caveat: the fork's own README says to prefer upstream for stability.
    # Set SDR_APP=sdrpp to go back -- it declares Conflicts: sdrpp, so apt
    # swaps between them cleanly in either direction.
    local SDR_APP=sdrpp-brown
    if pkg_available "$SDR_APP"; then
      apt_install "$SDR_APP"
      log "installed $SDR_APP (replaces mainline sdrpp if present)"
    elif pkg_available sdrpp; then
      warn "$SDR_APP unavailable — falling back to mainline sdrpp"
      apt_install sdrpp
      log "installed sdrpp"
    else
      warn "no SDR++ package in any configured repo"
      note "Neither sdrpp-brown nor sdrpp was available — both ship in Rex's ClockworkPi repo. Otherwise build from https://github.com/sannysanoff/SDRPlusPlusBrown"
    fi
    # Carry gqrx bookmarks over. gqrx and its config are left completely
    # alone — this only copies data into SDR++, and takes a tarball besides.
    if [[ -f "$USER_HOME/.config/gqrx/bookmarks.csv" ]]; then
      apt_install python3
      # Once only — re-running must not litter $HOME with tarballs.
      if compgen -G "$USER_HOME/gqrx-config-backup-*.tar.gz" >/dev/null; then
        log "gqrx config backup already exists, keeping it"
      else
        local gqrx_backup="$USER_HOME/gqrx-config-backup-${STAMP}.tar.gz"
        run tar czf "$gqrx_backup" -C "$USER_HOME/.config" gqrx
        run chown "${DESKTOP_USER}:${USER_GROUP}" "$gqrx_backup"
        log "backed up gqrx config to $gqrx_backup"
      fi

      write_file /usr/local/sbin/gqrx-bookmarks-to-sdrpp 0755 <<'GQRXCONV'
#!/usr/bin/env python3
"""Managed by uconsole/setup.sh — carry gqrx bookmarks over to SDR++.

gqrx stores bookmarks as semicolon-delimited CSV with two sections: tag lines
(2 fields) and bookmark lines (5 fields: frequency; name; modulation;
bandwidth; tags). SDR++ stores them as JSON, organised into named lists.

gqrx tags map onto SDR++ lists, which is the closest structural equivalent —
SDR++ has no tag concept. A bookmark carrying several tags is placed in each
corresponding list.

Nothing is ever deleted: an existing SDR++ config is backed up and merged
into, and bookmarks whose names already exist are left alone.
"""
import argparse
import json
import os
import shutil
import sys
import time

# SDR++ demod IDs, from decoder_modules/radio/src/radio_module.h:
#   NFM=0 WFM=1 AM=2 DSB=3 USB=4 CW=5 LSB=6 RAW=7
# Keys are gqrx's ModulationStrings, lowercased.
MODES = {
    "demod off": 7,
    "raw i/q": 7,
    "am": 2,
    "am-sync": 2,
    "lsb": 6,
    "usb": 4,
    "cw-l": 5,
    "cw-u": 5,
    "cw": 5,
    "narrow fm": 0,
    "wfm (mono)": 1,
    "wfm (stereo)": 1,
    "wfm (oirt)": 1,
}
DEFAULT_MODE = 0  # NFM


def parse_gqrx(path):
    """Yield (frequency, name, mode, bandwidth, [tags]) from bookmarks.csv."""
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            fields = [f.strip() for f in line.split(";")]
            # 2 fields is a tag/colour definition; only 5-field rows are bookmarks.
            if len(fields) != 5:
                continue
            try:
                freq = int(fields[0])
            except ValueError:
                print("  skipped line %d (unparseable frequency): %s" % (lineno, line))
                continue
            name = fields[1] or "%.6f MHz" % (freq / 1e6)
            modname = fields[2].lower()
            mode = MODES.get(modname)
            if mode is None:
                mode = DEFAULT_MODE
                print("  unknown modulation %r on %r — imported as NFM" % (fields[2], name))
            try:
                bw = int(fields[3])
            except ValueError:
                bw = 0
            tags = [t.strip() for t in fields[4].split(",") if t.strip()] or ["gqrx"]
            out.append((freq, name, mode, bw, tags))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--home", default=os.path.expanduser("~"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    gqrx_csv = os.path.join(args.home, ".config", "gqrx", "bookmarks.csv")
    sdrpp_dir = os.path.join(args.home, ".config", "sdrpp")
    sdrpp_cfg = os.path.join(sdrpp_dir, "frequency_manager_config.json")

    if not os.path.isfile(gqrx_csv):
        print("  no gqrx bookmarks at %s — nothing to convert" % gqrx_csv)
        return 0

    bookmarks = parse_gqrx(gqrx_csv)
    if not bookmarks:
        print("  %s has no bookmark rows" % gqrx_csv)
        return 0

    # Load and merge, rather than overwrite: SDR++ may already have lists.
    existed = os.path.isfile(sdrpp_cfg)
    if existed:
        try:
            with open(sdrpp_cfg, "r", encoding="utf-8") as fh:
                cfg = json.load(fh)
        except (ValueError, OSError) as exc:
            print("  existing %s is unreadable (%s) — refusing to touch it" % (sdrpp_cfg, exc))
            return 1
    else:
        cfg = {"selectedList": "General", "bookmarkDisplayMode": 1, "lists": {}}

    cfg.setdefault("lists", {})

    added = skipped = 0
    for freq, name, mode, bw, tags in bookmarks:
        for tag in tags:
            lst = cfg["lists"].setdefault(tag, {"showOnWaterfall": True, "bookmarks": {}})
            lst.setdefault("bookmarks", {})
            # SDR++ keys bookmarks by name, so names must be unique per list.
            key = name
            n = 2
            while key in lst["bookmarks"]:
                existing = lst["bookmarks"][key]
                if existing.get("frequency") == float(freq):
                    key = None  # same name, same frequency: already imported
                    break
                key = "%s (%d)" % (name, n)
                n += 1
            if key is None:
                skipped += 1
                continue
            lst["bookmarks"][key] = {
                "frequency": float(freq),
                "bandwidth": float(bw),
                "mode": mode,
            }
            added += 1

    if args.dry_run:
        print("  [dry-run] would write %d bookmark(s) across %d list(s) to %s"
              % (added, len(cfg["lists"]), sdrpp_cfg))
        return 0

    # Nothing new to import: leave the file alone and take no backup, so
    # repeated runs stay a genuine no-op.
    if existed and not added:
        print("  all %d bookmark(s) already present; nothing to do" % skipped)
        return 0

    if existed:
        backup = "%s.bak-%s" % (sdrpp_cfg, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(sdrpp_cfg, backup)
        print("  backed up existing SDR++ bookmarks to %s" % backup)

    # A selectedList naming a list that does not exist leaves the Frequency
    # Manager pointed at nothing on first launch.
    if cfg.get("selectedList") not in cfg["lists"] and cfg["lists"]:
        cfg["selectedList"] = sorted(cfg["lists"])[0]

    os.makedirs(sdrpp_dir, exist_ok=True)
    tmp = sdrpp_cfg + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=4, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, sdrpp_cfg)
    print("  imported %d bookmark(s) into %d list(s): %s"
          % (added, len(cfg["lists"]), ", ".join(sorted(cfg["lists"]))))
    if skipped:
        print("  %d already present, left alone" % skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
GQRXCONV

      if $DRY_RUN; then
        log "[dry-run] would convert gqrx bookmarks to SDR++"
      else
        /usr/local/sbin/gqrx-bookmarks-to-sdrpp --home "$USER_HOME" \
          || warn "bookmark conversion failed — gqrx config is untouched, retry by hand"
        chown -R "${DESKTOP_USER}:${USER_GROUP}" "$USER_HOME/.config/sdrpp"
      fi
      note "gqrx bookmarks imported into SDR++ (Module list -> Frequency Manager). gqrx config untouched; tarball backup in \$HOME."
    fi

    note "SDR needs the antenna on the 'SDR' IPEX pad. The SDR and internal-USB rails come up at boot; GPS and LoRa do not — see the README for turning those on."
  fi

  # --------------------------------------------------------------------- ham

  if want ham; then
    section "Amateur radio"
    apt_install python3
    # libhamlib-utils, not hamlib-utils: Debian names the binary package after
    # the library. It provides rigctl/rotctl, which is what JS8Call drives a
    # rig with.
    apt_install_opt js8call libhamlib-utils
    log "installed js8call and hamlib-utils"

    # GhostNet (S2 Underground) config, migrated from a working macOS install.
    # Identity, groups and dial frequency are baked in; audio devices, PTT and
    # rig control are not, since those depend on the radio attached here.
    write_file /usr/local/sbin/js8call-ghostnet-config 0755 <<'JS8CONF'
#!/usr/bin/env python3
"""Managed by uconsole/setup.sh — apply the GhostNet JS8Call configuration.

Migrated selectively from a working macOS JS8Call install. Only portable keys
are written: identity, groups, heartbeat/autoreply behaviour, and the dial
frequency. Deliberately NOT carried over, because they would be wrong or
harmful on the uConsole:

  SoundInId/SoundInName/SoundOutId/SoundOutName   macOS Core Audio devices
  WindowGeometry, Font, RXTextFont, TXTextFont    sized for a Mac, not 1280x480
  Rig, PTTMethod, PTTport, CATSerialPort          depends on the attached radio
  Notifications\\*\\path                            macOS sound file paths
  CallActivity, stations                          stale per-callsign heard data

JS8Call reads this with QSettings. Values are written exactly as QSettings
itself stores them — in particular MyGroups keeps its doubled '@@', which is
QSettings' own escaping. Do not "tidy" it to a single '@'.
"""
import argparse
import configparser
import os
import shutil
import sys
import time

CALLSIGN = "KA1PID"
GRID = "EM13LC"
GROUPS = "@@GHOSTNET, @@GSTFLASH, @@GNUSATX"
GHOSTNET_DIAL = "7107000"  # GhostNet calling frequency, 7.107 MHz

SETTINGS = {
    "Common": {
        "DialFreq": GHOSTNET_DIAL,
        "Freq": "1000",          # audio offset within the passband
        "SubMode": "0",          # normal speed
        "SubModeHB": "false",
        "SubModeHBAck": "false",
        "SubModeMultiDecode": "true",
        "HBInterval": "0",       # heartbeat off by default
        "CQInterval": "0",
    },
    "Configuration": {
        "MyCall": CALLSIGN,
        "MyGrid": GRID,
        "MyGroups": GROUPS,
        "AutoreplyOnAtStartup": "true",
        "AutoreplyConfirmation": "true",
        "HeartbeatQSOPause": "true",
        "HeartbeatAckSNR": "false",
        "HBRateLimit": "false",
        "HBMessage": "HB <MYGRID4>",
        "CQMessage": "CQ CQ CQ <MYGRID4>",
        "MyStatus": "IDLE <MYIDLE> VERSION <MYVERSION>",
        "Reply": "HW CPY?",
        "Macros": "TNX 73 GL",
        "AutoGrid": "false",
        "AvoidAllcall": "false",
        "TxIdleWatchdog": "60",
    },
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--home", default=os.path.expanduser("~"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    ini = os.path.join(args.home, ".config", "JS8Call.ini")

    cp = configparser.ConfigParser(
        interpolation=None,   # values contain bare '%' and '$'
        strict=False,         # tolerate duplicate keys from older writes
        delimiters=("=",),
        comment_prefixes=(),  # ';' and '#' are legal inside values here
    )
    cp.optionxform = str      # QSettings keys are case-sensitive

    existed = os.path.isfile(ini)
    if existed:
        try:
            with open(ini, encoding="utf-8") as fh:
                cp.read_file(fh)
        except (configparser.Error, OSError, UnicodeDecodeError) as exc:
            print("  existing %s is unparseable (%s) — refusing to touch it" % (ini, exc))
            return 1
    else:
        print("  no existing JS8Call.ini — creating one")

    changed = []
    for section, keys in SETTINGS.items():
        if not cp.has_section(section):
            cp.add_section(section)
        for key, val in keys.items():
            if cp.get(section, key, fallback=None) != val:
                changed.append("%s/%s" % (section, key))
            cp.set(section, key, val)

    if args.dry_run:
        print("  [dry-run] would write %d key(s) to %s" % (len(changed), ini))
        return 0

    # Re-running as config management must be a no-op when nothing differs:
    # no rewrite, and above all no new backup file each time.
    if existed and not changed:
        print("  %s already correct; nothing to do" % ini)
        return 0

    if existed:
        backup = "%s.bak-%s" % (ini, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(ini, backup)
        print("  backed up existing config to %s" % backup)

    os.makedirs(os.path.dirname(ini), exist_ok=True)
    tmp = ini + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        cp.write(fh, space_around_delimiters=False)
    os.replace(tmp, ini)

    print("  wrote GhostNet config to %s (%d key(s) changed)" % (ini, len(changed)))
    print("  callsign %s, grid %s, groups %s"
          % (CALLSIGN, GRID, GROUPS.replace("@@", "@")))
    print("  dial frequency %s MHz" % (int(GHOSTNET_DIAL) / 1e6))
    print("  NOT set (device-specific, configure in JS8Call): audio in/out devices, PTT method, rig")
    return 0


if __name__ == "__main__":
    sys.exit(main())
JS8CONF

    if $DRY_RUN; then
      log "[dry-run] would write the GhostNet JS8Call config for $DESKTOP_USER"
    else
      /usr/local/sbin/js8call-ghostnet-config --home "$USER_HOME" \
        || warn "JS8Call config failed — any existing config was left untouched"
      chown "${DESKTOP_USER}:${USER_GROUP}" "$USER_HOME/.config/JS8Call.ini" 2>/dev/null || true
    fi
    note "JS8Call: groups @GHOSTNET, @GSTFLASH, @GNUSATX; dial 7.107 MHz (GhostNet)."
    note "JS8Call: set audio in/out to your USB sound device under Settings -> Audio, and PTT under Settings -> Radio — neither was migrated, as they depend on the attached rig."
    note "JS8Call: 7.107 is set as the dial but is not in the preset Frequencies list; add it under Settings -> Frequencies to get it in the dropdown."
    note "JS8Call needs an external rig (CAT + USB audio) or an SDR fed through a loopback sink — the uConsole has no HF radio of its own."
  fi

  # ---------------------------------------------------------------- tailscale

  if want tailscale; then
    section "Tailscale"

    if ! pkg_available tailscale; then
      local ts_id=$OS_ID
      case $ts_id in
        debian|raspbian) ;;
        *) warn "unrecognised distro '$ts_id' for the Tailscale repo; using debian"; ts_id=debian ;;
      esac
      local ts_base="https://pkgs.tailscale.com/stable/${ts_id}/${OS_CODENAME}"
      if $DRY_RUN; then
        log "[dry-run] add Tailscale repo from ${ts_base}"
      else
        # These are served pre-dearmored, so no gpg step.
        curl -fsSL --max-time 30 "${ts_base}.noarmor.gpg" \
          -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
          || die "could not fetch the Tailscale signing key"
        curl -fsSL --max-time 30 "${ts_base}.tailscale-keyring.list" \
          -o /etc/apt/sources.list.d/tailscale.list \
          || die "could not fetch the Tailscale apt source"
        apt_update_soft
      fi
    fi

    apt_install tailscale
    run systemctl enable --now tailscaled

    # 'tailscale up' needs interactive auth, which a piped script cannot do.
    if tailscale status >/dev/null 2>&1; then
      log "tailscale already authenticated; leaving it alone"
    elif [[ -n ${TS_AUTHKEY:-} ]]; then
      run tailscale up --authkey "$TS_AUTHKEY" --hostname uconsole \
        || warn "tailscale up failed — check the auth key"
      log "tailscale brought up as 'uconsole'"
    else
      note "Tailscale is installed but not authenticated. Run: sudo tailscale up
    (or re-run with the key set after sudo: curl -fsSL <url> | sudo TS_AUTHKEY=tskey-... bash -s -- --only tailscale)"
    fi
  fi

  # -------------------------------------------------------------- postflight

  section "Done"
  if (( ${#NOTES[@]} )); then
    printf '\nNext steps:\n'
    local n
    for n in "${NOTES[@]}"; do printf '  * %s\n' "$n"; done
  fi
  printf '\n'
  if $DRY_RUN; then
    log "dry run complete — nothing was changed"
  else
    log "reboot to load the new overlays: sudo reboot"
  fi
}

main "$@"
