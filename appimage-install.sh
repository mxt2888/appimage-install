#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[32m'
    C_Y=$'\033[33m'; C_R=$'\033[31m'; C_C=$'\033[36m'; C_D=$'\033[2m'
else
    C_RST=''; C_B=''; C_G=''; C_Y=''; C_R=''; C_C=''; C_D=''
fi
info() { printf '%s\n' "${C_C}::${C_RST} $*" >&2; }
ok()   { printf '%s\n' "${C_G}✓${C_RST} $*" >&2; }
warn() { printf '%s\n' "${C_Y}!${C_RST} $*" >&2; }
err()  { printf '%s\n' "${C_R}✗${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }

sanitize() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9._-' '-' \
        | sed 's/-\{2,\}/-/g; s/^-//; s/-$//'
}

desktop_get() {
    awk -F= -v key="$2" '
        /^\[/   { in_entry = ($0 == "[Desktop Entry]"); next }
        in_entry && index($0, key"=") == 1 {
            sub(/^[^=]*=/, ""); print; exit
        }
    ' "$1"
}

desktop_set() {
    local f="$1" key="$2" val="$3"
    awk -v key="$key" -v val="$val" '
        function flush() { if (in_entry && !written) { print key"="val; written=1 } }
        /^\[/ {
            flush()
            in_entry = ($0 == "[Desktop Entry]")
            if (in_entry) written = 0
            print; next
        }
        {
            if (in_entry && index($0, key"=") == 1) { print key"="val; written=1; next }
            print
        }
        END { flush() }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

host_has_fuse2() {
    local d
    for d in /usr/lib /usr/lib64 /lib /lib64 /usr/local/lib \
             /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib/i386-linux-gnu; do
        [ -e "$d/libfuse.so.2" ] && return 0
    done
    if command -v ldconfig >/dev/null 2>&1; then
        ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' && return 0
    elif [ -x /sbin/ldconfig ]; then
        /sbin/ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' && return 0
    fi
    return 1
}

pick_largest_icon() {
    awk '
        {
            sz = 0
            if (match($0, /[0-9]+x[0-9]+/)) {
                s = substr($0, RSTART, RLENGTH); split(s, a, "x"); sz = a[1] + 0
            }
            print sz "\t" length($0) "\t" $0
        }' \
    | sort -k1,1nr -k2,2nr | head -n1 | cut -f3-
}

find_icon() {
    local root="$1" iconname="$2" res=""
    if [ -n "$iconname" ]; then
        res=$(find "$root" -type f \
                \( -iname "${iconname}.png" -o -iname "${iconname}.svg" -o -iname "${iconname}.xpm" \) \
                2>/dev/null | pick_largest_icon || true)
    fi
    if [ -z "$res" ]; then
        res=$(find "$root" -type f -path '*icons*' \
                \( -iname '*.png' -o -iname '*.svg' \) 2>/dev/null | pick_largest_icon || true)
    fi
    if [ -z "$res" ] && [ -e "$root/.DirIcon" ]; then
        res="$root/.DirIcon"
        if [ -L "$res" ]; then
            local tgt; tgt=$(readlink -f "$res" 2>/dev/null || true)
            [ -n "$tgt" ] && [ -e "$tgt" ] && res="$tgt"
        fi
    fi
    if [ -z "$res" ]; then
        res=$(find "$root" -maxdepth 3 -type f \
                \( -iname '*.png' -o -iname '*.svg' \) 2>/dev/null | pick_largest_icon || true)
    fi
    printf '%s' "$res"
}

icon_ext() {
    local f="$1" head8
    head8=$(od -An -tx1 -N8 "$f" 2>/dev/null | tr -d ' \n')
    case "$head8" in
        89504e470d0a1a0a*) echo png; return;;
        ffd8ff*)           echo jpg; return;;
    esac
    if head -c 512 "$f" 2>/dev/null | grep -qi '<svg\|<?xml'; then
        echo svg
    else
        echo png
    fi
}

generate_wrapper() {
    local out="$1" appimage="$2"
    cat > "$out" <<EOF
#!/bin/sh
APPIMAGE="$appimage"
EOF
    cat >> "$out" <<'EOF'
if [ ! -e "$APPIMAGE" ]; then
    echo "appimage-install: AppImage not found: $APPIMAGE" >&2
    exit 127
fi
_have_fuse2() {
    for d in /usr/lib /usr/lib64 /lib /lib64 /usr/local/lib \
             /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib/i386-linux-gnu; do
        [ -e "$d/libfuse.so.2" ] && return 0
    done
    if command -v ldconfig >/dev/null 2>&1; then
        ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' && return 0
    elif [ -x /sbin/ldconfig ]; then
        /sbin/ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' && return 0
    fi
    return 1
}
if [ -z "${APPIMAGE_EXTRACT_AND_RUN:-}" ] && ! _have_fuse2; then
    export APPIMAGE_EXTRACT_AND_RUN=1
fi
exec "$APPIMAGE" "$@"
EOF
    chmod +x "$out"
}

refresh_caches() {
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache -f -t "$ICON_DIR/hicolor" >/dev/null 2>&1 || true
}

read_manifest() {
    MANI_ID=''; MANI_NAME=''; MANI_VERSION=''; MANI_APPIMAGE=''
    MANI_WRAPPER=''; MANI_DESKTOP=''; MANI_ICON=''; MANI_SCOPE=''
    MANI_INSTALLED=''; MANI_SRC=''
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            ID)        MANI_ID="$v";;
            NAME)      MANI_NAME="$v";;
            VERSION)   MANI_VERSION="$v";;
            APPIMAGE)  MANI_APPIMAGE="$v";;
            WRAPPER)   MANI_WRAPPER="$v";;
            DESKTOP)   MANI_DESKTOP="$v";;
            ICON)      MANI_ICON="$v";;
            SCOPE)     MANI_SCOPE="$v";;
            INSTALLED) MANI_INSTALLED="$v";;
            SRC)       MANI_SRC="$v";;
        esac
    done < "$1"
}

