#!/usr/bin/env bash
#
# uconsole-setup.sh — first-time provisioning for a ClockworkPi uConsole (CM4)
# running Debian Bookworm with the HackerGadgets AIO v2 extension board.
#
# Intended invocation:
#
#   curl -fsSL https://raw.githubusercontent.com/pid1/utils/main/uconsole-setup.sh | sudo bash
#
# Everything lives inside main() so a truncated download — the pipe dropping
# mid-transfer — dies on an incomplete function definition rather than
# executing half a script that rewrites config.txt and purges packages.
#
# stdin is the script itself, so nothing here may read from it. All apt calls
# are non-interactive; the escape hatch for a real prompt is `< /dev/tty`.
#
# Flags have to go through `bash -s --`, since `| sudo bash --dry-run` would
# hand the flag to bash instead of to us:
#
#   curl -fsSL <url> | sudo bash -s -- --dry-run
#   curl -fsSL <url> | sudo bash -s -- --skip games --skip lora
#   curl -fsSL <url> | sudo bash -s -- --only sdr --user someone
#
# sudo scrubs the environment, so TS_AUTHKEY must be set *after* sudo:
#
#   curl -fsSL <url> | sudo TS_AUTHKEY=tskey-auth-... bash -s -- --only tailscale

# ---------------------------------------------------------------------------
# Getting an OS onto the uConsole first
#
#   1. Download Rex's Bookworm image, ClockworkPi-Bookworm-6.12.y.img.xz. Rex
#      publishes no images on GitHub -- his GitHub holds only source (pi-gen,
#      the kernel tree, the apt repo) -- so the images live on:
#        https://mega.nz/folder/LSInGD6J#0YezWX8xC4PkbyForgl1Hw
#        https://drive.google.com/drive/folders/1tw2uPVPsFDhQ5Onx4mlllYexUDmDp0eK
#        https://app.drime.cloud/drive/s/O3faUnk9ihg2vlrgek0LiaHRiU3fGb
#      all linked from the forum thread, which is also where the current
#      release and any per-version caveats are announced:
#        https://forum.clockworkpi.com/t/bookworm-6-12-y-for-the-uconsole-and-devterm/15847
#
#   2. Write it with Raspberry Pi Imager: Choose OS -> Use custom -> pick the
#      .xz (it decompresses on the fly). Balena Etcher works too. Imager's
#      advanced options can preset the Wi-Fi SSID/password -- worth doing,
#      since the uConsole keyboard is a slow way to type a passphrase.
#
#   3. Target is a microSD card. A CM4 *with* eMMC has no SD lines wired up and
#      must be flashed over USB with rpiboot/usbboot instead; CM4 Lite uses SD.
#
#   4. First boot expands the filesystem and reboots by itself. Log in with the
#      image's default account -- the forum thread is the authoritative source
#      for it; sources disagree between pi/clockworkpi and clockwork/clockwork,
#      so do not count on either -- then create your own account and drop the
#      default one, which has a publicly known password:
#      This script offers to do it for you: if the account is missing it
#      prompts, and hands the password prompt to adduser itself, so no
#      credential is ever typed into this script, echoed, or stored here.
#      Verify you can log in as the new account and that sudo works BEFORE
#      removing the default one:
#        sudo deluser --remove-home <default-user>
#
#   Rex's image ships his apt repo (github.com/ak-rex/akrex-arm-repo) already
#   configured, which is where sdrpp and the HackerGadgets AIO metapackage come
#   from rather than Debian. This script checks for that repo and adds it only
#   if missing, so it also works on a stock Bookworm image. --no-akrex-repo
#   opts out.
# ---------------------------------------------------------------------------

