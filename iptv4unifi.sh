#!/bin/sh
# shellcheck disable=SC2154  # $interface, $ip, ... worden door udhcpc gezet
#
# iptv4unifi 1.1.0 (2026-11-11) — KPN-tv op UniFi OS-routers (UDR7, UDR, UDM, UCG, UXG)
# Voor KPN, XS4ALL en Freedom. Vervanger voor fabianishere/udm-iptv:
#   - één script, geen .deb/debconf; alles in /data (overleeft firmware-updates)
#   - setup-wizard met controle vooraf en eerst testen; overstap van udm-iptv/udr-iptv
#   - automatisch herstel na firmware-update (via unifi-on-boot)
#   - watchdog: herstelt NAT/DHCP/interface als UniFi de config herschrijft
#
# Gebruik:
#   iptv4unifi.sh setup          installatie vanaf nul (wizard); ook overstap van udm-iptv/udr-iptv
#   iptv4unifi.sh status         interface, routes, NAT, multicast en log
#   iptv4unifi.sh check          controle vooraf, verandert niets
#   iptv4unifi.sh reconfigure    instellingen wijzigen (WAN-poort, LAN-bridge, decoders)
#   iptv4unifi.sh decoders [n]   aantal KPN-decoders opgeven (zet quickleave goed)
#   iptv4unifi.sh test [min]     tijdelijk draaien zonder te installeren (standaard 10 min)
#   iptv4unifi.sh debug on|off   uitgebreide logging aan/uit
#   iptv4unifi.sh logs           live meekijken in de log (Ctrl+C om te stoppen)
#   iptv4unifi.sh restart        service herstarten
#   iptv4unifi.sh uninstall      service + boot-hook verwijderen (config blijft in /data)
#   iptv4unifi.sh uninstall --purge   alles verwijderen, ook config en log
#   iptv4unifi.sh info           uitleg: hoe het werkt, bestanden, troubleshooting
#   iptv4unifi.sh install        (intern/boot-hook) niet-interactief installeren/herstellen
#   iptv4unifi.sh run|stop       (intern, door systemd)
#   iptv4unifi.sh version        versie en datum van dit script en van de geïnstalleerde config
#
# VERSIES
#   1.1.0  2026-11-11  alleen KPN (ook XS4ALL/Freedom), Nederlands; overstap van udm-iptv
#                      én udr-iptv; WAN-poort ook via PPPoE-sessie gevonden; nooit
#                      routes naar 0.0.0.0/0 of multicast via tv
#   1.0.0  2026-11-11  meerdere providers (niet gepubliceerd; vervangen door 1.1.0)
#   eerder: udr-iptv 2.0.0 en 2.1.0 (KPN-voorganger, zelfde auteur)
#
# ============================================================== INFO
#
# HOE KPN-TV WERKT
#   Over de glasvezel komen twee VLAN's binnen op de WAN-poort:
#     VLAN 6  internet  -> PPPoE (gebruiker/wachtwoord: internet/internet), regelt UniFi
#     VLAN 4  tv        -> DHCP met vendor-class "IPTV_RG", regelt dit script
#   KPN geeft op VLAN 4 alleen een adres aan een router die zich als "IPTV_RG"
#   meldt. Een decoder direct op VLAN 4 (bridged / "Passthrough VLANs") werkt niet.
#   De decoder vraagt een zender aan met een IGMP-"join" (bv. 224.0.251.118).
#   De IGMP-proxy (improxy) stuurt die join door naar KPN en routeert de
#   multicast-stream terug naar het LAN met de decoder.
#
#        KPN ──VLAN 4── WAN ── iptv (10.x.x.x) ── improxy ── LAN-bridge ── decoder
#                                                (join ↑ / stream ↓)
#        KPN ──VLAN 6── WAN ── PPPoE ── internet (los hiervan, door UniFi)
#
# WAT DIT SCRIPT DOET (bij start van de service)
#   1. VLAN-interface "iptv" (VLAN 4) aanmaken op de WAN-poort
#   2. IP-adres ophalen via DHCP en KPN's statische routes zetten
#      -> nooit een default route, dus internet blijft via PPPoE lopen
#   3. NAT naar de KPN-tv-servers (tv-gids, terugkijken)
#   4. IGMP-proxy starten: upstream iptv, downstream de LAN-bridge(s)
#   5. Watchdog: elke 30 s controleren en zo nodig herstellen
#
# BESTANDEN
#   /data/iptv4unifi/iptv4unifi.sh          dit script (in /data: overleeft firmware-updates)
#   /data/iptv4unifi/iptv4unifi.conf        jouw instellingen
#   /data/iptv4unifi/iptv4unifi.log     log (wordt automatisch ingekort)
#   /data/on_boot.d/10-iptv4unifi.sh  boot-hook: herinstalleert na firmware-update
#   /etc/systemd/system/iptv4unifi.service   systemd-service
#
# QUICKLEAVE (instellen met: iptv4unifi.sh decoders)
#   1 decoder:   aan  -> bij zappen stopt de oude stream direct (sneller zappen)
#   2+ decoders: uit  -> anders valt het beeld op decoder B weg als A zapt
#
# PROBLEMEN OPLOSSEN
#   iptv4unifi.sh check            voorwaarden controleren (verandert niets)
#   iptv4unifi.sh status           interface, routes, NAT, multicast-routes en log
#   tcpdump -ni br4 igmp     vraagt de decoder om zenders? (br4 = jouw LAN-bridge)
#   tcpdump -ni iptv igmp    stuurt de router de joins door naar KPN?
#   ip mroute show           (bron,groep) Iif: iptv Oifs: br4 = stream loopt
#
# ============================================================== EINDE INFO

set -u
VERSION="1.1.0"
RELEASE_DATE="2026-11-11"
VERSTR="$VERSION ($RELEASE_DATE)"

# ---------------------------------------------------------------- vaste paden
BASE_DIR="/data/iptv4unifi"
CONF_FILE="$BASE_DIR/iptv4unifi.conf"
DEB_DIR="$BASE_DIR/debs"
LOG_FILE="$BASE_DIR/iptv4unifi.log"
SELF="$BASE_DIR/iptv4unifi.sh"
RUN_DIR="/run/iptv4unifi"
SERVICE="iptv4unifi"
UNIT_FILE="/etc/systemd/system/$SERVICE.service"
BOOT_HOOK="/data/on_boot.d/10-iptv4unifi.sh"
OLD_CONF="/etc/udm-iptv.conf"
UDR_DIR="/data/udr-iptv"                   # udr-iptv (KPN-voorganger)
UDR_UNIT="/etc/systemd/system/udr-iptv.service"
UDR_HOOK="/data/on_boot.d/10-udr-iptv.sh"
LOG_MAX_BYTES=2000000
SYSNET="/sys/class/net"
IPFWD="/proc/sys/net/ipv4/ip_forward"