setup_locations() {
    if [ "$SYSTEM" -eq 1 ]; then
        APPS_DIR="/opt/appimages"
        DESKTOP_DIR="/usr/share/applications"
        ICON_DIR="/usr/share/icons"
        BIN_DIR="/usr/local/bin"
    else
        local data="${XDG_DATA_HOME:-$HOME/.local/share}"
        APPS_DIR="$data/appimages"
        DESKTOP_DIR="$data/applications"
        ICON_DIR="$data/icons"
        BIN_DIR="$HOME/.local/bin"
    fi
    REGISTRY="$APPS_DIR/.registry"
    mkdir -p "$APPS_DIR" "$DESKTOP_DIR" "$ICON_DIR" "$BIN_DIR" "$REGISTRY"
}

do_install() {
    local src="$1"
    [ -n "$src" ]      || die "no AppImage given. Try: appimage-install install ./App.AppImage"
    [ -f "$src" ]      || die "file not found: $src"
    src=$(readlink -f "$src")

    local magic ext_ok=0
    case "$src" in *.AppImage|*.appimage) ext_ok=1;; esac
    magic=$(od -An -tx1 -j8 -N3 "$src" 2>/dev/null | tr -d ' \n' || true)
    if [ "$magic" != "414902" ] && [ "$ext_ok" -ne 1 ] && [ "$FORCE" -ne 1 ]; then
        die "this does not look like an AppImage. Re-run with --force to install anyway."
    fi

    setup_locations
    info "Inspecting ${C_B}$(basename "$src")${C_RST}"

    local work; work=$(mktemp -d "${TMPDIR:-/tmp}/appimage-install.XXXXXX")
    trap 'rm -rf "$work"' RETURN
    local staged="$work/app.AppImage"
    cp -f "$src" "$staged"
    chmod +x "$staged"

    ( cd "$work" && "$staged" --appimage-extract >/dev/null 2>&1 ) \
        || die "could not extract this AppImage (is it a valid type-2 AppImage?)."
    local root="$work/squashfs-root"
    [ -d "$root" ] || die "extraction produced no squashfs-root; cannot read metadata."

    local desk=''
    desk=$(find "$root" -maxdepth 1 -iname '*.desktop' 2>/dev/null | head -n1 || true)
    [ -n "$desk" ] || desk=$(find "$root" -iname '*.desktop' 2>/dev/null | head -n1 || true)

    local display_name exec_val icon_name version desk_base
    if [ -n "$desk" ]; then
        desk_base=$(basename "$desk" .desktop)
        display_name=$(desktop_get "$desk" "Name" || true)
        exec_val=$(desktop_get "$desk" "Exec" || true)
        icon_name=$(desktop_get "$desk" "Icon" || true)
        version=$(desktop_get "$desk" "X-AppImage-Version" || true)
    else
        warn "no .desktop file inside the AppImage; synthesizing a minimal one."
        desk_base=$(basename "$src"); desk_base="${desk_base%.*}"
        display_name="$desk_base"; exec_val=""; icon_name=""; version=""
    fi

    local app_id command
    if [ -n "$NAME_OVERRIDE" ]; then
        app_id=$(sanitize "$NAME_OVERRIDE")
        command="$app_id"
    else
        if [ -n "$desk_base" ]; then app_id=$(sanitize "$desk_base")
        else app_id=$(sanitize "${display_name:-$(basename "$src")}"); fi
        local exec_first="${exec_val%% *}"
        case "$exec_first" in
            ""|AppRun|./AppRun|*/*|*%*) command="${app_id##*.}";;
            *) command=$(sanitize "$exec_first");;
        esac
        [ -n "$command" ] || command="$app_id"
    fi
    [ -n "$app_id" ]  || die "could not determine a name for this app; pass --name NAME."
    [ -n "$display_name" ] || display_name="$app_id"
    [ -n "$version" ] || version="unknown"

    local fcodes
    fcodes=$(printf '%s\n' "$exec_val" | { grep -oE '%[a-zA-Z]' || true; } \
             | tr '\n' ' ' | sed 's/ *$//')

    local dest_appimage="$APPS_DIR/$app_id.AppImage"
    local dest_wrapper="$BIN_DIR/$command"
    local dest_desktop="$DESKTOP_DIR/appimage_$app_id.desktop"

    if [ -e "$REGISTRY/$app_id" ] && [ "$FORCE" -ne 1 ]; then
        info "${C_B}$app_id${C_RST} is already installed — updating it."
    fi

    cp -f "$staged" "$dest_appimage"
    chmod +x "$dest_appimage"
    ok "Installed binary  → ${C_D}$dest_appimage${C_RST}"

    local dest_icon='' icon_src ext
    icon_src=$(find_icon "$root" "$icon_name")
    if [ -n "$icon_src" ] && [ -e "$icon_src" ]; then
        ext=$(icon_ext "$icon_src")
        dest_icon="$APPS_DIR/$app_id.$ext"
        cp -f "$icon_src" "$dest_icon"
        ok "Installed icon    → ${C_D}$dest_icon${C_RST}"
    else
        warn "no icon found inside the AppImage; the menu entry will use a generic icon."
    fi

    generate_wrapper "$dest_wrapper" "$dest_appimage"
    ok "Installed launcher → ${C_D}$dest_wrapper${C_RST}"

    local tmpdesk="$work/entry.desktop"
    if [ -n "$desk" ]; then
        cp -f "$desk" "$tmpdesk"
    else
        cat > "$tmpdesk" <<EOF
[Desktop Entry]
Type=Application
Name=$display_name
Terminal=false
Categories=Utility;
EOF
    fi
    local exec_field
    case "$dest_wrapper" in *" "*) exec_field="\"$dest_wrapper\"";; *) exec_field="$dest_wrapper";; esac
    desktop_set "$tmpdesk" "Exec"    "$exec_field${fcodes:+ $fcodes}"
    desktop_set "$tmpdesk" "TryExec" "$dest_wrapper"
    [ -n "$dest_icon" ] && desktop_set "$tmpdesk" "Icon" "$dest_icon"
    desktop_set "$tmpdesk" "X-AppImage-Install" "true"
    desktop_set "$tmpdesk" "X-AppImage-Id" "$app_id"
    cp -f "$tmpdesk" "$dest_desktop"
    chmod 644 "$dest_desktop"
    command -v desktop-file-validate >/dev/null 2>&1 \
        && { desktop-file-validate "$dest_desktop" 2>/dev/null \
             || warn "the .desktop entry has validation warnings (usually harmless)."; }
    ok "Installed menu entry → ${C_D}$dest_desktop${C_RST}"

    cat > "$REGISTRY/$app_id" <<EOF
ID=$app_id
NAME=$display_name
VERSION=$version
SCOPE=$([ "$SYSTEM" -eq 1 ] && echo system || echo user)
APPIMAGE=$dest_appimage
WRAPPER=$dest_wrapper
DESKTOP=$dest_desktop
ICON=$dest_icon
SRC=$(basename "$src")
INSTALLED=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    refresh_caches

    printf '\n' >&2
    ok "${C_B}${display_name}${C_RST} installed (id: ${C_B}$app_id${C_RST}, version: $version)."
    info "Launch it from your application menu, or run: ${C_B}$command${C_RST}"
    info "Remove it later with: ${C_B}appimage-install remove $app_id${C_RST}"

    case ":$PATH:" in
        *":$BIN_DIR:"*) : ;;
        *) warn "$BIN_DIR is not on your PATH. The menu entry works regardless, but to"
           warn "run '$command' in a terminal, add this to your shell rc:"
           printf '      %s\n' "export PATH=\"$BIN_DIR:\$PATH\"" >&2 ;;
    esac
    if ! host_has_fuse2; then
        info "FUSE2 isn't present on this system, so the launcher will use extract-and-run"
        info "automatically. (Installing 'libfuse2'/'fuse2' would make startup a bit faster.)"
    fi
}

resolve_id() {
    local q="$1" m
    [ -e "$REGISTRY/$q" ] && { printf '%s' "$q"; return; }
    for m in "$REGISTRY"/*; do
        [ -e "$m" ] || continue
        read_manifest "$m"
        if [ "$(basename "$MANI_APPIMAGE")" = "$(basename "$q")" ] || [ "$MANI_SRC" = "$(basename "$q")" ]; then
            printf '%s' "$(basename "$m")"; return
        fi
    done
    printf ''
}

do_remove() {
    local q="$1"
    [ -n "$q" ] || die "what should I remove? Try: appimage-install list"
    setup_locations
    local id; id=$(resolve_id "$q")
    [ -n "$id" ] || die "not installed: $q  (see 'appimage-install list')"

    read_manifest "$REGISTRY/$id"
    info "Removing ${C_B}${MANI_NAME:-$id}${C_RST} (id: $id)"
    local p
    for p in "$MANI_APPIMAGE" "$MANI_WRAPPER" "$MANI_DESKTOP" "$MANI_ICON"; do
        [ -n "$p" ] && [ -e "$p" ] && { rm -f "$p" && ok "removed ${C_D}$p${C_RST}"; }
    done
    rm -f "$REGISTRY/$id"
    refresh_caches
    ok "${C_B}${MANI_NAME:-$id}${C_RST} removed."
}

do_list() {
    setup_locations
    local found=0 m
    printf '%s%-22s %-28s %s%s\n' "$C_B" "ID" "NAME" "VERSION" "$C_RST" >&2
    for m in "$REGISTRY"/*; do
        [ -e "$m" ] || continue
        found=1; read_manifest "$m"
        printf '%-22s %-28s %s\n' "$MANI_ID" "$MANI_NAME" "$MANI_VERSION"
    done
    [ "$found" -eq 1 ] || info "No AppImages installed yet."
}

do_info() {
    local q="$1"
    [ -n "$q" ] || die "usage: appimage-install info <id>"
    setup_locations
    local id; id=$(resolve_id "$q")
    [ -n "$id" ] || die "not installed: $q"
    read_manifest "$REGISTRY/$id"
    printf '%sName%s        %s\n' "$C_B" "$C_RST" "$MANI_NAME"
    printf '%sId%s          %s\n' "$C_B" "$C_RST" "$MANI_ID"
    printf '%sVersion%s     %s\n' "$C_B" "$C_RST" "$MANI_VERSION"
    printf '%sScope%s       %s\n' "$C_B" "$C_RST" "$MANI_SCOPE"
    printf '%sAppImage%s    %s\n' "$C_B" "$C_RST" "$MANI_APPIMAGE"
    printf '%sLauncher%s    %s\n' "$C_B" "$C_RST" "$MANI_WRAPPER"
    printf '%sMenu entry%s  %s\n' "$C_B" "$C_RST" "$MANI_DESKTOP"
    printf '%sIcon%s        %s\n' "$C_B" "$C_RST" "${MANI_ICON:-<none>}"
    printf '%sInstalled%s   %s\n' "$C_B" "$C_RST" "$MANI_INSTALLED"
}

usage() {
    cat >&2 <<EOF
${C_B}appimage-install${C_RST} $VERSION — install AppImages like packages, on any distro.

${C_B}USAGE${C_RST}
  appimage-install install <file.AppImage> [options]
  appimage-install <file.AppImage>                 (shorthand for install)
  appimage-install remove  <id|file>      [--system]
  appimage-install list                   [--system]
  appimage-install info    <id>           [--system]
  appimage-install help

${C_B}OPTIONS${C_RST}
  --system        Install for all users (writes to /opt, /usr/share; uses sudo).
  --name NAME     Override the app id / command name.
  --force, -f     Skip the AppImage sanity check / overwrite without prompt.
  --version, -V   Print version.
  -h, --help      This help.

${C_B}WHAT IT DOES${C_RST}
  * Copies the AppImage to a stable location (~/.local/share/appimages, or /opt).
  * Adds an application-menu entry + icon using freedesktop (XDG) standards that
    GNOME, KDE, XFCE, Cinnamon, MATE, LXQt, etc. all read — hence "all distros".
  * Puts a launcher on your PATH and auto-falls-back to extract-and-run when the
    host lacks FUSE2, so apps launch even on Ubuntu 22.04+ / immutable distros.
  * Records every file it creates so 'remove' uninstalls cleanly.

${C_B}EXAMPLES${C_RST}
  appimage-install install ~/Downloads/GIMP-2.10-x86_64.AppImage
  appimage-install ~/Downloads/Obsidian.AppImage --name obsidian
  appimage-install list
  appimage-install remove gimp
EOF
}

SYSTEM=0
FORCE=0
NAME_OVERRIDE=""
ACTION=""
positional=()

while [ $# -gt 0 ]; do
    case "$1" in
        --system)       SYSTEM=1 ;;
        --force|-f)     FORCE=1 ;;
        --name)         shift; NAME_OVERRIDE="${1:-}" ;;
        --name=*)       NAME_OVERRIDE="${1#--name=}" ;;
        -V|--version)   echo "appimage-install $VERSION"; exit 0 ;;
        -h|--help)      ACTION="help" ;;
        --)             shift; while [ $# -gt 0 ]; do positional+=("$1"); shift; done; break ;;
        -*)             die "unknown option: $1  (try --help)" ;;
        *)              positional+=("$1") ;;
    esac
    shift
done

if [ "$SYSTEM" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "--system needs root; run again as root or install sudo."
    info "--system requested; elevating with sudo…"
    exec sudo -- "$0" "$@"
fi

cmd="${positional[0]:-}"
if [ "$ACTION" != "help" ]; then
    case "$cmd" in
        install|add)         ACTION="install"; TARGET="${positional[1]:-}" ;;
        remove|uninstall|rm) ACTION="remove";  TARGET="${positional[1]:-}" ;;
        list|ls)             ACTION="list" ;;
        info|show)           ACTION="info";    TARGET="${positional[1]:-}" ;;
        help|"")             ACTION="help" ;;
        *)
            if [ -f "$cmd" ]; then ACTION="install"; TARGET="$cmd"
            else err "unknown command: $cmd"; ACTION="help"; fi
            ;;
    esac
fi

case "$ACTION" in
    install) do_install "${TARGET:-}" ;;
    remove)  do_remove  "${TARGET:-}" ;;
    list)    do_list ;;
    info)    do_info   "${TARGET:-}" ;;
    *)       usage ;;
esac
