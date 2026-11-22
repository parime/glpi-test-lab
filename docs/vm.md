# VM du laboratoire : Proxmox VE dans Hyper-V

Ce lot (issue #5) monte les machines du labo dans **Proxmox VE**, lui-même installé dans **une
seule VM Hyper-V** avec la virtualisation imbriquée. Les VM du labo sont créées par l'**API de
Proxmox** (jeton d'API, jamais le mot de passe root dans le dépôt).

| VM | Système | Rôle dans les tests | Adresse | vCPU | Mémoire | Disque |
|---|---|---|---|---|---|---|
| `lab-proxmox` (Hyper-V) | Proxmox VE 9.2 | hôte des VM ; servira aussi au lot #15 (Proxmox VE à tester par les plugins) | 10.77.10.5 | 4 | 8 Go (statique) | 120 Go dynamique |
| `lab-pfsense` (101) | pfSense CE 2.7.2 | pare-feu, réseau segmenté, futur équipement réseau de la cartographie (#8) | LAN 10.77.10.1 | 1 | 1 Go | 8 Go |
| `lab-ad` (102, DC01) | Windows Server 2025 **Server Core**, évaluation 180 jours | contrôleur de `lab.local`, LDAP de GLPI, GPO de GLPI Agent, revues d'accès de GRC | 10.77.10.10 | 2 | 2 Go | 32 Go |
| `lab-win11` (103, PC-WIN11) | Windows 11 Entreprise, évaluation 90 jours | poste joint au domaine, agent déployé par GPO | 10.77.10.20 | 2 | 2,5 Go (4 Go pendant l'installation) | 64 Go |
| `lab-ubuntu` (104, srv-ubuntu) | Ubuntu Server 24.04 LTS | serveur Linux joint au domaine (realmd/SSSD), agent par cloud-init | 10.77.10.30 | 1 | 1 Go (2 Go pendant l'installation) | 10 Go |

Les disques des VM du labo sont en allocation fine (LVM-thin) : ils n'occupent que l'espace écrit.
Tout est gratuit (évaluations Microsoft, logiciels libres) et rien n'est écrit sur `C:` : disque
de Proxmox, ISO, supports, secrets et état sont dans `F:\Dev\glpi-test-lab-data\vm`.

Réglages : [`vm/vms.psd1`](../vm/vms.psd1). Pour en changer sans toucher au fichier versionné,
créez `vm/vms.local.psd1` (ignoré par git) avec seulement les clés à modifier :

```powershell
@{ Glpi = @{ UrlAgent = 'http://10.77.10.254:8102/' } }
```

## En bref : ce que vous lancez, dans l'ordre

Aucune commande n'a besoin des droits administrateur sur ce PC : votre compte est déjà membre du
groupe « Administrateurs Hyper-V ».

| # | Commande | Durée |
|---|---|---|
| 1 | `.\vm\10-telecharger-iso.ps1` | 30 à 60 min la première fois (environ 23 Go) |
| 2 | `.\vm\20-proxmox.ps1` | 30 à 45 min : VM Hyper-V, installation automatique de Proxmox, envoi des ISO |
| 3 | `.\vm\30-creer-vm.ps1 -Nom lab-pfsense`, puis l'installation de pfSense à la console | 15 min, [voir plus bas](#pfsense--installation-à-la-console) |
| 4 | `.\vm\30-creer-vm.ps1` | 1 à 2 h (installations sans intervention) |
| 5 | `.\vm\40-configurer.ps1` | 30 à 60 min (domaine, annuaire, GPO, jonctions, instantanés) |

Au quotidien : `.\vm\lab-vm.ps1 up`, `down`, `status`, `reset <vm>`.

Les scripts sont relançables : ils ne refont que ce qui manque.

Si Windows refuse les scripts (« l'exécution de scripts est désactivée ») :
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (sans droits administrateur), ou
`powershell -ExecutionPolicy Bypass -File <script>`.

### Seule étape administrateur, sur un PC neuf seulement

Sur un autre PC où Hyper-V n'est pas actif ou où le compte n'est pas dans le groupe
« Administrateurs Hyper-V », lancez une fois, dans une console PowerShell « en tant
qu'administrateur », [`vm/00-prerequis-admin.ps1`](../vm/00-prerequis-admin.ps1) : il active
Hyper-V (redémarrage éventuel) et ajoute le compte au groupe (fermer puis rouvrir la session). Il
ne fait rien d'autre. **Sur le PC du mainteneur, c'est déjà fait.**

## Prérequis

- Windows 11 Pro (ou Entreprise, Éducation), virtualisation activée dans le BIOS, Hyper-V actif.
- Docker Desktop (déjà utilisé par le socle) : il sert à préparer l'ISO d'installation
  automatique de Proxmox avec l'outil officiel, dans un conteneur Debian.
- Disque `F:` : environ 23 Go d'ISO, et 40 à 70 Go pour le VHDX dynamique de Proxmox (120 Go au
  plus), qui contient aussi une copie des ISO.
- Mémoire : 8 Go réservés à la VM Proxmox quand elle tourne (voir [Mémoire](#mémoire)).

## Réseau

```
 Internet
    │  (NAT et DHCP de Windows)
 « Default Switch » Hyper-V ── vmbr1 (WAN, DHCP) ── WAN de pfSense (vtnet0)
                                                      │
                                                   pfSense 10.77.10.1
                                                      │
 « lab-interne » Hyper-V ───── vmbr0 (LAN 10.77.10.0/24) ── LAN de pfSense (vtnet1), AD, Windows 11, Ubuntu
    │                           Proxmox 10.77.10.5 (administration, API, DHCP réservé à l'hôte)
 Windows (hôte) 10.77.10.254 ── Docker Desktop / Swarm : instances GLPI du labo (ports 8100-8199)
```

- **WAN** : le commutateur « Default Switch », créé par Windows, fournit NAT et DHCP sans droits
  administrateur. Il porte le pont Proxmox `vmbr1` et le WAN de pfSense.
- **LAN** : le commutateur interne « lab-interne » est créé par `20-proxmox.ps1` (un membre
  d'« Administrateurs Hyper-V » le peut sans élévation). Il porte le pont `vmbr0`, sur lequel
  Proxmox a son adresse d'administration. Windows ne peut pas fixer l'adresse de sa carte
  `vEthernet (lab-interne)` sans élévation : c'est donc le DHCP de Proxmox (dnsmasq, installé au
  premier démarrage) qui lui donne **10.77.10.254** par une réservation sur son adresse MAC, **sans
  passerelle ni DNS**, pour que seul le trafic du labo passe par là. Windows redemande une
  adresse toutes les 5 minutes tant qu'il n'en a pas.
- **Usurpation d'adresse MAC** activée sur les deux cartes de la VM Proxmox : sans elle, Hyper-V
  bloque les trames des VM imbriquées
  ([doc Microsoft](https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/enable-nested-virtualization)).
- **Docker et GLPI** : les VM joignent les instances GLPI du labo sur `http://10.77.10.254:<port>`
  (Docker Desktop publie les ports sur toutes les cartes de l'hôte ; la règle « Docker Desktop
  Backend » du pare-feu de Windows les autorise sur le profil « Public », celui de cette carte).
  Dans l'autre sens, les conteneurs GLPI joignent l'AD (`10.77.10.10:636`) à travers l'hôte, qui
  est directement sur le LAN.

### Plages vérifiées

Relevé du 22/11/2026 sur ce PC : Docker utilise 172.17.0.0/16 à 172.30.0.0/16, 192.168.65.0/24
(Docker Desktop), 192.168.77.0/24, 10.210.0.0/16 (réserve de Docker Swarm) et 10.211.0.0/16 ;
Windows utilise 172.25.240.0/20 (« Default Switch », plage choisie par Windows) et 172.18.96.0/20
(WSL). Le LAN du labo, **10.77.10.0/24**, ne chevauche aucune de ces plages. Le WAN suit la plage
de « Default Switch », que Windows peut changer au redémarrage : seuls Proxmox (`vmbr1`) et le WAN
de pfSense, tous deux en DHCP, l'utilisent ; rien dans le labo n'en dépend.

Remarque : le réseau Docker `assetsign-issue115` (172.25.0.0/16, hors labo) recouvre déjà la plage
de « Default Switch » ; cela ne gêne pas le labo, mais ce réseau de test peut être supprimé.

## Étape 1 : téléchargement des ISO

```powershell
.\vm\10-telecharger-iso.ps1
```

| Fichier | Source officielle | Vérification |
|---|---|---|
| Proxmox VE 9.2-1 | [enterprise.proxmox.com/iso](https://enterprise.proxmox.com/iso/) | `SHA256SUMS` officiel |
| Pilotes VirtIO 0.1.302 (projet Fedora) | [fedorapeople.org](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/) | pas de somme publiée pour l'ISO : relevée au premier téléchargement |
| Windows Server 2025, évaluation 180 jours (en-US) | [Centre d'évaluation](https://www.microsoft.com/evalcenter/download-windows-server-2025) | pas de somme publiée : relevée (`iso\SHA256SUMS.lab`) puis contrôlée |
| Windows 11 Entreprise, évaluation 90 jours (en-US) | [Centre d'évaluation](https://www.microsoft.com/evalcenter/download-windows-11-enterprise) | idem |
| Ubuntu Server 24.04 LTS | [releases.ubuntu.com/24.04](https://releases.ubuntu.com/24.04/) | `SHA256SUMS` officiel |
| pfSense CE 2.7.2 (installeur hors ligne) | [miroir Netgate](https://atxfiles.netgate.com/mirror/downloads/) | `.sha256` officiel |
| GLPI Agent 1.21 (MSI, installeur Linux) | [GitHub](https://github.com/glpi-project/glpi-agent/releases/tag/1.21) | `.sha256` officiel et somme épinglée |

Si un lien direct ne répond plus (formulaire Microsoft imposé, par exemple), le script affiche la
page à ouvrir et le nom exact attendu dans `F:\Dev\glpi-test-lab-data\vm\iso`, puis attend le
fichier.

Les ISO Windows sont en anglais (comptes intégrés `Administrator`, groupe `Administrators`) avec
réglages régionaux, fuseau et clavier français. Pour pfSense, Netgate ne distribue plus les
versions suivantes que par un installeur en ligne ([pfsense.org/download](https://www.pfsense.org/download/)) ;
la 2.7.2 hors ligne se met à jour ensuite depuis son interface.

## Étape 2 : Proxmox VE

```powershell
.\vm\20-proxmox.ps1
```

1. Crée le commutateur interne « lab-interne ».
2. Génère `answer.toml` et le script de premier démarrage sous `…\vm\proxmox\` (mot de passe
   root généré, clé SSH du labo) et prépare l'ISO d'installation automatique avec l'outil officiel
   `proxmox-auto-install-assistant prepare-iso --fetch-from iso`
   ([installation automatique](https://pve.proxmox.com/wiki/Automated_Installation)), dans un
   conteneur `debian:trixie` (dépôt `pve-no-subscription` et clé officielle, somme vérifiée :
   [dépôts](https://pve.proxmox.com/wiki/Package_Repositories)). Le fichier de réponses est validé
   par `validate-answer` avant.
3. Crée la VM Hyper-V `lab-proxmox` : génération 2, 4 vCPU, 8 Go **statiques** (obligatoire pour
   l'imbrication), `Set-VMProcessor -ExposeVirtualizationExtensions $true`, deux cartes à adresse
   MAC fixe avec usurpation d'adresse MAC, VHDX dynamique de 120 Go, démarrage sécurisé désactivé.
4. Démarre la VM : l'entrée « Automated Installation » est choisie seule après 10 s. Installation
   sur ext4 + LVM (le stockage `local-lvm` en LVM-thin permet les instantanés) ; au premier
   démarrage, le script embarqué ajoute le pont WAN `vmbr1` en DHCP, désactive les dépôts
   « enterprise » (sans abonnement), installe dnsmasq pour la réservation DHCP de l'hôte, et crée
   le jeton d'API `root@pam!lab`.
5. Lit en SSH le jeton et l'autorité de certification de Proxmox (`pve-root-ca.pem`) : les appels
   d'API vérifient le certificat. Le jeton est rangé dans `secrets.json` et dans un fichier
   d'en-tête lu par curl, pour qu'il n'apparaisse pas sur la ligne de commande.
6. Envoie les ISO du labo dans le stockage `local` de Proxmox par l'API (`…/storage/local/upload`).

Interface web : **https://10.77.10.5:8006/** (utilisateur `root`, royaume « Linux PAM », mot de
passe `RootProxmox` de `secrets.json`).

## Étape 3 : pfSense, installation à la console

```powershell
.\vm\30-creer-vm.ps1 -Nom lab-pfsense
```

La VM 101 est créée par l'API (1 vCPU, 1 Go, 8 Go) et démarre sur l'ISO. Son installeur est en
mode texte et n'a pas de fichier de réponses documenté par Netgate, d'où ces étapes manuelles,
dans l'interface de Proxmox (**VM 101 > Console**) :

1. Installeur pfSense CE 2.7.2 (intitulés à peu près identiques selon la version) : **Accept**,
   **Install**, clavier (par exemple **French**), **Auto (ZFS)**, **Install**, **stripe**, cocher
   le disque (barre d'espace), **YES**, « Manual configuration » **No**, **Reboot**.
2. Affectation des interfaces : VLAN **n**, WAN **vtnet0**, LAN **vtnet1**, **y**
   (vtnet0 est sur `vmbr1`, le WAN ; vtnet1 sur `vmbr0`, le LAN).
3. Menu **2) Set interface(s) IP address**, **2 (LAN)** : **10.77.10.1**, masque **24**, pas de
   passerelle, pas d'IPv6, serveur DHCP **n** (le DHCP du LAN est celui de Proxmox, réservé à
   l'hôte ; les VM ont des adresses fixes), revenir en HTTP **n**. Le WAN reste en DHCP.
4. Depuis l'hôte, **https://10.77.10.1/** (certificat auto-signé), `admin` / `pfsense`, assistant :
   nom `pfsense`, domaine **lab.local**, DNS vide, fuseau **Europe/Paris**, WAN et LAN inchangés,
   **décocher « Block RFC1918 Private Networks »** sur le WAN (le WAN est lui-même en 172.25.x),
   nouveau mot de passe `admin` : valeur `PfSense` de `secrets.json`.
5. **Services > DNS Resolver > Domain Overrides** : **lab.local** vers **10.77.10.10**.
6. Pour la cartographie (#8) : **Services > SNMP**, communauté en lecture = `SnmpPfSense` de
   `secrets.json`, interface **LAN**.
7. **Diagnostics > Backup & Restore** : téléchargez `config.xml` dans
   `F:\Dev\glpi-test-lab-data\vm\pfsense\config.xml` (une réinstallation se termine alors par
   « Restore Backup » au lieu des étapes 3 à 6).

Référence : [pfSense sur Proxmox](https://docs.netgate.com/pfsense/en/latest/recipes/virtualize-proxmox-ve.html).

## Étape 4 : VM Windows et Ubuntu

```powershell
.\vm\30-creer-vm.ps1
```

Chaque VM est créée par `POST /nodes/pve/qemu`
([paramètres](https://pve.proxmox.com/pve-docs/qm.1.html)) : disque VirtIO SCSI sur `local-lvm`,
carte VirtIO sur `vmbr0`, agent invité QEMU activé. Pour Windows, suivant les bonnes pratiques de
Proxmox ([Windows Server 2025](https://pve.proxmox.com/wiki/Windows_2025_guest_best_practices),
[Windows 11](https://pve.proxmox.com/wiki/Windows_11_guest_best_practices)) : UEFI (OVMF) avec
démarrage sécurisé et clés Microsoft préchargées, ISO VirtIO jointe, et **TPM 2.0 virtuel** pour
Windows 11. Windows 11 démarre son installation avec 4 Go (exigés par l'installeur), puis la VM
redescend à 2,5 Go : aucune clé de contournement (`LabConfig`) n'est nécessaire.

- **Windows** : un petit ISO `LABSUPPORT` contient `autounattend.xml` (partitions UEFI, image,
  langue, nom de machine, compte ; modèle [`vm/modeles/autounattend-windows.xml`](../vm/modeles/autounattend-windows.xml)),
  les pilotes VirtIO à charger pendant l'installation (`DriverPaths` : disque `vioscsi`, réseau
  `NetKVM`, port série `vioserial`), et l'installation de l'agent invité QEMU à la phase
  specialize (MSI de l'ISO VirtIO). Pour l'AD, il porte aussi l'annuaire de démonstration, le
  script de GPO et le MSI de GLPI Agent. Le script appuie sur Entrée par l'API (`sendkey`) pendant
  « Press any key to boot from CD or DVD ». Fin de l'installation = agent invité joignable.
- **Ubuntu** : ISO `CIDATA` (cloud-init NoCloud, [autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)) ;
  la ligne de commande GRUB (`linux /casper/vmlinuz autoinstall ---`) est tapée par `sendkey`,
  pour éviter la confirmation de Subiquity
  ([démarrage rapide](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html)).
  La VM s'éteint en fin d'installation ; le script retire les ISO et la redémarre. Ubuntu a
  besoin de pfSense (paquets) : le script attend qu'il réponde.

`-SupportsSeulement` génère seulement les supports (dans `…\vm\supports\<vm>\`) pour les relire.

## Étape 5 : configuration

```powershell
.\vm\40-configurer.ps1
```

PowerShell Direct n'existe pas dans une VM imbriquée : les VM Windows sont pilotées par l'**agent
invité QEMU** (`agent/exec` de l'API, [doc](https://pve.proxmox.com/wiki/Qemu-guest-agent)),
Ubuntu par SSH avec la clé du labo.

- **AD (DC01, Server Core)** : adresse fixe, mises à jour automatiques coupées (stratégie
  `NoAutoUpdate`), rôles AD DS, AD CS et GPMC, [nouvelle forêt](https://learn.microsoft.com/powershell/module/addsdeployment/install-addsforest)
  `lab.local` (NetBIOS `LAB`) avec DNS, redirecteur vers pfSense, [autorité d'entreprise](https://learn.microsoft.com/powershell/module/adcsdeployment/install-adcscertificationauthority)
  `LAB-CA` (LDAPS), annuaire de démonstration, **GPO de GLPI Agent**, certificat de `LAB-CA` copié
  dans `…\vm\ca\`.
- **Windows 11** : adresse fixe, DNS de l'AD, mises à jour automatiques, indexation (service
  Windows Search) et veille prolongée coupées,
  [jonction au domaine](https://learn.microsoft.com/powershell/module/microsoft.powershell.management/add-computer)
  dans `OU=Postes`, redémarrage : la GPO installe GLPI Agent au démarrage, et l'agent envoie tout
  de suite un inventaire. Le script vérifie la présence de l'agent.
- **Ubuntu** : GLPI Agent (installé au premier démarrage par cloud-init) vérifié, puis jonction
  au domaine par realmd et SSSD dans `OU=Serveurs`
  ([doc Ubuntu](https://documentation.ubuntu.com/server/how-to/sssd/with-active-directory/)).
- Chaque VM configurée est arrêtée proprement et reçoit l'**instantané « propre »**
  (`-NouvelInstantane` pour le remplacer).

### Déploiement de GLPI Agent par GPO

Script [`vm/invite/gpo-glpi-agent.ps1`](../vm/invite/gpo-glpi-agent.ps1), exécuté sur l'AD :

1. le MSI officiel épinglé (`GLPI-Agent-1.21-x64.msi`, somme vérifiée) est copié dans
   `\\lab.local\NETLOGON\glpi-agent\` ;
2. un script `installer-glpi-agent.cmd`, au même endroit, lance
   `msiexec /i … /quiet SERVER=<UrlAgent> TAG=labo-vm RUNNOW=1 ADD_FIREWALL_EXCEPTION=1 EXECMODE=1 ADDLOCAL=feat_AGENT,feat_NETINV`
   ([propriétés du MSI](https://glpi-agent.readthedocs.io/en/latest/installation/windows-command-line.html)),
   seulement si l'agent est absent (clé `HKLM\SOFTWARE\GLPI-Agent`, où le MSI range sa
   configuration) ;
3. la GPO **« Labo - GLPI Agent »** déclare ce script comme script de démarrage de l'ordinateur
   (`Machine\Scripts\scripts.ini`, extensions côté client des scripts,
   [MS-GPSCR](https://learn.microsoft.com/openspecs/windows_protocols/ms-gpscr/)) et est liée à
   `OU=Postes,OU=Ordinateurs,OU=Lab` ([New-GPO, New-GPLink](https://learn.microsoft.com/powershell/module/grouppolicy/)).

Pourquoi un script de démarrage et pas une GPO « Installation de logiciel » : celle-ci ne passe
pas de propriétés (`SERVER`, `TAG`, `RUNNOW`) au MSI sans fichier de transformation `.mst`.

Changer d'instance GLPI : `Glpi.UrlAgent` dans `vms.local.psd1`, puis relancer
`40-configurer.ps1 -Nom lab-ad` (le script de démarrage est réécrit ; un poste déjà équipé garde
sa configuration, à changer dans `HKLM\SOFTWARE\GLPI-Agent\server` ou par réinstallation).

Vérification : après le redémarrage qui suit la jonction, **PC-WIN11** apparaît dans **Parc >
Ordinateurs** de l'instance GLPI visée (étiquette `labo-vm`) ; dans la VM, le journal de
l'installation est `C:\Windows\Temp\glpi-agent-gpo.log`.

### Annuaire de démonstration

Défini dans [`vm/modeles/annuaire-demo.psd1`](../vm/modeles/annuaire-demo.psd1) (données fictives,
relançable sans doublon) : OU `Lab` (`Utilisateurs` par service, `Groupes`, `Comptes de service`,
`Comptes a privileges`, `Ordinateurs/Postes`, `Ordinateurs/Serveurs`, `Desactives`), 15 groupes
(RSSI, DPO, comité sécurité, techniciens, support N1, administrateurs serveurs, profils GLPI…),
15 comptes de personnes (directrice, RSSI `s.bernard`, DPO `t.dubois`, techniciens…), et les cas
utiles aux revues d'accès : compte à privilèges séparé (`adm.jfournier`), compte à privilèges
oublié sans expiration de mot de passe (`admin.ancien`), stagiaire expiré (`h.garnier`), départs
désactivés encore membres de groupes (`f.chevalier`, `g.mercier`), comptes de service
(`svc-glpi-ldap`, `svc-sauvegarde`, `svc-sql` avec SPN, `svc-supervision`). Téléphones dans la
tranche 01 99 00, réservée à la fiction.

## Brancher GLPI sur l'AD (LDAP)

Une **nouvelle** forêt Windows Server 2025 impose la signature LDAP : les liaisons simples en clair
sur 389 sont refusées ([doc Microsoft](https://learn.microsoft.com/windows-server/identity/ad-ds/ldap-signing)).
GLPI utilise une liaison simple : il faut **LDAPS** (636), fourni par `LAB-CA`. Le labo ne baisse
pas ce réglage.

**Configuration > Authentification > Annuaires LDAP > Ajouter** :

| Champ | Valeur |
|---|---|
| Serveur | `ldaps://dc01.lab.local` |
| Port | `636` |
| BaseDN | `DC=lab,DC=local` |
| DN du compte | `svc-glpi-ldap@lab.local` |
| Mot de passe | `CompteLdapGlpi` de `secrets.json` |
| Filtre de connexion | `(&(objectClass=user)(objectCategory=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))` |
| Champ de l'identifiant | `samaccountname` |
| Champ de synchronisation | `objectguid` |

Pour que TLS aboutisse, le conteneur GLPI doit résoudre `dc01.lab.local` en `10.77.10.10`
(`extra_hosts`) et faire confiance à `LAB-CA` (`…\vm\ca\lab-ca.pem`, désigné par `TLS_CACERT` dans
`/etc/ldap/ldap.conf`). Ces deux réglages relèvent de la pile GLPI (`stack/`, lot #2).

## Pilotage au quotidien

```powershell
.\vm\lab-vm.ps1 up                 # démarre Proxmox, puis pfSense, l'AD et les postes
.\vm\lab-vm.ps1 up lab-ad lab-win11
.\vm\lab-vm.ps1 status             # état, mémoire, instantané « propre », jours d'évaluation restants
.\vm\lab-vm.ps1 reset lab-win11    # retour à l'instantané « propre »
.\vm\lab-vm.ps1 down               # arrêt propre des VM, puis de Proxmox
```

Autres commandes : `installer`, `reinstaller <vm>`, `renouveler`, `planifier`, `deplanifier`,
`modele <vm>`, `supprimer <vm>` (`Get-Help .\vm\lab-vm.ps1 -Full`).

**Modèles** : `lab-vm.ps1 modele lab-ubuntu` fait une copie complète de la VM arrêtée et la
convertit en modèle Proxmox `tpl-lab-ubuntu` (VM 904), d'où cloner d'autres postes Linux en
quelques secondes. Pour Windows, un clone garde l'horloge d'évaluation et l'identité de la VM
d'origine : le labo réinstalle plutôt depuis l'ISO (installation sans intervention).

L'instantané « propre » est pris VM arrêtée, juste après la configuration. Revenir à celui d'un
poste joint au domaine longtemps après sa prise peut désynchroniser son compte machine (mot de
passe renouvelé tous les 30 jours) : dans ce cas, `lab-vm.ps1 reinstaller lab-win11`.

## Mémoire

| Niveau | Mémoire |
|---|---|
| VM Hyper-V `lab-proxmox` (statique, retirée à Windows quand elle tourne) | **8 Go** |
| dont pfSense / AD / Windows 11 / Ubuntu | 1 / 2 / 2,5 / 1 Go = **6,5 Go** |
| dont Proxmox lui-même | environ 1 à 1,5 Go |

Pendant l'installation de Windows 11, sa VM prend 4 Go (installations successives, pas toutes en
même temps). Sur les 32 Go du PC, il reste 24 Go pour Windows, Docker et les instances GLPI. Rien
ne démarre avec Windows : `lab-vm.ps1 up` / `down`.

Configuration requise citée : [Proxmox VE](https://pve.proxmox.com/wiki/System_Requirements),
[Windows Server 2025](https://learn.microsoft.com/windows-server/get-started/hardware-requirements)
(Server Core : 512 Mo, 32 Go), [Windows 11](https://learn.microsoft.com/windows/whats-new/windows-11-requirements)
(4 Go, 64 Go, TPM 2.0), [pfSense](https://docs.netgate.com/pfsense/en/latest/hardware/minimum-requirements.html).

## Durées d'évaluation et réinstallation

| Système | Durée |
|---|---|
| Windows Server 2025 | 180 jours |
| Windows 11 Entreprise | 90 jours |
| Proxmox VE, Ubuntu, pfSense | sans limite |

`lab-vm.ps1 status` affiche les jours restants (licence de Windows lue par l'agent invité, sinon
date d'installation dans `…\vm\etat.json`).

```powershell
.\vm\lab-vm.ps1 renouveler               # réinstalle ce qui expire dans moins de 7 jours
.\vm\lab-vm.ps1 renouveler -SeuilJours 14
.\vm\lab-vm.ps1 planifier                # chaque jour à 9 h, session ouverte (sans droits administrateur)
```

La réinstallation supprime la VM (disques et instantanés compris) puis enchaîne `30-creer-vm.ps1`
et `40-configurer.ps1`. Réinstaller l'AD crée un **nouveau** domaine : Windows 11 et Ubuntu sont
alors réinstallés aussi. Ce qui avait été ajouté à la main dans ces VM est perdu : gardez-le dans
`vm/modeles/`.

## Fichiers produits (hors dépôt)

Sous `F:\Dev\glpi-test-lab-data\vm` :

| Chemin | Contenu |
|---|---|
| `iso\` | ISO téléchargées, `SHA256SUMS.lab` (sommes relevées) |
| `logiciels\` | MSI et installeur Linux de GLPI Agent |
| `machines\lab-proxmox\` | VM Hyper-V et VHDX de Proxmox |
| `proxmox\` | `answer.toml`, script de premier démarrage, ISO automatique, `pve-root-ca.pem`, en-tête d'API |
| `supports\` | supports d'installation générés (contiennent des mots de passe) |
| `secrets.json` | `RootProxmox`, `JetonProxmox`, `AdminWindows` (Administrator du domaine, labadmin de Windows 11), `Dsrm`, `UtilisateursDemo`, `CompteLdapGlpi`, `Ubuntu`, `PfSense`, `SnmpPfSense` |
| `ssh\` | clé SSH du labo (root de Proxmox, labadmin d'Ubuntu) |
| `ca\` | certificat de LAB-CA (LDAPS) |
| `etat.json` | dates d'installation et de configuration |

## Dépannage

- **« Cette session ne peut pas piloter Hyper-V »** : compte hors du groupe « Administrateurs
  Hyper-V » (voir l'étape administrateur), ou session pas rouverte depuis l'ajout.
- **Proxmox ne répond pas sur 10.77.10.5** : console `vmconnect localhost lab-proxmox` ; journal du
  premier démarrage dans Proxmox : `/var/log/lab-premier-demarrage.log`. Si l'hôte n'a pas
  10.77.10.254 (`Get-NetIPAddress -InterfaceAlias "vEthernet (lab-interne)"`), attendez 5 minutes
  (nouvelle demande DHCP de Windows).
- **Windows reste sur « Press any key to boot from CD or DVD »** : `lab-vm.ps1 supprimer <vm>` puis
  `30-creer-vm.ps1 -Nom <vm>`, ou appuyez sur une touche dans la console de Proxmox.
- **Ubuntu demande « Continue with autoinstall? »** : répondez `yes` dans la console, ou augmentez
  `DelaiGrubSecondes`.
- **Les agents n'atteignent pas GLPI** : instance démarrée (`lab status`) ? Depuis la VM :
  `Test-NetConnection 10.77.10.254 -Port 8101`.