# ---------------------------------------------------------------- KPN-standaardwaarden
# Je eigen instellingen in /data/iptv4unifi/iptv4unifi.conf overschrijven deze.
WAN_IF="auto"            # WAN-poort, of auto = poort waar internet-VLAN 6 op draait
INTERNET_VLAN="6"        # KPN internet
IPTV_VLAN="4"            # KPN tv
IPTV_IF="iptv"           # naam van de VLAN-interface die we aanmaken
DHCP_VENDOR="IPTV_RG"    # DHCP optie 60; zonder deze waarde geeft KPN geen adres
IPTV_RANGES="213.75.0.0/16 217.166.0.0/16 195.121.0.0/16"   # KPN-tv-servers
LAN_IFS="br0"            # bridge(s) met decoders (br0 = standaard-LAN, br4 = VLAN 4, ...)
PROXY="improxy"          # improxy (zit in UniFi OS) | igmpproxy
IGMP_VERSION="2"         # KPN gebruikt IGMPv2
QUICKLEAVE="true"        # true = 1 decoder, false = 2 of meer
WATCHDOG_INTERVAL="30"
DEBUG="false"
CONF_VERSION=""

# shellcheck source=/dev/null
[ -r "$CONF_FILE" ] && . "$CONF_FILE"

# ---------------------------------------------------------------- hulpfuncties
log()  { echo "iptv4unifi: $*"; }
die()  { echo "iptv4unifi: fout: $*" >&2; exit 1; }
warn() { echo "iptv4unifi: LET OP: $*" >&2; }
need_root() { [ "$(id -u)" -eq 0 ] || die "draai als root"; }
is_tty() { [ -t 0 ]; }

udhcpc_cmd() {
    if command -v udhcpc >/dev/null 2>&1; then udhcpc "$@"; else busybox udhcpc "$@"; fi
}

ask() {          # ask "vraag" "standaard" -> antwoord in $REPLY (Enter = standaard)
    printf '%s [%s]: ' "$1" "$2"
    read -r REPLY
    [ -z "$REPLY" ] && REPLY=$2
    return 0
}

ask_yes() {      # ask_yes "vraag" J|N -> 0 bij ja
    def=$2
    if [ "$def" = "J" ]; then printf '%s [J/n]: ' "$1"; else printf '%s [j/N]: ' "$1"; fi
    read -r yn
    [ -z "$yn" ] && yn=$def
    case "$yn" in j|J|ja|Ja|y|Y) return 0 ;; *) return 1 ;; esac
}

wait_until() {   # wait_until <seconden> <commando...>
    t=$1; shift
    while ! "$@" >/dev/null 2>&1; do
        t=$((t - 2)); [ "$t" -le 0 ] && return 1
        sleep 2
    done
}

if_exists() { ip link show "$1" >/dev/null 2>&1; }
has_ipv4()  { ip -4 addr show dev "$1" 2>/dev/null | grep -q "inet "; }
if_ipv4()   { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -1; }

# ================================================================ interfaces
# WAN-poort: bij "auto" de parent van het internet-VLAN uit /proc/net/vlan/config,
# bv. "eth4.6 | 6 | eth4" -> eth4. Werkt dus ook met SFP+ of een andere WAN-poort.
resolve_wan_if() {
    if [ "$WAN_IF" != "auto" ]; then echo "$WAN_IF"; return; fi
    w=$(awk -F'|' -v id="$INTERNET_VLAN" \
        'NR > 2 { gsub(/ /, ""); if ($2 == id) { print $3; exit } }' \
        /proc/net/vlan/config 2>/dev/null)
    if [ -z "$w" ]; then
        # Terugval: het apparaat onder de PPPoE-sessie (bv. eth4.6 -> eth4)
        d=$(awk 'NR > 1 && $3 != "" { print $3; exit }' /proc/net/pppoe 2>/dev/null)
        [ -n "$d" ] && w=$(awk -F'|' -v n="$d" 'NR > 2 { gsub(/ /, ""); if ($1 == n) { print $3; exit } }' \
            /proc/net/vlan/config 2>/dev/null)
        w=${w:-$d}
    fi
    echo "$w"
}
wan_known() { [ -n "$(resolve_wan_if)" ]; }

# Andere interfaces met VLAN 4 op dezelfde WAN-poort (bv. van "Passthrough VLANs"
# in UniFi Network 11.1+, of een restant van udm-iptv). Die blokkeren onze interface.
vlan_conflicts() {
    wan=$(resolve_wan_if)
    [ -n "$wan" ] || return 0
    awk -F'|' -v id="$IPTV_VLAN" -v p="$wan" -v own="$IPTV_IF" \
        'NR > 2 { gsub(/ /, ""); if ($2 == id && $3 == p && $1 != own) print $1 }' \
        /proc/net/vlan/config 2>/dev/null
}

