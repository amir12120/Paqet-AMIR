#!/usr/bin/env bash
# paqet-panel / paqet-node installer.
#
#   curl -fsSL https://github.com/behzadea12/Paqet-Panel/releases/latest/download/install.sh | sudo bash
#   sudo bash install.sh                 # interactive wizard (needs a TTY)
#   sudo bash install.sh panel [options]
#   sudo bash install.sh node  --token pqn1.... [options]
#   sudo bash install.sh uninstall panel|node [--purge] [--remove-tunnels]
#
# Releases come from DEFAULT_REPO below unless --repo (or PAQET_REPO) names
# another repository.
#
# Two modes:
#   (A) One-liner / flags: non-interactive. On a port conflict it fails
#       immediately, names the service and PID that hold the port, and
#       prints the exact fix. --yes answers yes to confirmations (it does
#       not enter the wizard). --stop-conflicting is an opt-in to stop the
#       exact unit (or exact PID if there is no unit) so the install can
#       continue; that holder is restarted only if the installer fails.
#   (B) Interactive wizard: sudo bash install.sh  or  --interactive.
#       Also works from a piped one-liner when /dev/tty is available.
#       Asks role, domain, port, email, TLS mode, node options and the
#       other relevant flags, validates each step, then shows a summary
#       and asks to confirm. A busy port offers [Y] stop it, [N] abort,
#       [P] pick another port.
#
# Safety rules: this script never deletes, overwrites or stops anything
# without asking first (--yes answers "yes" to those questions). It never
# uses pkill or killall. Every download is checked against SHA256SUMS, and
# against an ed25519 signature when --pubkey is given. Run with --help.
set -euo pipefail
umask 022

PROGRAM=""
YES=0
DRY_RUN=0
TAG=""
# Repository whose releases this installer uses by default (--repo or
# PAQET_REPO override it; --from DIR uses no repository).
DEFAULT_REPO="behzadea12/Paqet-Panel"
REPO="${PAQET_REPO:-}"
REPO_SET=0 # 1 = --repo on the command line (the wizard does not ask then)
CORE_REPO="${PAQET_CORE_REPO:-}"
API="${PAQET_API:-https://api.github.com}"
FROM_DIR=""
PUBKEY="${PAQET_PUBKEY:-}"
LISTEN=""
PORT=""
CERT_DIR=""
ACME_HTTP=0 # v0.7.37: built-in ACME with HTTP-01 on port 80 (panel not on 443)
DOMAIN=""
EMAIL=""
NODE_LISTEN=""
TOKEN="${PAQET_NODE_TOKEN:-}"
AS_ROOT=0
NO_START=0
# ACME directory for --domain (default Let's Encrypt production); set it to
# the Let's Encrypt staging URL or a private ACME CA for tests.
ACME_DIR="${PAQET_ACME_DIRECTORY:-}"
INTERACTIVE=0
STOP_CONFLICTING=0
LOG_FILE="${PAQET_INSTALL_LOG:-}"
# Holders stopped to free a port: restored on failure (and listed at the
# end on success, so the user can start them again). Never pkill/killall.
STOPPED_UNITS="" # "unit:port:kind ..."
STOPPED_PIDS=""  # "pid:port:kind ..."

# PAQET_INSTALL_ROOT relocates every path (for tests); never set it on a
# real install.
R=${PAQET_INSTALL_ROOT:-}
PREFIX=$R/opt
CORE_DIR=$PREFIX/paqet/bin
CORE_BIN=$CORE_DIR/paqet
TUNNEL_USER=paqet
TUNNEL_CONF=$R/etc/paqet
VERSIONS_DIR=$PREFIX/paqet/cores
GOST2_CONF=$R/etc/gost2
GOST3_CONF=$R/etc/gost3
CORES="paqet gost2 gost3"
UNIT_DIR=$R/etc/systemd/system
POLKIT_DIR=$R/etc/polkit-1/rules.d
VAR=$R/var/lib
ETC=$R/etc

usage() {
  cat <<'USAGE'
Usage:
  install.sh                         interactive wizard (requires a terminal)
  install.sh --interactive [options]  same, with flags as defaults
  install.sh panel|node [options]     non-interactive (one-liner / flags)
  install.sh uninstall panel|node [--yes] [--purge] [--remove-tunnels]
                                     download the release's uninstall.sh,
                                     check it against SHA256SUMS and run it

When run with no role, or with --interactive, and a terminal is available
(including /dev/tty when the script was piped: curl … | sudo bash), a
step-by-step wizard asks for the role, domain, port, e-mail, TLS mode,
node options and the other relevant flags, checks each answer, then
prints a summary and asks to confirm.

On a one-liner / flags run, a busy port fails immediately: the message
names the service and PID that hold it and the exact command to fix it.
--yes answers yes to confirmations and never starts the wizard.
--stop-conflicting (opt-in) stops the exact systemd unit, or the exact
PID when there is no unit, so the install can continue; the holder is
restarted if the installer fails. pkill/killall are never used.


Release source:
  --repo OWNER/NAME     repository whose releases carry paqet-panel/paqet-node
                        (default behzadea12/Paqet-Panel)
  --core-repo OWNER/NAME
                        repository with paqet-linux-<arch> (installs the core too)
  --api URL             GitHub-compatible API (default https://api.github.com;
                        Gitea/Forgejo: https://host/api/v1)
  --version TAG         release tag (default: latest)
  --from DIR            offline install from DIR (binaries + SHA256SUMS[.sig])
  --pubkey BASE64       require a valid ed25519 signature on SHA256SUMS
                        (only for releases you sign yourself: the published
                        releases have no SHA256SUMS.sig)

Panel:
  --listen ADDR         listen address (default 127.0.0.1:8480)
  --port N              listen on 0.0.0.0:N (with --domain: HTTPS on that port)
  --domain NAME --email ADDR
                        serve HTTPS with Let's Encrypt via the built-in ACME
                        client: on 0.0.0.0:443 by default (TLS-ALPN-01); with
                        --port N on 0.0.0.0:N, the certificate is obtained
                        and renewed with HTTP-01 on port 80 (which must be
                        free and reachable). With a certbot certificate in
                        /etc/letsencrypt/live/NAME/ any --port works, port 80
                        is not used and --email is not needed

Node:
  --token TOKEN         join token from the panel (or PAQET_NODE_TOKEN)
  --node-listen ADDR    agent listen address (default 0.0.0.0:9443; firewall
                        it to the panel's IP)

General:
  --interactive, -i     step-by-step wizard (also the default when no role
                        is given and a terminal is available)
  --yes                 answer yes to every confirmation (non-interactive;
                        does not start the wizard)
  --stop-conflicting    one-liner: stop the exact unit or PID that holds a
                        needed port (restored if the installer fails)
  --dry-run             print what would be done, change nothing
  --root                run the service as root (no polkit rule); only if
                        polkit with JavaScript rules is unavailable
  --no-start            install but do not start the service
  -h, --help            this help

Environment:
  PAQET_REPO, PAQET_CORE_REPO, PAQET_API, PAQET_PUBKEY, PAQET_NODE_TOKEN
                        defaults for --repo, --core-repo, --api, --pubkey, --token
  PAQET_ACME_DIRECTORY  ACME directory URL for --domain (https; default
                        Let's Encrypt), for example the Let's Encrypt staging CA
USAGE
}

say() { _log "==> $*"; printf '==> %s\n' "$*" >&2; }
warn() { _log "WARNING: $*"; printf 'WARNING: %s\n' "$*" >&2; }
die() {
  _log "ERROR: $*"
  printf 'ERROR: %s\n' "$*" >&2
  [ -z "${WIZ_EOF_FILE:-}" ] || rm -f -- "$WIZ_EOF_FILE"
  if declare -F restore_holders >/dev/null 2>&1; then
    restore_holders
  fi
  exit 1
}

# confirm QUESTION [DEFAULT]: yes with --yes, otherwise ask on the terminal;
# Enter takes DEFAULT (y or n, default n). Without a terminal (piped install)
# and without --yes the answer is always "no".
confirm() {
  if [ "$YES" = 1 ]; then
    say "$1 -> yes (--yes)"
    return 0
  fi
  local ans="" def=${2:-n} hint="y/N"
  [ "$def" = y ] && hint="Y/n"
  if [ -n "${PAQET_INSTALL_INPUT:-}" ]; then
    # same feed as the wizard, so later "Upgrade it?" questions work
    if [ "$def" = y ]; then ans=$(wiz_ask "$1" "Y"); else ans=$(wiz_ask "$1" "N"); fi
  elif { : </dev/tty; } 2>/dev/null; then
    printf '%s [%s] ' "$1" "$hint" >/dev/tty
    read -r ans </dev/tty || ans=""
    [ -n "$ans" ] || ans=$def
    _log "ask: $1 => $ans"
  fi
  case $ans in
    y | Y | yes | YES) return 0 ;;
  esac
  return 1
}

# run CMD...: execute (argv, never through a shell string) or print it.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# put_file DEST MODE OWNER CONTENT_FILE: install a file, asking before
# replacing one that exists with different content.
put_file() {
  local dest=$1 mode=$2 owner=$3 src=$4
  if [ -e "$dest" ]; then
    if cmp -s "$src" "$dest"; then
      return 0
    fi
    if ! confirm "Replace existing $dest?"; then
      warn "kept existing $dest (it differs from the new version)"
      return 0
    fi
    run cp -p "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)"
  fi
  run install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dest"
}

# need_value OPT VALUE...: an option that takes a value got one (not empty,
# not the next option).
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ] || [[ $2 == --* ]]; then die "$1 needs a value (see --help)"; fi
}

parse_flags() {
  while [ $# -gt 0 ]; do
    case $1 in
      panel | node)
        [ -z "$PROGRAM" ] || die "role already set to $PROGRAM"
        PROGRAM=$1
        ;;
      --interactive | -i) INTERACTIVE=1 ;;
      --stop-conflicting) STOP_CONFLICTING=1 ;;
      --yes) YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --root) AS_ROOT=1 ;;
      --no-start) NO_START=1 ;;
      --repo) need_value "$@" && REPO=$2 && REPO_SET=1 && shift ;;
      --core-repo) need_value "$@" && CORE_REPO=$2 && shift ;;
      --api) need_value "$@" && API=$2 && shift ;;
      --version) need_value "$@" && TAG=$2 && shift ;;
      --from) need_value "$@" && FROM_DIR=$2 && shift ;;
      --pubkey) need_value "$@" && PUBKEY=$2 && shift ;;
      --listen) need_value "$@" && LISTEN=$2 && shift ;;
      --port) need_value "$@" && PORT=$2 && shift ;;
      --domain) need_value "$@" && DOMAIN=$2 && shift ;;
      --email) need_value "$@" && EMAIL=$2 && shift ;;
      --token) need_value "$@" && TOKEN=$2 && shift ;;
      --node-listen) need_value "$@" && NODE_LISTEN=$2 && shift ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

# has_tty: a real terminal, or a test feed in PAQET_INSTALL_INPUT.
has_tty() {
  if [ -n "${PAQET_INSTALL_INPUT:-}" ]; then
    return 0
  fi
  { : </dev/tty; } 2>/dev/null
}

setup_ui() {
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C0=$(printf '\033[0m')
    C1=$(printf '\033[1m')
    C2=$(printf '\033[32m')
    C3=$(printf '\033[36m')
    C4=$(printf '\033[33m')
    C5=$(printf '\033[31m')
  else
    C0="" C1="" C2="" C3="" C4="" C5=""
  fi
}

_log() {
  [ -n "${LOG_FILE:-}" ] || return 0
  # join tokens (pqn1./pqk1.) never reach the log file
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | sed 's/pq\([nk]\)1\.[A-Za-z0-9._-]*/pq\11.<redacted>/g' >>"$LOG_FILE" 2>/dev/null || true
}

setup_log() {
  local dir
  if [ -z "$LOG_FILE" ]; then
    if [ -n "$R" ]; then
      dir=$R/var/log
    elif [ "$(id -u)" = 0 ] && [ -d /var/log ]; then
      dir=/var/log
    else
      dir=${TMPDIR:-/tmp}
    fi
    mkdir -p "$dir" 2>/dev/null || dir=${TMPDIR:-/tmp}
    LOG_FILE=$dir/paqet-install-$(date +%Y%m%d-%H%M%S).log
  fi
  if ! (umask 077 && touch "$LOG_FILE") 2>/dev/null; then
    LOG_FILE=${TMPDIR:-/tmp}/paqet-install-$(date +%Y%m%d-%H%M%S).log
    (umask 077 && touch "$LOG_FILE") 2>/dev/null || LOG_FILE=""
  fi
  [ -z "$LOG_FILE" ] || chmod 0600 "$LOG_FILE" 2>/dev/null || true
  _log "start: $*"
  _log "cwd=$(pwd) user=$(id -u) interactive=$INTERACTIVE yes=$YES stop_conflicting=$STOP_CONFLICTING"
}

step() { # step N MSG
  printf '%s[%s]%s %s\n' "$C1$C3" "$1" "$C0" "$2" >&2
  _log "step $1: $2"
}

# unit_of_pid PID: the systemd unit for this exact PID (empty if none).
unit_of_pid() {
  local pid=$1 names u
  [ -n "$pid" ] || return 0
  names=$(systemctl show --pid="$pid" -p Names --value 2>/dev/null || true)
  names=${names#Names=}
  if [ -z "$names" ]; then
    names=$(systemctl show --pid="$pid" -p Names 2>/dev/null | sed 's/^Names=//' || true)
  fi
  names=${names#Names=}
  for u in $names; do
    case $u in
      *.service)
        printf '%s' "$u"
        return 0
        ;;
    esac
  done
  for u in $names; do
    case $u in
      *.socket)
        printf '%s' "$u"
        return 0
        ;;
    esac
  done
}

