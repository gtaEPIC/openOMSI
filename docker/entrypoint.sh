#!/bin/sh
# Starts the openOMSI dedicated server in its container (the image's entrypoint, under tini).
#
#   (nothing)          start the server from /data/server.cfg and the OMSI_SERVER_* variables
#   --flag ...         the same, with these flags added to the server's command line
#   print-config       show the server.cfg the server gets (passwords hidden) and stop
#   anything else      run that instead: sh, openomsi-launcher --cli mods, ...
#
# /data is the server's folder: server.cfg (written with every key and its meaning on the first
# start; never changed here afterwards), server-icon.png, content/ (mods, laid out like the
# OMSI 2 folder) and .openomsi (the game's own data). /omsi2 is the original OMSI 2, read-only.
#
# OMSI_SERVER_<KEY>=value sets the server.cfg key <key> (OMSI_SERVER_MAX_PLAYERS=8 is
# max_players = 8), over what the file says; OMSI_SERVER_<KEY>_FILE=/path reads the value from a
# file (a Docker secret). The server gets the file and these lines together in /tmp/openomsi.
set -eu

data=/data
cfg="$data/server.cfg"
template=/opt/openomsi/server.cfg.default
run=/tmp/openomsi
root="${OMSI_ROOT:-/omsi2}"
nl='
'

say() { printf 'openOMSI server: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

case "${1:-}" in
    "" | -*) mode=server ;;
    print-config) mode=print; shift ;;
    *) exec "$@" ;;
esac

# The last value server.cfg-style text gives a key, as the server reads it: keys in any case,
# lines starting with # are comments, the last line of a key wins, spaces round the value go.
value_of() {
    awk -v k="$1" '
        { line = $0; sub(/\r$/, "", line); sub(/^[ \t]+/, "", line) }
        substr(line, 1, 1) == "#" { next }
        { i = index(line, "="); if (!i) next
          key = tolower(substr(line, 1, i - 1)); sub(/[ \t]+$/, "", key)
          if (key == k) { v = substr(line, i + 1); found = 1 } }
        END { if (found) { sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v } }' "$2"
}

# The OMSI_SERVER_* variables as server.cfg lines, one a key (OMSI_SERVER_<KEY>_FILE after
# OMSI_SERVER_<KEY>, so the file wins).
env_lines() {
    known=""
    if [ -f "$template" ]; then
        known=$(sed -n 's/^\([a-z_][a-z0-9_]*\)[[:blank:]]*=.*/\1/p' "$template")
    fi
    # (the names are letters, digits and _ only, so eval just reads the variable)
    for name in $(env | sed -n 's/^\(OMSI_SERVER_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u); do
        case "$name" in
            *_FILE)
                key=${name#OMSI_SERVER_}; key=${key%_FILE}
                file=$(eval "printf '%s' \"\${$name-}\"")
                [ -r "$file" ] || die "$name: cannot read $file"
                value=$(cat "$file")
                ;;
            *)
                key=${name#OMSI_SERVER_}
                value=$(eval "printf '%s' \"\${$name-}\"")
                ;;
        esac
        key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
        case "$value" in
            *"$nl"*) say "$name has more than one line; left out"; continue ;;
        esac
        if [ -n "$known" ] && ! printf '%s\n' "$known" | grep -qx "$key"; then
            say "$name: server.cfg has no key \"$key\" (a typo?); passed on anyway"
        fi
        printf '%s = %s\n' "$key" "$value"
    done
}

if [ "$mode" = server ]; then
    if [ ! -d "$data" ] || [ ! -w "$data" ]; then
        die "$data is not writable for user $(id -u):$(id -g). Give the folder you mount there to that user (on Linux: sudo chown -R $(id -u):$(id -g) <folder>), or run the container as the folder's owner (compose: user: \"<uid>:<gid>\")."
    fi
    if [ ! -d "$root" ] || [ -z "$(ls -A "$root" 2>/dev/null)" ]; then
        die "no OMSI 2 at $root. openOMSI plays on the original game's files: mount your OMSI 2 folder (the one with Omsi.exe, maps and Vehicles) there, read-only, e.g.
    docker run ... --mount type=bind,src=\"/path/to/OMSI 2\",dst=/omsi2,readonly ...
(with docker/compose.yaml: OMSI2_PATH in .env)"
    fi
    if [ ! -e "$cfg" ]; then
        if [ -f "$template" ]; then cp "$template" "$cfg"; else : >"$cfg"; fi
        say "first start: wrote $cfg with every setting and its meaning"
    fi
fi

# The server's own copy: server.cfg (or, before the first start, the defaults) and the
# variables after it. Only the user can read it: it may hold passwords.
umask 077
mkdir -p "$run"
merged="$run/server.cfg"
lines=$(env_lines)
{
    if [ -f "$cfg" ]; then cat "$cfg"; elif [ -f "$template" ]; then cat "$template"; fi
    if [ -n "$lines" ]; then
        printf '\n# ---- the container'"'"'s OMSI_SERVER_* variables (they win over the lines above) ----\n'
        printf '%s\n' "$lines"
    fi
} >"$merged"

if [ "$mode" = print ]; then
    sed -E 's/^([[:blank:]]*(admin_password|voice_channel_password)[[:blank:]]*=[[:blank:]]*)[^[:blank:]].*$/\1********/I' "$merged"
    exit 0
fi

# The ports, checked before the server takes them: it would not say when the web port cannot
# be had (it takes any free one then, which Docker does not pass on), and the game port's TCP
# side is the mods' (so the two must differ).
port=$(value_of port "$merged"); port=${port:-27015}
web=$(value_of web_port "$merged"); web=${web:-27025}
for p in "port=$port" "web_port=$web"; do
    v=${p#*=}
    case "$v" in
        *[!0-9]* | "") die "${p%%=*} = $v is not a port number" ;;
    esac
    if [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then
        die "${p%%=*} = $v is not a port number (1-65535)"
    fi
done
[ "$port" -ne "$web" ] || die "port and web_port are both $port: the web port needs one of its own (by custom the game port + 10, e.g. 27025)"

# What the helpers (omsi-health, omsi-admin, omsi-status) need to know
printf 'OMSI_PORT=%s\nOMSI_WEB_PORT=%s\n' "$port" "$web" >"$run/runtime.env"
password=$(value_of admin_password "$merged")
if [ -n "$password" ]; then
    printf 'X-Admin-Password: %s\n' "$password" >"$run/admin.hdr"
else
    rm -f "$run/admin.hdr"
fi
# (the server's icon is read beside its server.cfg)
ln -sf "$data/server-icon.png" "$run/server-icon.png"
# A tunnel's process id from the container's last run: the game would look that number up
# with ps, which this image does not have, and the process went with the old container anyway
rm -f "$data/.openomsi/cloudflared.pid"
umask 022

count=0
[ -z "$lines" ] || count=$(printf '%s\n' "$lines" | grep -c '')
say "OMSI 2 at $root; game port $port (UDP and TCP), web port $web; settings: $cfg and $count OMSI_SERVER_* variable(s)"
# The game writes every OMSI_* variable into its log when it starts: these may hold passwords,
# and the server has them in its server.cfg now
for name in $(env | sed -n 's/^\(OMSI_SERVER_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$name"
done
exec /opt/openomsi/openomsi --root "$root" --server "$merged" "$@"
