# Evil Twin Lab

Script Bash interactif (`evil-twin.sh`) pour monter un laboratoire Wi-Fi de test : activation du mode monitor, scan de réseaux, tests de désauthentification, et création d'un point d'accès (AP) factice avec DHCP/DNS pour observer le trafic client.

Conçu pour l'apprentissage de la sécurité Wi-Fi (audits, formation, CTF, home-lab) **sur du matériel et des réseaux que vous possédez ou que vous êtes explicitement autorisé à tester**.

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
| 10 | Configurer une redirection DNS / DNS SPOOFING | MITM
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

