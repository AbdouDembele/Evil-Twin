# Evil Twin Lab

Script Bash interactif (`evil-twin.sh`) clone un wifi existant et déconnecte tous ses utilisateurs pour faire du MITM et dns spoofing. 


## Fonctionnalités

- Détection et sélection d'interfaces Wi-Fi
- Activation / désactivation du mode monitor (via `airmon-ng`)
- Scan des réseaux à proximité (via `airodump-ng`)
- Sélection d'un réseau cible (BSSID / ESSID / canal)
- Attaque de désauthentification ciblée (via `aireplay-ng`)
- Création d'un point d'accès de laboratoire (`hostapd` + `dnsmasq`)
  - Attribution IP automatique (DHCP)
  - NAT / forwarding vers Internet
  - Redirections DNS personnalisées (sinkhole de domaines)
- Suivi des clients connectés (connexions / déconnexions, baux DHCP)
- Logs DNS et logs clients consultables depuis le menu
- Nettoyage automatique à la sortie (Ctrl+C géré) : arrêt des services, retour en mode managed, restauration de NetworkManager

## Prérequis

- Linux (testé sur Debian/Ubuntu/Kali)
- Une carte Wi-Fi supportant le mode monitor et l'injection de paquets
- Droits root (`sudo`)
- Paquets requis :

```bash
sudo apt install aircrack-ng hostapd dnsmasq iproute2 iw iptables
```

Le script vérifie automatiquement la présence de ces dépendances au démarrage et s'arrête si l'une d'elles manque.

## Installation

```bash
git clone https://github.com/<votre-utilisateur>/evil-twin.git
cd evil-twin
chmod +x evil-twin.sh
```

## Utilisation

```bash
sudo ./evil-twin.sh
```

Le script affiche un menu interactif :

| Option | Action |
|--------|--------|
| 1 | Afficher les interfaces Wi-Fi |
| 2 | Activer le mode monitor |
| 3 | Scanner les réseaux |
| 4 | Choisir un réseau |
| 5 | Lancer une attaque deauth (aireplay-ng) |
| 6 | Créer l'AP de laboratoire |
| 7 | Voir les clients connectés |
| 8 | Voir les logs clients |
| 9 | Voir les logs réseau |
| 10 | Configurer une redirection DNS |
| 11 | Voir les redirections DNS |
| 12 | Arrêter l'AP |
| 0 | Quitter |

### Flux type

1. Choisir l'interface Wi-Fi (demandé au lancement)
2. **2** – Activer le mode monitor
3. **3** – Scanner les réseaux à proximité
4. **4** – Sélectionner le réseau cible
5. **5** – (optionnel) Tester la désauthentification
6. **6** – Créer l'AP de laboratoire reprenant le SSID/canal ciblé
7. **7 / 8 / 9** – Observer les clients et le trafic DNS

En quittant le menu (option **0**) ou avec **Ctrl+C**, le script nettoie automatiquement : arrêt de `hostapd`/`dnsmasq`, suppression des règles iptables, retour de la carte en mode managed, redémarrage de NetworkManager.

## DNS spoofing & MITM : comment ça marche

Une fois l'AP de laboratoire actif (option 6), le script se trouve en position de **man-in-the-middle** naturel : tout appareil qui se connecte à ce point d'accès route obligatoirement son trafic à travers la machine qui exécute le script. C'est cette position réseau qui rend le DNS spoofing possible — aucune manipulation ARP supplémentaire n'est nécessaire puisque la machine *est* la passerelle et le résolveur DNS du client.

### Le chemin du trafic

```
Client Wi-Fi → AP (hostapd) → dnsmasq (DHCP + DNS) → iptables NAT → Internet
```