list_bridges() {
    for path in "$SYSNET"/br*; do
        [ -e "$path" ] || continue
        b=${path##*/}
        if [ "$b" = "br0" ]; then v="standaard-LAN (VLAN 1)"; else v="VLAN ${b#br}"; fi
        printf '    %-8s %-18s %s\n' "$b" "$(if_ipv4 "$b")" "$v"
    done
}

# Draait er een IGMP-proxy die niet van ons is? (UniFi's eigen "IGMP Proxy", udm-iptv)
foreign_proxy() {
    for p in improxy igmpproxy; do
        for pid in $(pgrep -x "$p" 2>/dev/null); do
            [ -f "$RUN_DIR/proxy.pid" ] && [ "$pid" = "$(cat "$RUN_DIR/proxy.pid")" ] && continue
            echo "$p (pid $pid)"
        done
    done
}

# ================================================================ netwerk
nat_apply() {
    tgt=$1
    for r in $IPTV_RANGES; do
        iptables -t nat -C POSTROUTING -o "$tgt" -d "$r" -j MASQUERADE \
            -m comment --comment iptv4unifi 2>/dev/null && continue
        iptables -t nat -A POSTROUTING -o "$tgt" -d "$r" -j MASQUERADE \
            -m comment --comment iptv4unifi && log "NAT-regel gezet voor $r"
    done
}

nat_clear() {
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -- '--comment iptv4unifi' \
        | sed 's/^-A /-D /' | while read -r rule; do
            # shellcheck disable=SC2086
            iptables -t nat $rule 2>/dev/null || true
        done
}

# DHCP-client op de IPTV-interface. -O staticroutes: KPN geeft de routes naar de
# tv-servers via optie 121. -V IPTV_RG: zonder deze vendor-class geen adres.
# -s $SELF: dit script is zelf de udhcpc-hook (zie dhcp_hook).
dhcp_start() {
    tgt=$1
    mkdir -p "$RUN_DIR"
    [ -f "$RUN_DIR/udhcpc.pid" ] && kill "$(cat "$RUN_DIR/udhcpc.pid")" 2>/dev/null
    udhcpc_cmd -b -R -O staticroutes ${DHCP_VENDOR:+-V "$DHCP_VENDOR"} \
        -p "$RUN_DIR/udhcpc.pid" -s "$SELF" -i "$tgt"
}

dhcp_alive() {
    [ -f "$RUN_DIR/udhcpc.pid" ] && kill -0 "$(cat "$RUN_DIR/udhcpc.pid")" 2>/dev/null
}

network_up() {
    wait_until 120 wan_known || die "WAN-poort niet gevonden (WAN_IF=$WAN_IF); staat internet op VLAN $INTERNET_VLAN?"
    wan=$(resolve_wan_if)
    wait_until 60 if_exists "$wan" || die "interface $wan bestaat niet"

    c=$(vlan_conflicts)
    [ -n "$c" ] && die "VLAN $IPTV_VLAN is al in gebruik op $wan door: $c (staat 'Passthrough VLANs' aan in UniFi?)"

    ip link delete dev "$IPTV_IF" 2>/dev/null
    ip link add link "$wan" name "$IPTV_IF" type vlan id "$IPTV_VLAN" \
        || die "kan VLAN $IPTV_VLAN niet aanmaken op $wan"
    ip link set dev "$IPTV_IF" up
    log "WAN $wan, tv via $IPTV_IF (VLAN $IPTV_VLAN)"

    # Reverse-path filter uit: anders gooit de kernel multicast van KPN weg
    sysctl -qw "net.ipv4.conf.$IPTV_IF.rp_filter=0" 2>/dev/null || true

    dhcp_start "$IPTV_IF"
    # De IGMP-proxy start niet zonder IP-adres op de upstream-interface
    wait_until 60 has_ipv4 "$IPTV_IF" || die "geen adres van KPN op $IPTV_IF na 60s"
    log "$IPTV_IF: $(if_ipv4 "$IPTV_IF")"
    nat_apply "$IPTV_IF"
}

network_down() {
    if [ -f "$RUN_DIR/udhcpc.pid" ]; then
        kill "$(cat "$RUN_DIR/udhcpc.pid")" 2>/dev/null
        rm -f "$RUN_DIR/udhcpc.pid"
    fi
    nat_clear
    ip link delete dev "$IPTV_IF" 2>/dev/null
    rm -f "$RUN_DIR/proxy.conf" "$RUN_DIR/proxy.pid"
}

# ================================================================ udhcpc-hook
# udhcpc roept dit script aan met deconfig|bound|renew|leasefail|nak.
# KPN stuurt "staticroutes" (bv. 213.75.112.0/21 via 10.x.x.1); de router-optie
# wordt dan genegeerd (RFC 3442). Nooit een default route via tv.
# Nooit via tv routeren: default route en multicast-adressen
routable_range() {
    case "$1" in 0.0.0.0/0|0.0.0.0/*|22[4-9].*|23[0-9].*) return 1 ;; esac
    return 0
}

dhcp_routes() {
    if [ -n "${staticroutes:-}" ]; then
        # shellcheck disable=SC2086
        set -- $staticroutes
        while [ $# -ge 2 ]; do
            if [ "$2" != "0.0.0.0" ] && routable_range "$1"; then
                ip -4 route replace "$1" via "$2" dev "$interface"
            fi
            shift 2
        done
    elif [ -n "${router:-}" ]; then
        for r in $IPTV_RANGES; do
            routable_range "$r" && ip -4 route replace "$r" via "${router%% *}" dev "$interface"
        done
    fi
}

dhcp_hook() {
    case "$1" in
        deconfig) ip -4 addr flush dev "$interface"; ip link set dev "$interface" up ;;
        bound|renew)
            ip -4 addr replace "$ip/${mask:-24}" ${broadcast:+broadcast "$broadcast"} dev "$interface"
            dhcp_routes
            log "$1: $ip/${mask:-24} op $interface" ;;
        leasefail) log "geen DHCP-antwoord van KPN op $interface" ;;
        nak)       log "DHCP NAK van KPN op $interface" ;;
    esac
    exit 0
}

# ================================================================ IGMP-proxy
is_lan_if() { case " $LAN_IFS " in *" $1 "*) return 0 ;; esac; return 1; }

conf_improxy() {
    echo "# gegenereerd door iptv4unifi $VERSTR"
    echo "igmp enable version $IGMP_VERSION"
    echo "mld disable"
    if [ "$QUICKLEAVE" = "true" ]; then echo "quickleave enable"; else echo "quickleave disable"; fi
    echo "upstream $1"
    for l in $LAN_IFS; do echo "downstream $l"; done
}

conf_igmpproxy() {
    echo "# gegenereerd door iptv4unifi $VERSTR"
    [ "$QUICKLEAVE" = "true" ] && echo "quickleave"
    echo "phyint $1 upstream ratelimit 0 threshold 1"
    for r in $IPTV_RANGES; do echo "  altnet $r"; done
    for path in "$SYSNET"/*; do
        ifn=${path##*/}
        if [ "$ifn" = "lo" ] || [ "$ifn" = "$1" ]; then continue; fi
        if is_lan_if "$ifn"; then
            echo "phyint $ifn downstream ratelimit 0 threshold 1"
        else
            echo "phyint $ifn disabled"
        fi
    done
}

# Start de proxy op de achtergrond. Zonder debug gaat de (luidruchtige) standaard-
# uitvoer van improxy naar /dev/null, zodat de log klein blijft.
proxy_start() {
    tgt=$1
    command -v "$PROXY" >/dev/null 2>&1 || die "$PROXY niet gevonden (draai: $SELF setup)"
    mkdir -p "$RUN_DIR"
    if [ "$PROXY" = "improxy" ]; then
        conf_improxy "$tgt" > "$RUN_DIR/proxy.conf"
        if [ "$DEBUG" = "true" ]; then improxy -d 5 -c "$RUN_DIR/proxy.conf" &
        else improxy -c "$RUN_DIR/proxy.conf" >/dev/null & fi
    else
        conf_igmpproxy "$tgt" > "$RUN_DIR/proxy.conf"
        if [ "$DEBUG" = "true" ]; then igmpproxy -n -d -v "$RUN_DIR/proxy.conf" &
        else igmpproxy -n "$RUN_DIR/proxy.conf" >/dev/null & fi
    fi
    PROXY_PID=$!
    echo "$PROXY_PID" > "$RUN_DIR/proxy.pid"
    log "$PROXY gestart (pid $PROXY_PID): upstream $tgt, downstream $LAN_IFS"
}