main() {
  set -euo pipefail

  # ------------------------------------------------------------------ config

  local GH_KEY_USER=pid1
  local DEFAULT_USER=jroemer
  local AIOV2_REPO=https://github.com/hackergadgets/aiov2_ctl.git
  local AIOV2_DIR=/opt/aiov2_ctl
  local MESHTASTIC_REPO=http://download.opensuse.org/repositories/network:/Meshtastic:/beta/Raspbian_12/
  # Rex (ak-rex) maintains the ClockworkPi apt repo that his Bookworm image
  # ships with. It is served straight out of a GitHub repo, and carries the
  # things Debian does not have: sdrpp, the hackergadgets AIO metapackage,
  # pinctrl, and the rtlsdrblog fork of rtl-sdr.
  local AKREX_BASE=https://raw.githubusercontent.com/ak-rex/akrex-arm-repo/main/bookworm
  local AKREX_KEYRING=/etc/apt/keyrings/ak-rex.gpg
  local AKREX_LIST=/etc/apt/sources.list.d/ak-rex.list

  # AIO v2 puts each subsystem behind a GPIO-switched power rail. Nothing on
  # the board responds until these are driven high. (V1 had no such gating.)
  local RAIL_GPS=27 RAIL_LORA=16 RAIL_SDR=7 RAIL_USB=23

  local BEGIN_MARK='# >>> uconsole-setup >>>'
  local END_MARK='# <<< uconsole-setup <<<'

  local ALL_SECTIONS=(base desktop games aio rtc gps lora sdr ham tailscale)

  # Game/emulator packages shipped in the stock uConsole image. This is an
  # explicit allowlist rather than a `uconsole-*` glob on purpose: the kernel,
  # 4G utils and keyboard firmware share those prefixes, and globbing them
  # would take out your kernel updates along with Cave Story.
  local GAME_PKGS=(
    retroarch retroarch-assets retroarch-assets-xmb retroarch-assets-ozone
    dosbox dosbox-staging
    openttd openttd-data openttd-opengfx openttd-opensfx openttd-openmsx
    devterm-tic80-cpi devterm-cavestory-cpi devterm-cavestory-cpi-cm4
    uconsole-tic80 uconsole-cavestory uconsole-love2d uconsole-liko12
    uconsole-lowresnx uconsole-dosbox-staging
  )
  # Belt-and-braces: nothing matching this may be purged, ever.
  local DENY_RE='^(uconsole-kernel|uconsole[-_]4g|uconsole[-_]keyboard|clockworkpi-|devterm-kernel|raspberrypi-)'

  # Hardware groups. The stock `cpi` account is preloaded into these; a fresh
  # account is not, and none of the AIO peripherals work non-root without them.
  local HW_GROUPS=(dialout spi i2c gpio plugdev audio video netdev)

  # --------------------------------------------------------------- arg parse

  local DRY_RUN=false
  local ADD_AKREX_REPO=true
  local DESKTOP_USER=""
  local -a ONLY=() SKIP=()

  while (( $# )); do
    case $1 in
      --dry-run)      DRY_RUN=true ;;
      --no-akrex-repo) ADD_AKREX_REPO=false ;;
      --user)         DESKTOP_USER=${2:?--user needs a value}; shift ;;
      --user=*)       DESKTOP_USER=${1#*=} ;;
      --only)         ONLY+=("${2:?--only needs a section}"); shift ;;
      --only=*)       ONLY+=("${1#*=}") ;;
      --skip)         SKIP+=("${2:?--skip needs a section}"); shift ;;
      --skip=*)       SKIP+=("${1#*=}") ;;
      -h|--help)
        printf 'usage: uconsole-setup.sh [--dry-run] [--no-akrex-repo] [--user NAME] [--only SECTION]... [--skip SECTION]...\n'
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

  # Replace our marker-delimited block in a file, or append it if absent.
  apply_block() {
    local file=$1 content stripped
    content=$(cat)
    stripped=$(sed "\|^${BEGIN_MARK}\$|,\|^${END_MARK}\$|d" "$file")
    printf '%s\n\n%s\n%s\n%s\n' \
      "$stripped" "$BEGIN_MARK" "$content" "$END_MARK" | write_file "$file" 0644
  }

  local AKREX_DONE=false
  ensure_akrex_repo() {
    $ADD_AKREX_REPO || return 0
    $AKREX_DONE && return 0
    AKREX_DONE=true

    # Already configured (Rex's own image ships it) — nothing to do.
    if [[ -f $AKREX_LIST ]] || pkg_available sdrpp; then
      log "ak-rex apt repo already available"
      return 0
    fi

    section "Adding Rex's ClockworkPi apt repo"
    if $DRY_RUN; then
      log "[dry-run] add ${AKREX_BASE} stable main"
      return 0
    fi

    mkdir -p /etc/apt/keyrings
    if ! curl -fsSL --max-time 30 "${AKREX_BASE}/KEY.gpg" \
         | gpg --dearmor --yes -o "$AKREX_KEYRING"; then
      warn "could not fetch ak-rex signing key — continuing without the repo"
      return 0
    fi
    chmod 0644 "$AKREX_KEYRING"

    # signed-by scopes this key to this repo only. The upstream README drops
    # the key in trusted.gpg.d, which would trust it for every configured
    # repo; there is no reason to grant it that.
    printf 'deb [arch=arm64 signed-by=%s] %s stable main\n' \
      "$AKREX_KEYRING" "$AKREX_BASE" > "$AKREX_LIST"

    if apt-get update -y; then
      log "ak-rex repo added (sdrpp, hackergadgets AIO, pinctrl, rtl-sdr)"
    else
      warn "apt update failed after adding the ak-rex repo — removing it again"
      rm -f "$AKREX_LIST" "$AKREX_KEYRING"
      apt-get update -y || true
    fi
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
  local f
  for f in "$BOOT_DIR/config.txt" "$BOOT_DIR/cmdline.txt"; do
    [[ -f $f ]] && run cp -a "$f" "${f}.bak-${STAMP}"
  done
  log "boot files backed up with suffix .bak-${STAMP}"

  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -y

  # -------------------------------------------------------------------- base

  if want base; then
    section "Base system"

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
# Managed by uconsole-setup.sh — refresh authorized_keys from GitHub.
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
# Managed by uconsole-setup.sh
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

    # i3 runs an interactive config wizard when it starts with no config,
    # which would block a headless first boot. Write one up front.
    local i3dir="$USER_HOME/.config/i3"
    if [[ -f /etc/i3/config ]]; then
      run mkdir -p "$i3dir"
      run cp -n /etc/i3/config "$i3dir/config"
      # Mod1 is Alt, which collides with too much; Mod4 is the super key.
      # Changing the definition line retroactively changes every later
      # expansion, because i3 substitutes variables in parse order.
      $DRY_RUN || sed -i 's/^set \$mod Mod1/set $mod Mod4/' "$i3dir/config"
    else
      warn "/etc/i3/config missing — writing a minimal config"
      write_file "$i3dir/config" 0644 <<'I3MIN'
set $mod Mod4
font pango:Atkinson Hyperlegible Mono 12
bindsym $mod+Return exec alacritty
bindsym $mod+d exec dmenu_run
bindsym $mod+Shift+q kill
bindsym $mod+Shift+r restart
I3MIN
    fi

    # Appended bindings win: i3 uses the last binding declared for a key.
    if ! grep -q 'uconsole-setup' "$i3dir/config" 2>/dev/null; then
      $DRY_RUN || cat >> "$i3dir/config" <<'I3EXTRA'

# --- uconsole-setup ---------------------------------------------------------
# 12pt is a starting point for the 5" 720p panel, which is ~290 DPI; raise it
# here if title bars and the status bar read too small.
font pango:Atkinson Hyperlegible Mono 12
bindsym $mod+Return exec alacritty
bindsym XF86MonBrightnessUp   exec brightnessctl set +10%
bindsym XF86MonBrightnessDown exec brightnessctl set 10%-
I3EXTRA
      log "wrote $i3dir/config"
    fi

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
<!-- Managed by uconsole-setup.sh -->
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

    # Start X on tty1 only. The panel is mounted rotated, so it comes up
    # portrait and needs a transform; detect at runtime rather than assume,
    # because some images already apply it at the DRM level and rotating a
    # second time leaves the display sideways.
    write_file "$USER_HOME/.xinitrc" 0755 <<'XINITRC'
#!/bin/sh
# Managed by uconsole-setup.sh
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
exec i3
XINITRC

    # Sourcing .profile keeps this from shadowing the shell's normal setup,
    # which bash would otherwise skip once .bash_profile exists.
    write_file "$USER_HOME/.bash_profile" 0644 <<'BASHPROF'
# Managed by uconsole-setup.sh
[ -f "$HOME/.profile" ] && . "$HOME/.profile"

if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
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
    note "Desktop: tty1 autologins as $DESKTOP_USER and starts i3. Mod key is Super; Mod+Return is a terminal, Mod+d is dmenu."
    note "Fonts: monospace -> Atkinson Hyperlegible Mono, serif/sans-serif -> Atkinson Hyperlegible Next, via /etc/fonts/local.conf. i3 uses Mono at 12pt (~/.config/i3/config); raise it if it reads small on the 5\" panel."
    note "Desktop: screen rotation is detected at X startup, so it is a no-op if the image already rotates the panel. If it lands sideways, edit ~/.xinitrc."
    note "Wi-Fi on a Lite image: 'sudo raspi-config' (System Options -> Wireless LAN), or nmtui if NetworkManager is in use."
  fi

  # ------------------------------------------------------------------- games

  if want games; then
    section "Removing games and emulators"

    local -a purge=() p
    for p in "${GAME_PKGS[@]}"; do
      pkg_installed "$p" && purge+=("$p")
    done

    # libretro cores are unambiguous; sweep whatever is installed.
    local core
    while read -r core; do
      [[ -n $core ]] && purge+=("$core")
    done < <(dpkg-query -W -f='${Package}\n' 'libretro-*' 2>/dev/null || true)

    # Assert the deny list before doing anything destructive.
    for p in "${purge[@]}"; do
      [[ $p =~ $DENY_RE ]] && die "refusing to purge protected package '$p' — this is a bug, stopping"
    done

    if (( ${#purge[@]} )); then
      log "purging ${#purge[@]} package(s): ${purge[*]}"
      run apt-get purge -y "${purge[@]}"
      run apt-get autoremove --purge -y
    else
      log "no game packages installed"
    fi

    # Anything else under those vendor prefixes is reported, never removed —
    # it may well be hardware support rather than a game.
    local -a leftovers=()
    while read -r p; do
      [[ -z $p ]] && continue
      [[ $p =~ $DENY_RE ]] && continue
      local skip=false q
      for q in "${GAME_PKGS[@]}"; do [[ $q == "$p" ]] && skip=true; done
      $skip || leftovers+=("$p")
    done < <(dpkg-query -W -f='${Package}\n' 'devterm-*' 'uconsole-*' 2>/dev/null || true)
    if (( ${#leftovers[@]} )); then
      note "Vendor packages left untouched (review by hand if unwanted): ${leftovers[*]}"
    fi

    # Per-user leftovers. Sweep every human home, not just $DESKTOP_USER — if
    # that account is new rather than a renamed 'cpi', the game data is in the
    # old home and would otherwise survive.
    local u uid home d
    while IFS=: read -r u _ uid _ _ home _; do
      (( uid >= 1000 && uid < 65534 )) || continue
      [[ -d $home ]] || continue
      for d in \
        .config/retroarch .local/share/retroarch .cache/retroarch \
        .config/openttd .local/share/openttd \
        .config/dosbox .config/dosbox-staging .local/share/dosbox-staging \
        .local/share/love .local/share/tic80 .config/tic80 \
        .local/share/liko12 .local/share/lowresnx
      do
        [[ -d "$home/$d" ]] || continue
        run rm -rf "${home:?}/${d}"
        log "removed $home/$d"
      done

      # Launcher entries pointing at the binaries we just purged.
      local dir entry
      for dir in "$home/.local/share/applications" "$home/Desktop"; do
        [[ -d $dir ]] || continue
        while read -r entry; do
          [[ -n $entry ]] || continue
          run rm -f "$entry"
          log "removed launcher $entry"
        done < <(grep -rlEi '^Exec=.*(retroarch|tic80|cavestory|openttd|dosbox|liko12|lowresnx|love)' \
                   "$dir" --include='*.desktop' 2>/dev/null || true)
      done

      # Reported, not deleted — these commonly hold things you put there.
      for d in Games games ROMs roms; do
        [[ -d "$home/$d" ]] && note "Left in place (may hold your own files): $home/$d"
      done
    done < /etc/passwd

    run update-desktop-database /usr/share/applications 2>/dev/null || true
  fi

  # --------------------------------------------------------------- AIO board

  local AIO_VIA_PACKAGE=false
  if want aio; then
    section "HackerGadgets AIO v2 board"
    ensure_akrex_repo

    if pkg_available hackergadgets-uconsole-aio-board; then
      log "vendor metapackage available — using it"
      run apt-get install -y --install-recommends hackergadgets-uconsole-aio-board
      AIO_VIA_PACKAGE=true
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
      for rail in GPS LORA SDR USB; do
        run aiov2_ctl "$rail" on || warn "aiov2_ctl $rail on failed"
      done
      run systemctl enable aiov2-rails-boot.service \
        || warn "aiov2-rails-boot.service not found; rails may not persist across reboot"
      log "power rails enabled via aiov2_ctl"
    else
      # Fallback: raw pinctrl plus our own oneshot, so the board still comes
      # up with its rails on even without the vendor tooling.
      apt_install pinctrl || apt_install raspi-utils || true
      write_file /usr/local/sbin/uconsole-aio-rails 0755 <<'RAILS'
#!/bin/sh
# Managed by uconsole-setup.sh — AIO v2 power rails (GPS/LoRa/SDR/USB hub).
set -eu
STATE=${1:-on}
case "$STATE" in
    on)  LEVEL=dh ;;
    off) LEVEL=dl ;;
    *)   echo "usage: $0 [on|off]" >&2; exit 2 ;;
esac
for pin in __RAIL_GPS__ __RAIL_LORA__ __RAIL_SDR__ __RAIL_USB__; do
    pinctrl "$pin" op
    pinctrl "$pin" "$LEVEL"
done
RAILS
      if ! $DRY_RUN; then
        sed -i \
          -e "s|__RAIL_GPS__|${RAIL_GPS}|" \
          -e "s|__RAIL_LORA__|${RAIL_LORA}|" \
          -e "s|__RAIL_SDR__|${RAIL_SDR}|" \
          -e "s|__RAIL_USB__|${RAIL_USB}|" \
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
      log "power rails enabled via pinctrl fallback unit"
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
# Managed by uconsole-setup.sh — AIO v2 GPS on the CM4 PL011 UART.
START_DAEMON="true"
USBAUTO="false"
DEVICES="/dev/ttyS0"
# -n polls the receiver without waiting for a client to connect.
GPSD_OPTIONS="-n -s 9600"
GPSD
    run systemctl enable gpsd.socket
    log "gpsd configured for /dev/ttyS0 @ 9600"
    note "GPS needs the antenna on the 'GPS' IPEX pad and a clear sky view; check with 'cgps -s' or 'gpsmon' after reboot."
    note "For PPS-disciplined time, add to /etc/chrony/chrony.conf: refclock PPS /dev/pps0 refid PPS"
  fi

  # -------------------------------------------------------------------- lora

  if want lora; then
    section "LoRa / Meshtastic"
    ensure_akrex_repo

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
          apt-get update -y || warn "apt update failed after adding the Meshtastic repo"
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
# Managed by uconsole-setup.sh — HackerGadgets AIO v2 (SX1262) on uConsole CM4.
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
    note "Meshtastic will not transmit until you set a LoRa region, e.g.: meshtastic --set lora.region US"
  fi

  # --------------------------------------------------------------------- sdr

  if want sdr; then
    section "SDR"
    ensure_akrex_repo
    apt_install rtl-sdr librtlsdr0

    # The DVB-T driver claims the dongle on plug-in and starves SDR software.
    write_file /etc/modprobe.d/blacklist-rtl8xxxu.conf 0644 <<'BLACKLIST'
# Managed by uconsole-setup.sh — keep the DVB-T driver off the RTL-SDR.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
BLACKLIST
    log "blacklisted the DVB-T kernel drivers"

    if pkg_available sdrpp; then
      apt_install sdrpp
      log "installed sdrpp"
    else
      warn "sdrpp not in any configured repo"
      note "SDR++ (sdrpp) was unavailable — it ships in Rex's ClockworkPi Bookworm repo. Add that repo and 'apt install sdrpp', or grab a release from https://github.com/AlexandreRouma/SDRPlusPlus/releases"
    fi
    # Carry gqrx bookmarks over. gqrx and its config are left completely
    # alone — this only copies data into SDR++, and takes a tarball besides.
    if [[ -f "$USER_HOME/.config/gqrx/bookmarks.csv" ]]; then
      apt_install python3
      local gqrx_backup="$USER_HOME/gqrx-config-backup-${STAMP}.tar.gz"
      run tar czf "$gqrx_backup" -C "$USER_HOME/.config" gqrx
      run chown "${DESKTOP_USER}:${USER_GROUP}" "$gqrx_backup"
      log "backed up gqrx config to $gqrx_backup"

      write_file /usr/local/sbin/gqrx-bookmarks-to-sdrpp 0755 <<'GQRXCONV'
#!/usr/bin/env python3
"""Managed by uconsole-setup.sh — carry gqrx bookmarks over to SDR++.

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
    if os.path.isfile(sdrpp_cfg):
        try:
            with open(sdrpp_cfg, "r", encoding="utf-8") as fh:
                cfg = json.load(fh)
        except (ValueError, OSError) as exc:
            print("  existing %s is unreadable (%s) — refusing to touch it" % (sdrpp_cfg, exc))
            return 1
        if not args.dry_run:
            backup = "%s.bak-%s" % (sdrpp_cfg, time.strftime("%Y%m%d-%H%M%S"))
            shutil.copy2(sdrpp_cfg, backup)
            print("  backed up existing SDR++ bookmarks to %s" % backup)
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

    note "SDR needs the antenna on the 'SDR' IPEX pad; the dongle sits behind the internal USB rail."
  fi

  # --------------------------------------------------------------------- ham

  if want ham; then
    section "Amateur radio"
    apt_install js8call hamlib-utils python3
    log "installed js8call and hamlib-utils"

    # GhostNet (S2 Underground) config, migrated from a working macOS install.
    # Identity, groups and dial frequency are baked in; audio devices, PTT and
    # rig control are not, since those depend on the radio attached here.
    write_file /usr/local/sbin/js8call-ghostnet-config 0755 <<'JS8CONF'
#!/usr/bin/env python3
"""Managed by uconsole-setup.sh — apply the GhostNet JS8Call configuration.

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

    if os.path.isfile(ini):
        try:
            with open(ini, encoding="utf-8") as fh:
                cp.read_file(fh)
        except (configparser.Error, OSError, UnicodeDecodeError) as exc:
            print("  existing %s is unparseable (%s) — refusing to touch it" % (ini, exc))
            return 1
        if not args.dry_run:
            backup = "%s.bak-%s" % (ini, time.strftime("%Y%m%d-%H%M%S"))
            shutil.copy2(ini, backup)
            print("  backed up existing config to %s" % backup)
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
        apt-get update -y
      fi
    fi

    apt_install tailscale
    run systemctl enable --now tailscaled

    # 'tailscale up' needs interactive auth, which a piped script cannot do.
    if [[ -n ${TS_AUTHKEY:-} ]]; then
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
