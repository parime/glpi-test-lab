# VM Hyper-V du laboratoire

Ce lot (issue #5) monte quatre machines virtuelles sous Hyper-V, sur ce PC :

| VM | Système | Rôle dans les tests | Adresse |
|---|---|---|---|
| `lab-pfsense` | pfSense CE (gratuit) | pare-feu, réseau segmenté, futur équipement réseau de la cartographie (#8) | LAN 10.77.10.1, WAN 10.77.0.2 |
| `lab-ad` (DC01) | Windows Server 2025, évaluation 180 jours | contrôleur du domaine `lab.local`, annuaire LDAP de GLPI, revues d'accès de GRC | 10.77.10.10 |
| `lab-win11` (PC-WIN11) | Windows 11 Entreprise, évaluation 90 jours | poste joint au domaine, inventorié par GLPI Agent | 10.77.10.20 |
| `lab-ubuntu` (srv-ubuntu) | Ubuntu Server 24.04 LTS | serveur Linux inventorié par GLPI Agent | 10.77.10.30 |

Tout est gratuit : versions d'évaluation de Microsoft, logiciels libres. Rien n'est écrit sur `C:` :
disques, ISO, supports d'installation, secrets et état vont dans `F:\Dev\glpi-test-lab-data\vm`.

Les réglages sont dans [`vm/vms.psd1`](../vm/vms.psd1) (réseaux, mémoire, URL de GLPI, version de
GLPI Agent…). Pour en changer sans toucher au fichier versionné, créez `vm/vms.local.psd1` (ignoré
par git) avec seulement les clés à modifier, par exemple :

```powershell
@{ Glpi = @{ UrlAgent = 'http://10.77.10.254:8102/' } }
```

## En bref : ce que vous lancez, dans l'ordre

| # | Commande | Droits | Durée |
|---|---|---|---|
| 1 | `vm\00-prerequis-admin.ps1` | **administrateur, une seule fois** | 1 min (+ redémarrage si Hyper-V était absent) |
| 2 | fermer puis rouvrir la session Windows | | |
| 3 | `vm\10-telecharger-iso.ps1` | session ordinaire | 15 à 60 min (environ 18 Go) |
| 4 | `vm\20-creer-vm.ps1` | session ordinaire | 1 à 2 h (installations sans intervention) |
| 5 | installation de pfSense à la console | session ordinaire | 15 min, [voir plus bas](#pfsense--installation-à-la-console) |
| 6 | `vm\30-configurer.ps1` | session ordinaire | 20 à 40 min |

Ensuite, au quotidien : `vm\lab-vm.ps1 up`, `down`, `status`, `reset <vm>`.

Les scripts sont relançables : ils ne refont que ce qui manque. Une étape interrompue se reprend
en relançant la même commande.

## Prérequis

- Windows 11 Pro (ou Entreprise, Éducation), virtualisation activée dans le BIOS. Hyper-V est
  activé par l'étape administrateur s'il ne l'est pas.
- Environ 18 Go pour les ISO et 45 à 60 Go pour les disques des VM sur `F:` (disques dynamiques :
  165 Go au plus si tous se remplissaient).
- Mémoire : voir [plus bas](#mémoire-utilisée) (6 à 11 Go pour les quatre VM).
- Les scripts s'exécutent avec Windows PowerShell 5.1, fourni avec Windows. Si Windows refuse de
  lancer un script (« l'exécution de scripts est désactivée »), autorisez les scripts locaux pour
  votre compte (sans droits administrateur) :

  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```

  ou lancez chaque script avec `powershell -ExecutionPolicy Bypass -File <script>`.

## Étape 1 : l'unique étape en administrateur

Tout ce qui exige les droits administrateur est regroupé dans **un seul script**,
[`vm/00-prerequis-admin.ps1`](../vm/00-prerequis-admin.ps1). Il ne crée rien d'autre que ce qui est
listé ci-dessous et peut être relancé sans risque.

1. Menu Démarrer, tapez « PowerShell », clic droit sur **Windows PowerShell**, puis
   **Exécuter en tant qu'administrateur**.
2. Dans cette fenêtre :

   ```powershell
   powershell -ExecutionPolicy Bypass -File F:\Dev\glpi-test-lab-vm\vm\00-prerequis-admin.ps1
   ```

   (adaptez le chemin si le dépôt est cloné ailleurs). Pour créer aussi les VM dans la foulée,
   ajoutez `-CreerVm` (après avoir téléchargé les ISO, étape 3).
3. Lisez le **bilan** affiché à la fin :
   - « REDÉMARRAGE DE WINDOWS NÉCESSAIRE » : Hyper-V vient d'être activé ; redémarrez puis relancez
     la même commande ;
   - « FERMEZ PUIS ROUVREZ VOTRE SESSION WINDOWS » : votre compte vient d'entrer dans le groupe
     « Administrateurs Hyper-V » ; l'appartenance n'est prise en compte qu'à la session suivante.

Ce que fait le script :

| Action | Pourquoi | Commande Microsoft |
|---|---|---|
| Active Hyper-V s'il ne l'est pas | hyperviseur des VM | `Enable-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V -All` |
| Vérifie les plages d'adresses | ne pas casser les réseaux de l'hôte, de Docker ni un NAT existant | `Get-NetIPAddress`, `Get-NetRoute`, `docker network inspect`, `Get-NetNat` |
| Crée le commutateur interne `lab-interne`, adresse de l'hôte 10.77.10.254/24 | LAN du labo ; l'hôte y joint l'AD (LDAP) et les VM y joignent GLPI | `New-VMSwitch -SwitchType Internal`, `New-NetIPAddress` |
| Crée le commutateur interne `lab-nat`, adresse 10.77.0.1/24, et le NAT `lab-nat` | sortie Internet du WAN de pfSense | `New-VMSwitch`, `New-NetNat` |
| Ouvre TCP 8100-8199 depuis 10.77.0.0/24 et 10.77.10.0/24 | les agents GLPI des VM joignent les instances GLPI du labo | `New-NetFirewallRule` |
| Range les VM et disques Hyper-V par défaut sous `F:\Dev\glpi-test-lab-data\vm\machines` | rien sur `C:` | `Set-VMHost` |
| Crée le gardien local `UntrustedGuardian` | protège la clé du TPM virtuel exigé par Windows 11 | `New-HgsGuardian -GenerateCertificates` |
| Ajoute votre compte au groupe « Administrateurs Hyper-V » (SID S-1-5-32-578) | tous les autres scripts tournent ensuite **sans** élévation | `Add-LocalGroupMember` |

Pour ne pas toucher au groupe : `-SansGroupe` (il faudra alors lancer tous les scripts en
administrateur). Pour ajouter un autre compte : `-Utilisateur MACHINE\compte`.

### Plages d'adresses retenues

Relevé fait sur ce PC le 22/11/2026 : Docker utilise 172.17.0.0/16 à 172.30.0.0/16,
192.168.77.0/24, 10.210.0.0/24 et 10.211.0.0/16, et réserve 10.210.0.0/16 aux réseaux de Docker
Swarm ; Windows utilise 172.25.240.0/20 (« Default Switch ») et 172.18.96.0/20 (WSL). Le labo prend
donc **10.77.0.0/24** (NAT) et **10.77.10.0/24** (LAN), libres. Le script refait la vérification à
chaque lancement et s'arrête en cas de chevauchement : changez alors `Reseau` dans
`vm\vms.local.psd1`.

### Un autre réseau NAT existe déjà

Windows n'accepte qu'**un seul** réseau NAT (WinNAT) par hôte
([doc Microsoft](https://learn.microsoft.com/windows-server/virtualization/hyper-v/setup-nat-network)).
Si le bilan signale un NAT existant, le script ne le touche pas et ne crée pas celui du labo :
pfSense n'aura alors pas Internet (le reste du labo fonctionne). Deux solutions, à votre choix :
supprimer l'ancien NAT s'il ne sert plus (`Get-NetNat`, puis `Remove-NetNat -Name <nom>` en
administrateur) et relancer le script, ou indiquer dans `vms.local.psd1` une plage `Nat.Prefixe`
contenue dans le NAT existant.

## Étape 3 : téléchargement des ISO

```powershell
.\vm\10-telecharger-iso.ps1
```

| Fichier | Source officielle | Vérification |
|---|---|---|
| Windows Server 2025, évaluation 180 jours (en-US) | [Centre d'évaluation Microsoft](https://www.microsoft.com/evalcenter/download-windows-server-2025), lien direct de la page | Microsoft ne publie pas de somme : SHA-256 relevée au premier téléchargement (`iso\SHA256SUMS.lab`) puis contrôlée ensuite |
| Windows 11 Entreprise, évaluation 90 jours (en-US) | [Centre d'évaluation Microsoft](https://www.microsoft.com/evalcenter/download-windows-11-enterprise) | idem |
| Ubuntu Server 24.04 LTS (dernière version ponctuelle) | [releases.ubuntu.com/24.04](https://releases.ubuntu.com/24.04/) | `SHA256SUMS` officiel |
| pfSense CE 2.7.2 (installeur hors ligne) | [miroir Netgate](https://atxfiles.netgate.com/mirror/downloads/) | fichier `.sha256` officiel |
| GLPI Agent 1.21 (MSI et installeur Linux) | [publication GitHub](https://github.com/glpi-project/glpi-agent/releases/tag/1.21) | `glpi-agent-1.21.sha256` officiel **et** somme épinglée dans `vms.psd1` |

Les ISO Windows sont en anglais (comptes intégrés `Administrator`, groupe `Administrators`,
prévisibles pour les scripts) avec réglages régionaux, fuseau et clavier français.

Si un lien direct de Microsoft ne répond plus (formulaire d'inscription imposé, lien changé), le
script affiche la page à ouvrir et le **nom de fichier exact** attendu dans
`F:\Dev\glpi-test-lab-data\vm\iso`, puis attend que le fichier y soit déposé. `-SansAttente` signale
seulement le manque.

Sur pfSense : depuis la 2.7.2, Netgate distribue les nouvelles versions de pfSense CE par le
« Netgate Installer », un installeur en ligne téléchargé depuis sa boutique (gratuit, avec
compte) : [pfsense.org/download](https://www.pfsense.org/download/). L'installeur hors ligne 2.7.2
reste sur le miroir officiel avec sa somme : c'est lui qui est téléchargé automatiquement. Après
installation, pfSense peut être mis à jour depuis son interface (System > Update).

## Étape 4 : création et installation des VM

```powershell
.\vm\20-creer-vm.ps1                 # toutes les VM
.\vm\20-creer-vm.ps1 -Nom lab-ubuntu # une seule
```

Pour chaque VM : disque VHDX dynamique, génération 2, démarrage sécurisé (modèle
`MicrosoftWindows` pour Windows, `MicrosoftUEFICertificateAuthority` pour Ubuntu, désactivé pour
pfSense comme le demande [Netgate](https://docs.netgate.com/pfsense/en/latest/recipes/virtualize-hyper-v.html)),
TPM virtuel pour Windows 11, points de contrôle automatiques désactivés. Puis :

- **Windows Server et Windows 11** : un petit ISO contenant `autounattend.xml` (généré depuis
  [`vm/modeles/autounattend-windows.xml`](../vm/modeles/autounattend-windows.xml)) est joint à la
  VM ; Windows Setup le lit tout seul
  ([ordre de recherche](https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-automation-overview)).
  Le script appuie sur Entrée au clavier virtuel pendant « Press any key to boot from CD or DVD ».
  Partitions UEFI, langue, fuseau, nom de machine, mot de passe administrateur : rien à saisir.
- **Ubuntu** : un ISO `CIDATA` (cloud-init NoCloud) contient la configuration
  [autoinstall](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
  générée depuis [`vm/modeles/ubuntu-user-data.yml`](../vm/modeles/ubuntu-user-data.yml), l'installeur
  Linux de GLPI Agent et son script d'installation. Subiquity demande une confirmation avant
  d'écrire sur le disque sauf si `autoinstall` figure sur la ligne de commande du noyau
  ([démarrage rapide](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html)) :
  le script ouvre la ligne de commande de GRUB (touche `c`) et tape
  `linux /casper/vmlinuz autoinstall ---`, `initrd /casper/initrd`, `boot`. La VM s'éteint en fin
  d'installation ; le script éjecte les ISO et la redémarre. Si GRUB n'est pas encore affiché au
  moment de la saisie (PC lent), augmentez `DelaiGrubSecondes` dans `vms.local.psd1`.
- **pfSense** : la VM démarre sur l'ISO ; l'installation se fait à la console (étape 5).

`-SupportsSeulement` génère seulement les supports (dans `…\vm\supports\<vm>\`) pour les relire,
sans Hyper-V ni droits. `-SansAttente` lance les installations sans attendre leur fin.

Pour suivre une installation : `vmconnect.exe localhost lab-ad` (ou le Gestionnaire Hyper-V).

## pfSense : installation à la console

L'installeur de pfSense est un programme en mode texte : il n'a pas de fichier de réponses
documenté par Netgate, d'où ces étapes manuelles (une quinzaine de minutes). La VM a deux cartes :
la première (`hn0`) sur `lab-nat` = **WAN**, la seconde (`hn1`) sur `lab-interne` = **LAN**.

1. Ouvrez la console : `vmconnect.exe localhost lab-pfsense`.
2. Installeur pfSense CE 2.7.2 (les intitulés peuvent varier légèrement selon la version) :
   accepter la licence (**Accept**), **Install**, disposition du clavier (par exemple
   **French**), partitionnement **Auto (ZFS)**, **Install**, type **stripe**, cocher le disque
   (barre d'espace), confirmer (**YES**), « Manual configuration » : **No**, puis **Reboot**.
   La VM redémarre sur son disque (le disque passe avant le DVD dans l'ordre de démarrage).
3. Affectation des interfaces (doc Netgate « Virtualizing with Hyper-V ») : VLAN **n**, WAN
   **hn0**, LAN **hn1**, confirmer **y**.
4. Menu de la console, option **2) Set interface(s) IP address** :
   - **1 (WAN)** : DHCP **n**, adresse **10.77.0.2**, masque **24**, passerelle **10.77.0.1**,
     IPv6 **aucune** (Entrée), revenir en HTTP **n** ;
   - **2 (LAN)** : adresse **10.77.10.1**, masque **24**, pas de passerelle (Entrée), IPv6
     **aucune**, serveur DHCP **y**, plage **10.77.10.100** à **10.77.10.199**, revenir en HTTP **n**.
5. Depuis l'hôte (qui est sur le LAN en 10.77.10.254), ouvrez **https://10.77.10.1/**
   (certificat auto-signé). Identifiants d'usine : `admin` / `pfsense`. L'assistant :
   - nom `pfsense`, domaine **lab.local**, serveur DNS : laissez vide (le résolveur de pfSense
     interroge directement Internet) ;
   - fuseau **Europe/Paris** ; WAN et LAN : gardez les valeurs de l'étape 4 ;
   - nouveau mot de passe `admin` : la valeur `PfSense` de `F:\Dev\glpi-test-lab-data\vm\secrets.json`.
6. **Services > DNS Resolver > Domain Overrides** : domaine **lab.local**, serveur **10.77.10.10**
   (les machines du LAN résolvent ainsi le domaine).
7. **Services > DHCP Server > LAN** : serveur DNS **10.77.10.10** (postes ajoutés plus tard).
8. Pour la cartographie (#8), **Services > SNMP** : activer, communauté en lecture = valeur
   `SnmpPfSense` de `secrets.json`, interface d'écoute **LAN**.
9. **Diagnostics > Backup & Restore** : téléchargez `config.xml` et rangez-le dans
   `F:\Dev\glpi-test-lab-data\vm\pfsense\config.xml`. Une réinstallation se termine alors par
   « Restore Backup » de ce fichier au lieu des étapes 4 à 8.
10. `.\vm\30-configurer.ps1 -Nom lab-pfsense` vérifie que pfSense répond et prend le point de
    contrôle « propre ».

Variante récente : avec le Netgate Installer (pfSense CE 2.8 et suivants), WAN et LAN se
règlent pendant l'installation (écran « Network Setup » de la
[doc Netgate](https://docs.netgate.com/pfsense/en/latest/install/install-walkthrough.html)) ;
il lui faut Internet sur le WAN, que le NAT `lab-nat` fournit. Déposez l'ISO dans le dossier
`iso` et indiquez son nom dans `vms.local.psd1` (`Iso.PfSense.Fichier`).

## Étape 6 : configuration après installation

```powershell
.\vm\30-configurer.ps1
```

Les VM Windows sont pilotées par
[PowerShell Direct](https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct)
(par le bus de la VM, sans réseau), Ubuntu par SSH avec la clé du labo
(`…\vm\ssh\lab_ed25519`).

- **AD (DC01)** : adresse fixe, rôles AD DS et AD CS,
  [nouvelle forêt](https://learn.microsoft.com/powershell/module/addsdeployment/install-addsforest)
  `lab.local` (NetBIOS `LAB`) avec DNS intégré, redirecteur DNS vers pfSense,
  [autorité de certification d'entreprise](https://learn.microsoft.com/powershell/module/adcsdeployment/install-adcscertificationauthority)
  `LAB-CA` (le contrôleur reçoit ainsi un certificat et répond en LDAPS), puis l'annuaire de
  démonstration. Le certificat de `LAB-CA` est copié dans `…\vm\ca\lab-ca.cer` et `lab-ca.pem`.
- **Windows 11** : adresse fixe, DNS de l'AD,
  [jonction au domaine](https://learn.microsoft.com/powershell/module/microsoft.powershell.management/add-computer)
  dans `OU=Postes,OU=Ordinateurs,OU=Lab,DC=lab,DC=local`, puis GLPI Agent.
- **Ubuntu** : GLPI Agent s'installe tout seul au premier démarrage ; le script vérifie le service
  et relance l'installation si besoin (journal dans la VM : `/var/log/lab-glpi-agent.log`).
- Chaque VM configurée est arrêtée proprement et reçoit le **point de contrôle « propre »**
  (`-NouveauPointDeControle` pour le remplacer, `-SansPointDeControle` pour s'en passer).

### Annuaire de démonstration

Défini dans [`vm/modeles/annuaire-demo.psd1`](../vm/modeles/annuaire-demo.psd1) (données fictives,
relançable sans doublon) :

- OU `Lab` : `Utilisateurs` (Direction, Securite, Informatique, RH, Finance, Commercial),
  `Groupes`, `Comptes de service`, `Comptes a privileges`, `Ordinateurs` (Postes, Serveurs),
  `Desactives` ;
- 15 groupes globaux de sécurité, dont `GG-RSSI`, `GG-DPO`, `GG-Comite-Securite`,
  `GG-Techniciens`, `GG-Support-N1`, `GG-Admins-Serveurs` et les groupes de profils GLPI
  (`GG-GLPI-Admins`, `GG-GLPI-Techniciens`, `GG-GLPI-Utilisateurs`, ce dernier imbriquant les
  groupes métier) ;
- 15 comptes de personnes avec fonction, service, responsable, courriel et téléphone fictif
  (tranche 01 99 00, réservée à la fiction) : directrice générale, RSSI (`s.bernard`), DPO
  (`t.dubois`), analyste sécurité, administrateur systèmes, techniciens N1 et N2, RH, finance,
  commercial ;
- cas pour les revues d'accès : compte à privilèges séparé (`adm.jfournier`, Admins du domaine),
  compte à privilèges oublié dont le mot de passe n'expire jamais (`admin.ancien`), stagiaire au
  compte expiré (`h.garnier`), deux départs désactivés encore membres de groupes (`f.chevalier`,
  `g.mercier`, ce dernier dans `GG-Admins-Serveurs`) ;
- comptes de service : `svc-glpi-ldap` (liaison LDAP de GLPI), `svc-sauvegarde` (Opérateurs de
  sauvegarde), `svc-sql` (avec SPN), `svc-supervision`.

Mots de passe : `UtilisateursDemo` (tous les comptes de démonstration) et `CompteLdapGlpi`
(`svc-glpi-ldap`) dans `secrets.json`.

## Brancher GLPI sur l'AD (LDAP)

Pour une **nouvelle** forêt, Windows Server 2025 impose la signature LDAP et refuse donc les
liaisons simples en clair sur le port 389
([doc Microsoft](https://learn.microsoft.com/windows-server/identity/ad-ds/ldap-signing)). GLPI se
connecte par une liaison simple : il faut **LDAPS** (port 636), fourni par l'autorité `LAB-CA`. Le
labo ne baisse pas ce réglage de sécurité.

Dans GLPI : **Configuration > Authentification > Annuaires LDAP > Ajouter** :

| Champ | Valeur |
|---|---|
| Nom | `lab.local` |
| Serveur | `ldaps://dc01.lab.local` |
| Port | `636` |
| BaseDN | `DC=lab,DC=local` |
| DN du compte (pour les connexions non anonymes) | `svc-glpi-ldap@lab.local` |
| Mot de passe du compte | valeur `CompteLdapGlpi` de `secrets.json` |
| Filtre de connexion | `(&(objectClass=user)(objectCategory=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))` |
| Champ de l'identifiant | `samaccountname` |
| Champ de synchronisation | `objectguid` |

Le conteneur GLPI doit, pour que TLS aboutisse :

1. résoudre `dc01.lab.local` en `10.77.10.10` (entrée `extra_hosts` du service GLPI, ou DNS) ;
2. faire confiance à `LAB-CA` : monter `F:\Dev\glpi-test-lab-data\vm\ca\lab-ca.pem` dans le
   conteneur et le désigner dans `/etc/ldap/ldap.conf` (`TLS_CACERT /chemin/lab-ca.pem`).

Ces deux réglages concernent la pile GLPI (`stack/`, lot #2) et sont à y ajouter. Le conteneur
joint `10.77.10.10` à travers l'hôte, qui est sur le LAN du labo.

Contrôle rapide depuis l'hôte : `Test-NetConnection 10.77.10.10 -Port 636`.

## GLPI Agent

Version officielle **1.21**, épinglée avec ses sommes SHA-256 dans `vms.psd1`.

- Windows 11 : MSI, options documentées
  ([doc](https://glpi-agent.readthedocs.io/en/latest/installation/windows-command-line.html)) :
  `SERVER=<UrlAgent> ADD_FIREWALL_EXCEPTION=1 RUNNOW=1 EXECMODE=1 TAG=labo-vm ADDLOCAL=feat_AGENT,feat_NETINV`
  (`feat_NETINV` prépare l'inventaire réseau de #8).
- Ubuntu : installeur Linux officiel,
  `--install --server=<UrlAgent> --tag=labo-vm --type=typical --runnow --no-question --silent`
  (options de `--help`).

L'URL vient de `Glpi.UrlAgent` (par défaut `http://10.77.10.254:8101/`, l'instance `glpi12-a` du
labo vue depuis le LAN). `RUNNOW` / `--runnow` envoient un premier inventaire tout de suite : les
postes apparaissent dans **Parc > Ordinateurs** de cette instance (étiquette `labo-vm`). Pour viser
une autre instance, changez `Glpi.UrlAgent` puis réinstallez l'agent (ou modifiez `server` dans la
configuration de l'agent).

## Pilotage au quotidien

```powershell
.\vm\lab-vm.ps1 up                 # démarre tout : pfSense, AD, puis les postes
.\vm\lab-vm.ps1 up lab-ad lab-win11
.\vm\lab-vm.ps1 status             # état, mémoire, point « propre », jours d'évaluation restants
.\vm\lab-vm.ps1 reset lab-win11    # retour au point de contrôle « propre »
.\vm\lab-vm.ps1 down               # arrêt propre, ordre inverse
```

Autres commandes : `installer`, `reinstaller <vm>`, `renouveler`, `planifier`, `deplanifier`,
`supprimer <vm>` (détail : `Get-Help .\vm\lab-vm.ps1 -Full`).

Le point de contrôle « propre » est pris VM **arrêtée**, juste après la configuration : `reset`
remet la VM dans cet état connu en quelques secondes, puis la redémarre. Les points de contrôle
sont de type standard
([Checkpoint-VM](https://learn.microsoft.com/powershell/module/hyper-v/checkpoint-vm)).

Attention : revenir au point « propre » d'un poste joint au domaine longtemps après sa prise peut
désynchroniser le mot de passe de son compte machine (renouvelé tous les 30 jours par défaut). Dans
ce cas : `lab-vm.ps1 reinstaller lab-win11`.

## Mémoire utilisée

Mémoire dynamique de Hyper-V (multiples de 128 Mo, comme le recommande Microsoft), sauf pfSense
(FreeBSD) en mémoire fixe :

| VM | Démarrage | Minimum | Maximum |
|---|---|---|---|
| lab-pfsense | 1 024 Mo | 1 024 Mo (fixe) | 1 024 Mo |
| lab-ad | 2 048 Mo | 2 048 Mo | 4 096 Mo |
| lab-win11 | 4 096 Mo (exigé par l'installation de Windows 11) | 2 048 Mo | 4 096 Mo |
| lab-ubuntu | 2 048 Mo | 1 024 Mo | 2 048 Mo |
| **Total** | **9 Go** | **6 Go** | **11 Go** |

Sur 32 Go, il reste au moins 21 Go pour Windows, Docker et les instances GLPI. Les VM ne tournent
que quand on les démarre (`lab-vm.ps1 up`) : aucune n'est lancée avec Windows. `lab-vm.ps1 status`
affiche la mémoire réellement attribuée.

## Durées d'évaluation et réinstallation

| Système | Durée | À l'échéance |
|---|---|---|
| Windows Server 2025 | 180 jours | l'évaluation expire : réinstaller (ci-dessous) |
| Windows 11 Entreprise | 90 jours | idem |
| Ubuntu Server LTS, pfSense CE | sans limite | rien à faire |

`lab-vm.ps1 status` affiche les jours restants : lus dans la licence de Windows quand la VM tourne
(`SoftwareLicensingProduct.GracePeriodRemaining`), sinon calculés depuis la date d'installation
(`…\vm\etat.json`).

**Réinstallation automatique** :

```powershell
.\vm\lab-vm.ps1 renouveler               # réinstalle ce qui expire dans moins de 7 jours
.\vm\lab-vm.ps1 renouveler -SeuilJours 14
.\vm\lab-vm.ps1 planifier                # chaque jour à 9 h, session ouverte (tâche de votre compte, sans droits administrateur)
```

La réinstallation supprime la VM, son disque et ses points de contrôle, puis enchaîne
`20-creer-vm.ps1` et `30-configurer.ps1` : installation sans intervention, domaine, annuaire de
démonstration, agent et nouveau point « propre ». Réinstaller l'AD crée un **nouveau** domaine :
Windows 11 est alors réinstallé aussi, sa jonction étant perdue. Les ISO déjà téléchargées
servent à nouveau (une nouvelle évaluation repart pour 180 ou 90 jours). Ce que vous aviez ajouté
à la main dans ces VM est perdu : gardez-le dans les modèles (`vm/modeles/`) pour qu'il soit
recréé.

Réinstallation manuelle d'une VM : `.\vm\lab-vm.ps1 reinstaller lab-ad` (confirmation demandée,
`-Force` pour s'en passer). pfSense n'expire pas ; en cas de besoin, `reinstaller lab-pfsense`
puis les étapes de la console et la restauration de `config.xml`.

## Fichiers produits (hors dépôt)

Sous `F:\Dev\glpi-test-lab-data\vm` :

| Chemin | Contenu |
|---|---|
| `iso\` | ISO téléchargées, `SHA256SUMS.lab` (sommes relevées des ISO Microsoft) |
| `logiciels\` | MSI et installeur Linux de GLPI Agent |
| `machines\<vm>\` | VM, disque VHDX, points de contrôle |
| `supports\` | `autounattend.xml` et supports CIDATA générés (contiennent des mots de passe) |
| `secrets.json` | mots de passe générés : `AdminWindows` (Administrator du domaine et labadmin de Windows 11), `Dsrm`, `UtilisateursDemo`, `CompteLdapGlpi`, `Ubuntu`, `PfSense`, `SnmpPfSense` |
| `ssh\` | clé SSH du labo (`ssh -i …\ssh\lab_ed25519 labadmin@10.77.10.30`) |
| `ca\` | certificat de l'autorité LAB-CA (LDAPS) |
| `etat.json` | dates d'installation et de configuration |

## Dépannage

- **« Cette session ne peut pas piloter Hyper-V »** : étape 1 non faite, ou session Windows pas
  rouverte depuis l'ajout au groupe « Administrateurs Hyper-V ».
- **Windows reste sur « Press any key to boot from CD or DVD » puis affiche une erreur de
  démarrage** : la touche est arrivée trop tôt ou trop tard. `lab-vm.ps1 supprimer <vm>` puis
  `20-creer-vm.ps1 -Nom <vm>`, ou appuyez sur une touche dans `vmconnect` au bon moment.
- **TPM virtuel non activé (Windows 11)** : créez cette VM depuis la console administrateur :
  `00-prerequis-admin.ps1 -CreerVm`.
- **Ubuntu demande « Continue with autoinstall? »** : la ligne GRUB n'a pas été saisie ; répondez
  `yes` dans `vmconnect`, ou augmentez `DelaiGrubSecondes`.
- **Les agents n'atteignent pas GLPI** : instance GLPI démarrée (`lab status`) ? Depuis la VM,
  `Test-NetConnection 10.77.10.254 -Port 8101`. La règle de pare-feu de l'étape 1 doit exister
  (`Get-NetFirewallRule -Name glpi-test-lab-vm-glpi`).
- **Pas d'Internet dans les VM** : pfSense installé et configuré (étape 5) ? NAT créé (bilan de
  l'étape 1) ?