# Log inkorten zonder de open file-handle van systemd te breken (copy-truncate)
log_trim() {
    [ -f "$LOG_FILE" ] || return 0
    [ "$(wc -c < "$LOG_FILE")" -gt "$LOG_MAX_BYTES" ] || return 0
    tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && cat "$LOG_FILE.tmp" > "$LOG_FILE"
    rm -f "$LOG_FILE.tmp"
}

# ================================================================ run + watchdog
# Gestart door systemd. Ernstige fouten (proxy weg, interface weg) -> exit, systemd
# herstart na 10 s. Kleine problemen (NAT weg, DHCP-client weg) herstelt de watchdog.
run() {
    log "iptv4unifi $VERSTR start"
    for l in $LAN_IFS; do
        wait_until 120 if_exists "$l" || die "LAN-bridge $l bestaat niet (check het netwerk in UniFi of draai: $SELF reconfigure)"
    done
    network_up
    PROXY_PID=""
    trap 'log "stoppen"; [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null; exit 0' TERM INT
    proxy_start "$IPTV_IF"

    while sleep "$WATCHDOG_INTERVAL"; do
        kill -0 "$PROXY_PID" 2>/dev/null || die "$PROXY is gestopt; service herstart"
        if_exists "$IPTV_IF" || die "$IPTV_IF verdwenen; service herstart"
        for l in $LAN_IFS; do if_exists "$l" || die "LAN-bridge $l verdwenen; service herstart"; done
        if ! dhcp_alive; then
            log "DHCP-client gestopt; opnieuw starten"
            dhcp_start "$IPTV_IF"
        fi
        has_ipv4 "$IPTV_IF" || log "waarschuwing: $IPTV_IF heeft geen adres van KPN"
        nat_apply "$IPTV_IF"
        log_trim
    done
}

# ================================================================ pakketten
# improxy zit standaard in UniFi OS en blijft na firmware-updates bestaan.
# Is hij er niet, dan proberen we improxy en daarna igmpproxy via apt.
proxy_ensure() {
    command -v "$PROXY" >/dev/null 2>&1 && return 0
    for p in improxy igmpproxy; do
        if command -v "$p" >/dev/null 2>&1; then
            log "$PROXY niet gevonden; ik gebruik $p"
            PROXY=$p; set_conf PROXY "$p"; return 0
        fi
    done
    log "IGMP-proxy installeren via apt..."
    apt-get update -qq >/dev/null 2>&1 || true
    for p in improxy igmpproxy; do
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" >/dev/null 2>&1; then
            PROXY=$p; set_conf PROXY "$p"
            systemctl disable --now "$p" 2>/dev/null || true
            # Kopie bewaren voor herstel zonder internet na een firmware-update
            mkdir -p "$DEB_DIR"; (cd "$DEB_DIR" && apt-get download "$p" >/dev/null 2>&1) || true
            log "$p geïnstalleerd"; return 0
        fi
    done
    if ls "$DEB_DIR"/*.deb >/dev/null 2>&1; then
        dpkg -i "$DEB_DIR"/*.deb >/dev/null 2>&1 && command -v "$PROXY" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# ================================================================ config
set_conf() {     # set_conf KEY VALUE: één regel in iptv4unifi.conf aanpassen of toevoegen
    [ -f "$CONF_FILE" ] || return 0
    if grep -q "^$1=" "$CONF_FILE"; then
        sed -i "s|^$1=\"[^\"]*\"|$1=\"$2\"|" "$CONF_FILE"
    else
        echo "$1=\"$2\"" >> "$CONF_FILE"
    fi
}

write_conf() {
    mkdir -p "$BASE_DIR"
    cat > "$CONF_FILE" <<EOF
# iptv4unifi configuratie (KPN) — aanpassen met: $SELF reconfigure
# Gemaakt met versie $VERSTR op $(date '+%Y-%m-%d %H:%M')
CONF_VERSION="$VERSION"
WAN_IF="$WAN_IF"            # auto = poort waar internet-VLAN 6 op draait
LAN_IFS="$LAN_IFS"          # bridge(s) met decoders
QUICKLEAVE="$QUICKLEAVE"    # true = 1 decoder, false = 2 of meer
PROXY="$PROXY"              # improxy | igmpproxy
DEBUG="$DEBUG"
# Geavanceerd (KPN-waarden; normaal niet aanpassen)
INTERNET_VLAN="$INTERNET_VLAN"
IPTV_VLAN="$IPTV_VLAN"
IPTV_IF="$IPTV_IF"
DHCP_VENDOR="$DHCP_VENDOR"
IPTV_RANGES="$IPTV_RANGES"
IGMP_VERSION="$IGMP_VERSION"
WATCHDOG_INTERVAL="$WATCHDOG_INTERVAL"
EOF
}

copy_self() {
    mkdir -p "$BASE_DIR"
    [ "$(readlink -f "$0")" = "$(readlink -f "$SELF" 2>/dev/null)" ] || cp "$0" "$SELF"
    sed -i 's/\r$//' "$SELF"
    chmod 755 "$SELF"
}

decoders_to_ql() {   # zet $QUICKLEAVE op basis van aantal decoders; 1 bij fout
    case "$1" in
        1)      QUICKLEAVE="true" ;;
        [2-9]*) QUICKLEAVE="false" ;;
        *)      return 1 ;;
    esac
}

# ================================================================ udm-iptv opruimen
udm_iptv_installed() { dpkg -s udm-iptv >/dev/null 2>&1; }

remove_udm_iptv() {
    [ -r "$OLD_CONF" ] && cp "$OLD_CONF" /data/udm-iptv.conf.bak && log "kopie van $OLD_CONF in /data/udm-iptv.conf.bak"
    systemctl disable --now udm-iptv >/dev/null 2>&1 || true
    # udm-iptv ruimt bij stoppen zijn VLAN-interface en DHCP-client niet op
    pkill -f 'udhcpc.*-i iptv' 2>/dev/null || true
    ip link delete iptv 2>/dev/null || true
    for r in 213.75.0.0/16 217.166.0.0/16 195.121.0.0/16; do
        iptables -t nat -D POSTROUTING -d "$r" -j MASQUERADE -o iptv 2>/dev/null || true
    done
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq udm-iptv >/dev/null 2>&1 || true
    if udm_iptv_installed; then warn "udm-iptv kon niet verwijderd worden"; return 1; fi
    log "udm-iptv verwijderd (improxy blijft staan)"
}

udr_iptv_installed() { [ -f "$UDR_UNIT" ] || [ -r "$UDR_DIR/iptv.conf" ]; }

remove_udr_iptv() {
    systemctl disable --now udr-iptv >/dev/null 2>&1 || true
    rm -f "$UDR_UNIT" "$UDR_HOOK"
    systemctl daemon-reload 2>/dev/null || true
    if [ -d "$UDR_DIR" ]; then
        bak="$UDR_DIR.bak-$(date +%Y%m%d)"
        mv "$UDR_DIR" "$bak" && log "bestanden van udr-iptv bewaard in $bak"
    fi
    log "udr-iptv verwijderd"
}

# ================================================================ unifi-on-boot
onboot_installed() {
    systemctl list-unit-files 2>/dev/null | grep -qE '^(unifi-on-boot|udm-boot)'
}

install_onboot() {
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        https://github.com/unredacted/unifi-on-boot/releases/latest 2>/dev/null)
    ver=${url##*/v}
    case "$ver" in [0-9]*) ;; *) ver="1.0.8"; log "laatste versie onbekend; ik gebruik $ver" ;; esac
    tmp=$(mktemp -d)
    if curl -fsSL -o "$tmp/uob.deb" \
        "https://github.com/unredacted/unifi-on-boot/releases/download/v${ver}/unifi-on-boot_${ver}_all.deb" \
        && dpkg -i "$tmp/uob.deb" >/dev/null 2>&1; then
        log "unifi-on-boot $ver geïnstalleerd"
    else
        warn "unifi-on-boot installeren mislukt; zie github.com/unredacted/unifi-on-boot"
    fi
    rm -rf "$tmp"
}