# describe_from_own OWN: "\"nginx\",pid=13,fd=6 (nginx.service, PID 13)"
describe_from_own() {
  local own=$1 comm pid unit
  comm=$(printf '%s' "$own" | sed -n 's/^"\([^"]*\)".*/\1/p')
  pid=$(printf '%s' "$own" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')
  [ -n "$pid" ] && unit=$(unit_of_pid "$pid")
  if [ -n "$unit" ] && [ -n "$pid" ]; then
    printf '%s (%s, PID %s)' "$own" "$unit" "$pid"
  elif [ -n "$pid" ] && [ -n "$comm" ]; then
    printf '%s (PID %s, process %s, no systemd unit)' "$own" "$pid" "$comm"
  elif [ -n "$pid" ]; then
    printf '%s (PID %s, no systemd unit)' "$own" "$pid"
  else
    printf '%s' "$own"
  fi
}

# stop_holder ADDR KIND: stop the exact unit, or the exact PID if there is
# no unit. Never pkill/killall. Returns 0 when the holder was stopped (or
# would be, in --dry-run). KIND is listen or http01 (for the restore note).
stop_holder() {
  local addr=$1 kind=${2:-listen} own comm pid unit
  own=$(port_owner "$addr")
  [ -n "$own" ] || return 0
  comm=$(printf '%s' "$own" | sed -n 's/^"\([^"]*\)".*/\1/p')
  pid=$(printf '%s' "$own" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')
  [ -n "$pid" ] && unit=$(unit_of_pid "$pid")
  if [ -n "$unit" ]; then
    say "stopping $unit (PID ${pid:-unknown}) to free port ${addr##*:}"
    if [ "$DRY_RUN" = 1 ]; then
      printf '[dry-run] systemctl stop -- %q\n' "$unit"
    else
      systemctl stop -- "$unit" || {
        warn "could not stop $unit"
        return 1
      }
    fi
    STOPPED_UNITS="$STOPPED_UNITS $unit:${addr##*:}:$kind"
    _log "stopped unit $unit port ${addr##*:} kind $kind"
    return 0
  fi
  if [ -z "$pid" ]; then
    warn "could not find a PID for the process on port ${addr##*:}: $own"
    return 1
  fi
  # Tests use a relocated root and invented PIDs: never send a signal.
  if [ -n "$R" ]; then
    say "would stop PID $pid (process ${comm:-unknown}) to free port ${addr##*:} (not signalled in the test root)"
    STOPPED_PIDS="$STOPPED_PIDS $pid:${addr##*:}:$kind"
    return 0
  fi
  if [ ! -d "/proc/$pid" ]; then
    warn "PID $pid is no longer running"
    return 1
  fi
  if [ -n "$comm" ] && [ -r "/proc/$pid/comm" ]; then
    local got
    got=$(tr -d '\n' <"/proc/$pid/comm" 2>/dev/null || true)
    if [ -n "$got" ] && [ "$got" != "$comm" ]; then
      warn "refusing to stop PID $pid: /proc/$pid/comm is $got, expected $comm"
      return 1
    fi
  fi
  say "stopping PID $pid (process ${comm:-unknown}, no systemd unit) to free port ${addr##*:}"
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] kill -TERM -- %q\n' "$pid"
  else
    kill -TERM -- "$pid" || {
      warn "could not stop PID $pid"
      return 1
    }
  fi
  STOPPED_PIDS="$STOPPED_PIDS $pid:${addr##*:}:$kind"
  _log "stopped pid $pid port ${addr##*:} kind $kind"
}

restore_holders() {
  local rec unit port kind pid rest
  [ -n "${STOPPED_UNITS:-}${STOPPED_PIDS:-}" ] || return 0
  say "restoring processes that were stopped to free a port"
  for rec in $STOPPED_UNITS; do
    unit=${rec%%:*}
    rest=${rec#*:}
    port=${rest%%:*}
    kind=${rest#*:}
    say "starting $unit again (it held port $port, $kind)"
    if [ "$DRY_RUN" = 1 ]; then
      printf '[dry-run] systemctl start -- %q\n' "$unit"
    else
      systemctl start -- "$unit" || warn "could not start $unit again; run: systemctl start $unit"
    fi
  done
  for rec in $STOPPED_PIDS; do
    pid=${rec%%:*}
    rest=${rec#*:}
    port=${rest%%:*}
    kind=${rest#*:}
    warn "PID $pid (port $port, $kind) was stopped and cannot be restarted automatically (it had no systemd unit). Start that program again yourself if you still need it."
  done
  STOPPED_UNITS=""
  STOPPED_PIDS=""
}

report_stopped_holders() {
  local rec unit port kind pid rest
  [ -n "${STOPPED_UNITS:-}${STOPPED_PIDS:-}" ] || return 0
  printf '\n%sThe following were left stopped so this install can use their port:%s\n' "$C4" "$C0"
  for rec in $STOPPED_UNITS; do
    unit=${rec%%:*}
    rest=${rec#*:}
    port=${rest%%:*}
    kind=${rest#*:}
    printf '  %s (port %s, %s) — start it again with: systemctl start %s\n' "$unit" "$port" "$kind" "$unit"
  done
  for rec in $STOPPED_PIDS; do
    pid=${rec%%:*}
    rest=${rec#*:}
    port=${rest%%:*}
    kind=${rest#*:}
    printf '  PID %s (port %s, %s) had no systemd unit; start that program again yourself if you still need it.\n' "$pid" "$port" "$kind"
  done
  if printf '%s %s\n' "$STOPPED_UNITS" "$STOPPED_PIDS" | grep -q ':http01'; then
    printf '  Note: the built-in HTTP-01 challenge needs port 80 free for every renewal, not only the first certificate.\n'
  fi
}

# handle_port_conflict SVC ADDR HINT KIND
# KIND=listen|http01. On a free port: return 0. Interactive: Y/N/P.
# Non-interactive: die, unless --stop-conflicting (then stop and continue).
handle_port_conflict() {
  local svc=$1 addr=$2 hint=$3 kind=${4:-listen} own ans newp
  [ "$NO_START" = 1 ] && return 0
  own=$(port_busy_msg "$svc" "$addr")
  [ -n "$own" ] || return 0
  local state="nothing was changed"
  systemctl is-active --quiet "$svc" 2>/dev/null && state="nothing was changed; the running $svc keeps its current settings"

  conflict_die() {
    die "port ${addr##*:} is already used by: $own
  $state. Exact fix (pick one):
    - free that port (stop the unit named above, or the exact PID), or
    - $hint
    - opt-in to stop that exact holder and continue:
        $(rerun_cmd -s) ${PROGRAM:-panel} --stop-conflicting ${DOMAIN:+--domain $DOMAIN} ${EMAIL:+--email $EMAIL} ${PORT:+--port $PORT}
    - or run the wizard and choose [Y] stop / [P] another port:
        $(rerun_cmd -s) --interactive"
  }

  if [ "$INTERACTIVE" = 1 ] && [ "$YES" != 1 ]; then
    printf '%sPort %s is already used by: %s%s\n' "$C5$C1" "${addr##*:}" "$own" "$C0" >&2
    if [ "$kind" = http01 ]; then
      printf '  The built-in Let'\''s Encrypt HTTP-01 challenge needs port 80. [Y] stop this holder for the install (it stays stopped so renewals work; it is restarted if the installer fails). [N] abort. [P] switch the panel to port 443 (TLS-ALPN-01, port 80 not used).\n' >&2
    else
      printf '  [Y] stop this exact unit or PID so the install can use the port (restarted if the installer fails). [N] abort. [P] choose another port.\n' >&2
    fi
    while true; do
      ans=$(wiz_ask "Port ${addr##*:} busy: [Y] stop / [N] abort / [P] other port" "N")
      case $ans in
        y | Y | yes | YES)
          stop_holder "$addr" "$kind" || die "could not stop the holder of port ${addr##*:}: $own"
          if [ "$DRY_RUN" != 1 ] && [ -z "$R" ]; then
            own=$(port_busy_msg "$svc" "$addr")
            [ -z "$own" ] || die "port ${addr##*:} is still used by: $own after the stop"
          fi
          return 0
          ;;
        n | N | no | NO)
          die "aborted: port ${addr##*:} is already used by: $own
  $state."
          ;;
        p | P)
          if [ "$kind" = http01 ]; then
            say "switching to port 443 (TLS-ALPN-01); port 80 will not be used"
            PORT=443
            LISTEN=0.0.0.0:443
            LISTEN_SET=1
            ACME_HTTP=0
            return 0
          fi
          newp=$(wiz_ask "New port" "$(free_port)")
          if ! [[ $newp =~ ^[0-9]{1,5}$ ]] || [ "$newp" -lt 1 ] || [ "$newp" -gt 65535 ]; then
            warn "port must be 1-65535"
            continue
          fi
          # v0.7.43: keep the address part (a loopback panel stays on
          # loopback; only the port changes)
          if [ "$svc" = paqet-node ]; then
            NODE_LISTEN=${addr%:*}:$newp
            NODE_LISTEN_SET=1
            handle_port_conflict "$svc" "$NODE_LISTEN" "$hint" listen
          else
            LISTEN=${addr%:*}:$newp
            PORT=""
            [ "${addr%:*}" != 0.0.0.0 ] || PORT=$newp
            LISTEN_SET=1
            handle_port_conflict "$svc" "$LISTEN" "$(rerun_cmd -s) panel --port $(free_port)${DOMAIN:+ --domain $DOMAIN}${EMAIL:+ --email $EMAIL}" listen
          fi
          return 0
          ;;
        *) warn "please answer Y, N or P" ;;
      esac
    done
  fi

  if [ "$STOP_CONFLICTING" = 1 ]; then
    say "port ${addr##*:} is used by: $own; --stop-conflicting will stop that exact holder"
    stop_holder "$addr" "$kind" || conflict_die
    if [ "$DRY_RUN" != 1 ] && [ -z "$R" ]; then
      own=$(port_busy_msg "$svc" "$addr")
      [ -z "$own" ] || conflict_die
    fi
    return 0
  fi
  conflict_die
}

# wiz_eof: the input ended (Ctrl-D, closed terminal or answer file): the
# default is used, but a question that keeps getting no answer (a loop
# whose default is not valid) stops the installer instead of spinning.
# wiz_ask runs in $(...), so the count lives in a file (WIZ_EOF_FILE, made
# by run_wizard) and the stop is a TERM to this installer's own PID.
WIZ_EOF_FILE=""
wiz_eof() {
  ans=""
  [ -n "$WIZ_EOF_FILE" ] && [ -f "$WIZ_EOF_FILE" ] || return 0
  printf 'x' >>"$WIZ_EOF_FILE"
  if [ "$(wc -c <"$WIZ_EOF_FILE")" -gt 20 ]; then
    printf '\nERROR: no more input from the terminal; stopped before any change\n' >&2
    _log "ERROR: wizard input closed"
    rm -f -- "$WIZ_EOF_FILE"
    kill -TERM $$
  fi
}

wiz_ask() { # wiz_ask PROMPT [DEFAULT]
  local prompt=$1 def=${2-} ans=""
  if [ -n "${PAQET_INSTALL_INPUT:-}" ]; then
    printf '%s' "$prompt" >&2
    [ -n "$def" ] && printf ' [%s]' "$def" >&2
    printf ': ' >&2
    IFS= read -r ans <&3 || wiz_eof
  else
    printf '%s' "$prompt" >/dev/tty
    [ -n "$def" ] && printf ' [%s]' "$def" >/dev/tty
    printf ': ' >/dev/tty
    IFS= read -r ans </dev/tty || wiz_eof
  fi
  ans=${ans#"${ans%%[![:space:]]*}"}
  ans=${ans%"${ans##*[![:space:]]}"}
  [ -n "$ans" ] || ans=$def
  _log "ask: $prompt => $ans"
  printf '%s' "$ans"
}

wiz_secret() { # wiz_secret PROMPT: like wiz_ask, typed without echo, never logged
  local prompt=$1 ans=""
  if [ -n "${PAQET_INSTALL_INPUT:-}" ]; then
    printf '%s: ' "$prompt" >&2
    IFS= read -r ans <&3 || wiz_eof
    printf '\n' >&2
  else
    printf '%s: ' "$prompt" >/dev/tty
    IFS= read -rs ans </dev/tty || wiz_eof
    printf '\n' >/dev/tty
  fi
  ans=${ans#"${ans%%[![:space:]]*}"}
  ans=${ans%"${ans##*[![:space:]]}"}
  if [ -n "$ans" ]; then _log "ask: $prompt => (hidden, ${#ans} chars)"; else _log "ask: $prompt => (empty)"; fi
  printf '%s' "$ans"
}

wiz_yn() { # wiz_yn PROMPT DEFAULT(y/n)  -> 0=yes
  local def=$2 ans
  while true; do
    ans=$(wiz_ask "$1" "$def")
    case $ans in
      y | Y | yes | YES) return 0 ;;
      n | N | no | NO) return 1 ;;
      *) warn "please answer y or n" ;;
    esac
  done
}

host_ipv4s() {
  if command -v ip >/dev/null; then
    ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  else
    hostname -I 2>/dev/null | tr ' ' '\n'
  fi
}

domain_points_here() { # domain_points_here NAME  (0 = yes or skipped)
  local name=$1 hip dip match=0
  if [ -n "$R" ]; then
    say "domain DNS check skipped under PAQET_INSTALL_ROOT"
    return 0
  fi
  if ! command -v getent >/dev/null; then
    warn "getent is not available; cannot check whether $name points at this server"
    return 1
  fi
  dip=$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u)
  if [ -z "$dip" ]; then
    warn "$name did not resolve to an IPv4 address"
    return 1
  fi
  hip=$(host_ipv4s | sort -u)
  say "DNS for $name: $(printf '%s' "$dip" | tr '\n' ' ')"
  say "addresses of this server: $(printf '%s' "$hip" | tr '\n' ' ')"
  for a in $dip; do
    for b in $hip; do
      [ "$a" = "$b" ] && match=1
    done
  done
  [ "$match" = 1 ]
}

wizard_preflight() {
  local ok=1 kb
  step "preflight" "checking systemd, disk, and network"
  if [ -n "$R" ]; then
    say "systemd: skipped under PAQET_INSTALL_ROOT (test)"
  elif [ -d /run/systemd/system ]; then
    say "systemd: ok"
  else
    warn "systemd does not appear to be running (/run/systemd/system is missing)"
    ok=0
  fi
  kb=$(df -Pk "${R:-/}" 2>/dev/null | awk 'NR==2 { print $4 }')
  if [ -n "$kb" ] && [ "$kb" -lt 102400 ]; then
    warn "only ${kb} KiB free on ${R:-/} (want at least 100 MiB)"
    ok=0
  elif [ -n "$kb" ]; then
    say "disk space: $((kb / 1024)) MiB free"
  fi
  if [ -n "$FROM_DIR" ]; then
    say "network: offline install (--from $FROM_DIR)"
  elif [ -n "$R" ]; then
    say "network: skipped under PAQET_INSTALL_ROOT (test)"
  else
    if curl -fsSI --max-time 8 --proto '=https,http' "$API" >/dev/null 2>&1; then
      say "GitHub/API reachable: $API"
    else
      warn "cannot reach $API (needed unless you pass --from DIR)"
      ok=0
    fi
  fi
  if [ "$DRY_RUN" != 1 ]; then
    check_prereqs
    if [ -z "$PREREQ_MISSING" ]; then
      say "prerequisites: ok"
    elif [ -n "$PREREQ_PKGS" ]; then
      say "missing on this server: $PREREQ_MISSING"
      if wiz_yn "Install the missing packages ($PREREQ_PKGS) with $PKG_MGR (after the summary)?" "y"; then
        PREREQ_OK=y
      else
        PREREQ_OK=n
      fi
    else
      warn "missing on this server: $PREREQ_MISSING (no supported package manager found; install them yourself)"
    fi
  fi
  [ "$ok" = 1 ] && return 0
  if wiz_yn "A preflight check failed. Continue anyway?" "n"; then
    return 0
  fi
  die "aborted at preflight"
}

run_wizard() {
  local ans mode def_mode
  setup_ui
  if [ -n "${PAQET_INSTALL_INPUT:-}" ]; then
    exec 3<"$PAQET_INSTALL_INPUT" || die "cannot read PAQET_INSTALL_INPUT=$PAQET_INSTALL_INPUT"
  elif ! has_tty; then
    die "--interactive needs a terminal (or was piped without /dev/tty). Re-run in a terminal: $(rerun_cmd)
  Without a terminal, give the role and flags instead: $(rerun_cmd -s) panel|node [options] (see --help)."
  fi
  WIZ_EOF_FILE=$(mktemp)
  printf '%s\n' "${C1}${C2}paqet installer — step-by-step wizard${C0}" >&2
  [ -n "$LOG_FILE" ] && printf 'Log: %s\n' "$LOG_FILE" >&2
  wizard_preflight

  step 1 "role"
  if [ -z "$PROGRAM" ]; then
    while true; do
      ans=$(wiz_ask "Install the panel or a node agent? (panel/node)" "panel")
      case $ans in
        panel | node)
          PROGRAM=$ans
          break
          ;;
        *) warn "please answer panel or node" ;;
      esac
    done
  else
    say "role: $PROGRAM (from the command line)"
  fi

  local keep_cfg=0 cur_listen="" cur_tls=""
  if [ "$PROGRAM" = panel ] && [ -f "$ETC/paqet-panel/panel.yaml" ] &&
    [ -z "$DOMAIN" ] && [ -z "$PORT" ] && [ -z "$LISTEN" ]; then
    # v0.7.43: an upgrade through the wizard keeps the address and TLS of
    # the existing panel unless the operator wants to change them.
    cur_listen=$(sed -n 's/^listen: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$ETC/paqet-panel/panel.yaml" | head -n 1)
    cur_tls=$(sed -n 's/^ *domains: *\[ *"\([^"]*\)".*/\1/p' "$ETC/paqet-panel/panel.yaml" | head -n 1)
    [ -n "$cur_tls" ] || ! grep -q '^ *cert_file:' "$ETC/paqet-panel/panel.yaml" || cur_tls="certificate files"
    say "existing panel found: listen ${cur_listen:-?}, TLS ${cur_tls:-none}"
    if wiz_yn "Keep its current address and TLS settings (only upgrade)?" "y"; then
      keep_cfg=1
    fi
  elif [ "$PROGRAM" = node ] && [ -z "$NODE_LISTEN" ] &&
    { [ -f "$UNIT_DIR/paqet-node.service" ] || [ -f "$ETC/paqet-node/listen" ]; }; then
    cur_listen=$(unit_arg "$UNIT_DIR/paqet-node.service" --listen)
    [ -n "$cur_listen" ] || cur_listen=$(head -n 1 "$ETC/paqet-node/listen" 2>/dev/null || true)
    if [ -n "$cur_listen" ]; then
      say "existing node agent found: listen $cur_listen"
      if wiz_yn "Keep its current listen address $cur_listen?" "y"; then
        keep_cfg=1
      fi
    fi
  fi

  if [ "$PROGRAM" = panel ] && [ "$keep_cfg" = 1 ]; then
    say "keeping the panel's address and TLS settings"
  elif [ "$PROGRAM" = panel ]; then
    step 2 "domain and TLS"
    if [ -z "$DOMAIN" ]; then
      if wiz_yn "Serve the panel with a domain name and HTTPS?" "n"; then
        while true; do
          DOMAIN=$(wiz_ask "Domain name" "")
          [[ $DOMAIN =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
          warn "domain must be a DNS name (example: panel.example.com)"
        done
      fi
    else
      say "domain: $DOMAIN (from the command line)"
    fi
    if [ -n "$DOMAIN" ]; then
      if domain_points_here "$DOMAIN"; then
        say "$DOMAIN points at this server"
      else
        warn "$DOMAIN does not resolve to an IPv4 address of this server (Let's Encrypt will fail until it does)"
        wiz_yn "Continue anyway?" "n" || die "aborted: domain $DOMAIN does not point at this server"
      fi
      if [ -f "$R/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && [ -f "$R/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
        say "found a certbot certificate in /etc/letsencrypt/live/$DOMAIN/"
        def_mode=3
      else
        def_mode=1
      fi
      if [ -z "$PORT" ] && [ -z "$LISTEN" ]; then
        printf '  TLS mode:\n    1) listen on 443, certificate via TLS-ALPN-01 (no port 80)  [default]\n    2) listen on another port, certificate via HTTP-01 on port 80\n    3) use an existing certificate in /etc/letsencrypt/live/%s/\n' "$DOMAIN" >&2
        while true; do
          mode=$(wiz_ask "TLS mode" "$def_mode")
          case $mode in
            1)
              PORT=443
              break
              ;;
            2)
              while true; do
                PORT=$(wiz_ask "Panel HTTPS port" "8880")
                if ! [[ $PORT =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                  warn "port must be 1-65535"
                  continue
                fi
                [ "$PORT" != 80 ] && break
                warn "port 80 is reserved for the HTTP-01 challenge; choose 443 or another port"
              done
              break
              ;;
            3)
              if [ ! -f "$R/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
                warn "no certificate in $R/etc/letsencrypt/live/$DOMAIN/"
                continue
              fi
              PORT=$(wiz_ask "Panel HTTPS port" "443")
              break
              ;;
            *) warn "please choose 1, 2 or 3" ;;
          esac
        done
      fi
      if [ -z "$EMAIL" ] && [ ! -f "$R/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        while true; do
          EMAIL=$(wiz_ask "E-mail for Let's Encrypt" "")
          [[ $EMAIL == *@*.* ]] && break
          warn "a valid e-mail address is required for the built-in ACME client"
        done
      fi
    else
      step 3 "listen address"
      if [ -z "$LISTEN" ] && [ -z "$PORT" ]; then
        if wiz_yn "Listen on a public port (0.0.0.0)?" "n"; then
          PORT=$(wiz_ask "Panel port" "8480")
        else
          LISTEN=$(wiz_ask "Listen address" "127.0.0.1:8480")
        fi
      fi
    fi
  else
    step 2 "node options"
    if [ -z "$TOKEN" ]; then
      while true; do
        TOKEN=$(wiz_secret "Join token from the panel (pqn1.…, hidden while typing; empty if already enrolled)")
        [ -z "$TOKEN" ] || [[ $TOKEN =~ ^pq[nk]1\.[A-Za-z0-9._-]+$ ]] && break
        warn "that does not look like a join token (it starts with pqn1.); paste it again"
      done
      [ -z "$TOKEN" ] || say "join token received (${#TOKEN} characters)"
    fi
    if [ -z "$NODE_LISTEN" ] && [ "$keep_cfg" != 1 ]; then
      while true; do
        NODE_LISTEN=$(wiz_ask "Agent listen address" "0.0.0.0:9443")
        [[ $NODE_LISTEN =~ ^[][A-Za-z0-9.:-]*:[0-9]{1,5}$ ]] && break
        warn "listen address must be HOST:PORT (example: 0.0.0.0:9443)"
      done
    fi
  fi

  if [ -z "$FROM_DIR" ] && [ "$REPO_SET" = 0 ]; then
    step "repo" "release source"
    local def_repo=${REPO:-$DEFAULT_REPO}
    while true; do
      REPO=$(wiz_ask "GitHub repository with the release (Enter keeps it)" "$def_repo")
      [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && break
      warn "repository must be OWNER/NAME (example: $DEFAULT_REPO)"
    done
  fi

  step "summary" "review and confirm"
  printf '%s------------ summary ------------%s\n' "$C1" "$C0" >&2
  printf '  role:           %s\n' "$PROGRAM" >&2
  if [ "$PROGRAM" = panel ]; then
    printf '  domain:         %s\n' "${DOMAIN:-none}" >&2
    printf '  email:          %s\n' "${EMAIL:-none}" >&2
    if [ "$keep_cfg" = 1 ]; then
      printf '  port/listen:    keep current (%s, TLS %s)\n' "${cur_listen:-?}" "${cur_tls:-none}" >&2
    else
      printf '  port/listen:    %s\n' "${LISTEN:-${PORT:+0.0.0.0:$PORT}}" >&2
    fi
  else
    if [ -n "$TOKEN" ]; then
      printf '  token:          %s…\n' "${TOKEN%%.*}" >&2
    else
      printf '  token:          (none)\n' >&2
    fi
    if [ "$keep_cfg" = 1 ]; then
      printf '  node-listen:    keep current (%s)\n' "$cur_listen" >&2
    else
      printf '  node-listen:    %s\n' "${NODE_LISTEN:-0.0.0.0:9443}" >&2
    fi
  fi
  printf '  repo:           %s\n' "${REPO:-none}" >&2
  printf '  version:        %s\n' "${TAG:-latest}" >&2
  printf '  core-repo:      %s\n' "${CORE_REPO:-none}" >&2
  printf '  from:           %s\n' "${FROM_DIR:-github}" >&2
  if [ -n "$PREREQ_PKGS" ]; then
    if [ "$PREREQ_OK" = y ]; then printf '  packages:       install %s\n' "$PREREQ_PKGS" >&2; else printf '  packages:       missing %s (not installing)\n' "$PREREQ_PKGS" >&2; fi
  fi
  printf '  dry-run:        %s\n' "$DRY_RUN" >&2
  printf '  log:            %s\n' "${LOG_FILE:-none}" >&2
  printf '%s---------------------------------%s\n' "$C1" "$C0" >&2
  wiz_yn "Proceed with the install?" "y" || die "aborted by the operator"
  rm -f -- "$WIZ_EOF_FILE"
  WIZ_EOF_FILE=""
}

maybe_wizard() {
  if [ "$YES" = 1 ]; then
    if [ "$INTERACTIVE" = 1 ]; then
      die "--yes keeps the non-interactive mode; omit --yes to use the wizard, or pass panel|node and the flags"
    fi
    if [ -z "$PROGRAM" ]; then
      die "first argument must be 'panel' or 'node' ( --yes does not start the wizard; see --help )"
    fi
    return 0
  fi
  if [ "$INTERACTIVE" = 1 ]; then
    run_wizard
    return 0
  fi
  if [ -z "$PROGRAM" ]; then
    if has_tty; then
      INTERACTIVE=1
      run_wizard
      return 0
    fi
    die "first argument must be 'panel' or 'node'. For the step-by-step wizard, run the installer in a terminal: $(rerun_cmd)
  Without a terminal, give the role and flags instead: $(rerun_cmd -s) panel|node [options] (see --help)."
  fi
}

parse_args() {
  parse_flags "$@"
  setup_ui
  setup_log "$*"
  maybe_wizard
  validate_args
}


validate_args() {
  local re_repo='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  local re_tag='^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'
  if [ -z "$FROM_DIR" ]; then
    REPO=${REPO:-$DEFAULT_REPO}
    [[ $REPO =~ $re_repo ]] || die "--repo must be OWNER/NAME"
  fi
  [ -z "$REPO" ] || [[ $REPO =~ $re_repo ]] || die "--repo must be OWNER/NAME"
  [ -z "$CORE_REPO" ] || [[ $CORE_REPO =~ $re_repo ]] || die "--core-repo must be OWNER/NAME"
  [ -z "$TAG" ] || [[ $TAG =~ $re_tag ]] || die "invalid --version"
  case $API in
    https://*) ;;
    http://127.0.0.1* | http://localhost*) warn "using a plain-http release mirror on loopback" ;;
    *) die "--api must use https" ;;
  esac
  if [ -n "$PORT" ]; then
    if ! [[ $PORT =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then die "--port must be 1-65535"; fi
    [ -z "$LISTEN" ] || die "use either --port or --listen"
    LISTEN=0.0.0.0:$PORT
  fi
  if [ -n "$DOMAIN" ] || [ -n "$EMAIL" ]; then
    [ "$PROGRAM" = panel ] || die "--domain/--email are panel options"
    [[ $DOMAIN =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "--domain must be a DNS name"
    if [ -f "$R/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && [ -f "$R/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
      CERT_DIR=$R/etc/letsencrypt/live/$DOMAIN # existing certbot cert: any port
    else
      [[ $EMAIL == *@*.* ]] || die "--email is required with --domain when no certificate exists in /etc/letsencrypt/live/$DOMAIN (built-in Let's Encrypt)"
      if [ -n "$LISTEN" ] && [[ $LISTEN != *:443 ]]; then
        # v0.7.37: HTTPS on another port; the certificate comes via HTTP-01
        # on port 80 (the panel answers only the challenge there).
        [[ $LISTEN != *:80 ]] || die "--domain cannot serve the panel on port 80 (port 80 answers the Let's Encrypt HTTP-01 challenge); use --port 443 or another port"
        ACME_HTTP=1
      fi
    fi
    LISTEN=${LISTEN:-0.0.0.0:443}
  fi
  if [ -n "$ACME_DIR" ]; then
    [[ $ACME_DIR =~ ^https://[A-Za-z0-9.:/_-]+$ ]] || die "PAQET_ACME_DIRECTORY must be an https:// URL"
    if [ -z "$DOMAIN" ] || [ -n "$CERT_DIR" ]; then warn "PAQET_ACME_DIRECTORY is only used with --domain and the built-in ACME client; ignored"; fi
  fi
  LISTEN_SET=0
  [ -z "$LISTEN" ] || LISTEN_SET=1
  LISTEN=${LISTEN:-127.0.0.1:8480}
  NODE_LISTEN_SET=0
  [ -z "$NODE_LISTEN" ] || NODE_LISTEN_SET=1
  NODE_LISTEN=${NODE_LISTEN:-0.0.0.0:9443}
  local re_addr='^[][A-Za-z0-9.:-]*:[0-9]{1,5}$'
  for v in "$LISTEN" "$NODE_LISTEN"; do
    [[ $v =~ $re_addr ]] || die "invalid listen address: $v"
    local p=$((10#${v##*:}))
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then die "invalid listen address: $v (the port must be 1-65535)"; fi
  done
  if [ -n "$TOKEN" ]; then
    [[ $TOKEN =~ ^pq[nk]1\.[A-Za-z0-9._-]+$ ]] || die "the join token looks malformed"
  fi
  if [ -n "$PUBKEY" ]; then
    [[ $PUBKEY =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "--pubkey must be a base64 ed25519 key"
  fi
}

# detect_arch: release suffix for this host (uname -m → amd64/arm64/armv7/386/riscv64).
detect_arch() {
  case $(uname -m) in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    armv7l | armv7 | armhf) echo armv7 ;;
    i386 | i486 | i586 | i686 | x86) echo 386 ;;
    riscv64) echo riscv64 ;;
    *) return 1 ;;
  esac
}

preflight() {
  [ "$DRY_RUN" = 1 ] || [ -n "$R" ] || [ "$(id -u)" = 0 ] || die "run as root (sudo)"
  [ "$(uname -s)" = Linux ] || die "Linux only"
  command -v systemctl >/dev/null || die "systemd is required"
  ARCH=$(detect_arch) || die "unsupported architecture $(uname -m) (need linux-amd64, linux-arm64, linux-armv7, linux-386 or linux-riscv64)"
  ensure_prereqs
  for c in sha256sum install cmp; do
    command -v "$c" >/dev/null || die "missing tool: $c"
  done
  if [ -z "$FROM_DIR" ]; then
    command -v curl >/dev/null || die "curl is required (or use --from DIR)"
  fi
  if [ -n "$PUBKEY" ]; then
    command -v openssl >/dev/null || die "openssl (3.x) is required for --pubkey"
  fi
  if [ "$AS_ROOT" = 0 ] && ! polkit_js; then
    warn "polkit with JavaScript rules was not found; the service cannot manage paqet@ units as an unprivileged user."
    say "without polkit the $PROGRAM service runs as root, still sandboxed by systemd (install polkitd and re-run to use an unprivileged user)"
    confirm "Run the $PROGRAM service as root (sandboxed)?" y || die "aborted; install polkit (polkitd) or pass --root"
    AS_ROOT=1
  elif [ "$AS_ROOT" = 0 ] && ! polkit_up; then
    warn "polkit is installed but its service (polkit.service) does not run; the service cannot manage paqet@ units as an unprivileged user."
    say "so the $PROGRAM service runs as root, still sandboxed by systemd (see: systemctl status polkit; fix it and re-run to use an unprivileged user)"
    confirm "Run the $PROGRAM service as root (sandboxed)?" y || die "aborted; install polkit (polkitd) or pass --root"
    AS_ROOT=1
  fi
}

# --- prerequisites (v0.7.44) -----------------------------------------------
# missing_prereqs: prints "TOOL" words for what this host lacks: curl,
# certs, tar, xz (GitHub release archives), sha256sum/install (coreutils),
# cmp (diffutils), libpcap (the paqet core links libpcap.so.0.8) and polkit
# (so the service can run unprivileged; optional).
PKG_MGR=""
PREREQ_MISSING=""
PREREQ_PKGS=""
PREREQ_OK="" # y = install them, n = do not (wizard answer); empty = ask later
have_libpcap() {
  if command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -Eq 'libpcap\.so\.(0\.8|1)[[:space:]]'; then
    return 0
  fi
  local d
  for d in /lib /usr/lib /lib64 /usr/lib64 /lib/*-linux-gnu* /usr/lib/*-linux-gnu*; do
    [ -e "$d/libpcap.so.0.8" ] || [ -e "$d/libpcap.so.1" ] && return 0
  done
  return 1
}
missing_prereqs() {
  local m=""
  [ -n "$FROM_DIR" ] || command -v curl >/dev/null || m="$m curl"
  [ -n "$FROM_DIR" ] || [ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ] || [ -e /etc/ssl/cert.pem ] || m="$m certs"
  command -v tar >/dev/null || m="$m tar"
  [ -n "$FROM_DIR" ] || command -v xz >/dev/null || m="$m xz"
  { command -v sha256sum >/dev/null && command -v install >/dev/null; } || m="$m coreutils"
  command -v cmp >/dev/null || m="$m cmp"
  have_libpcap || m="$m libpcap"
  # polkit only on a fresh install: an upgrade keeps the service user it has
  if [ "$AS_ROOT" != 1 ] && ! polkit_js && [ ! -f "$UNIT_DIR/paqet-panel.service" ] && [ ! -f "$UNIT_DIR/paqet-node.service" ]; then
    m="$m polkit"
  fi
  printf '%s' "${m# }"
}
detect_pkg_mgr() {
  local c
  for c in apt-get dnf yum zypper pacman apk; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}
apt_has() { # (no grep -q: under pipefail an early exit would fail the pipe)
  [ -n "$(apt-cache show "$1" 2>/dev/null | sed -n 's/^Package: //p')" ]
}
# prereq_pkgs MGR TOOLS: package names for this package manager
# shellcheck disable=SC2086,SC2048 # package lists are split on purpose
prereq_pkgs() {
  local mgr=$1 t out=""
  shift
  for t in $*; do
    case $mgr:$t in
      *:curl) out="$out curl" ;;
      *:certs) out="$out ca-certificates" ;;
      *:tar) out="$out tar" ;;
      apt-get:xz) out="$out xz-utils" ;;
      *:xz) out="$out xz" ;;
      *:coreutils) out="$out coreutils" ;;
      *:cmp) out="$out diffutils" ;;
      apt-get:libpcap)
        if apt_has libpcap0.8t64; then out="$out libpcap0.8t64"; else out="$out libpcap0.8"; fi ;;
      zypper:libpcap) out="$out libpcap1" ;;
      *:libpcap) out="$out libpcap" ;;
      apt-get:polkit) ! apt_has polkitd || out="$out polkitd" ;;
      apk:polkit) ;;
      *:polkit) out="$out polkit" ;;
    esac
  done
  printf '%s' "${out# }"
}
pkg_install_cmd() { # pkg_install_cmd MGR PKGS...: the command as text
  local mgr=$1
  shift
  case $mgr in
    apt-get) printf 'apt-get install -y --no-install-recommends %s' "$*" ;;
    dnf | yum) printf '%s install -y %s' "$mgr" "$*" ;;
    zypper) printf 'zypper --non-interactive install %s' "$*" ;;
    pacman) printf 'pacman -S --needed --noconfirm %s' "$*" ;;
    apk) printf 'apk add %s' "$*" ;;
  esac
}
# check_prereqs: fills PREREQ_MISSING / PKG_MGR / PREREQ_PKGS (no change)
# shellcheck disable=SC2086,SC2048 # package lists are split on purpose
check_prereqs() {
  PREREQ_MISSING=""
  PREREQ_PKGS=""
  # under PAQET_INSTALL_ROOT (tests) only when PAQET_TEST_PREREQS=1
  [ -z "$R" ] || [ "${PAQET_TEST_PREREQS:-0}" = 1 ] || return 0
  PREREQ_MISSING=$(missing_prereqs)
  PREREQ_PKGS=""
  [ -n "$PREREQ_MISSING" ] || return 0
  PKG_MGR=$(detect_pkg_mgr) || PKG_MGR=""
  if [ "$PKG_MGR" = apt-get ] && [ -z "$R" ] && [ "$DRY_RUN" != 1 ] &&
    { ! apt_has xz-utils || ! apt_has libpcap0.8 && ! apt_has libpcap0.8t64; }; then
    # empty package lists (fresh cloud/container image): refresh them first
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
  fi
  [ -z "$PKG_MGR" ] || PREREQ_PKGS=$(prereq_pkgs "$PKG_MGR" $PREREQ_MISSING)
}
# install_prereqs: install PREREQ_PKGS (after the operator said yes)
# shellcheck disable=SC2086,SC2048 # package lists are split on purpose
install_prereqs() {
  [ -n "$PREREQ_PKGS" ] || return 0
  say "installing prerequisites: $(pkg_install_cmd "$PKG_MGR" $PREREQ_PKGS)"
  if [ -n "$R" ] || [ "$DRY_RUN" = 1 ]; then
    say "(skipped: test root or --dry-run)"
    return 0
  fi
  local rc=0
  case $PKG_MGR in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PREREQ_PKGS >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$? ;;
    dnf | yum) "$PKG_MGR" install -y $PREREQ_PKGS >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$? ;;
    zypper) zypper --non-interactive install $PREREQ_PKGS >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$? ;;
    pacman) pacman -S --needed --noconfirm $PREREQ_PKGS >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$? ;;
    apk) apk add $PREREQ_PKGS >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$? ;;
  esac
  case " $PREREQ_PKGS " in
    *" polkitd "* | *" polkit "*)
      # dbus read its config before the polkitd user existed ("Unknown
      # username polkitd"), so polkitd cannot own its bus name until dbus
      # reloads it; then start polkit once.
      systemctl reload dbus.service >/dev/null 2>&1 || systemctl reload dbus-broker.service >/dev/null 2>&1 || true
      systemctl restart polkit.service >/dev/null 2>&1 || true
      ;;
  esac
  [ "$rc" = 0 ] || die "installing prerequisites failed ($PKG_MGR exit $rc; see the log). Install them yourself and re-run: $(pkg_install_cmd "$PKG_MGR" $PREREQ_PKGS)"
  hash -r
}
# ensure_prereqs: called from preflight; asks (default yes) unless the
# wizard already asked, installs, then fails clearly on what is still missing.
# shellcheck disable=SC2086,SC2048,SC2046 # package lists are split on purpose
ensure_prereqs() {
  [ "$DRY_RUN" != 1 ] || return 0
  check_prereqs
  [ -n "$PREREQ_MISSING" ] || return 0
  local need=${PREREQ_MISSING/polkit/}
  need=$(printf '%s' "$need" | xargs)
  if [ -n "$PREREQ_PKGS" ]; then
    if [ -z "$PREREQ_OK" ]; then
      say "missing on this server: $PREREQ_MISSING"
      if confirm "Install the missing packages ($PREREQ_PKGS) with $PKG_MGR now?" y; then PREREQ_OK=y; else PREREQ_OK=n; fi
    fi
    [ "$PREREQ_OK" != y ] || install_prereqs
  fi
  [ -n "$R" ] && return 0
  local still
  still=$(missing_prereqs)
  still=${still/polkit/}
  still=$(printf '%s' "$still" | xargs)
  if [ -n "$still" ]; then
    if [ -n "$PKG_MGR" ]; then
      die "missing prerequisites: $still. Install them and re-run: $(pkg_install_cmd "$PKG_MGR" $(prereq_pkgs "$PKG_MGR" $still)) (or re-run with --yes to install them automatically)"
    fi
    die "missing prerequisites: $still (no supported package manager found: apt-get, dnf, yum, zypper, pacman, apk). Install them and re-run."
  fi
}

# polkit_up: on a fresh install, polkit.service runs (or starts). An
# upgrade keeps the service user it has, so it is not checked then.
polkit_up() {
  [ -z "$R" ] && [ "$DRY_RUN" != 1 ] || return 0
  [ ! -f "$UNIT_DIR/paqet-panel.service" ] && [ ! -f "$UNIT_DIR/paqet-node.service" ] || return 0
  systemctl is-active --quiet polkit.service 2>/dev/null && return 0
  systemctl start polkit.service >/dev/null 2>&1 || true
  sleep 1
  systemctl is-active --quiet polkit.service 2>/dev/null
}

polkit_js() {
  [ -d "$POLKIT_DIR" ] || [ -d /usr/share/polkit-1/rules.d ] || return 1
  command -v pkaction >/dev/null || return 1
  local v
  v=$(pkaction --version 2>/dev/null | awk '{print $NF}')
  # 0.105 (old Debian/Ubuntu) only knows .pkla files; >= 0.106 has JS rules.
  case $v in
    0.10[0-5]* | 0.[0-9][0-9]) return 1 ;;
  esac
  return 0
}

TMP=""
cleanup() {
  # On failure, put back anything we stopped to free a port. On success
  # INSTALL_OK=1 and the holders stay stopped so the new service can bind;
  # report_stopped_holders prints how to start them again.
  if [ "${INSTALL_OK:-0}" != 1 ]; then
    if declare -F restore_holders >/dev/null 2>&1; then
      restore_holders
    fi
  fi
  [ -z "$TMP" ] || rm -rf -- "$TMP"
}

# fetch_release REPO: download (or copy from --from) the release's
# SHA256SUMS (+ signature) into $TMP/<repo-dir> and echo that dir.
fetch_release() {
  local repo=$1 dir url tag
  dir="$TMP/$(printf '%s' "$repo" | tr '/' '_')"
  mkdir -p "$dir"
  if [ -n "$FROM_DIR" ]; then
    cp -- "$FROM_DIR/SHA256SUMS" "$dir/"
    [ ! -f "$FROM_DIR/SHA256SUMS.sig" ] || cp -- "$FROM_DIR/SHA256SUMS.sig" "$dir/"
  else
    if [ -n "$TAG" ]; then
      url="$API/repos/$repo/releases/tags/$TAG"
    else
      url="$API/repos/$repo/releases/latest"
    fi
    curl -fsSL --proto '=https,http' -H 'Accept: application/json' -o "$dir/release.json" "$url" ||
      die "cannot read release info from $url"
    tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/release.json" | head -n 1)
    [ -n "$tag" ] || die "no release found in $repo"
    printf '%s\n' "$tag" >"$dir/TAG"
    download_asset "$dir" SHA256SUMS
    download_asset "$dir" SHA256SUMS.sig optional
  fi
  verify_signature "$dir"
  maybe_unpack_arch_tarball "$dir"
  printf '%s\n' "$dir"
}

# maybe_unpack_arch_tarball DIR: GitHub releases since v0.7.34 ship one
# paqet-release-TAG-linux-ARCH.tar.xz per architecture (plus SHA256SUMS),
# not the loose paqet-panel-linux-ARCH files get_binary expects. Download
# that tarball, check it against SHA256SUMS, and extract it into DIR so
# the inner SHA256SUMS and binaries are ready. No-op for --from or when
# the loose binaries are already present (older release layout).
maybe_unpack_arch_tarball() {
  local dir=$1 name inner tmpd
  [ -z "$FROM_DIR" ] || return 0
  [ -f "$dir/SHA256SUMS" ] || return 0
  if [ -f "$dir/paqet-panel-linux-$ARCH" ] || [ -f "$dir/paqet-node-linux-$ARCH" ]; then
    return 0
  fi
  name=$(awk -v a="$ARCH" '{
    n = $2; sub(/^\*/, "", n)
    if (n ~ ("^paqet-release-.*-linux-" a "\\.tar\\.xz$")) { print n; exit }
  }' "$dir/SHA256SUMS")
  [ -n "$name" ] || return 0
  command -v tar >/dev/null || die "tar is required to unpack $name"
  download_asset "$dir" "$name"
  (cd "$dir" && grep -E "^[0-9a-f]{64}[[:space:]]+\*?$name\$" SHA256SUMS | sha256sum -c --status -) ||
    die "checksum mismatch (or no SHA256SUMS entry) for $name"
  say "verified $name"
  tmpd="$dir/unpack.$$"
  mkdir -p "$tmpd"
  tar -xJf "$dir/$name" -C "$tmpd" || die "cannot extract $name"
  inner=$(dirname "$(find "$tmpd" -type f \( -name "paqet-panel-linux-$ARCH" -o -name "paqet-node-linux-$ARCH" \) | head -n 1)")
  [ -n "$inner" ] && [ "$inner" != "." ] || die "$name does not contain paqet-panel-linux-$ARCH or paqet-node-linux-$ARCH"
  cp -a "$dir/SHA256SUMS" "$dir/SHA256SUMS.release"
  cp -a "$inner"/. "$dir/"
  rm -rf "$tmpd"
}

download_asset() {
  local dir=$1 name=$2 optional=${3:-} url
  url=$(grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*/'"$name"'"' "$dir/release.json" |
    sed 's/.*"\(http[^"]*\)"$/\1/' | head -n 1 || true)
  if [ -z "$url" ]; then
    [ -n "$optional" ] && return 0
    die "release has no asset $name"
  fi
  curl -fsSL --proto '=https,http' -o "$dir/$name" "$url" || die "download failed: $url"
}

verify_signature() {
  local dir=$1
  [ -n "$PUBKEY" ] || return 0
  [ -f "$dir/SHA256SUMS.sig" ] || die "--pubkey was given but this release is not signed (no SHA256SUMS.sig). The published releases are not signed: run again without --pubkey (SHA256SUMS is still checked), or use it only with releases you sign yourself"
  # Wrap the raw ed25519 key in SubjectPublicKeyInfo DER for openssl.
  {
    printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
    printf '%s' "$PUBKEY" | base64 -d
  } >"$dir/pub.der"
  base64 -d "$dir/SHA256SUMS.sig" >"$dir/sig.bin" 2>/dev/null || cp "$dir/SHA256SUMS.sig" "$dir/sig.bin"
  openssl pkeyutl -verify -pubin -keyform DER -inkey "$dir/pub.der" -rawin \
    -in "$dir/SHA256SUMS" -sigfile "$dir/sig.bin" >/dev/null 2>&1 ||
    die "SHA256SUMS signature verification FAILED"
  say "SHA256SUMS signature OK"
}

# get_binary DIR NAME: download/copy NAME next to SHA256SUMS and verify it.
get_binary() {
  local dir=$1 name=$2
  if [ -n "$FROM_DIR" ]; then
    cp -- "$FROM_DIR/$name" "$dir/$name" || die "$FROM_DIR/$name not found"
  elif [ ! -f "$dir/$name" ]; then
    # Already extracted from paqet-release-*-linux-$ARCH.tar.xz when the
    # GitHub release ships archives instead of loose binaries.
    download_asset "$dir" "$name"
  fi
  (cd "$dir" && grep -E "^[0-9a-f]{64}[[:space:]]+\*?$name\$" SHA256SUMS | sha256sum -c --status -) ||
    die "checksum mismatch (or no SHA256SUMS entry) for $name"
  say "verified $name"
}

ensure_user() {
  local user=$1 group=${2:-}
  if ! getent group "${group:-$user}" >/dev/null; then
    run groupadd --system "${group:-$user}"
  fi
  if ! id -u "$user" >/dev/null 2>&1; then
    run useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin -g "${group:-$user}" "$user"
  fi
}

# install_bin SRC DEST OWNER [DIROWNER]: atomic replace, keeping DEST.prev.
# DIROWNER (default OWNER) owns the directory; self-updating services need
# to own their bin dir to swap the binary in.
install_bin() {
  local src=$1 dest=$2 owner=$3 dirowner=${4:-$3}
  run install -d -m 0755 -o "${dirowner%%:*}" -g "${dirowner##*:}" "$(dirname "$dest")"
  if [ -e "$dest" ] && cmp -s "$src" "$dest"; then
    say "$dest is already this version"
    return 0
  fi
  run install -m 0755 -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dest.new"
  if [ -e "$dest" ]; then
    run ln -f "$dest" "$dest.prev"
  fi
  run mv -f "$dest.new" "$dest"
}

service_exists() { [ -f "$UNIT_DIR/$1.service" ]; }

# port_owner ADDR: prints the process listening on ADDR's port (empty = free).
port_owner() {
  local port=${1##*:}
  command -v ss >/dev/null || return 0
  ss -Hltnp "sport = :$port" 2>/dev/null | grep -o 'users:(([^)]*' | head -n 1 | sed 's/users:((//' || true
}

free_port() {
  local p
  for p in 8443 8880 2053 2083 2087 2096 9080 18480; do
    [ -n "$(ss -Hltn "sport = :$p" 2>/dev/null)" ] || { echo "$p"; return; }
  done
}

# low_port ADDR: true when ADDR's port is below 1024 (needs CAP_NET_BIND_SERVICE).
low_port() {
  local p=${1##*:}
  [[ $p =~ ^[0-9]{1,5}$ ]] && [ "$((10#$p))" -lt 1024 ]
}

# port_busy_msg SVC ADDR: prints who owns ADDR's port when it is not SVC
# itself (empty = free or ours).
port_busy_msg() {
  local svc=$1 addr=$2 own
  own=$(port_owner "$addr")
  [ -n "$own" ] || return 0
  case $own in *"\"$svc\""* | *"\"paqet-panel\""*) return 0 ;; esac
  describe_from_own "$own"
}

# rerun_cmd [-s]: how the user started this installer, for "re-run with"
# hints (PAQET_BOOTSTRAP_CMD overrides it). A script piped from curl has no
# file to re-run, so the hint is the same curl one-liner; -s adds the
# "bash -s --" that options need after a pipe.
rerun_cmd() {
  local c=${PAQET_BOOTSTRAP_CMD:-} src=${BASH_SOURCE[0]:-} url
  [[ $c =~ ^[A-Za-z0-9\ ./:|_-]+$ ]] || c=""
  if [ -n "$c" ]; then
    printf '%s' "$c"
  elif [ -n "$src" ] && [ -f "$src" ]; then
    [[ $src =~ ^[A-Za-z0-9./_-]+$ ]] || src=install.sh
    printf 'sudo bash %s' "$src"
  else
    url="https://github.com/${REPO:-$DEFAULT_REPO}/releases/latest/download/install.sh"
    [ -z "$TAG" ] || url="https://github.com/${REPO:-$DEFAULT_REPO}/releases/download/$TAG/install.sh"
    if [ "${1:-}" = -s ]; then
      printf 'curl -fsSL %s | sudo bash -s --' "$url"
    else
      printf 'curl -fsSL %s | sudo bash' "$url"
    fi
  fi
}

# precheck_port SVC ADDR HINT: before anything is changed, refuse when another
# program owns the port the service is going to listen on (a running
# service, its unit and its config stay exactly as they are).
precheck_port() {
  handle_port_conflict "$1" "$2" "$3" listen
}

# check_port SVC ADDR: last check right before (re)starting SVC. A fresh,
# not yet running service is disabled so it cannot crash-loop; a running
# one is never stopped here.
check_port() {
  local svc=$1 addr=$2 own
  own=$(port_busy_msg "$svc" "$addr")
  [ -n "$own" ] || return 0
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    die "port ${addr##*:} is already used by: $own
  $svc was left running as it is."
  fi
  run systemctl disable "$svc" >/dev/null 2>&1 || true
  die "port ${addr##*:} is already used by: $own
  $svc was not started (it would crash-loop). Re-run with a free port, e.g.:
    $(rerun_cmd -s) panel --port $(free_port)${DOMAIN:+ --domain $DOMAIN}${EMAIL:+ --email $EMAIL}"
}

start_or_restart() {
  local svc=$1
  run systemctl daemon-reload
  if [ "$NO_START" = 1 ]; then
    say "not starting $svc (--no-start)"
    if [ "$DRY_RUN" != 1 ] && systemctl is-active --quiet "$svc"; then
      warn "$svc is still running with the old version and settings until you restart it: systemctl restart $svc"
    fi
    return 0
  fi
  if systemctl is-active --quiet "$svc"; then
    if confirm "Restart the running $svc now to use the new version?" y; then
      run systemctl restart "$svc"
    else
      warn "$svc keeps running the old version until you restart it"
    fi
  else
    run systemctl enable --now "$svc"
  fi
}

install_core() {
  [ -n "$CORE_REPO" ] || [ -n "$FROM_DIR" ] || return 0
  local dir name=paqet-linux-$ARCH
  if [ -n "$FROM_DIR" ] && [ ! -f "$FROM_DIR/$name" ]; then
    return 0
  fi
  dir=$(fetch_release "${CORE_REPO:-local/core}")
  get_binary "$dir" "$name"
  if [ -e "$CORE_BIN" ] && ! cmp -s "$dir/$name" "$CORE_BIN"; then
    confirm "Replace the installed paqet core $CORE_BIN? (running tunnels keep the old one until restarted)" || return 0
  fi
  install_bin "$dir/$name" "$CORE_BIN" "$SVC_USER:$TUNNEL_USER"
}

# write_tunnel_units CMD...: the sandboxed <core>@.service template of every
# core (paqet, gost2, gost3), printed by the program itself (CMD -core <id>)
# so it matches what the panel/agent expects byte for byte. Each runs
# <versions_dir>/<core>/links/%i, the per-tunnel link to its selected version.
write_tunnel_units() {
  local c
  for c in $CORES; do
    if [ "$DRY_RUN" = 1 ]; then
      say "would write $UNIT_DIR/$c@.service"
      continue
    fi
    "$@" -core "$c" >"$TMP/$c@.service"
    put_file "$UNIT_DIR/$c@.service" 0644 root:root "$TMP/$c@.service"
  done
}

# make_core_dirs: tunnel config dirs of every core and the versions dir.
make_core_dirs() {
  local d
  for d in "$TUNNEL_CONF" "$GOST2_CONF" "$GOST3_CONF"; do
    run install -d -m 2750 -o "$SVC_USER" -g "$TUNNEL_USER" "$d"
  done
  run install -d -m 0755 -o "$SVC_USER" -g "$TUNNEL_USER" "$CORE_DIR"
  run install -d -m 0755 -o "$SVC_USER" -g "$TUNNEL_USER" "$VERSIONS_DIR"
  fix_core_perms
}

# fix_core_perms: an existing /opt/paqet tree may have been created 0700 by
# other scripts; the services must traverse it and own the versions state.
fix_core_perms() {
  local d f
  if [ -d "$PREFIX/paqet" ]; then run chmod a+rx "$PREFIX/paqet"; fi
  for d in "$VERSIONS_DIR" "$CORE_DIR"; do
    [ -d "$d" ] || continue
    run chown "$SVC_USER:$TUNNEL_USER" "$d"
    run chmod 0755 "$d"
  done
  if [ -d "$VERSIONS_DIR" ]; then
    for d in "$VERSIONS_DIR"/*/ "$VERSIONS_DIR"/*/*/ "$VERSIONS_DIR"/*/links/; do
      [ -d "$d" ] || continue
      run chown "$SVC_USER:$TUNNEL_USER" "$d"
      run chmod 0755 "$d"
    done
    for f in "$VERSIONS_DIR"/*/state.json; do
      [ -f "$f" ] || continue
      run chown "$SVC_USER:$TUNNEL_USER" "$f"
      run chmod 0644 "$f"
    done
    for f in "$VERSIONS_DIR"/*/*/paqet "$VERSIONS_DIR"/*/*/gost; do
      [ -f "$f" ] || continue
      run chmod a+rx "$f"
    done
  fi
  return 0
}

# write_tunnels_target: paqet-tunnels.target (wanted by multi-user.target)
# and its .wants dir, writable by the services through the paqet-units
# group. Tunnels are enabled by a symlink there, so the services need no
# polkit right to enable/disable arbitrary unit files. Enablements made
# by older versions (multi-user.target.wants) are moved over.
UNITS_GROUP=paqet-units
write_tunnels_target() {
  local wants=$UNIT_DIR/paqet-tunnels.target.wants l
  cat >"$TMP/paqet-tunnels.target" <<'TARGET'
# Installed by install.sh. Tunnel instances are enabled by symlinks in
# paqet-tunnels.target.wants/, managed by paqet-panel / paqet-node.
[Unit]
Description=paqet tunnels

[Install]
WantedBy=multi-user.target
TARGET
  put_file "$UNIT_DIR/paqet-tunnels.target" 0644 root:root "$TMP/paqet-tunnels.target"
  if [ "$AS_ROOT" = 0 ]; then
    getent group "$UNITS_GROUP" >/dev/null || run groupadd --system "$UNITS_GROUP"
    run install -d -m 0775 -o root -g "$UNITS_GROUP" "$wants"
  else
    run install -d -m 0755 -o root -g root "$wants"
  fi
  for l in "$UNIT_DIR"/multi-user.target.wants/paqet@*.service "$UNIT_DIR"/multi-user.target.wants/gost2@*.service "$UNIT_DIR"/multi-user.target.wants/gost3@*.service; do
    [ -L "$l" ] || continue
    run ln -sfn "$(readlink "$l")" "$wants/$(basename "$l")"
    run rm -f -- "$l"
  done
  run systemctl daemon-reload
  run systemctl enable paqet-tunnels.target
}

write_polkit() {
  [ "$AS_ROOT" = 0 ] || return 0
  cat >"$TMP/polkit.rules" <<RULES
// Installed by paqet $PROGRAM install.sh. Lets the $SVC_USER service start,
// stop and restart paqet tunnel units, and only those. Enabling at boot is
// a symlink in paqet-tunnels.target.wants/ (group $UNITS_GROUP), so no
// unit-file or daemon-reload rights are granted.
polkit.addRule(function (action, subject) {
  if (subject.user !== "$SVC_USER") {
    return polkit.Result.NOT_HANDLED;
  }
  if (action.id === "org.freedesktop.systemd1.manage-units") {
    var unit = action.lookup("unit") || "";
    var verb = action.lookup("verb") || "";
    // paqet-<name>.service: tunnels made by paqet-manager, managed like
    // the panel's own (never the panel/node services themselves).
    var tunnel = /^(paqet|gost2|gost3)@[A-Za-z0-9][A-Za-z0-9_-]{0,31}\.service\$/.test(unit) ||
      (/^paqet-[a-z0-9][a-z0-9_-]{0,31}\.service\$/.test(unit) &&
       !/^paqet-(panel|node|tunnels)([-.]|\.service\$)/.test(unit));
    if (tunnel && ["start", "stop", "restart"].indexOf(verb) >= 0) {
      return polkit.Result.YES;
    }
  }
  return polkit.Result.NOT_HANDLED;
});
RULES
  run install -d -m 0755 "$POLKIT_DIR"
  put_file "$POLKIT_DIR/50-paqet-$PROGRAM.rules" 0644 root:root "$TMP/polkit.rules"
}

# unit_sandbox: hardening shared by the panel and node services.
unit_sandbox() {
  cat <<SANDBOX
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077
SANDBOX
}

user_lines() {
  if [ "$AS_ROOT" = 1 ]; then
    printf '# Runs as root (--root): no polkit available.\n'
    printf 'ReadWritePaths=%s\n' "$UNIT_DIR"
    printf 'CapabilityBoundingSet=CAP_CHOWN CAP_FOWNER CAP_DAC_OVERRIDE CAP_KILL CAP_NET_BIND_SERVICE\n'
  else
    printf 'User=%s\nGroup=%s\nSupplementaryGroups=systemd-journal %s %s%s\n' "$SVC_USER" "$SVC_USER" "$TUNNEL_USER" "$UNITS_GROUP" "$(getent group paqet-proxy >/dev/null && echo ' paqet-proxy')"
    if [ "${NEED_BIND:-0}" = 1 ]; then
      printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n'
    else
      printf 'CapabilityBoundingSet=\n'
    fi
  fi
}

# rw_paths DATA BINDIR: ReadWritePaths of the service. Every dir is created
# first, and the optional ones carry "-" so a missing dir can never fail
# the service with 226/NAMESPACE.
rw_paths() {
  local d
  for d in "$TUNNEL_CONF" "$GOST2_CONF" "$GOST3_CONF" "$CORE_DIR" "$VERSIONS_DIR"; do
    [ -d "$d" ] || run install -d -m 0755 -o "$SVC_USER" -g "$TUNNEL_USER" "$d"
  done
  # Root-owned and sticky (3770): the panel adds and removes its own request
  # files; the root helper's results cannot be replaced by it (audit F1).
  if [ -d "$R/var/lib/paqet-spool" ] && [ ! -L "$R/var/lib/paqet-spool" ]; then
    run chmod 3770 "$R/var/lib/paqet-spool"
  else
    run install -d -m 3770 -o root -g "$SVC_USER" "$R/var/lib/paqet-spool"
  fi
  printf 'ReadWritePaths=%s %s -%s -%s -%s -%s -%s -%s -%s\n' "$1" "$2" "$TUNNEL_CONF" "$GOST2_CONF" "$GOST3_CONF" "$CORE_DIR" "$VERSIONS_DIR" "$UNIT_DIR/paqet-tunnels.target.wants" "$R/var/lib/paqet-spool"
}

# detect_core [PANEL_YAML]: the paqet core the tunnels use. An existing
# panel.yaml value is kept while it exists; otherwise the panel's own core
# (/opt/paqet/bin/paqet), otherwise the one on PATH (e.g. /usr/local/bin/paqet
# installed by paqet-manager).
detect_core() {
  local cfg=${1:-} cur=""
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    cur=$(awk '/^  paqet:/{p=1;next} /^  [a-z0-9]+:/{p=0} p && /^    binary:/{sub(/^    binary: */,""); gsub(/"/,""); print; exit}' "$cfg")
  fi
  if [ -n "$cur" ] && [ -x "$cur" ]; then
    CORE_BIN=$cur
  elif [ -x "$CORE_BIN" ]; then
    :
  elif [ -z "$CORE_REPO" ] && command -v paqet >/dev/null; then
    CORE_BIN=$(command -v paqet)
    say "using the paqet core found on PATH: $CORE_BIN"
  fi
  CORE_CUR=$cur
}

# unit_arg UNIT FLAG: the word after FLAG on the unit's ExecStart= line
# (v0.7.23: a re-install keeps what the existing unit uses).
unit_arg() {
  [ -f "$1" ] || return 0
  awk -v f="$2" '/^ExecStart=/{for (i = 1; i < NF; i++) if ($i == f) {print $(i + 1); exit}}' "$1"
}

# write_helper: a tiny root service (no network, fixed script) that keeps
# paqet-manager-made tunnels manageable without restarting them:
#  - /etc/paqet and its *.yaml readable by the panel (group, 0640), since
#    paqet-manager resets them to 0700/0600;
#  - moves their boot enablement (multi-user.target.wants/paqet-<name>.service)
#    into paqet-tunnels.target.wants, where the panel enables/disables;
#  - removes the unit file of a tunnel deleted in the panel (marker in
#    /etc/paqet/.deleted/<name>), only for the paqet-manager pattern.
write_helper() {
  local h=$R/usr/local/libexec/paqet-panel-helper
  cat >"$TMP/helper" <<'HELPER'
#!/bin/sh
# Installed by paqet-panel install.sh. Runs as root via paqet-panel-helper.service.
#
# Every directory this helper works in (config dirs, .ops, .deleted, the
# spool) can be written by the unprivileged panel/node user, so no name in
# them is trusted (v0.7.9, audit F1):
#  - files are never written, chmod'ed or chown'ed by a name the panel
#    controls. New files are built in a fresh root-only directory created
#    inside the target directory ("stage", entered with cd, its parent
#    checked by device:inode) and moved into place with rename(2), which
#    replaces a planted symlink instead of writing through it;
#  - permission fixes on existing files go through a hard link in the stage
#    (never through a symlink, single-link files only) and use chgrp/chown -h;
#  - panel-supplied files (.req, .data, .keep) are read with the panel
#    user's own privileges (setpriv), never as root;
#  - .ops and the spool are root-owned and sticky (3770): the panel can add
#    and remove its own files but not replace the helper's.
# shellcheck disable=SC2329 # the st_* stage commands run through in_stage
set -u
R=${PAQET_INSTALL_ROOT:-}
CONF=$R/etc/paqet
UNITS=$R/etc/systemd/system
WANTS=$UNITS/paqet-tunnels.target.wants
G=${PANEL_GROUP:-paqet-panel}
[ -d "$CONF" ] || exit 0
ME=$(id -u)
GU=$(id -u "$G" 2>/dev/null) || GU=65534
plain_ok() { # plain_ok NAME: paqet-NAME.service runs paqet with CONF/NAME.yaml
  f=$UNITS/paqet-$1.service
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  grep -Eq "^ExecStart=[^ ]*/paqet run -c $CONF/$1\.yaml\$" "$f"
}
valid() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,31}$' && case $1 in panel | node | tunnels | panel-* | node-*) return 1 ;; esac; }
# lid PATH: "dev:inode" of PATH when PATH itself is a real directory
# (lstat: a symlink prints nothing).
lid() { stat -c '%F|%d:%i' -- "$1" 2>/dev/null | sed -n 's/^directory|//p'; }
# asg CMD...: run CMD with the panel user's privileges (reads of files the
# panel supplies; a planted symlink then only reaches what the panel can read).
asg() {
  if [ "$ME" = 0 ] && [ "$GU" != 0 ]; then
    setpriv --reuid="$GU" --regid="$G" --clear-groups -- "$@"
  else
    "$@"
  fi
}
# own FILE OWNER:GROUP: chown without following symlinks; falls back to the
# group alone (tests run unprivileged).
own() { chown -h -- "$2" "$1" 2>/dev/null || chgrp -h -- "${2#*:}" "$1" 2>/dev/null || [ "$ME" != 0 ]; }
# in_stage DIR CMD...: run CMD (a subshell) with the cwd in a fresh
# root-only dir created inside DIR. DIR must be a real directory and the
# stage's ".." must be exactly that directory, so "../NAME" always names an
# entry of DIR, whatever the panel renames or plants meanwhile.
in_stage() (
  dir=$1
  shift
  id=$(lid "$dir")
  [ -n "$id" ] || exit 1
  sd=$(mktemp -d -- "$dir/.helper.XXXXXX") || exit 1
  if ! cd -P -- "$sd" 2>/dev/null; then
    rmdir -- "$sd" 2>/dev/null
    exit 1
  fi
  case $(stat -c '%u:%a' .) in "$ME:700" | "$ME:2700") ;; *) false ;; esac &&
    [ "$(stat -c '%d:%i' ..)" = "$id" ] || {
    cd / && rmdir -- "$sd" 2>/dev/null
    exit 1
  }
  "$@"
  rc=$?
  rm -f -- ./f ./m
  cd .. && rmdir -- "./${sd##*/}" 2>/dev/null
  exit $rc
)
# --- stage commands (cwd = stage, ".." = target dir) ---
# st_put NAME MODE OWNER:GROUP: stdin -> ../NAME, atomic.
st_put() { cat >f && chmod "$2" f && own f "$3" && mv -fT -- f "../$1"; }
# st_meta NAME GROUP: ../NAME (regular file, one link, not a symlink) gets
# GROUP when it is root's, and g+r when it is 600/6[0-3]0.
st_meta() {
  ln -P -- "../$1" m 2>/dev/null && [ -f m ] && [ ! -L m ] && [ "$(stat -c %h m)" = 2 ] || return 1
  if [ "$(stat -c %G m)" = root ]; then chgrp -h -- "$2" m || return 1; fi
  case $(stat -c %a m) in 6[0-3]0) chmod g+r,o-rwx m ;; esac
}
# st_own NAME OWNER:GROUP: hand a helper-written file to the panel (so it can
# delete it in the sticky dir).
st_own() { ln -P -- "../$1" m 2>/dev/null && [ -f m ] && [ ! -L m ] && [ "$(stat -c %h m)" = 2 ] && own m "$2"; }
# st_copy SRC NAME MAX OWNER:GROUP: copy SRC (read with the panel's rights)
# into ../NAME when it is at most MAX bytes.
st_copy() {
  asg head -c "$(($3 + 1))" -- "$1" >f && [ "$(stat -c %s f)" -le "$3" ] &&
    chmod 0640 f && own f "$4" && mv -fT -- f "../$2"
}
# st_view SRC NAME: root copy of an external unit's config, opened with
# O_NOFOLLOW (the path was checked to contain no symlink).
st_view() {
  dd if="$1" iflag=nofollow bs=65536 count=5 of=f 2>/dev/null && [ "$(stat -c %s f)" -le 262144 ] &&
    chmod 0640 f && own f "$G:$G" && mv -fT -- f "../$2"
}
# res DIR NAME TEXT: write a result file, owned by the panel user.
res() { printf '%s\n' "$3" | in_stage "$1" st_put "$2" 0640 "$G:$G"; }
# sticky DIR: root-owned request dirs become 3770 (panel may add/remove its own
# files only); helper-written result files of older versions are handed over
# to the panel so it can still delete them.
sticky() {
  id=$(lid "$1")
  [ -n "$id" ] || return 0
  [ "$(stat -c %u -- "$1")" = "$ME" ] || return 0
  (cd -P -- "$1" 2>/dev/null && [ "$(stat -c %d:%i .)" = "$id" ] && { chgrp -h -- "$G" . 2>/dev/null; chmod 3770 .; }) || true
  for x in "$1"/*.res "$1"/*.view; do
    [ -f "$x" ] && [ ! -L "$x" ] && [ "$(stat -c %u -- "$x")" = "$ME" ] || continue
    in_stage "$1" st_own "${x##*/}" "$G:$G" || true
  done
}
# Tunnel group: the panel/node service is a member (SupplementaryGroups).
TG=paqet
getent group "$TG" >/dev/null 2>&1 || TG=$G
fixdir() { # fixdir DIR: root-only dirs (paqet-manager resets them) get group rwx back
  [ -d "$1" ] && [ ! -L "$1" ] || return 0
  [ "$(stat -c %G "$1")" != root ] || chgrp -h "$TG" "$1"
  case $(stat -c %a "$1") in 7[0-7]0 | 27[0-7]0 | 2750) chmod g+rwx,g+s "$1" ;; esac
}
# fixfiles DIR GROUP GLOB...: config files paqet-manager reset to root 600
# get GROUP read access back.
fixfiles() {
  fd=$1 fg=$2
  shift 2
  for x in "$@"; do
    [ -f "$x" ] && [ ! -L "$x" ] || continue
    case $(stat -c %G "$x"):$(stat -c %a "$x") in root:* | *:6[0-3]0) ;; *) continue ;; esac
    in_stage "$fd" st_meta "${x##*/}" "$fg" || true
  done
}
fixdir "$CONF"
fixfiles "$CONF" "$G" "$CONF"/*.yaml
if [ -d "$WANTS" ]; then
  for l in "$UNITS"/multi-user.target.wants/paqet-*.service; do
    [ -L "$l" ] || continue
    u=$(basename "$l"); n=${u#paqet-}; n=${n%.service}
    valid "$n" && plain_ok "$n" || continue
    ln -sfn "$UNITS/$u" "$WANTS/$u" && rm -f -- "$l"
  done
fi
# Turn on IP traffic accounting for script units, live, without restarting them.
if [ -z "$R" ] && command -v systemctl >/dev/null; then
  for f in "$UNITS"/paqet-*.service; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    u=$(basename "$f"); n=${u#paqet-}; n=${n%.service}
    valid "$n" && plain_ok "$n" || continue
    [ "$(systemctl show -p IPAccounting --value "$u" 2>/dev/null)" = yes ] && continue
    systemctl set-property "$u" IPAccounting=yes >/dev/null 2>&1 || true
  done
fi
# Host operations requested by the panel or node agent (CONF/.ops/*.req):
# per-tunnel firewall rules and unit resource limits. Every field is
# re-validated here; only these fixed commands can run.
OPS=$CONF/.ops
[ -e "$OPS" ] || [ -L "$OPS" ] || { mkdir -p "$OPS" && chgrp -h "$G" "$OPS" && chmod 3770 "$OPS"; }
sticky "$OPS"
REQ=""
# rq FILE: load a request (read with the panel's rights, at most 4 KiB).
rq() { REQ=$(asg head -c 8192 -- "$1" 2>/dev/null) || REQ=""; }
kv() { printf '%s\n' "$REQ" | sed -n "s/^$1=//p" | head -n1; }
cdir() { case $1 in paqet) echo "$CONF" ;; gost2) echo "$R/etc/gost2" ;; gost3) echo "$R/etc/gost3" ;; esac; }
# unit_ok CORE NAME UNIT: UNIT is the tunnel's own unit, managed by the panel
unit_ok() {
  case $3 in
  "$1@$2.service") [ -f "$UNITS/$1@.service" ] && ls "$(cdir "$1")/$2".* >/dev/null 2>&1 ;;
  "paqet-$2.service") [ "$1" = paqet ] && plain_ok "$2" ;;
  *) return 1 ;;
  esac
}
fw1() { # fw1 add|del TAG TABLE CHAIN RULE...
  o=$1 t=$2 tb=$3 ch=$4; shift 4
  if iptables -t "$tb" -C "$ch" "$@" -m comment --comment "$t" 2>/dev/null; then
    [ "$o" = add ] || iptables -t "$tb" -D "$ch" "$@" -m comment --comment "$t"
  else
    [ "$o" = del ] || iptables -t "$tb" -A "$ch" "$@" -m comment --comment "$t"
  fi
}
fw() { # fw add|del TAG SET PORT
  if [ "$3" = allow ]; then
    fw1 "$1" "$2" filter INPUT -p tcp --dport "$4" -j ACCEPT &&
      fw1 "$1" "$2" filter INPUT -p udp --dport "$4" -j ACCEPT
  else
    fw1 "$1" "$2" raw PREROUTING -p tcp --dport "$4" -j NOTRACK &&
      fw1 "$1" "$2" raw OUTPUT -p tcp --sport "$4" -j NOTRACK &&
      fw1 "$1" "$2" mangle OUTPUT -p tcp --sport "$4" --tcp-flags RST RST -j DROP
  fi
}
# parse STEM (fw.NAME | fw.CORE~NAME) -> sets c, n, tag
stem() {
  r=${1#*.}
  case $r in *~*) c=${r%%~*}; n=${r#*~}; tag="paqet-panel:$c/$n" ;; *) c=paqet; n=$r; tag="paqet-panel:$n" ;; esac
  case $c in paqet | gost2 | gost3) ;; *) return 1 ;; esac
  valid "$n"
}
now() { date -u +%FT%TZ; }
if [ -z "$R" ] && [ -n "$(lid "$OPS")" ]; then
  for q in "$OPS"/fw.*.req "$OPS"/limits.*.req; do
    [ -f "$q" ] && [ ! -L "$q" ] || continue
    b=$(basename "$q" .req)
    rq "$q"
    if ! stem "$b" || { [ -n "$(kv core)" ] && [ "$(kv core)" != "$c" ]; } || [ "$(kv name)" != "$n" ]; then
      msg="rejected: invalid request $(now)"
    else
      case $b in
      fw.*)
        op=$(kv op); port=$(kv port); set=$(kv set); [ -n "$set" ] || set=raw
        if printf '%s' "$op" | grep -Eqx 'add|del' && printf '%s' "$set" | grep -Eqx 'raw|allow' &&
          { [ "$set" = allow ] || [ "$c" = paqet ]; } &&
          printf '%s' "$port" | grep -Eqx '[1-9][0-9]{0,4}' && [ "$port" -le 65535 ] && command -v iptables >/dev/null; then
          if fw "$op" "$tag" "$set" "$port" || { [ "$op" = add ] && fw del "$tag" "$set" "$port" && false; }; then
            if [ "$op" = add ]; then
              printf '%s\n' "$set $port" | in_stage "$OPS" st_put "$b.keep" 0640 "$ME:$G"
            else
              in_stage "$OPS" rm -f -- "../$b.keep"
            fi
            msg="ok: $op $set port $port $(now)"
          else msg="failed: $op $set port $port $(now)"; fi
        else msg="rejected: bad request $(now)"; fi ;;
      limits.*)
        u=$(kv unit); mem=$(kv mem); cpu=$(kv cpu); tk=$(kv tasks)
        if unit_ok "$c" "$n" "$u" && printf '%s' "$mem" | grep -Eqx '[1-9][0-9]{0,5}[MG]|infinity' &&
          { [ -z "$cpu" ] || printf '%s' "$cpu" | grep -Eqx '[1-9][0-9]{0,3}%'; } && printf '%s' "$tk" | grep -Eqx '[1-9][0-9]{0,5}|infinity'; then
          if systemctl set-property "$u" "MemoryMax=$mem" "CPUQuota=$cpu" "TasksMax=$tk" >/dev/null 2>&1; then
            msg="ok: $u MemoryMax=$mem CPUQuota=$cpu TasksMax=$tk $(now)"
          else msg="failed: $u $(now)"; fi
        else msg="rejected: bad request $(now)"; fi ;;
      esac
    fi
    res "$OPS" "$b.res" "$msg"
    rm -f -- "$q"
  done
  # External tunnels (other tools): unit actions + config view. The unit
  # must exist, not be a panel unit, and run an allowlisted tool binary.
  for q in "$OPS"/ext.*.req; do
    [ -f "$q" ] && [ ! -L "$q" ] || continue
    b=$(basename "$q" .req)
    rq "$q"
    u=$(kv unit); op=$(kv op)
    ex=""
    if printf '%s' "$u" | grep -Eqx '[A-Za-z0-9@._:-]{1,96}\.service' &&
      ! printf '%s' "$u" | grep -Eq '^(paqet@|gost2@|gost3@|paqet-)' &&
      printf '%s' "$op" | grep -Eqx 'start|stop|restart|enable|disable|view' &&
      [ "$b" = "ext.$(printf '%s' "${u%.service}" | tr '@:' '__')" ]; then
      ex=$(systemctl show -p ExecStart --value -- "$u" 2>/dev/null | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' | head -n1)
    fi
    bin=$(printf '%s' "$ex" | awk '{print $1}')
    if [ -z "$bin" ] || ! basename "$bin" | grep -Eqi 'gost|backhaul|rathole|frpc|frps|chisel'; then
      msg="rejected: not an external tunnel unit $(now)"
    elif [ "$op" = view ]; then
      # shellcheck disable=SC2086 # word-split the command line on purpose
      set -- $ex; cfg=""
      while [ $# -gt 0 ]; do
        case $1 in
        -c | -C | --config | -config | --conf) cfg=${2:-}; break ;;
        --config=* | -C=*) cfg=${1#*=}; break ;;
        /*.toml | /*.yaml | /*.yml | /*.json | /*.ini | /*.conf) [ "$1" = "$bin" ] || { cfg=$1; break; } ;;
        esac
        shift
      done
      # absolute, no symlink anywhere in the path, a regular file
      if [ -n "$cfg" ] && [ "${cfg#/}" != "$cfg" ] && [ "$(realpath -e -- "$cfg" 2>/dev/null)" = "$cfg" ] &&
        [ -f "$cfg" ] && [ ! -L "$cfg" ] && in_stage "$OPS" st_view "$cfg" "$b.view"; then
        msg="ok: view $cfg $(now)"
      else msg="failed: no readable config file on the command line $(now)"; fi
    elif systemctl "$op" -- "$u" >/dev/null 2>&1; then
      msg="ok: $op $u $(now)"
    else msg="failed: $op $u $(now)"; fi
    res "$OPS" "$b.res" "$msg"
    rm -f -- "$q"
  done
  # Re-apply kept firewall rules (iptables rules do not survive a reboot).
  if command -v iptables >/dev/null; then
    for k in "$OPS"/fw.*.keep; do
      [ -f "$k" ] && [ ! -L "$k" ] || continue
      b=$(basename "$k" .keep); stem "$b" || continue
      set=""; port=""
      read -r set port <<KEEP || true
$(asg head -c 64 -- "$k" 2>/dev/null)
KEEP
      [ -n "${port:-}" ] || { port=$set; set=raw; } # v0.4.0 keep files hold only the port
      printf '%s' "$set" | grep -Eqx 'raw|allow' && printf '%s' "$port" | grep -Eqx '[1-9][0-9]{0,4}' && fw add "$tag" "$set" "$port" || true
    done
  fi
fi
# v0.7.15 automatic rules for raw fake-TCP clients (kcp, pck):
# CONF/.ops/fwc.NAME.req -> .keep (spec) / .res (last op) / .st (last check).
# Comment paqet-NAME (the one used by hand, so existing rules are found by
# -C and never duplicated). Every field is re-validated here; a rule on an
# SSH port (22, every port sshd or ssh.socket listens on or has in
# sshd_config / the socket unit) is refused; only these fixed iptables commands run.
ip4ok() {
  printf '%s' "$1" | grep -Eqx '((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])' &&
    [ "$1" != 0.0.0.0 ]
}
sshports() { # 22 + 45678 + what sshd (or its systemd socket) listens on + Port lines of sshd_config(.d)
  {
    echo 22
    echo 45678
    ss -ltnpH 2>/dev/null | grep -E '\("sshd",' | awk '{print $4}' | sed 's/.*://'
    cat "$R/etc/ssh/sshd_config" "$R"/etc/ssh/sshd_config.d/*.conf 2>/dev/null |
      sed -n 's/^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p'
    for u in ssh.socket sshd.socket; do # socket activation: ListenStream= of the unit and its drop-ins
      for f in "$R/usr/lib/systemd/system/$u" "$R/lib/systemd/system/$u" "$R/etc/systemd/system/$u" \
        "$R/usr/lib/systemd/system/$u.d"/*.conf "$R/etc/systemd/system/$u.d"/*.conf \
        "$R/run/systemd/system/$u.d"/*.conf "$R/run/systemd/generator/$u.d"/*.conf; do
        [ -f "$f" ] || continue
        sed -n 's/^[[:space:]]*ListenStream[[:space:]]*=[[:space:]]*\(.*:\)\{0,1\}\([0-9][0-9]*\)[[:space:]]*$/\2/p' "$f"
      done
    done
    if [ -z "$R" ]; then
      systemctl show -p Listen ssh.socket sshd.socket 2>/dev/null |
        sed -n 's/^Listen=\(.*:\)\{0,1\}\([0-9][0-9]*\) (Stream)$/\2/p'
    fi
  } | grep -Ex '[0-9]{1,5}' | sort -un
}
portok() {
  printf '%s' "$1" | grep -Eqx '[1-9][0-9]{0,4}' && [ "$1" -le 65535 ] || return 1
  ! sshports | grep -qx "$1"
}
fcok() { # fcok TRANSPORT PEER SPORT LPORT
  printf '%s' "$1" | grep -Eqx 'kcp|pck' || return 1
  if [ "$4" = 0 ]; then
    ip4ok "$2" && portok "$3"
  else
    portok "$4" || return 1
    # optional peer scopes a fixed-port rule; required for server/reverse
    if [ -n "$2" ]; then ip4ok "$2"; else return 0; fi
  fi
}
FCN=0
FCW=2
FCH=""
FCCH=0
fc1() { # fc1 add|del|check TAG TABLE CHAIN TARGET MATCH...: counts present rules in FCN
  o=$1 t=$2 tb=$3 ch=$4 tg=$5
  shift 5
  if iptables -w -t "$tb" -C "$ch" "$@" -m comment --comment "$t" -j "$tg" 2>/dev/null; then
    FCN=$((FCN + 1))
    if [ "$o" = del ]; then iptables -w -t "$tb" -D "$ch" "$@" -m comment --comment "$t" -j "$tg" && FCCH=1; fi
  elif [ -n "$FCH" ] && iptables -w -t "$tb" -C "$ch" "$@" -m comment --comment "$FCH" -j "$tg" 2>/dev/null; then
    # v0.7.18: the same rule made by hand (comment paqet-NAME) counts as
    # present; it is never duplicated and never deleted by the panel.
    FCN=$((FCN + 1))
  elif [ -n "$FCH" ] && fceq "$tb" "$ch" "$tg" "$FCH" "$@"; then
    # v0.7.38: a handmade paqet-NAME rule for the same port and target
    # (with or without a peer IP, --sport or --dport for RST) is equivalent.
    FCN=$((FCN + 1))
  elif [ "$o" = add ]; then
    iptables -w -t "$tb" -A "$ch" "$@" -m comment --comment "$t" -j "$tg" && FCCH=1
  fi
  return 0
}
fceq() { # fceq TABLE CHAIN TARGET HANDTAG -- args: handmade equivalent (same port + target)
  # Variable names must not clash with the request loop (tag, port, ...).
  eqtb=$1 eqch=$2 eqtg=$3 eqtag=$4
  shift 4
  eqport="" eqrst="" eqprev=""
  for a in "$@"; do
    case $eqprev in --dport | --sport) eqport=$a ;; esac
    case $a in --tcp-flags) eqrst=yes ;; esac
    eqprev=$a
  done
  [ -n "$eqport" ] && [ -n "$eqtag" ] || return 1
  eqrules=$(iptables -w -t "$eqtb" -S "$eqch" 2>/dev/null) || return 1
  [ -n "$eqrules" ] || return 1
  printf '%s\n' "$eqrules" | grep -F -- "-A $eqch " | grep -F -- " -j $eqtg" | grep -E -- "--(dport|sport) $eqport( |$)" | grep -F -- "--comment $eqtag" | {
    if [ "$eqrst" = yes ]; then grep -F -- "--tcp-flags RST RST"; else cat; fi
  } | grep -q .
}
fcr() { # fcr add|del|check TAG PEER SPORT LPORT (validated with fcok first; transport in $fr, side in $fside)
  # v0.7.16: the raw NOTRACK pair. kcp is NOTRACK-only (no RST DROP).
  # v0.7.18: pck on a fixed local port also drops the kernel's RSTs.
  # v0.7.38: server/reverse uses --dport for RST; fixed-port rules are
  # scoped to the peer IP when it is known.
  FCN=0 FCW=2
  FCH=paqet-${2#paqet-autofw-}
  if [ "$5" = 0 ]; then
    fc1 "$1" "$2" raw PREROUTING NOTRACK -p tcp -s "$3" --sport "$4"
    fc1 "$1" "$2" raw OUTPUT NOTRACK -p tcp -d "$3" --dport "$4"
  else
    if [ -n "$3" ]; then
      fc1 "$1" "$2" raw PREROUTING NOTRACK -p tcp -s "$3" --dport "$5"
      fc1 "$1" "$2" raw OUTPUT NOTRACK -p tcp -d "$3" --sport "$5"
    else
      fc1 "$1" "$2" raw PREROUTING NOTRACK -p tcp --dport "$5"
      fc1 "$1" "$2" raw OUTPUT NOTRACK -p tcp --sport "$5"
    fi
    if [ "$fr" = pck ]; then
      FCW=3
      if [ "$fside" = server ]; then
        fc1 "$1" "$2" mangle OUTPUT DROP -p tcp --dport "$5" --tcp-flags RST RST
      else
        fc1 "$1" "$2" mangle OUTPUT DROP -p tcp --sport "$5" --tcp-flags RST RST
      fi
    fi
  fi
}
fcsave() { # persist (iptables-save > /etc/iptables/rules.v4) when a rule changed
  [ "$FCCH" = 1 ] && command -v iptables-save >/dev/null || return 0
  # v0.7.22: not while a firewall-page removal waits for confirmation
  [ ! -f "$OPS/fwx.undo" ] || return 0
  d=$R/etc/iptables
  [ -e "$d" ] || mkdir -p -- "$d" || return 0
  [ -d "$d" ] && [ ! -L "$d" ] || return 0
  iptables-save >"$d/.rules.v4.paqet-tmp" && mv -f -- "$d/.rules.v4.paqet-tmp" "$d/rules.v4" || rm -f -- "$d/.rules.v4.paqet-tmp"
  FCCH=0
}
fcstate() { # fcstate STEM: write the check result (FCN of FCW)
  if [ "$FCN" = "$FCW" ]; then s=applied; else s=missing; fi
  res "$OPS" "$1.st" "$s $FCN/$FCW $(now)"
}
fckeep() { # fckeep FILE: prints "TRANSPORT PEER SPORT LPORT" of a keep file
  asg head -c 128 -- "$1" 2>/dev/null | head -n1
}
fcnorm() { # sets fr fp fs fl fside from "$@" (peer "-" = none); returns 1 when invalid
  fr=${1:-} fp=${2:--} fs=${3:-0} fl=${4:-0} fside=${5:-}
  [ "$fp" != - ] || fp=""
  if [ "$fl" != 0 ]; then fs=0; fi
  if [ "$fside" = server ] && [ -z "$fp" ]; then return 1; fi
  fcok "$fr" "$fp" "$fs" "$fl"
}
FCRUN=0
if [ -z "$R" ] || [ "${PAQET_HELPER_FWC_TEST:-}" = 1 ]; then FCRUN=1; fi
if [ "$FCRUN" = 1 ] && [ -n "$(lid "$OPS")" ] && command -v iptables >/dev/null; then
  for q in "$OPS"/fwc.*.req; do
    [ -f "$q" ] && [ ! -L "$q" ] || continue
    b=$(basename "$q" .req)
    n=${b#fwc.}
    rq "$q"
    op=$(kv op)
    k="$OPS/$b.keep"
    ks=""
    if [ -f "$k" ] && [ ! -L "$k" ]; then ks=$(fckeep "$k"); fi
    if ! valid "$n" || [ "$(kv core)" != paqet ] || [ "$(kv name)" != "$n" ] || ! printf '%s' "$op" | grep -Eqx 'add|del|check'; then
      msg="rejected: invalid request $(now)"
    else
      tr=$(kv transport)
      # v0.7.16: del always uses the kept (panel-applied) spec only.
      if [ "$op" = del ]; then tr=""; fi
      if [ -z "$tr" ] && [ "$op" != add ]; then
        # shellcheck disable=SC2086 # keep line = four plain words
        fcnorm $ks
      else
        fcnorm "$tr" "$(kv peer)" "$(kv sport)" "$(kv lport)" "$(kv side)"
      fi
      okspec=$?
      if [ "$okspec" != 0 ]; then
        if [ "$op" != add ] && [ -z "$tr" ] && [ -z "$ks" ]; then
          msg="ok: $op nothing kept $(now)"
        else msg="rejected: bad rule spec (IPv4, ports 1-65535, never an SSH port) $(now)"; fi
      else
        tag="paqet-autofw-$n"
        spec="$fr ${fp:--} $fs $fl"
        [ -z "$fside" ] || spec="$spec $fside"
        case $op in
        add)
          if [ -n "$ks" ] && [ "$ks" != "$spec" ]; then
            # shellcheck disable=SC2086
            if fcnorm $ks; then fcr del "$tag" "$fp" "$fs" "$fl"; fi
            fcnorm "$tr" "$(kv peer)" "$(kv sport)" "$(kv lport)" "$(kv side)"
          fi
          fcr add "$tag" "$fp" "$fs" "$fl"
          fcr check "$tag" "$fp" "$fs" "$fl"
          fcstate "$b"
          if [ "$FCN" = "$FCW" ]; then
            printf '%s\n' "$spec" | in_stage "$OPS" st_put "$b.keep" 0640 "$ME:$G"
            msg="ok: add $spec $(now)"
          else msg="failed: add $spec ($FCN/$FCW present) $(now)"; fi ;;
        del)
          fcr del "$tag" "$fp" "$fs" "$fl"
          in_stage "$OPS" rm -f -- "../$b.keep" "../$b.st"
          msg="ok: del $spec $(now)" ;;
        check)
          fcr check "$tag" "$fp" "$fs" "$fl"
          fcstate "$b"
          msg="ok: check $spec $FCN/$FCW $(now)" ;;
        esac
      fi
    fi
    res "$OPS" "$b.res" "$msg"
    rm -f -- "$q"
  done
  # Refresh the status of kept automatic rules (v0.7.16: check only,
  # persistence is rules.v4 written on an explicit Apply).
  for k in "$OPS"/fwc.*.keep; do
    [ -f "$k" ] && [ ! -L "$k" ] || continue
    b=$(basename "$k" .keep)
    n=${b#fwc.}
    valid "$n" || continue
    # shellcheck disable=SC2046 # keep line = four plain words
    fcnorm $(fckeep "$k") || continue
    # v0.7.16: status only; never re-adds rules on its own.
    fcr check "paqet-autofw-$n" "$fp" "$fs" "$fl"
    fcstate "$b"
  done
  fcsave
fi
# v0.7.22 firewall page. Every run writes a snapshot of the live rules
# (.ops/fwx.live): paqet-* rules in raw/mangle PREROUTING|OUTPUT and filter
# INPUT in full, every other rule only counted, chain policies and the
# ports that must stay reachable. .ops/fwx.req removes unmanaged paqet-*
# rules (never a rule a panel keep file owns, never an ACCEPT for a
# protected port, never another rule); the removal waits for .ops/fwx.ok.req
# with the same id until its deadline, else the rules are put back at
# their old position. Nothing is added; nat, FORWARD, docker and other
# chains are never touched. rules.v4 is written only after a confirmation.
fxline() { # fxline RULE: strict shape (no quotes or shell characters, one paqet-* comment)
  printf '%s' "$1" | grep -Eqx -- '-A (PREROUTING|OUTPUT|INPUT) [-A-Za-z0-9 .:/_,!]{1,400}' || return 1
  [ "$(printf '%s' "$1" | grep -o -- '--comment' | wc -l)" = 1 ] || return 1
  printf '%s' "$1" | grep -Eq -- '--comment paqet-[A-Za-z0-9:/_.-]{1,64}( |$)' &&
    printf '%s' "$1" | grep -Eq -- ' -j (NOTRACK|DROP|ACCEPT)$'
}
# v0.7.24: editable scope = raw PREROUTING/OUTPUT NOTRACK, mangle OUTPUT
# DROP, filter INPUT and OUTPUT ACCEPT or DROP, for IPv4 and IPv6.
fxok() { # fxok TABLE RULE: chain and target allowed for this table
  c=${2#-A }
  c=${c%% *}
  fxchain "$1" "$c" && fxline "$2" || return 1
  case $1:$c:$2 in
  raw:*" -j NOTRACK" | mangle:OUTPUT:*" -j DROP" | filter:*" -j ACCEPT" | filter:*" -j DROP") return 0 ;;
  esac
  return 1
}
fxtag() { printf '%s' "$1" | sed -n 's/.*--comment \(paqet-[A-Za-z0-9:\/_.-]*\).*/\1/p'; }
fxchain() {
  case $1:$2 in raw:PREROUTING | raw:OUTPUT | mangle:OUTPUT | filter:INPUT | filter:OUTPUT) return 0 ;; esac
  return 1
}
fxipt() { if [ "$1" = 6 ]; then echo ip6tables; else echo iptables; fi; }
fxmanaged() { # fxmanaged TAG: true when a panel keep file owns rules with this tag
  case $1 in
  paqet-autofw-*) x=${1#paqet-autofw-}; valid "$x" && [ -f "$OPS/fwc.$x.keep" ] ;;
  paqet-panel:*/*)
    x=${1#paqet-panel:}
    case ${x%%/*} in gost2 | gost3) valid "${x#*/}" && [ -f "$OPS/fw.${x%%/*}~${x#*/}.keep" ] ;; *) false ;; esac ;;
  paqet-panel:*) x=${1#paqet-panel:}; valid "$x" && [ -f "$OPS/fw.$x.keep" ] ;;
  paqet-*) x=${1#paqet-}; valid "$x" && [ -f "$OPS/fwc.$x.keep" ] ;;
  *) false ;;
  esac
}
fxprot() { # ports that must stay reachable: fixed ones + every SSH port (sshports) + what the agents, proxies listen on
  {
    printf '22\n45678\n9443\n443\n2053\n80\n8880\n'
    sshports
    ss -ltnupH 2>/dev/null | grep -E 'users:\(\("(sshd|paqet-node|paqet-panel|paqet-caddy|caddy|xray|docker-proxy|pg-node|pasarguard|cdnmux)"' |
      awk '{print $5}' | sed 's/.*://'
  } | grep -Ex '[0-9]{1,5}' | sort -un
}
fxport() { printf '%s' "$1" | sed -n 's/.* --dport \([0-9]*\).*/\1/p'; }
fxports() { # fxports RULE: every --sport/--dport value (N or N:M), one per line
  printf '%s\n' "$1" | grep -oE -- '--(sport|dport) [0-9]{1,5}(:[0-9]{1,5})?' | sed 's/^--[a-z]* //'
}
# fxguard TABLE RULE PROT: why an added rule could cut access (empty = fine).
# ACCEPT never cuts access. DROP/NOTRACK need a port (or are ICMP) and may
# not touch a protected port (SSH, agents, panel, proxies).
fxguard() {
  case $2 in *" -j ACCEPT") return 0 ;; esac
  ps=$(fxports "$2")
  if [ -z "$ps" ]; then
    case $2 in *" -p icmp "* | *" -p ipv6-icmp "*) return 0 ;; esac
    echo "a DROP/NOTRACK rule needs a port (or ICMP): $2"
    return 0
  fi
  for r in $ps; do
    lo=${r%%:*}
    hi=${r#*:}
    for p in $3; do
      if [ "$p" -ge "$lo" ] && [ "$p" -le "$hi" ]; then
        echo "touches protected port $p (SSH, node agent, panel, proxies): $2"
        return 0
      fi
    done
  done
}
fxtagok() { # a tag for a new rule: paqet-NAME, not a tunnel-kept or reserved tag
  printf '%s' "$1" | grep -Eqx 'paqet-[a-z0-9][a-z0-9-]{0,40}' || return 1
  case $1 in paqet-autofw-* | paqet-panel*) return 1 ;; esac
  ! fxmanaged "$1"
}
fxdump() {
  echo "time $(now)"
  echo "cap edit2"
  for fam in 4 6; do
    ipt=$(fxipt "$fam")
    command -v "$ipt" >/dev/null || continue
    for tb in raw mangle nat filter security; do
      "$ipt" -w -t "$tb" -S 2>/dev/null | tr -d '\r' | head -n 3000 | while IFS= read -r l; do
        case $l in
        "-P "* | "-N "* | "-A "*) printf 'F %s %s %s\n' "$fam" "$tb" "$l" ;;
        esac
        case $l in
        "-P "*)
          set -f
          # shellcheck disable=SC2086 # -P CHAIN POLICY
          set -- $l
          set +f
          if [ "$fam" = 4 ] && fxchain "$tb" "$2"; then echo "P $tb $2 $3"; fi ;;
        "-A "*)
          ch=${l#-A }
          ch=${ch%% *}
          if fxok "$tb" "$l"; then
            if fxmanaged "$(fxtag "$l")"; then m=managed; else m=free; fi
            echo "E $fam $tb $m $l"
            if [ "$fam" = 4 ]; then echo "R $tb $m $l"; fi
          elif [ "$fam" = 4 ] && fxchain "$tb" "$ch"; then echo "O $tb $ch"; fi ;;
        esac
      done
    done
  done
  fxprot | sed 's/^/S /'
  if [ -f "$OPS/fwx.undo" ]; then sed -n 's/^id=/U id /p; s/^deadline=/U deadline /p' "$OPS/fwx.undo"; fi
}
fxrun() { # fxrun FAM TABLE OP RULE-WITHOUT-"-A " [POS]: one iptables call on a validated rule
  set -f
  x=$(fxipt "$1")
  # shellcheck disable=SC2086 # the rule passed fxline (no quotes, no shell characters)
  if [ -n "${5:-}" ]; then
    "$x" -w -t "$2" "$3" ${4%% *} "$5" ${4#* }
  else
    "$x" -w -t "$2" "$3" $4
  fi
  r=$?
  set +f
  return $r
}
fxsplit() { # fxsplit "F|T|REST": sets FF FT FR (an old "T|REST" line is IPv4)
  case $1 in
  4\|* | 6\|*) FF=${1%%|*}; x=${1#*|} ;;
  *) FF=4; x=$1 ;;
  esac
  FT=${x%%|*}
  FR=${x#*|}
}
fxrestore() { # undo: delete added rules, put removed rules back (reverse order, old position)
  u=$OPS/fwx.undo
  [ -f "$u" ] && [ ! -L "$u" ] && [ "$(stat -c %u -- "$u")" = "$ME" ] || { rm -f -- "$u"; return 1; }
  prot=$(fxprot)
  sed -n 's/^added=//p' "$u" | tac | while IFS= read -r x; do
    fxsplit "$x"
    fxok "$FT" "$FR" && fxtagok "$(fxtag "$FR")" || continue
    fxrun "$FF" "$FT" -C "${FR#-A }" 2>/dev/null || continue
    fxrun "$FF" "$FT" -D "${FR#-A }"
  done
  sed -n 's/^rule=//p' "$u" | tac | while IFS= read -r x; do
    fxsplit "$x"
    pos=${FR%%|*}
    l=${FR#*|}
    ch=${l#-A }
    ch=${ch%% *}
    fxok "$FT" "$l" && printf '%s' "$pos" | grep -Eqx '[1-9][0-9]{0,3}' || continue
    # never (re)adds a DROP/NOTRACK on a protected port (such rules are not removable either)
    [ -z "$(fxguard "$FT" "$l" "$prot")" ] || continue
    fxrun "$FF" "$FT" -C "${l#-A }" 2>/dev/null && continue
    n=$("$(fxipt "$FF")" -w -t "$FT" -S "$ch" 2>/dev/null | grep -c '^-A ')
    if [ "$pos" -le $((n + 1)) ]; then fxrun "$FF" "$FT" -I "${l#-A }" "$pos"; else fxrun "$FF" "$FT" -A "${l#-A }"; fi
  done
  rm -f -- "$u"
}
fxsave6() { # after a confirmed IPv6 change: rules.v6, only where it is already used
  d=$R/etc/iptables
  [ -f "$d/rules.v6" ] && [ ! -L "$d/rules.v6" ] && command -v ip6tables-save >/dev/null || return 0
  ip6tables-save >"$d/.rules.v6.paqet-tmp" && mv -f -- "$d/.rules.v6.paqet-tmp" "$d/rules.v6" || rm -f -- "$d/.rules.v6.paqet-tmp"
}
FXRUN=0
if [ -z "$R" ] || [ "${PAQET_HELPER_FWX_TEST:-}" = 1 ]; then FXRUN=1; fi
if [ "$FXRUN" = 1 ] && [ -n "$(lid "$OPS")" ] && command -v iptables >/dev/null; then
  u=$OPS/fwx.undo
  uid=""
  if [ -f "$u" ]; then uid=$(sed -n 's/^id=//p' "$u" | head -n1); fi
  for q in "$OPS/fwx.ok.req" "$OPS/fwx.cancel.req"; do
    [ -f "$q" ] && [ ! -L "$q" ] || continue
    rq "$q"
    id=$(kv id)
    if [ -n "$uid" ] && [ "$id" = "$uid" ]; then
      case $q in
      *.ok.req)
        six=0
        if grep -Eq '^(rule|added)=6\|' "$u"; then six=1; fi
        rm -f -- "$u"
        # persist only where rules.v4 / rules.v6 are already used
        if [ -f "$R/etc/iptables/rules.v4" ]; then FCCH=1; fi
        if [ "$six" = 1 ]; then fxsave6; fi
        msg="ok: confirmed $id $(now)" ;;
      *) fxrestore; msg="ok: cancelled $id, rules put back $(now)" ;;
      esac
      uid=""
    else msg="rejected: no pending change $id $(now)"; fi
    res "$OPS" fwx.res "$msg"
    rm -f -- "$q"
  done
  if [ -n "$uid" ]; then
    dl=$(sed -n 's/^deadline=//p' "$u" | head -n1)
    if ! printf '%s' "$dl" | grep -Eqx '[0-9]{1,12}' || [ "$(date +%s)" -ge "$dl" ]; then
      fxrestore
      res "$OPS" fwx.res "rolled back: $uid was not confirmed in time, rules put back $(now)"
      uid=""
    fi
  fi
  q=$OPS/fwx.req
  if [ -f "$q" ] && [ ! -L "$q" ]; then
    rq "$q"
    id=$(kv id)
    ttl=$(kv ttl)
    printf '%s' "$ttl" | grep -Eqx '[0-9]{3}' && [ "$ttl" -ge 120 ] && [ "$ttl" -le 600 ] || ttl=180
    dels=$(printf '%s\n' "$REQ" | sed -n 's/^del=//p' | head -n 9)
    adds=$(printf '%s\n' "$REQ" | sed -n 's/^add=//p' | head -n 9)
    prot=$(fxprot)
    nops=$(printf '%s\n%s\n' "$dels" "$adds" | grep -c .)
    bad=""
    if [ -n "$uid" ]; then bad="another change is waiting for confirmation"
    elif ! printf '%s' "$id" | grep -Eqx '[0-9a-f]{16}'; then bad="bad id"
    elif [ "$nops" -lt 1 ] || [ "$nops" -gt 8 ]; then bad="1-8 rules per change"
    else
      bad=$(printf '%s\n' "$dels" | while IFS= read -r d; do
        [ -n "$d" ] || continue
        fxsplit "$d"
        l=$FR
        if ! fxok "$FT" "$l"; then echo "not an editable paqet-* rule: $l"; break; fi
        if fxmanaged "$(fxtag "$l")"; then echo "managed by a tunnel (use its firewall card): $l"; break; fi
        case $l in *" -j ACCEPT")
          p=$(fxport "$l")
          if [ -z "$p" ] || printf '%s\n' "$prot" | grep -qx "$p"; then echo "protected or unknown port: $l"; break; fi ;;
        esac
        g=$(fxguard "$FT" "$l" "$prot")
        if [ -n "$g" ]; then echo "change by hand, $g"; break; fi
        fxrun "$FF" "$FT" -C "${l#-A }" 2>/dev/null || { echo "rule not present: $l"; break; }
      done)
      if [ -z "$bad" ]; then
        bad=$(printf '%s\n' "$adds" | while IFS= read -r d; do
          [ -n "$d" ] || continue
          fxsplit "$d"
          pos=${FR%%|*}
          l=${FR#*|}
          printf '%s' "$pos" | grep -Eqx '[0-9]{1,4}' || { echo "bad position: $d"; break; }
          if ! fxok "$FT" "$l"; then echo "not an allowed rule (raw NOTRACK, mangle OUTPUT DROP, filter INPUT/OUTPUT ACCEPT or DROP, one paqet-* comment): $l"; break; fi
          if ! fxtagok "$(fxtag "$l")"; then echo "use a tag paqet-NAME that no tunnel keeps: $l"; break; fi
          g=$(fxguard "$FT" "$l" "$prot")
          if [ -n "$g" ]; then echo "$g"; break; fi
          if fxrun "$FF" "$FT" -C "${l#-A }" 2>/dev/null; then
            # present already: fine only when the same change removes it
            printf '%s\n' "$dels" | grep -Fxq -- "$FF|$FT|$l" || { echo "rule already present: $l"; break; }
          fi
        done)
      fi
    fi
    if [ -n "$bad" ]; then msg="rejected: $bad $(now)"
    else
      dl=$(($(date +%s) + ttl))
      printf 'id=%s\ndeadline=%s\n' "$id" "$dl" | in_stage "$OPS" st_put fwx.undo 0600 "$ME:0"
      n=0
      a=0
      failed=""
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        fxsplit "$d"
        l=$FR
        ch=${l#-A }
        ch=${ch%% *}
        pos=$("$(fxipt "$FF")" -w -t "$FT" -S "$ch" 2>/dev/null | grep '^-A ' | grep -Fxn -- "$l" | head -n1 | cut -d: -f1)
        [ -n "$pos" ] || pos=1
        { cat -- "$u" && printf 'rule=%s|%s|%s|%s\n' "$FF" "$FT" "$pos" "$l"; } | in_stage "$OPS" st_put fwx.undo 0600 "$ME:0"
        if fxrun "$FF" "$FT" -D "${l#-A }"; then n=$((n + 1)); else failed="remove $l"; break; fi
      done <<EOF
$dels
EOF
      if [ -z "$failed" ]; then
        while IFS= read -r d; do
          [ -n "$d" ] || continue
          fxsplit "$d"
          pos=${FR%%|*}
          l=${FR#*|}
          ch=${l#-A }
          ch=${ch%% *}
          { cat -- "$u" && printf 'added=%s|%s|%s\n' "$FF" "$FT" "$l"; } | in_stage "$OPS" st_put fwx.undo 0600 "$ME:0"
          cnt=$("$(fxipt "$FF")" -w -t "$FT" -S "$ch" 2>/dev/null | grep -c '^-A ')
          if [ "$pos" -ge 1 ] && [ "$pos" -le $((cnt + 1)) ]; then fxrun "$FF" "$FT" -I "${l#-A }" "$pos"; else fxrun "$FF" "$FT" -A "${l#-A }"; fi || { failed="add $l"; break; }
          a=$((a + 1))
        done <<EOF
$adds
EOF
      fi
      if [ -n "$failed" ]; then
        fxrestore
        msg="failed: could not $failed; nothing changed $(now)"
      else msg="pending: $id removed $n added $a, confirm before $dl $(now)"; fi
    fi
    res "$OPS" fwx.res "$msg"
    rm -f -- "$q"
  fi
  fxdump | in_stage "$OPS" st_put fwx.live 0640 "$ME:$G"
  fcsave
fi
# v0.7.23 tunnel map: every run also writes the host's listening sockets
# with the owning process and systemd unit (.ops/listen.live), so the panel
# can tell a port held by another program (xray, nginx, ...) from the
# tunnel's own socket. Read-only: ss and /proc/PID/cgroup.
lsunit() { sed -n 's#^0::.*/\([A-Za-z0-9@._:-]*\.\(service\|scope\)\)$#\1#p' "/proc/$1/cgroup" 2>/dev/null | head -n1; }
lsdump() {
  echo "time $(now)"
  ss -ltnupH 2>/dev/null | head -n 4000 | awk '{
    loc = $5; port = loc; sub(/.*:/, "", port); addr = substr(loc, 1, length(loc) - length(port) - 1)
    sub(/%.*/, "", addr); gsub(/[^0-9A-Za-z.:*\[\]]/, "", addr)
    name = "-"; pid = "-"
    if (match($0, /users:\(\("[^"]*",pid=[0-9]+/)) {
      u = substr($0, RSTART + 9, RLENGTH - 9); name = u; sub(/".*/, "", name); pid = u; sub(/.*pid=/, "", pid)
      gsub(/[^A-Za-z0-9._-]/, "_", name); name = substr(name, 1, 32)
    }
    if (port ~ /^[0-9]+$/ && ($1 == "tcp" || $1 == "udp")) print $1, (addr == "" ? "*" : addr), port, name, pid
  }' | while read -r pr ad po na pi; do
    un=-
    case $pi in '' | *[!0-9]*) ;; *)
      un=$(lsunit "$pi")
      [ -n "$un" ] || un=- ;;
    esac
    echo "L $pr $ad $po $na $pi $un"
  done
}
if [ "$FXRUN" = 1 ] && [ -n "$(lid "$OPS")" ] && command -v ss >/dev/null; then
  lsdump | in_stage "$OPS" st_put listen.live 0640 "$ME:$G"
fi
# v0.7.25 full-release install requested from the panel / node agent
# (.ops/release.req: id, role, tag, sums). The release was checked by the
# panel/agent and is copied here (read with the panel user's rights, regular
# files with known names only) into a root-only directory, checked again
# (SHA256SUMS hash from the request, every file, version stamp, role of this
# host) and installed by paqet-release-job in its own transient systemd unit,
# so a closed browser or the restarting panel cannot stop it half-way.
RW=$R/var/lib/paqet-release
RJ=$R/usr/local/libexec/paqet-release-job
RLRUN=0
if [ -z "$R" ] || [ "${PAQET_HELPER_REL_TEST:-}" = 1 ]; then RLRUN=1; fi
rlarch() { # this host's release suffix (same mapping as detect_arch in install.sh)
  case $(uname -m) in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    armv7l | armv7 | armhf) echo armv7 ;;
    i386 | i486 | i586 | i686 | x86) echo 386 ;;
    riscv64) echo riscv64 ;;
  esac
}
rlbusy() { # a job is running (its state says so and it is younger than 45 min)
  for st in "$RW"/*/state; do
    [ -f "$st" ] || continue
    if grep -qx 'status=running' "$st" && [ -n "$(find "$st" -mmin -45 2>/dev/null)" ]; then return 0; fi
  done
  return 1
}
rlcopy() { # rlcopy SRC DST: known regular files only, read as the panel user
  n=0
  for f in "$1"/* "$1"/.[!.]*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    b=${f##*/}
    printf '%s' "$b" | grep -Eqx 'paqet-(panel|node|caddy)-linux-(amd64|arm64|armv7|386|riscv64)|install\.sh|uninstall\.sh|update-guard\.sh|CHANGELOG\.md|SHA256SUMS|SHA256SUMS\.sig' || { echo "unexpected file $b"; return 1; }
    [ -f "$f" ] && [ ! -L "$f" ] || { echo "$b is not a regular file"; return 1; }
    n=$((n + 1))
    [ "$n" -le 24 ] || { echo "too many files"; return 1; }
    asg head -c 167772161 -- "$f" >"$2/$b" || { echo "cannot read $b"; return 1; }
    [ "$(stat -c %s "$2/$b")" -le 167772160 ] || { echo "$b too large"; return 1; }
  done
  [ "$n" -gt 0 ] || { echo "empty release"; return 1; }
}
rlcheck() { # rlcheck DIR ROLE TAG SUMS: prints the reason when bad
  a=$(rlarch)
  [ -n "$a" ] || { echo "unsupported architecture"; return 1; }
  [ "$(sha256sum "$1/SHA256SUMS" 2>/dev/null | cut -c1-64)" = "$4" ] || { echo "SHA256SUMS is not the one the panel checked"; return 1; }
  for f in "paqet-panel-linux-$a" "paqet-node-linux-$a" "paqet-caddy-linux-$a" install.sh uninstall.sh update-guard.sh; do
    grep -Eq "^[0-9a-f]{64}  \*?$f\$" "$1/SHA256SUMS" || { echo "not a full release for $a (no $f)"; return 1; }
  done
  (cd "$1" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) || { echo "files do not match SHA256SUMS"; return 1; }
  grep -q 'Usage: install.sh panel|node' "$1/install.sh" || { echo "install.sh is not the paqet-panel installer"; return 1; }
  grep -qaF "paqet-version:$3;" "$1/paqet-$2-linux-$a" || { echo "paqet-$2 is not the $3 release build"; return 1; }
}
if [ "$RLRUN" = 1 ] && [ -n "$(lid "$OPS")" ]; then
  q=$OPS/release.req
  if [ -f "$q" ] && [ ! -L "$q" ]; then
    rq "$q"
    id=$(kv id); role=$(kv role); tag=$(kv tag); sums=$(kv sums)
    bad=""
    if ! printf '%s' "$id" | grep -Eqx '[0-9a-f]{16}'; then bad="bad id"
    elif ! printf '%s' "$tag" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?'; then bad="bad tag"
    elif ! printf '%s' "$sums" | grep -Eqx '[0-9a-f]{64}'; then bad="bad sums"
    elif [ "$role" != panel ] && [ "$role" != node ]; then bad="bad role"
    elif [ ! -x "$R/opt/paqet-$role/bin/paqet-$role" ]; then bad="paqet-$role is not installed on this host (only updates are done here)"
    elif [ "$role" = node ] && [ -x "$R/opt/paqet-panel/bin/paqet-panel" ]; then bad="this host runs the panel; a node agent is never installed here"
    elif rlbusy; then bad="another release install is running"
    elif [ ! -f "$RJ" ]; then bad="the release job is missing (re-run install.sh by hand once)"
    fi
    src=$R/var/lib/paqet-$role/release-stage/$id/paqet-release-$tag
    if [ -z "$bad" ]; then
      # the stage must be a real directory at exactly that path (no symlinked component)
      if ! [ -d "$src" ] || [ -L "$src" ] || [ "$(cd -P -- "$src" 2>/dev/null && pwd -P)" != "$(cd -P -- "$R/var/lib/paqet-$role" 2>/dev/null && pwd -P)/release-stage/$id/paqet-release-$tag" ]; then
        bad="staged release not found"
      fi
    fi
    if [ -z "$bad" ]; then
      # parent /var/lib always exists, so -m applies to the one new directory
      # shellcheck disable=SC2174
      [ -d "$RW" ] || mkdir -p -m 0700 "$RW"
      chmod 0700 "$RW"
      J=$RW/$id
      rm -rf -- "$J"
      mkdir -m 0700 "$J" "$J/rel" || bad="cannot create $J"
      [ -n "$bad" ] || bad=$(rlcopy "$src" "$J/rel") || true
      [ -n "$bad" ] || bad=$(rlcheck "$J/rel" "$role" "$tag" "$sums") || true
    fi
    if [ -z "$bad" ]; then
      printf 'id=%s\nrole=%s\nto=%s\n' "$id" "$role" "$tag" >"$J/job.env"
      printf 'id=%s\nrole=%s\nfrom=\nto=%s\nstatus=running\nstep=queued\ntime=%s\nmsg=\n' "$id" "$role" "$tag" "$(now)" >"$J/state"
      if [ -z "$R" ]; then
        if systemd-run --unit="paqet-release-$id" --collect --no-block --quiet \
          --property=Type=oneshot --property=TimeoutStartSec=45min /bin/sh "$RJ" "$id" >/dev/null 2>&1; then
          msg="ok: queued $id $(now)"
        else
          sed -i 's/^status=running$/status=failed/; s/^msg=$/msg=systemd-run failed, nothing was changed/' "$J/state"
          msg="failed: systemd-run $id $(now)"
        fi
      else
        msg="ok: queued $id $(now)"
        PAQET_INSTALL_ROOT=$R sh "$RJ" "$id" >/dev/null 2>&1 || true
      fi
    else
      msg="rejected: $bad $(now)"
    fi
    # the panel's stage is removed with the panel's own rights
    if printf '%s' "$id" | grep -Eqx '[0-9a-f]{16}' && { [ "$role" = panel ] || [ "$role" = node ]; }; then
      asg rm -rf -- "$R/var/lib/paqet-$role/release-stage/$id" 2>/dev/null || true
    fi
    res "$OPS" release.res "$msg"
    rm -f -- "$q"
  fi
  # mirror the newest job's state (and the end of its log) for the panel
  # newest by mtime (v0.7.27: ls -t instead of the non-POSIX test -nt; job
  # dirs are root-owned and named by validated hex ids, so no odd names)
  # shellcheck disable=SC2012
  last=$(ls -t -- "$RW"/*/state 2>/dev/null | head -n 1)
  [ -f "$last" ] || last=""
  if [ -n "$last" ]; then
    { cat -- "$last"; [ -f "${last%/state}/install.log" ] && tail -n 30 -- "${last%/state}/install.log" | sed 's/^/log=/'; } | in_stage "$OPS" st_put release.state 0640 "$ME:$G"
  fi
fi
# Config writes handed over by the panel/node when the config dir is not
# writable for it (SPOOL/w.<core>.<file>.req [+ .data]). Only plain tunnel
# config names in the three known config dirs; content is copied, never run.
snow() { date -u +%FT%TZ; }
SPOOL=$R/var/lib/paqet-spool
[ -e "$SPOOL" ] || [ -L "$SPOOL" ] || { mkdir -p "$SPOOL" && chgrp -h "$G" "$SPOOL" && chmod 3770 "$SPOOL"; }
sticky "$SPOOL"
for q in "$SPOOL"/w.*.req; do
  [ -f "$q" ] && [ ! -L "$q" ] || continue
  b=$(basename "$q" .req)
  rq "$q"
  c=$(kv core); f=$(kv file); op=$(kv op); mk=$(kv mark)
  case $c in paqet) d=$CONF ;; gost2) d=$R/etc/gost2 ;; gost3) d=$R/etc/gost3 ;; *) d="" ;; esac
  if [ -z "$d" ]; then
    msg="rejected: core"
  elif [ "$op" = fix ] && [ "$b" = "w.$c.fix" ]; then
    fixdir "$d"
    fixfiles "$d" "$TG" "$d"/*.yaml "$d"/*.json
    msg="ok: fixed $(snow)"
  elif ! printf '%s' "$f" | grep -Eqx '[a-z0-9][a-z0-9_-]{0,31}\.(yaml|json)' || [ "$b" != "w.$c.$f" ]; then
    msg="rejected: file name"
  elif [ "$op" = write ]; then
    src=$SPOOL/$b.data
    if [ -f "$src" ] && [ ! -L "$src" ]; then
      mkdir -p "$d" && fixdir "$d"
      if in_stage "$d" st_copy "$src" "$f" 1048576 "$G:$TG"; then
        msg="ok: wrote $d/$f $(snow)"
      else msg="failed: write $(snow)"; fi
    else msg="rejected: data"; fi
  elif [ "$op" = delete ]; then
    if [ -f "$d/$f" ] && [ ! -L "$d/$f" ]; then rm -f -- "$d/$f"; fi
    n=${f%.*}
    if [ "$c" = paqet ] && [ "$mk" = "paqet-$n.service" ] && valid "$n"; then
      [ -e "$CONF/.deleted" ] || [ -L "$CONF/.deleted" ] || mkdir -p "$CONF/.deleted"
      printf '%s\n' "$mk" | in_stage "$CONF/.deleted" st_put "$n" 0640 "$ME:$G" || true
    fi
    msg="ok: deleted $(snow)"
  else msg="rejected: op"; fi
  res "$SPOOL" "$b.res" "$msg"
  rm -f -- "$q" "$SPOOL/$b.data"
done
reload=0
# Deleted-tunnel markers: only a real directory (never a symlink to some
# other directory) is scanned; entries are handled relative to it.
did=$(lid "$CONF/.deleted")
if [ -n "$did" ] && cd -P -- "$CONF/.deleted" 2>/dev/null && [ "$(stat -c %d:%i .)" = "$did" ]; then
  for mk in ./*; do
    [ -f "$mk" ] || [ -L "$mk" ] || continue
    n=${mk#./}
    if [ ! -L "$mk" ] && valid "$n" && [ ! -e "$CONF/$n.yaml" ] && plain_ok "$n" && ! systemctl is-active --quiet "paqet-$n.service"; then
      systemctl disable "paqet-$n.service" >/dev/null 2>&1 || true
      rm -f -- "$UNITS/paqet-$n.service" "$WANTS/paqet-$n.service"
      if command -v crontab >/dev/null && crontab -l >/dev/null 2>&1; then
        crontab -l | grep -Ev "systemctl restart paqet-$n(\.service)?( |\$)" | crontab - || true
      fi
      reload=1
    fi
    rm -f -- "$mk"
  done
fi
cd /
[ "$reload" = 0 ] || systemctl daemon-reload
exit 0
HELPER
  cat >"$TMP/reljob" <<'RELJOB'
#!/bin/sh
# Installed by paqet-panel install.sh (v0.7.25). Runs as root in its own
# transient unit (systemd-run paqet-release-ID), started by the root helper
# for a release the panel/agent and the helper have both checked:
#   back up the installed program files -> install.sh ROLE --from . --yes
#   -> health check -> on failure put the backup back and restart.
# The database is not touched: a newer panel's migrations are additive and
# older panels ignore them; the panel saved a database copy before asking.
set -u
R=${PAQET_INSTALL_ROOT:-}
id=${1:-}
printf '%s' "$id" | grep -Eqx '[0-9a-f]{16}' || exit 2
J=$R/var/lib/paqet-release/$id
[ -f "$J/job.env" ] || exit 2
role=$(sed -n 's/^role=//p' "$J/job.env" | head -n1)
to=$(sed -n 's/^to=//p' "$J/job.env" | head -n1)
case $role in panel | node) ;; *) exit 2 ;; esac
printf '%s' "$to" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' || exit 2
exe=$R/opt/paqet-$role/bin/paqet-$role
from=$("$exe" -version 2>/dev/null | awk '{print $2; exit}')
st() { # st STATUS STEP MSG
  printf 'id=%s\nrole=%s\nfrom=%s\nto=%s\nstatus=%s\nstep=%s\ntime=%s\nmsg=%s\n' "$id" "$role" "$from" "$to" "$1" "$2" "$(date -u +%FT%TZ)" "$3" >"$J/state.tmp"
  mv -f "$J/state.tmp" "$J/state"
}
kick() { [ -n "$R" ] || systemctl start --no-block paqet-panel-helper.service >/dev/null 2>&1 || true; }
log=$J/install.log
: >"$log"
# 1. backup of everything install.sh may replace
st running backup ""
list=""
for f in "opt/paqet-$role" "etc/paqet-$role" "etc/systemd/system/paqet-$role.service" \
  etc/systemd/system/paqet-panel-helper.service etc/systemd/system/paqet-panel-helper.path etc/systemd/system/paqet-panel-helper.timer \
  usr/local/libexec/paqet-panel-helper usr/local/libexec/paqet-release-job "etc/polkit-1/rules.d/50-paqet-$role.rules" \
  usr/local/bin/paqet-caddy etc/paqet-proxy etc/systemd/system/paqet-proxy.service \
  etc/systemd/system/paqet@.service etc/systemd/system/gost2@.service etc/systemd/system/gost3@.service etc/systemd/system/paqet-tunnels.target; do
  if [ -e "$R/$f" ]; then list="$list $f"; fi
done
# shellcheck disable=SC2086 # list is a set of fixed relative paths
if ! tar -C "${R:-/}" -czf "$J/backup.tgz" $list >>"$log" 2>&1; then
  st failed backup "backup failed; nothing was changed"
  kick
  exit 1
fi
# 2. the full installer from the release folder (keeps settings: no listen/domain options)
st running install ""
rc=0
(cd "$J/rel" && bash ./install.sh "$role" --from . --yes) >>"$log" 2>&1 || rc=$?
# 3. health: the service runs the new version and stays up
ok=0
if [ "$rc" = 0 ]; then
  st running health ""
  i=0
  while [ "$i" -lt "${PAQET_RELEASE_WAIT:-45}" ]; do
    i=$((i + 1))
    if systemctl is-active --quiet "paqet-$role" && [ "$("$exe" -version 2>/dev/null | awk '{print $2; exit}')" = "$to" ]; then
      sleep "${PAQET_RELEASE_SETTLE:-8}"
      systemctl is-active --quiet "paqet-$role" && ok=1
      break
    fi
    sleep 2
  done
fi
if [ "$ok" = 1 ]; then
  st "done" "" "installed $to (was $from)"
else
  why="install.sh failed (exit $rc)"
  [ "$rc" != 0 ] || why="paqet-$role did not come up healthy on $to"
  st running rollback "$why"
  if tar -C "${R:-/}" -xzf "$J/backup.tgz" >>"$log" 2>&1; then
    systemctl daemon-reload >>"$log" 2>&1 || true
    systemctl restart "paqet-$role" >>"$log" 2>&1 || true
    systemctl restart paqet-panel-helper.path >>"$log" 2>&1 || true
    sleep "${PAQET_RELEASE_SETTLE:-8}"
    if systemctl is-active --quiet "paqet-$role"; then
      st rolled_back "" "$why; the previous version ($from) was put back"
    else
      st failed rollback "$why; files put back but paqet-$role is not running: see $log"
    fi
  else
    st failed rollback "$why; restoring the backup failed: restore $J/backup.tgz by hand"
  fi
fi
# keep the last 3 jobs
ls -dt "$R"/var/lib/paqet-release/*/ 2>/dev/null | tail -n +4 | while IFS= read -r d; do rm -rf -- "$d"; done
kick
RELJOB
  run install -d -m 0755 "$(dirname "$h")"
  put_file "$h" 0755 root:root "$TMP/helper"
  put_file "$R/usr/local/libexec/paqet-release-job" 0755 root:root "$TMP/reljob"
  cat >"$TMP/helper.service" <<UNIT
# Installed by install.sh (see $h).
[Unit]
Description=paqet-panel root helper (config permissions, tunnel unit cleanup)
StartLimitIntervalSec=0

[Service]
Type=oneshot
Environment=PANEL_GROUP=$SVC_USER
ExecStart=/bin/sh $h
UNIT
  cat >"$TMP/helper.path" <<UNIT
[Unit]
Description=paqet-panel root helper trigger

[Path]
PathChanged=$TUNNEL_CONF
DirectoryNotEmpty=$TUNNEL_CONF/.deleted
# v0.7.22: only request files trigger it; the helper's own state there
# (fwx.live, *.keep, *.res) must not, or it would run in a loop.
PathExistsGlob=$TUNNEL_CONF/.ops/*.req
DirectoryNotEmpty=$R/var/lib/paqet-spool

[Install]
WantedBy=multi-user.target
UNIT
  cat >"$TMP/helper.timer" <<UNIT
[Unit]
Description=paqet-panel root helper (periodic)

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNIT
  local u
  for u in service path timer; do
    put_file "$UNIT_DIR/paqet-panel-helper.$u" 0644 root:root "$TMP/helper.$u"
  done
  run systemctl daemon-reload
  run systemctl enable --now paqet-panel-helper.path paqet-panel-helper.timer >/dev/null 2>&1 || warn "could not enable paqet-panel-helper"
  # an already running path unit keeps its old watches until restarted
  run systemctl restart paqet-panel-helper.path >/dev/null 2>&1 || warn "could not restart paqet-panel-helper.path"
  # Run once now: permissions only, no tunnel is stopped or restarted.
  run systemctl start paqet-panel-helper.service || warn "paqet-panel-helper failed (see journalctl -u paqet-panel-helper)"
}

# install_proxy DIR: paqet-proxy, a panel-managed Caddy (layer4 + Cloudflare
# DNS) for putting forwards behind one port. It starts with no listeners and
# is driven only through its admin socket (group paqet-proxy). Optional: a
# release without the binary skips it.
install_proxy() {
  local dir=$1 name="paqet-caddy-linux-$ARCH" changed=0
  if ! (get_binary "$dir" "$name") 2>/dev/null; then
    warn "$name not in this release; reverse proxy not installed"
    return 0
  fi
  ensure_user paqet-proxy
  [ -e "$R/usr/local/bin/paqet-caddy" ] && cmp -s "$dir/$name" "$R/usr/local/bin/paqet-caddy" || changed=1
  install_bin "$dir/$name" "$R/usr/local/bin/paqet-caddy" root:root
  run install -d -m 0755 "$R/etc/paqet-proxy"
  printf '{"admin":{"listen":"unix//run/paqet-proxy/admin.sock|0660"}}\n' >"$TMP/base.json"
  put_file "$R/etc/paqet-proxy/base.json" 0644 root:root "$TMP/base.json"
  cat >"$TMP/paqet-proxy.service" <<'UNIT'
# Installed by install.sh. Config is pushed by paqet-panel / paqet-node over
# the admin socket and autosaved (--resume); restarts keep the last config.
[Unit]
Description=paqet-proxy (reverse proxy managed by paqet-panel)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=paqet-proxy
Group=paqet-proxy
Environment=HOME=/var/lib/paqet-proxy XDG_DATA_HOME=/var/lib/paqet-proxy XDG_CONFIG_HOME=/var/lib/paqet-proxy
ExecStart=/usr/local/bin/paqet-caddy run --resume --config /etc/paqet-proxy/base.json
Restart=always
RestartSec=3
StateDirectory=paqet-proxy
StateDirectoryMode=0700
RuntimeDirectory=paqet-proxy
RuntimeDirectoryMode=0750
RuntimeDirectoryPreserve=yes
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
  put_file "$UNIT_DIR/paqet-proxy.service" 0644 root:root "$TMP/paqet-proxy.service"
  run systemctl daemon-reload
  [ "$NO_START" = 1 ] && return 0
  if ! systemctl is-active --quiet paqet-proxy; then
    run systemctl enable --now paqet-proxy
  elif [ "$changed" = 1 ]; then
    # The proxy carries no tunnel; a restart only blips proxied connections.
    run systemctl restart paqet-proxy
  fi
}

install_panel() {
  SVC_USER=paqet-panel
  local bindir=$PREFIX/paqet-panel/bin data=$VAR/paqet-panel etc=$ETC/paqet-panel dir
  if [ -x "$bindir/paqet-panel" ]; then
    say "existing panel found: $("$bindir/paqet-panel" -version 2>/dev/null || echo unknown)"
    confirm "Upgrade it? (config and data are kept)" y || die "aborted"
  elif service_exists paqet-panel; then
    die "a paqet-panel.service from another installation exists ($UNIT_DIR/paqet-panel.service, binary $bindir/paqet-panel missing).
  It is not ours, so it was left untouched. If you no longer need it, run:
    sudo systemctl disable --now paqet-panel
    sudo mv $UNIT_DIR/paqet-panel.service /root/paqet-panel.service.old
    sudo systemctl daemon-reload
  then re-run this installer. (Its data and config are not deleted.)"
  fi
  # v0.7.34: check the port the panel will listen on before anything is
  # changed (a re-run with a busy port used to rewrite panel.yaml and then
  # stop the running panel).
  local target=$LISTEN
  if [ -f "$etc/panel.yaml" ] && [ "$LISTEN_SET" = 0 ] && [ -z "$CERT_DIR" ] && [ -z "$DOMAIN" ]; then
    target=$(sed -n 's/^listen: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$etc/panel.yaml" | head -n 1)
    [ -n "$target" ] || target=$LISTEN
  fi
  precheck_port paqet-panel "$target" "$(rerun_cmd -s) panel --port $(free_port)${DOMAIN:+ --domain $DOMAIN}${EMAIL:+ --email $EMAIL}"
  if [ "$ACME_HTTP" = 1 ] && [ "$NO_START" != 1 ]; then
    # v0.7.37: HTTP-01 needs port 80 for the first certificate and renewals.
    # v0.7.38: name the service+PID; --stop-conflicting / wizard Y/N/P.
    handle_port_conflict paqet-panel 0.0.0.0:80 "free port 80 (it must stay free for renewals), or
    - serve the panel on 443: $(rerun_cmd -s) panel --domain $DOMAIN --email ${EMAIL:-ADDR}, or
    - get a certificate yourself so it is in /etc/letsencrypt/live/$DOMAIN/
      (e.g. certbot certonly --webroot or a DNS plugin), then:
      $(rerun_cmd -s) panel --domain $DOMAIN --port ${LISTEN##*:}" http01
  fi
  dir=$(fetch_release "${REPO:-local/panel}")
  get_binary "$dir" "paqet-panel-linux-$ARCH"
  get_binary "$dir" update-guard.sh

  ensure_user "$TUNNEL_USER"
  [ "$AS_ROOT" = 1 ] || ensure_user "$SVC_USER"
  [ "$AS_ROOT" = 0 ] || SVC_USER=root
  run install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$data"
  run install -d -m 0750 -o root -g "$SVC_USER" "$etc"
  make_core_dirs
  install_bin "$dir/paqet-panel-linux-$ARCH" "$bindir/paqet-panel" "$SVC_USER:$SVC_USER"
  install_bin "$dir/update-guard.sh" "$bindir/update-guard.sh" "root:root" "$SVC_USER:$SVC_USER"
  install_core

  detect_core "$etc/panel.yaml"
  local tlsconf=""
  if [ -n "$CERT_DIR" ]; then
    run install -d -m 0750 -o root -g "$SVC_USER" "$etc/tls"
    run install -m 0640 -o root -g "$SVC_USER" "$CERT_DIR/fullchain.pem" "$etc/tls/fullchain.pem"
    run install -m 0640 -o root -g "$SVC_USER" "$CERT_DIR/privkey.pem" "$etc/tls/privkey.pem"
    if [ -d "$R/etc/letsencrypt/renewal-hooks/deploy" ]; then
      # shellcheck disable=SC2016 # $RENEWED_LINEAGE expands in the hook
      printf '#!/bin/sh\n# installed by paqet-panel install.sh: copy renewed cert for the panel\n[ "$RENEWED_LINEAGE" = "%s" ] || exit 0\ninstall -m 0640 -o root -g %s "$RENEWED_LINEAGE/fullchain.pem" %s/tls/fullchain.pem\ninstall -m 0640 -o root -g %s "$RENEWED_LINEAGE/privkey.pem" %s/tls/privkey.pem\nsystemctl try-restart paqet-panel\n' \
        "$CERT_DIR" "$SVC_USER" "$etc" "$SVC_USER" "$etc" >"$TMP/hook"
      put_file "$R/etc/letsencrypt/renewal-hooks/deploy/paqet-panel.sh" 0755 root:root "$TMP/hook"
    fi
    tlsconf=$(printf 'tls:\n  cert_file: %s/tls/fullchain.pem\n  key_file: %s/tls/privkey.pem\n' "$etc" "$etc")
  elif [ -n "$DOMAIN" ]; then
    tlsconf=$(printf 'tls:\n  acme:\n    domains: ["%s"]\n    email: "%s"\n' "$DOMAIN" "$EMAIL")
    [ -z "$ACME_DIR" ] || tlsconf=$(printf '%s\n    directory_url: "%s"\n' "$tlsconf" "$ACME_DIR")
    if [ "$ACME_HTTP" = 1 ]; then
      tlsconf=$(printf '%s\n    challenge: http-01\n    http_listen: ":80"\n' "$tlsconf")
    fi
  fi
  local fresh=0
  [ -f "$etc/panel.yaml" ] || fresh=1
  if [ "$fresh" = 1 ]; then
    {
      printf '# Generated by install.sh. Re-run install.sh with --listen, --port,\n# --domain/--email to change listen/tls; restart paqet-panel after edits.\n'
      printf 'listen: "%s"\n' "$LISTEN"
      printf 'data_dir: %s\n' "$data"
      printf 'cores:\n  unit_dir: %s\n  versions_dir: %s\n' "$UNIT_DIR" "$VERSIONS_DIR"
      printf '  paqet:\n    enabled: true\n    config_dir: %s\n    binary: %s\n    run_as: %s\n' "$TUNNEL_CONF" "$CORE_BIN" "$TUNNEL_USER"
      printf '  gost2:\n    enabled: true\n    config_dir: %s\n    run_as: %s\n' "$GOST2_CONF" "$TUNNEL_USER"
      printf '  gost3:\n    enabled: true\n    config_dir: %s\n    run_as: %s\n' "$GOST3_CONF" "$TUNNEL_USER"
      printf 'updates:\n  api: "%s"\n' "$API"
      [ -z "$REPO" ] || printf '  panel_repo: "%s"\n' "$REPO"
      [ -z "$CORE_REPO" ] || printf '  core_repo: "%s"\n' "$CORE_REPO"
      [ -z "$PUBKEY" ] || printf '  public_key: "%s"\n' "$PUBKEY"
      [ -z "$tlsconf" ] || printf '%s\n' "$tlsconf"
    } >"$TMP/panel.yaml"
    run install -m 0640 -o root -g "$SVC_USER" "$TMP/panel.yaml" "$etc/panel.yaml"
  else
    if [ "$CORE_CUR" != "$CORE_BIN" ] && [ -x "$CORE_BIN" ]; then
      # The configured core is missing (or unset): point it at the found one.
      # Replace the paqet section's binary line, or add one after its
      # config_dir when there is none (never a second key).
      local has=0
      [ -z "$CORE_CUR" ] || has=1
      awk -v b="$CORE_BIN" -v has="$has" '
        /^  paqet:/ { p = 1; print; next }
        /^  [a-z0-9]+:/ || /^[^ ]/ { p = 0 }
        p && /^    binary:/ { if (!done) print "    binary: " b; done = 1; next }
        p && !has && /^    config_dir:/ && !done { print; print "    binary: " b; done = 1; next }
        { print }' "$etc/panel.yaml" >"$TMP/panel.yaml"
      run cp -p "$etc/panel.yaml" "$etc/panel.yaml.bak"
      run install -m 0640 -o root -g "$SVC_USER" "$TMP/panel.yaml" "$etc/panel.yaml"
      say "paqet core in $etc/panel.yaml: ${CORE_CUR:-unset} -> $CORE_BIN"
    else
      say "keeping paqet core $CORE_BIN"
    fi
  fi
  if [ "$fresh" = 0 ] && [ -n "$REPO" ] && ! grep -Eq '^[[:space:]]+panel_repo:' "$etc/panel.yaml"; then
    # v0.7.36: an install without updates.panel_repo (one-liner before
    # v0.7.36) gets the release repository, so the Updates page finds releases.
    awk -v r="$REPO" '
      /^updates:/ { print; print "  panel_repo: \"" r "\""; done = 1; next }
      { print }
      END { if (!done) { print "updates:"; print "  panel_repo: \"" r "\"" } }' "$etc/panel.yaml" >"$TMP/panel.yaml"
    run cp -p "$etc/panel.yaml" "$etc/panel.yaml.bak"
    run install -m 0640 -o root -g "$SVC_USER" "$TMP/panel.yaml" "$etc/panel.yaml"
    say "updates.panel_repo in $etc/panel.yaml: $REPO (old copy: $etc/panel.yaml.bak)"
  fi
  if [ "$fresh" = 1 ]; then
    :
  elif [ "$LISTEN_SET" = 1 ] || [ -n "$tlsconf" ]; then
    # Re-run with --listen/--port/--domain: apply them to the existing config.
    awk -v l="$LISTEN" -v t="$tlsconf" '
      /^listen:/ { print "listen: \"" l "\""; next }
      /^tls:/ { skip = 1; next }
      skip && /^[ \t]/ { next }
      { skip = 0; print }
      END { if (t != "") print t }' "$etc/panel.yaml" >"$TMP/panel.yaml"
    run cp -p "$etc/panel.yaml" "$etc/panel.yaml.bak"
    run install -m 0640 -o root -g "$SVC_USER" "$TMP/panel.yaml" "$etc/panel.yaml"
    say "updated listen ($LISTEN)${tlsconf:+ and tls} in $etc/panel.yaml (old copy: $etc/panel.yaml.bak)"
    if [ -z "$CERT_DIR" ]; then
      # v0.7.37: no longer on a certbot certificate: remove our deploy hook
      # and the copied certificate (a certbot lineage itself is not touched)
      local hook=$R/etc/letsencrypt/renewal-hooks/deploy/paqet-panel.sh
      if [ -f "$hook" ] && grep -q 'installed by paqet-panel install.sh' "$hook" 2>/dev/null; then
        run rm -f -- "$hook"
        say "removed the certbot deploy hook $hook (the panel no longer uses that certificate)"
      fi
      if [ -d "$etc/tls" ] && [ ! -L "$etc/tls" ]; then
        run rm -rf -- "$etc/tls"
        say "removed $etc/tls (copied certificate no longer used)"
      fi
    fi
  else
    LISTEN=$(sed -n 's/^listen: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$etc/panel.yaml" | head -n 1)
    say "keeping existing $etc/panel.yaml (listen $LISTEN)"    # v0.7.26: a re-run without options (e.g. by the release job) keeps
    # the low-port capability an earlier --domain/--port run gave the unit.
    if grep -qx 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$UNIT_DIR/paqet-panel.service" 2>/dev/null; then
      NEED_BIND=1
      say "keeping CAP_NET_BIND_SERVICE of the existing unit"
    fi
  fi
  [ -z "$DOMAIN" ] || NEED_BIND=1
  if low_port "$LISTEN"; then NEED_BIND=1; fi

  write_tunnel_units "$bindir/paqet-panel" core-unit -config "$etc/panel.yaml"
  write_tunnels_target
  write_polkit
  write_helper
  install_proxy "$dir"
  {
    cat <<UNIT
# Installed by install.sh. Overrides belong in a drop-in:
#   systemctl edit paqet-panel
[Unit]
Description=paqet-panel (tunnel management panel)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
Type=simple
ExecStartPre=/bin/sh $bindir/update-guard.sh $bindir/paqet-panel $data
ExecStart=$bindir/paqet-panel -config $etc/panel.yaml
Restart=always
RestartSec=3
UNIT
    user_lines
    rw_paths "$data" "$bindir"
    unit_sandbox
    printf '\n[Install]\nWantedBy=multi-user.target\n'
  } >"$TMP/paqet-panel.service"
  put_file "$UNIT_DIR/paqet-panel.service" 0644 root:root "$TMP/paqet-panel.service"
  [ "$NO_START" = 1 ] || check_port paqet-panel "$LISTEN"
  start_or_restart paqet-panel

  local where=$LISTEN url
  if [ -n "$DOMAIN" ]; then
    url=https://$DOMAIN
    [ "${LISTEN##*:}" = 443 ] || url=$url:${LISTEN##*:}
    if [ -n "$CERT_DIR" ]; then
      where="$LISTEN ($url, certificate from certbot: $CERT_DIR)"
    elif [ -n "$ACME_DIR" ]; then
      where="$LISTEN ($url, certificate from $ACME_DIR via the built-in ACME client)"
    else
      where="$LISTEN ($url, certificate from Let's Encrypt via the built-in ACME client)"
    fi
    if [ "$ACME_HTTP" = 1 ]; then
      where="$where
           the certificate is requested on the first HTTPS visit and renewed
           through port 80 (HTTP-01): keep TCP 80 and ${LISTEN##*:} open in the firewall"
    fi
  elif [ -n "$CERT_DIR" ]; then
    where="$LISTEN (HTTPS, certificate from $CERT_DIR)"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    cat <<DONE

Dry run: nothing was installed or changed. Without --dry-run, paqet-panel
would be installed with:
  config:  $etc/panel.yaml
  data:    $data
  listen:  $where
DONE
    return 0
  fi
  cat <<DONE

paqet-panel is installed.
  config:  $etc/panel.yaml
  data:    $data
  listen:  $where
DONE
  # v0.7.37: the first-administrator hint only while there is none
  local admins=""
  if [ "$SVC_USER" = root ]; then
    admins=$("$bindir/paqet-panel" admin list -config "$etc/panel.yaml" 2>/dev/null | tail -n +2) || admins="?"
  elif command -v runuser >/dev/null; then
    admins=$(runuser -u "$SVC_USER" -- "$bindir/paqet-panel" admin list -config "$etc/panel.yaml" 2>/dev/null | tail -n +2) || admins="?"
  else
    admins="?"
  fi
  if [ -z "$admins" ]; then
    cat <<DONE

Create the first administrator (there is no default password):
  sudo -u $SVC_USER $bindir/paqet-panel admin create -config $etc/panel.yaml --username <name>
DONE
  elif [ "$admins" = "?" ]; then
    cat <<DONE

If no administrator exists yet, create one (there is no default password):
  sudo -u $SVC_USER $bindir/paqet-panel admin create -config $etc/panel.yaml --username <name>
DONE
  else
    printf '\nAdministrators: %s (manage them with: sudo -u %s %s/paqet-panel admin list|create|reset-password -config %s)\n' \
      "$(printf '%s\n' "$admins" | awk '{print $2}' | paste -sd, -)" "$SVC_USER" "$bindir" "$etc/panel.yaml"
  fi
  case $LISTEN in
    127.0.0.1:* | localhost:* | \[::1\]:*) printf '\nThe panel listens on loopback only; reach it with: ssh -L 8480:%s <server>\n' "$LISTEN" ;;
  esac
}

install_node() {
  SVC_USER=paqet-node
  local bindir=$PREFIX/paqet-node/bin data=$VAR/paqet-node etc=$ETC/paqet-node dir
  if [ -x "$bindir/paqet-node" ]; then
    say "existing node agent found: $("$bindir/paqet-node" -version 2>/dev/null || echo unknown)"
    confirm "Upgrade it? (enrollment and tunnels are kept)" y || die "aborted"
  elif service_exists paqet-node; then
    die "a paqet-node.service exists but $bindir/paqet-node does not; refusing to guess."
  fi
  if [ -x "$PREFIX/paqet-panel/bin/paqet-panel" ]; then
    warn "paqet-panel is installed on this host and already manages its tunnels (as \"panel host\"). A node agent here would manage the same tunnels a second time (duplicate listings and alerts)."
    confirm "Install the node agent anyway?" || die "aborted"
  fi
  # v0.7.23: an update keeps the agent's listen address unless given again
  # (--node-listen). v0.7.34: its port is checked before anything changes.
  local keep
  if [ "$NODE_LISTEN_SET" = 0 ]; then
    keep=$(unit_arg "$UNIT_DIR/paqet-node.service" --listen)
    # v0.7.36: after "uninstall node" (unit gone, config kept) the address
    # the panel knows is still the one saved at the last install.
    if [ -z "$keep" ] && [ -f "$etc/listen" ]; then
      keep=$(head -n 1 "$etc/listen" 2>/dev/null || true)
    fi
    if [[ $keep =~ ^[][A-Za-z0-9.:-]*:[0-9]{1,5}$ ]] && [ "$keep" != "$NODE_LISTEN" ]; then
      NODE_LISTEN=$keep
      say "keeping the agent's listen address $keep (--node-listen changes it)"
    fi
  fi
  precheck_port paqet-node "$NODE_LISTEN" "$(rerun_cmd -s) node --node-listen 0.0.0.0:<free port>"
  dir=$(fetch_release "${REPO:-local/panel}")
  get_binary "$dir" "paqet-node-linux-$ARCH"
  get_binary "$dir" update-guard.sh

  ensure_user "$TUNNEL_USER"
  [ "$AS_ROOT" = 1 ] || ensure_user "$SVC_USER"
  [ "$AS_ROOT" = 0 ] || SVC_USER=root
  run install -d -m 0700 -o "$SVC_USER" -g "$SVC_USER" "$data"
  run install -d -m 0750 -o root -g "$SVC_USER" "$etc"
  make_core_dirs
  install_bin "$dir/paqet-node-linux-$ARCH" "$bindir/paqet-node" "$SVC_USER:$SVC_USER"
  install_bin "$dir/update-guard.sh" "$bindir/update-guard.sh" "root:root" "$SVC_USER:$SVC_USER"
  install_core

  if [ -n "$TOKEN" ]; then
    printf 'PAQET_NODE_TOKEN=%s\n' "$TOKEN" >"$TMP/token.env"
    run install -m 0600 -o root -g root "$TMP/token.env" "$etc/token.env"
  fi
  printf '%s\n' "$NODE_LISTEN" >"$TMP/listen"
  run install -m 0644 -o root -g root "$TMP/listen" "$etc/listen"
  detect_core
  # v0.7.23: an update keeps the agent's paqet core unless a core from
  # --core-repo is installed anew.
  local unit=$UNIT_DIR/paqet-node.service old
  old=$(unit_arg "$unit" --paqet-binary)
  if [ -z "$CORE_REPO" ] && [ -n "$old" ] && [ "$old" != "$CORE_BIN" ] && [ -x "$old" ]; then
    CORE_BIN=$old
    say "keeping paqet core $old"
  fi
  local args=(serve --listen "$NODE_LISTEN" --data-dir "$data" --paqet-config-dir "$TUNNEL_CONF"
    --unit-dir "$UNIT_DIR" --paqet-binary "$CORE_BIN" --paqet-run-as "$TUNNEL_USER"
    --versions-dir "$VERSIONS_DIR" --gost2-config-dir "$GOST2_CONF" --gost3-config-dir "$GOST3_CONF")
  write_tunnel_units "$bindir/paqet-node" core-unit "${args[@]:1}"
  write_tunnels_target
  write_polkit
  write_helper
  install_proxy "$dir"
  if low_port "$NODE_LISTEN"; then NEED_BIND=1; fi
  {
    cat <<UNIT
# Installed by install.sh.
[Unit]
Description=paqet-node (agent managed by paqet-panel)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Only needed until the node is enrolled; delete the file afterwards.
EnvironmentFile=-$etc/token.env
# Rolls a failed self-update back to paqet-node.prev (see update-guard.sh).
ExecStartPre=/bin/sh $bindir/update-guard.sh $bindir/paqet-node $data
ExecStart=$bindir/paqet-node ${args[*]}
Restart=always
RestartSec=3
UNIT
    user_lines
    rw_paths "$data" "$bindir"
    unit_sandbox
    printf '\n[Install]\nWantedBy=multi-user.target\n'
  } >"$TMP/paqet-node.service"
  put_file "$UNIT_DIR/paqet-node.service" 0644 root:root "$TMP/paqet-node.service"
  [ "$NO_START" = 1 ] || check_port paqet-node "$NODE_LISTEN"
  start_or_restart paqet-node

  if [ "$DRY_RUN" = 1 ]; then
    printf '\nDry run: nothing was installed or changed. Without --dry-run, paqet-node would be installed and listen on %s.\n' "$NODE_LISTEN"
    return 0
  fi
  cat <<DONE

paqet-node is installed and listens on $NODE_LISTEN.
Allow that port ONLY from the panel's IP, e.g.:
  iptables -A INPUT -p tcp --dport ${NODE_LISTEN##*:} -s <panel-ip> -j ACCEPT
  iptables -A INPUT -p tcp --dport ${NODE_LISTEN##*:} -j DROP
DONE
  [ -z "$TOKEN" ] || printf '\nThen click "Enroll" in the panel and remove %s/token.env.\n' "$etc"
  if [ -z "$TOKEN" ] && [ -f "$data/node.crt" ]; then
    printf '\nThis node is already enrolled (no join token needed). If its port changed, set the new address (port %s) on the node in the panel.\n' "${NODE_LISTEN##*:}"
  elif [ -z "$TOKEN" ]; then
    printf '\nNo join token given: add the node in the panel, put its token in %s/token.env and restart paqet-node.\n' "$etc"
  fi
}

# run_uninstall ROLE [options]: v0.7.43 "install.sh uninstall panel|node",
# so the curl one-liner can uninstall too. Fetches the release (the same
# source and checks as an install: SHA256SUMS, optional signature), then
# runs its uninstall.sh, which asks before every stop or delete.
run_uninstall() {
  local role="" pass=() dir
  while [ $# -gt 0 ]; do
    case $1 in
      panel | node)
        [ -z "$role" ] || die "role already set to $role"
        role=$1
        ;;
      --yes)
        YES=1
        pass+=("$1")
        ;;
      --purge | --remove-tunnels) pass+=("$1") ;;
      --repo) need_value "$@" && REPO=$2 && REPO_SET=1 && shift ;;
      --api) need_value "$@" && API=$2 && shift ;;
      --version) need_value "$@" && TAG=$2 && shift ;;
      --from) need_value "$@" && FROM_DIR=$2 && shift ;;
      --pubkey) need_value "$@" && PUBKEY=$2 && shift ;;
      -h | --help)
        cat <<'USAGE'
Usage: install.sh uninstall panel|node [--yes] [--purge] [--remove-tunnels]
                                       [--version TAG] [--repo OWNER/NAME] [--from DIR]

Downloads uninstall.sh from the release (latest unless --version), checks
it against SHA256SUMS and runs it. Every step that stops or deletes
something asks first (--yes answers yes; without a terminal --yes is
required). By default configuration, data, tunnel configs and running
tunnels are kept.
  --purge           also offer to delete data, configuration, the service
                    user and the release-install work files
  --remove-tunnels  also offer to stop and remove tunnels, their configs,
                    the cores, tunnel statistics and the automatic tunnel
                    firewall rules (paqet-autofw-*)
USAGE
        exit 0
        ;;
      *) die "unknown option for uninstall: $1 (see: install.sh uninstall --help)" ;;
    esac
    shift
  done
  [ -n "$role" ] || die "usage: install.sh uninstall panel|node [--yes] [--purge] [--remove-tunnels] (see: install.sh uninstall --help)"
  local re_repo='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' re_tag='^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'
  if [ -z "$FROM_DIR" ]; then
    REPO=${REPO:-$DEFAULT_REPO}
    [[ $REPO =~ $re_repo ]] || die "--repo must be OWNER/NAME"
    command -v curl >/dev/null || die "curl is required (or use --from DIR)"
  fi
  [ -z "$TAG" ] || [[ $TAG =~ $re_tag ]] || die "invalid --version"
  case $API in
    https://*) ;;
    http://127.0.0.1* | http://localhost*) warn "using a plain-http release mirror on loopback" ;;
    *) die "--api must use https" ;;
  esac
  if [ -n "$PUBKEY" ]; then
    [[ $PUBKEY =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "--pubkey must be a base64 ed25519 key"
    command -v openssl >/dev/null || die "openssl (3.x) is required for --pubkey"
  fi
  [ -n "$R" ] || [ "$(id -u)" = 0 ] || die "run as root (sudo)"
  [ "$(uname -s)" = Linux ] || die "Linux only"
  ARCH=$(detect_arch) || die "unsupported architecture $(uname -m)"
  if [ "$YES" = 0 ] && ! { : </dev/tty; } 2>/dev/null; then
    die "no terminal to confirm the steps: run it in a terminal, or add --yes to answer yes to every question"
  fi
  TMP=$(mktemp -d)
  trap cleanup EXIT
  dir=$(fetch_release "${REPO:-local/panel}")
  get_binary "$dir" uninstall.sh
  INSTALL_OK=1
  say "running uninstall.sh $role${pass[*]:+ ${pass[*]}}"
  # stdin may be the piped script itself: uninstall.sh asks on /dev/tty
  bash "$dir/uninstall.sh" "$role" ${pass[@]+"${pass[@]}"} </dev/null
}

main() {
  setup_ui
  if [ "${1:-}" = uninstall ]; then
    shift
    setup_log "uninstall $*"
    run_uninstall "$@"
    return 0
  fi
  parse_args "$@"
  preflight
  TMP=$(mktemp -d)
  trap cleanup EXIT
  case $PROGRAM in
    panel) install_panel ;;
    node) install_node ;;
  esac
  INSTALL_OK=1
  report_stopped_holders
  [ -z "$LOG_FILE" ] || say "install log: $LOG_FILE"
}

# Allow sourcing for tests (INSTALL_SH_LIB=1) without running main.
if [ "${INSTALL_SH_LIB:-0}" != 1 ]; then
  main "$@"
fi