1. **`hostapd`** diffuse le SSID ciblé et accepte les connexions Wi-Fi.
2. **`dnsmasq`** répond aux requêtes DHCP (`dhcp-option=6,$AP_IP` dans la config) : chaque client reçoit `AP_IP` (`192.168.50.1`) comme serveur DNS. Le client ne choisit rien — il fait confiance à l'AP.
3. Toute requête DNS du client arrive donc directement à `dnsmasq`, qui consulte d'abord ses propres règles avant de relayer vers les résolveurs upstream (`server=8.8.8.8`, `server=1.1.1.1` dans `DNSMASQ_CONF`).
4. **`iptables`** (MASQUERADE + FORWARD) laisse passer le reste du trafic normalement vers Internet, pour ne pas éveiller de soupçons sur une connexion qui semble fonctionner.

### Le spoofing lui-même

La fonction `configure_dns_redirect` (option 10) écrit une ligne dans `DNS_REDIRECT_CONF`, inclus par référence dans la config principale :

```
conf-file=$DNS_REDIRECT_CONF
```

Chaque redirection ajoutée prend la forme :

```
address=/exemple.com/192.168.1.1
```

C'est la directive `address=` de dnsmasq : toute requête `A`/`AAAA` pour ce domaine (et ses sous-domaines) reçoit directement l'IP indiquée, **sans jamais interroger les serveurs upstream**. dnsmasq est rechargé à chaud après chaque ajout (kill + relance sur `DNSMASQ_PID`), donc la redirection est active immédiatement pour les nouvelles requêtes.

Concrètement, si un client tape `exemple.com` dans son navigateur, sa requête DNS ne quitte jamais la machine du lab — elle est interceptée et répondue localement, redirigeant le client vers n'importe quel serveur que vous contrôlez (page de capture, portail de démonstration, etc.).

### Visibilité du trafic

- **`show_network_logs` (option 9)** parse `DNS_LOG` (`log-queries` activé dans la config dnsmasq) et affiche chaque requête sous la forme `client → domaine demandé`, ce qui permet d'observer en clair tous les noms de domaine consultés par les clients connectés — même ceux qui ne sont pas redirigés.
- **`show_clients` (option 7)** croise `iw station dump` et les baux DHCP (`/var/lib/misc/dnsmasq.leases`) pour associer MAC, IP et hostname de chaque appareil connecté.

### Pourquoi ça fonctionne (et ses limites)

- Ça fonctionne parce que le DNS en clair (UDP/53, sans DoH/DoT) fait confiance au premier résolveur qui répond, sans vérification cryptographique.
- **HTTPS n'est pas cassé par cette technique seule** : rediriger un domaine vers une IP différente donne un avertissement de certificat si le client tente une connexion TLS normale, sauf si un serveur avec un certificat valide pour ce domaine répond à cette IP (ce qui nécessite un CA compromis ou une PKI de lab installée sur les appareils clients).
- Un client utilisant **DNS sur HTTPS (DoH)** ou **DNS sur TLS (DoT)**, ou un résolveur codé en dur (ex. `1.1.1.1` configuré manuellement dans le navigateur), contourne entièrement ce spoofing puisque ses requêtes DNS ne passent plus par `dnsmasq`.
- La technique complète (AP usurpant un SSID légitime + deauth pour forcer la reconnexion + DNS spoofing) est précisément ce qu'on appelle une attaque **Evil Twin** : elle repose sur le fait que la plupart des appareils se reconnectent automatiquement à un SSID connu sans vérifier l'identité cryptographique du point d'accès (WPA2/3-Personal n'authentifie pas l'AP auprès du client, seulement le contraire).

## Configuration

Les paramètres réseau par défaut sont modifiables en tête de script :

```bash
INTERNET_INTERFACE="eth0"   # interface fournissant l'accès Internet
AP_IP="192.168.50.1"
AP_NETWORK="192.168.50.0/24"
DHCP_START="192.168.50.10"
DHCP_END="192.168.50.100"
```

## Limitations connues

- Le canal ciblé doit être supporté par votre carte Wi-Fi (2.4 GHz / 5 GHz selon le matériel).
- Certains drivers ne respectent pas toujours le canal demandé par `aireplay-ng` — vérifiez avec `iw dev <iface> info`.
- La création d'AP nécessite que la carte supporte le mode AP (`iw list` → `Supported interface modes`).