# ================================================================ setup (wizard)
# Volgorde: eerst alleen vragen en controleren (er verandert niets), dan kiezen:
# testen (aanbevolen), direct installeren, alleen opslaan of afbreken.
# udm-iptv wordt pas verwijderd als jij bevestigt dat de tv werkt.
setup() {
    need_root
    is_tty || die "setup is interactief; draai het in een SSH-sessie"
    echo "=== iptv4unifi $VERSTR — KPN-tv instellen ==="
    echo "Stap 1: vragen en controleren. Er wordt nog niets gewijzigd."
    echo

    [ -e /proc/net/ip_mr_vif ] || die "deze kernel ondersteunt geen multicast-routing (firmware bijwerken?)"

    # --- voorgangers (alleen vaststellen, nog niets doen)
    old_lan=""; old_ql=""; have_udm=""; have_udr=""
    if udm_iptv_installed; then
        have_udm="ja"
        # shellcheck source=/dev/null
        old_lan=$( (. "$OLD_CONF" 2>/dev/null; echo "${IPTV_LAN_INTERFACES:-}") )
        echo "udm-iptv (van fabianishere) is geïnstalleerd$(systemctl is-active --quiet udm-iptv && echo ' en draait'). Dat blijft zo tot je zelf kiest."
    fi
    if udr_iptv_installed; then
        have_udr="ja"
        # shellcheck source=/dev/null
        eval "$( (. "$UDR_DIR/iptv.conf" 2>/dev/null; echo "r_lan='${LAN_IFS:-}' r_ql='${QUICKLEAVE:-}'") )"
        old_lan=${r_lan:-$old_lan}; old_ql=$r_ql
        echo "udr-iptv (KPN-voorganger) is geïnstalleerd$(systemctl is-active --quiet udr-iptv && echo ' en draait'). Dat blijft zo tot je zelf kiest."
    fi
    old=""; [ -n "$have_udm" ] && old="udm-iptv"; [ -n "$have_udr" ] && old="${old:+$old en }udr-iptv"
    [ -n "$old" ] && echo

    # --- WAN
    WAN_IF="auto"
    wan=$(resolve_wan_if)
    if [ -n "$wan" ]; then
        echo "WAN-poort gevonden: $wan (KPN-internet op VLAN $INTERNET_VLAN)"
    else
        echo "Geen internet op VLAN $INTERNET_VLAN gevonden."
        echo "Stel in UniFi eerst internet in: WAN-poort, VLAN 6, PPPoE, internet/internet."
        ask "WAN-poort handmatig opgeven (bv. eth4)" ""
        { [ -n "$REPLY" ] && if_exists "$REPLY"; } || die "WAN-poort onbekend"
        WAN_IF=$REPLY; wan=$REPLY
    fi
    echo

    # --- LAN
    echo "Netwerken (LAN-bridges) op deze router:"
    list_bridges
    def="br0"
    if [ -n "$old_lan" ]; then def=$old_lan
    elif if_exists br4; then def="br4"; fi
    echo "Kies de bridge van het netwerk waar je KPN-decoder(s) op zitten."
    ask "LAN-bridge(s), spatie-gescheiden" "$def"
    LAN_IFS=$REPLY
    for l in $LAN_IFS; do if_exists "$l" || die "bridge $l bestaat niet"; done
    echo

    # --- decoders
    ask "Hoeveel KPN-decoders heb je?" "$([ "$old_ql" = "false" ] && echo 2 || echo 1)"
    decoders_to_ql "$REPLY" || die "aantal moet een getal zijn"
    ndec=$REPLY
    echo

    # --- controle vooraf (alleen lezen)
    PROXY="improxy"
    command -v improxy >/dev/null 2>&1 || { command -v igmpproxy >/dev/null 2>&1 && PROXY="igmpproxy"; }
    pre_ok=0
    check pre || pre_ok=1
    echo
    if [ "$pre_ok" -ne 0 ]; then
        echo "De controle vond [FOUT]-meldingen. Los die bij voorkeur eerst op."
        ask_yes "Toch doorgaan?" N || die "afgebroken; er is niets gewijzigd"
    fi

    # --- samenvatting en keuze
    echo "=== Samenvatting ==="
    echo "  WAN-poort:   $wan (tv via VLAN $IPTV_VLAN, DHCP met $DHCP_VENDOR)"
    echo "  LAN:         $LAN_IFS"
    echo "  Decoders:    $ndec (quickleave $( [ "$QUICKLEAVE" = "true" ] && echo aan || echo uit))"
    echo "  IGMP-proxy:  $PROXY (IGMPv$IGMP_VERSION)"
    [ -n "$old" ] && echo "  $old: blijft staan tot na de test"
    echo
    echo "Wat wil je doen?"
    echo "  1) eerst testen (aanbevolen) — daarna kies je of je installeert"
    echo "  2) direct installeren${old:+ ($old wordt verwijderd)}"
    echo "  3) alleen instellingen opslaan"
    echo "  4) afbreken"
    ask "Keuze" "1"; choice=$REPLY

    case "$choice" in
        1)
            copy_self; write_conf
            ask "Hoeveel minuten testen?" "10"; mins=$REPLY
            case "$mins" in ''|*[!0-9]*) mins=10 ;; esac
            echo
            echo "Tijdens de test: haal 10 s de stroom van de decoder af, kijk tv en zap een paar keer."
            echo "Na $mins minuten (of eerder met Ctrl+C) stopt de test vanzelf"
            [ -n "$old" ] && echo "en wordt $old weer gestart."
            echo
            # Eigen proces: de test ruimt altijd zelf op. Ctrl+C stopt alleen de test.
            trap 'echo' INT
            "$SELF" test "$mins" 2>&1 | tee -ia "$LOG_FILE"
            trap - INT
            echo
            echo "Test klaar.${old:+ $old draait weer; er is niets blijvend veranderd.}"
            if ! ask_yes "Werkte de tv goed (beeld en zappen)?" J; then
                echo "Jammer. Er is niets geïnstalleerd. Laatste regels van de test:"
                tail -n 15 "$LOG_FILE" 2>/dev/null
                echo
                echo "Opnieuw testen:  $SELF test 10      Instellingen:  $SELF reconfigure"
                exit 0
            fi
            ask_yes "Nu definitief installeren${old:+ en $old verwijderen}?" J \
                || { log "instellingen bewaard; installeren kan later met: $SELF setup"; exit 0; }
            ;;
        2)
            copy_self; write_conf ;;
        3)
            copy_self; write_conf
            log "opgeslagen in $CONF_FILE; er is verder niets gewijzigd"
            echo "  Testen:       $SELF test 10"
            echo "  Installeren:  $SELF setup"
            exit 0 ;;
        *)
            die "afgebroken; er is niets gewijzigd" ;;
    esac

    # --- vanaf hier wordt er echt iets veranderd
    if [ -n "$have_udm" ]; then
        remove_udm_iptv || die "udm-iptv verwijderen mislukt; er is verder niets gewijzigd"
    fi
    [ -n "$have_udr" ] && remove_udr_iptv
    proxy_ensure || die "geen IGMP-proxy beschikbaar"
    install_service

    echo
    if onboot_installed; then
        log "unifi-on-boot aanwezig: herstel na firmware-updates werkt"
    else
        echo "Voor automatisch herstel na een firmware-update is 'unifi-on-boot' nodig"
        echo "(github.com/unredacted/unifi-on-boot)."
        if ask_yes "unifi-on-boot nu installeren?" J; then install_onboot; fi
    fi

    echo
    log "wachten op KPN..."
    i=0
    while ! has_ipv4 "$IPTV_IF" && [ $i -lt 30 ]; do sleep 2; i=$((i + 1)); done
    if has_ipv4 "$IPTV_IF"; then
        log "klaar! $IPTV_IF heeft $(if_ipv4 "$IPTV_IF") van KPN."
        echo "Herstart je decoder(s) als de tv niet vanzelf beeld geeft."
        echo
        check || true
    else
        warn "nog geen adres van KPN. Kijk in de log: $SELF logs"
    fi
}

# ================================================================ install (niet-interactief)
# Ook gebruikt door de boot-hook na een firmware-update: elke stap mag vaker draaien.
install_service() {
    proxy_ensure || die "geen IGMP-proxy beschikbaar"
    systemctl disable --now igmpproxy 2>/dev/null || true

    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=iptv4unifi $VERSTR (KPN IPTV)
After=network-online.target
Wants=network-online.target
Conflicts=igmpproxy.service udm-iptv.service udr-iptv.service

[Service]
Type=simple
ExecStart=$SELF run
ExecStopPost=$SELF stop
Restart=always
RestartSec=10
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p "${BOOT_HOOK%/*}"
    cat > "$BOOT_HOOK" <<EOF
#!/bin/sh
# iptv4unifi $VERSTR: herstel na firmware-update; doet niets als alles er nog staat
if [ ! -f $UNIT_FILE ]; then
    $SELF install >> $LOG_FILE 2>&1
fi
EOF
    chmod 755 "$BOOT_HOOK"

    log_trim
    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null 2>&1
    systemctl restart "$SERVICE"
    log "service geïnstalleerd en gestart (log: $LOG_FILE)"
}

install() {
    need_root
    copy_self
    [ -r "$CONF_FILE" ] || die "geen config; draai eerst: $SELF setup"
    if systemctl is-active --quiet udm-iptv 2>/dev/null || systemctl is-active --quiet udr-iptv 2>/dev/null; then
        die "udm-iptv of udr-iptv draait nog; draai $SELF setup om over te stappen"
    fi
    install_service
}

uninstall() {
    need_root
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT_FILE" "$BOOT_HOOK"
    systemctl daemon-reload
    log "verwijderd; config en log staan nog in $BASE_DIR"
}

purge() {
    need_root
    ask_yes "Alles verwijderen, inclusief config en log in $BASE_DIR?" N || { log "afgebroken"; return 0; }
    uninstall
    rm -rf "$BASE_DIR"
    log "volledig verwijderd (improxy en unifi-on-boot blijven staan)"
}

# ================================================================ reconfigure / decoders / debug
reconfigure() {
    need_root
    is_tty || die "reconfigure is interactief; draai het in een SSH-sessie"
    [ -r "$CONF_FILE" ] || die "geen config; draai eerst: $SELF setup"
    echo "=== iptv4unifi instellingen wijzigen (Enter = huidige waarde) ==="
    echo "WAN-poort: 'auto' = poort met internet-VLAN $INTERNET_VLAN (nu: $(resolve_wan_if))"
    ask "WAN-poort" "$WAN_IF"; n_wan=$REPLY
    echo "Netwerken (LAN-bridges):"; list_bridges
    ask "LAN-bridge(s) met decoders" "$LAN_IFS"; n_lan=$REPLY
    for l in $n_lan; do if_exists "$l" || die "bridge $l bestaat niet"; done
    cur=$([ "$QUICKLEAVE" = "true" ] && echo 1 || echo 2)
    ask "Aantal KPN-decoders" "$cur"
    decoders_to_ql "$REPLY" || die "aantal moet een getal zijn"
    ask "IGMP-proxy (improxy/igmpproxy)" "$PROXY"; n_proxy=$REPLY
    case "$n_proxy" in improxy|igmpproxy) ;; *) die "kies improxy of igmpproxy" ;; esac
    ask_yes "Opslaan en toepassen?" J || { log "niets gewijzigd"; return 0; }
    WAN_IF=$n_wan; LAN_IFS=$n_lan; PROXY=$n_proxy
    write_conf
    proxy_ensure || die "kon $PROXY niet vinden of installeren"
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl restart "$SERVICE" && log "opgeslagen en service herstart"
    else
        log "opgeslagen; start met: $SELF install"
    fi
}

decoders_cmd() {
    need_root
    [ -r "$CONF_FILE" ] || die "geen config; draai eerst: $SELF setup"
    n=${1:-}
    if [ -z "$n" ]; then
        is_tty || die "gebruik: $0 decoders <aantal>"
        ask "Hoeveel KPN-decoders heb je?" "$([ "$QUICKLEAVE" = "true" ] && echo 1 || echo 2)"; n=$REPLY
    fi
    decoders_to_ql "$n" || die "aantal moet een getal zijn"
    set_conf QUICKLEAVE "$QUICKLEAVE"
    log "$n decoder(s): quickleave $( [ "$QUICKLEAVE" = "true" ] && echo aan || echo uit)"
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl restart "$SERVICE" && log "service herstart"
    fi
}

debug_cmd() {
    need_root
    case "${1:-}" in
        on|aan)  set_conf DEBUG true;  log "debug AAN" ;;
        off|uit) set_conf DEBUG false; log "debug UIT" ;;
        *) die "gebruik: $0 debug on|off" ;;
    esac
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl restart "$SERVICE" && log "service herstart; volg met: $SELF logs"
    fi
}

# ================================================================ LAN-/WAN-inspectie
# Hostnaam bij een MAC-adres uit de DHCP-leases van de router (dnsmasq)
lease_name() {
    for f in /run/dnsmasq.dhcp.leases /run/dnsmasq.leases /var/run/dnsmasq*.leases /run/dnsmasq*/*.leases; do
        [ -r "$f" ] || continue
        n=$(awk -v m="$1" 'tolower($2) == tolower(m) { print $4; exit }' "$f")
        [ -n "$n" ] && [ "$n" != "*" ] && { echo "$n"; return; }
    done
    echo "?"
}

# Apparaten op een bridge: "mac poort" per regel (geleerde adressen, geen eigen poorten)
bridge_clients() {
    bridge fdb show br "$1" 2>/dev/null \
        | awk '!/permanent/ && !/self/ && $2 == "dev" { print $1, $3 }' | sort -u
}

is_wifi_port() { case "$1" in wifi*|ath*|wlan*|ra*) return 0 ;; esac; return 1; }

# Controleert het tv-netwerk aan de LAN-kant. Gebruikt pass/fail/info/attn uit check().
check_lan() {
    for l in $LAN_IFS; do
        if_exists "$l" || continue
        echo "--- tv-netwerk $l ---"
        ip4=$(if_ipv4 "$l")
        if [ -n "$ip4" ]; then pass "$l heeft router-adres $ip4"
        else fail "$l heeft geen IP-adres (VLAN Only-netwerk?). Geef het netwerk in UniFi een gateway/subnet met DHCP"; fi
        [ "$l" = "br0" ] && info "de decoder zit op je standaard-LAN; een apart tv-netwerk houdt de stream van je andere apparaten weg"

        snoop=$(cat "$SYSNET/$l/bridge/multicast_snooping" 2>/dev/null)
        if [ "$snoop" = "1" ]; then pass "IGMP snooping aan op $l"
        else info "IGMP snooping staat uit op $l. Zet in UniFi 'IGMP Snooping' aan voor dit netwerk"; fi

        wired=0; wifi=0; list=""
        for m in "$SYSNET/$l"/brif/*; do
            [ -e "$m" ] || continue
            p=${m##*/}
            if is_wifi_port "$p"; then wifi_ports="${wifi_ports:-} $p"; fi
        done
        tmpc=$(bridge_clients "$l")
        if [ -n "$tmpc" ]; then
            while read -r mac port; do
                [ -n "$mac" ] || continue
                if is_wifi_port "$port"; then wifi=$((wifi + 1)); kind="wifi "; else wired=$((wired + 1)); kind="kabel"; fi
                list="$list
           $kind  $mac  $(lease_name "$mac")  (via $port)"
            done <<EOF2
$tmpc
EOF2
        fi
        total=$((wired + wifi))
        if [ "$total" -eq 0 ]; then
            info "geen apparaten gezien op $l. Staat de decoder aan, en staat zijn switchpoort op dit netwerk (Native VLAN)?"
        else
            pass "$total apparaat/apparaten op $l ($wired via kabel, $wifi via wifi):$list"
        fi
        if [ "$wifi" -gt 0 ]; then
            attn "er zitten wifi-apparaten op het tv-netwerk. Multicast via wifi vertraagt je wifi; koppel geen SSID aan dit netwerk"
        elif [ -n "${wifi_ports:-}" ]; then
            info "wifi-poorten in $l:${wifi_ports} (UniFi maakt die soms standaard aan; geen probleem zolang er geen SSID aan dit netwerk hangt)"
        fi
        wifi_ports=""
    done
}

check_wan() {
    pp=$(ip -4 -o addr show 2>/dev/null | awk '$2 ~ /^ppp/ {print $2": "$4; exit}')
    if [ -n "$pp" ]; then pass "internet via PPPoE ($pp)"
    else info "geen PPPoE-verbinding gevonden; KPN-internet hoort PPPoE op VLAN 6 te zijn"; fi
    if [ "$(cat "$IPFWD" 2>/dev/null)" = "1" ]; then pass "IP-forwarding aan"
    else fail "IP-forwarding staat uit"; fi
}

# ================================================================ status / check
status() {
    echo "=== iptv4unifi $VERSTR ==="
    echo "Config gemaakt met: ${CONF_VERSION:-onbekend}   service: $(sed -n 's/^Description=//p' "$UNIT_FILE" 2>/dev/null || echo 'niet geïnstalleerd')"
    echo "WAN: $(resolve_wan_if) (WAN_IF=$WAN_IF)   tv: VLAN $IPTV_VLAN -> $IPTV_IF"
    echo "LAN: $LAN_IFS   proxy: $PROXY (IGMPv$IGMP_VERSION, quickleave $QUICKLEAVE)"
    echo "Service: $(systemctl is-active "$SERVICE" 2>/dev/null)   boot-hook: $([ -x "$BOOT_HOOK" ] && echo ja || echo nee)   unifi-on-boot: $(onboot_installed && echo ja || echo nee)"
    echo "=== $IPTV_IF ==="
    if if_exists "$IPTV_IF"; then if_ipv4 "$IPTV_IF"; ip -4 route show dev "$IPTV_IF"; else echo "bestaat niet"; fi
    echo "=== NAT ==="
    iptables -t nat -S POSTROUTING 2>/dev/null | grep iptv4unifi || echo "geen regels"
    echo "=== Multicast (VIF / actieve streams) ==="
    cat /proc/net/ip_mr_vif 2>/dev/null
    ip mroute show 2>/dev/null | grep -v unresolved | head -10
    echo "=== Log ==="
    tail -n 15 "$LOG_FILE" 2>/dev/null
}

check() {
    mode=${1:-}      # "pre" = vanuit setup, vóór er een config is
    ok=0
    pass() { echo "  [OK]   $*"; }
    fail() { echo "  [FOUT] $*"; ok=1; }
    info() { echo "  [INFO] $*"; }
    attn() { echo "  [LET OP] $*"; }
    echo "=== iptv4unifi $VERSTR: controle (verandert niets) ==="
    if [ "$mode" != "pre" ]; then
        if [ -r "$CONF_FILE" ]; then pass "config: $CONF_FILE"; else fail "geen config — draai: $0 setup"; fi
    fi
    wan=$(resolve_wan_if)
    if [ -n "$wan" ] && if_exists "$wan"; then pass "WAN-poort: $wan (internet op VLAN $INTERNET_VLAN)"
    else fail "WAN-poort niet gevonden — staat KPN-internet op VLAN $INTERNET_VLAN (PPPoE)?"; fi
    c=$(vlan_conflicts)
    if [ -z "$c" ]; then pass "VLAN $IPTV_VLAN vrij op de WAN-poort"
    else fail "VLAN $IPTV_VLAN bezet door: $c — 'Passthrough VLANs' in UniFi uitzetten"; fi
    for l in $LAN_IFS; do
        if if_exists "$l"; then pass "LAN-bridge: $l ($(if_ipv4 "$l"))"
        else fail "LAN-bridge $l bestaat niet — check het netwerk in UniFi of: $0 reconfigure"; fi
    done
    if command -v "$PROXY" >/dev/null 2>&1; then pass "$PROXY aanwezig"; else fail "$PROXY niet gevonden"; fi
    if command -v udhcpc >/dev/null 2>&1 || busybox udhcpc --help >/dev/null 2>&1; then pass "udhcpc aanwezig"; else fail "udhcpc niet gevonden"; fi
    if [ -e /proc/net/ip_mr_vif ]; then pass "kernel ondersteunt multicast-routing"; else fail "geen multicast-routing in de kernel"; fi
    check_wan
    if udm_iptv_installed; then info "udm-iptv is geïnstalleerd — '$0 setup' biedt aan het te verwijderen"; fi
    if udr_iptv_installed; then info "udr-iptv is geïnstalleerd — '$0 setup' biedt aan het te verwijderen"; fi
    fp=$(foreign_proxy)
    if [ -n "$fp" ] && ! systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        info "er draait al een IGMP-proxy: $fp (udm-iptv, udr-iptv of 'IGMP Proxy' in UniFi?)"
    fi
    if onboot_installed; then pass "unifi-on-boot aanwezig (herstel na firmware-update)"
    else info "geen unifi-on-boot (nodig voor herstel na firmware-update)"; fi
    check_lan
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null && has_ipv4 "$IPTV_IF"; then
        pass "tv-interface $IPTV_IF heeft $(if_ipv4 "$IPTV_IF") van KPN"
        n=$(ip mroute show 2>/dev/null | grep -c "Iif: $IPTV_IF")
        if [ "$n" -gt 0 ]; then pass "$n actieve tv-stream(s)"; else info "geen actieve tv-stream (staat de tv aan?)"; fi
    fi
    echo "--- in UniFi zelf controleren (kan dit script niet zien) ---"
    echo "  - switchpoort van de decoder: Native VLAN = tv-netwerk, Tagged = Block All"
    echo "  - IGMP snooping aan op alle switches tussen router en decoder"
    echo "  - 'IGMP Proxy' en 'Passthrough VLANs' bij je internetverbinding: uit"
    echo "  - geen SSID gekoppeld aan het tv-netwerk"
    if [ "$mode" != "pre" ]; then
        echo "=== $PROXY-config die gegenereerd zou worden ==="
        if [ "$PROXY" = "improxy" ]; then conf_improxy "$IPTV_IF"; else conf_igmpproxy "$IPTV_IF"; fi
    fi
    return $ok
}

# ================================================================ test
# Draait N minuten zonder iets te installeren. Een EXIT-trap ruimt altijd op en
# start een eerder draaiende udm-iptv/iptv4unifi weer: bij einde, Ctrl+C of fout.
test_run() {
    need_root
    mins=${1:-10}
    [ -r "$CONF_FILE" ] || die "geen config; draai eerst: $0 setup"
    copy_self
    restore=""
    for s in udm-iptv udr-iptv "$SERVICE"; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            restore="$restore $s"; log "$s tijdelijk stoppen"; systemctl stop "$s"
        fi
    done
    ip link delete "$IPTV_IF" 2>/dev/null
    PROXY_PID=""
    cleanup() {
        trap - EXIT INT TERM
        log "test beëindigen en opruimen"
        [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
        network_down
        for s in $restore; do systemctl start "$s" && log "$s weer gestart"; done
    }
    trap cleanup EXIT
    trap 'exit 0' INT TERM
    network_up
    proxy_start "$IPTV_IF"
    log "TEST ACTIEF voor $mins minuten — herstart de decoder en zap. Ctrl+C = stoppen."
    end=$(( $(date +%s) + mins * 60 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        sleep 5
        kill -0 "$PROXY_PID" 2>/dev/null || die "$PROXY is gestopt"
        if [ $(( $(date +%s) % 60 )) -lt 5 ]; then
            log "nog ~$(( (end - $(date +%s)) / 60 )) min; actieve streams: $(ip mroute show 2>/dev/null | grep -c 'Iif: ')"
        fi
    done
    log "testtijd voorbij"
}

# ================================================================ main
case "${1:-}" in
    deconfig|bound|renew|leasefail|nak) dhcp_hook "$1" ;;
    run)       run ;;
    stop)      network_down ;;
    setup|migrate) setup ;;
    install)   install ;;
    uninstall) if [ "${2:-}" = "--purge" ]; then purge; else uninstall; fi ;;
    reconfigure|configure) reconfigure ;;
    decoders)  decoders_cmd "${2:-}" ;;
    debug)     debug_cmd "${2:-}" ;;
    logs|log)  tail -n 50 -f "$LOG_FILE" ;;
    check)     check "${2:-}" ;;
    test)      test_run "${2:-10}" ;;
    restart)   systemctl restart "$SERVICE" ;;
    status|diagnose) status ;;
    info)      awk '/^# =+ INFO/ {on=1; next} /^# =+ EINDE INFO/ {exit} on' "$0" | sed 's/^# \{0,1\}//' ;;
    -v|--version|version)
        echo "iptv4unifi $VERSTR"
        [ -r "$CONF_FILE" ] && echo "config:  $CONF_FILE (gemaakt met ${CONF_VERSION:-onbekend})"
        [ -f "$UNIT_FILE" ] && echo "service: $(sed -n 's/^Description=//p' "$UNIT_FILE")"
        ;;
    *) awk 'NR>=3 && /^# =+ INFO/ {exit} NR>=3' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
