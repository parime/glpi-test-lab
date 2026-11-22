# Configuration des VM du laboratoire (lot #5) : Proxmox VE dans UNE VM Hyper-V (virtualisation
# imbriquée), et les VM du labo dans Proxmox, créées par son API.
#
# Ce fichier est versionné : n'y mettez aucun secret. Les mots de passe et le jeton d'API Proxmox
# sont générés au premier lancement dans <Racine>\secrets.json (hors dépôt).
# Pour adapter sans modifier ce fichier, créez vm\vms.local.psd1 (ignoré par git) avec seulement
# les clés à changer, par exemple : @{ Glpi = @{ UrlAgent = 'http://10.77.10.254:8102/' } }
#
# Règle du mainteneur : rien de surdimensionné. Les VM ne servent qu'à faire remonter des
# inventaires et un annuaire : CPU, mémoire et disque au minimum documenté par chaque éditeur.
@{
    # Tout ce qui est produit (disque de Proxmox, ISO, supports, secrets, état) va ici, jamais sur C:.
    Racine = 'F:\Dev\glpi-test-lab-data\vm'

    # --- La VM Hyper-V qui porte Proxmox VE ------------------------------------------------------
    # Configuration requise : https://pve.proxmox.com/wiki/System_Requirements (processeur 64 bits
    # avec Intel VT ou AMD-V, 1 Go pour Proxmox plus la mémoire des VM invitées).
    # Virtualisation imbriquée sous Hyper-V (mémoire statique, extensions exposées, usurpation
    # d'adresse MAC pour le réseau des VM invitées) :
    # https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/enable-nested-virtualization
    Proxmox = @{
        NomVm        = 'lab-proxmox'
        # 9.1-1 et non 9.2-1 : l'installeur 9.2-1 ne trouve pas son propre lecteur DVD dans une VM
        # Hyper-V de génération 2 (« searching for block device containing the ISO » sans fin),
        # constaté ici le 22/11/2026 et signalé sur le forum Proxmox :
        # https://forum.proxmox.com/threads/proxmox-ve-9-2-1-iso-not-installing-in-nested-hyper-v.183899/
        # La 9.1-1 s'installe ; la mise à jour vers 9.2 se fait ensuite par apt (dépôt no-subscription).
        Iso          = 'proxmox-ve_9.1-1.iso'
        Processeurs  = 4
        MemoireMo    = 8192       # statique (exigée par l'imbrication) : 1 Go pour Proxmox + VM invitées
        DisqueGo     = 120        # VHDX dynamique : disques des VM (allocation fine) et ISO
        Fqdn         = 'pve.lab.local'
        Noeud        = 'pve'
        IpLan        = '10.77.10.5'
        Clavier      = 'fr'
        Pays         = 'fr'
        Fuseau       = 'Europe/Paris'
        # DNS de Proxmox pendant l'installation (le pont WAN prend ensuite le DNS du DHCP).
        Dns          = '9.9.9.9'
        # Adresses MAC fixes des deux cartes, pour que l'installation automatique les reconnaisse.
        MacWan       = '00155D770A01'
        MacLan       = '00155D770A02'
        StockageIso    = 'local'
        StockageDisque = 'local-lvm'
    }

    Reseau = @{
        # WAN : commutateur « Default Switch » de Windows (NAT et DHCP fournis par Windows, sans
        # droits administrateur). Pont Proxmox vmbr1, en DHCP ; le WAN de pfSense y est aussi.
        CommutateurWan = 'Default Switch'
        # LAN : commutateur interne « lab-interne » (créé sans élévation par un membre
        # d'« Administrateurs Hyper-V »), pont Proxmox vmbr0 (celui que crée l'installeur, avec
        # l'adresse d'administration de Proxmox). L'hôte y reçoit 10.77.10.254 par le
        # DHCP de Proxmox (réservation sur l'adresse MAC de sa carte « vEthernet (lab-interne) »),
        # sans passerelle : seul le trafic du labo passe par là.
        CommutateurLan = 'lab-interne'
        PontLan        = 'vmbr0'
        PontWan        = 'vmbr1'
        Prefixe        = '10.77.10.0/24'
        IpHote         = '10.77.10.254'
        Passerelle     = '10.77.10.1'      # pfSense (LAN)
    }

    Domaine = @{
        Nom     = 'lab.local'
        NetBios = 'LAB'
        BaseDn  = 'DC=lab,DC=local'
    }

    # Instance GLPI qui reçoit les inventaires. 10.77.10.254 est l'hôte vu depuis le LAN du labo ;
    # 8101 est glpi12-a dans instances.txt (socle, lot #2).
    Glpi = @{
        UrlAgent = 'http://10.77.10.254:8101/'
        Tag      = 'labo-vm'
    }

    # GLPI Agent, version officielle épinglée : https://github.com/glpi-project/glpi-agent/releases/tag/1.21
    # Sommes du fichier officiel glpi-agent-1.21.sha256, vérifiées aussi au téléchargement.
    GlpiAgent = @{
        Version          = '1.21'
        Msi              = 'GLPI-Agent-1.21-x64.msi'
        MsiSha256        = '152bd777abc5a6d0e8a1f163af25c6b8c166f47895d115076b480863a5f0de6c'
        Linux            = 'glpi-agent-1.21-linux-installer.pl'
        LinuxSha256      = 'bde7235d77ca54766903ba4eda4a637e17e05e5ed489019c69e9b33bbef69395'
        # Options du MSI : https://glpi-agent.readthedocs.io/en/latest/installation/windows-command-line.html
        AddLocalWindows  = 'feat_AGENT,feat_NETINV'
        # Options de « perl glpi-agent-1.21-linux-installer.pl --help ».
        TypeLinux        = 'typical'
    }

    # ISO Windows en anglais (noms des comptes et groupes intégrés prévisibles : Administrator,
    # Administrators), réglages régionaux et clavier français.
    Langue = @{
        WindowsUi      = 'en-US'
        WindowsRegion  = 'fr-FR'
        WindowsClavier = '040c:0000040c'
        WindowsFuseau  = 'Romance Standard Time'
        UbuntuLocale   = 'fr_FR.UTF-8'
        UbuntuClavier  = 'fr'
        UbuntuFuseau   = 'Europe/Paris'
    }

    Iso = @{
        # https://www.proxmox.com/en/downloads (ISO et SHA256SUMS : https://enterprise.proxmox.com/iso/)
        Proxmox = @{
            Fichier = 'proxmox-ve_9.1-1.iso'
            Base    = 'https://enterprise.proxmox.com/iso/'
        }
        # Pilotes VirtIO pour Windows, projet Fedora (gratuit) :
        # https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md
        # Version figée (dossier « archive-virtio ») ; pas de somme publiée pour l'ISO.
        VirtIO = @{
            Fichier = 'virtio-win-0.1.302.iso'
            Url     = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso'
            Page    = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/'
            Sha256  = ''
        }
        # Centre d'évaluation Microsoft : https://www.microsoft.com/evalcenter/download-windows-server-2025
        # Lien direct « ISO downloads, English (United States) ». Pas de somme publiée : relevée au
        # premier téléchargement (iso\SHA256SUMS.lab) puis vérifiée ensuite.
        WindowsServer2025 = @{
            Fichier         = 'WindowsServer2025-evaluation-en-us.iso'
            Url             = 'https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us'
            Page            = 'https://www.microsoft.com/evalcenter/download-windows-server-2025'
            Sha256          = ''
            EvaluationJours = 180
        }
        # https://www.microsoft.com/evalcenter/download-windows-11-enterprise (ISO Enterprise, en-US)
        Windows11Entreprise = @{
            Fichier         = 'Windows11-Entreprise-evaluation-en-us.iso'
            Url             = 'https://go.microsoft.com/fwlink/?LinkId=2382600&clcid=0x409&culture=en-us&country=us'
            Page            = 'https://www.microsoft.com/evalcenter/download-windows-11-enterprise'
            Sha256          = ''
            EvaluationJours = 90
        }
        # https://releases.ubuntu.com/24.04/ : dernière version ponctuelle « live-server » de SHA256SUMS.
        UbuntuServer = @{
            Base  = 'https://releases.ubuntu.com/24.04/'
            Motif = '^ubuntu-24\.04(\.\d+)*-live-server-amd64\.iso$'
        }
        # pfSense CE : installeur hors ligne 2.7.2 du miroir officiel Netgate, avec sa somme. Les
        # versions suivantes passent par le « Netgate Installer » en ligne : https://www.pfsense.org/download/
        PfSense = @{
            Fichier   = 'pfSense-CE-2.7.2-RELEASE-amd64.iso'
            UrlGz     = 'https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz'
            UrlSha256 = 'https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz.sha256'
            Page      = 'https://www.pfsense.org/download/'
        }
    }

    # VM invitées dans Proxmox. Ordre de démarrage : pfSense, AD, puis les postes.
    # MemoireMo : mémoire de fonctionnement ; MemoireInstallationMo : mémoire pendant l'installation
    # quand l'installeur exige plus, ramenée ensuite à MemoireMo.
    Vm = @(
        @{
            Nom         = 'lab-pfsense'
            VmId        = 101
            Role        = 'pare-feu'
            Iso         = 'PfSense'
            Ordre       = 1
            Coeurs      = 1
            MemoireMo   = 1024      # https://docs.netgate.com/pfsense/en/latest/hardware/minimum-requirements.html
            DisqueGo    = 8
            Ip          = '10.77.10.1'
        }
        @{
            Nom         = 'lab-ad'
            NomMachine  = 'DC01'
            VmId        = 102
            Role        = 'ad'
            Iso         = 'WindowsServer2025'
            # Index dans sources\install.wim, relevés le 22/11/2026 dans l'ISO 26100.32230 :
            # 1 Standard (Server Core, sans interface), 2 Standard (expérience de bureau),
            # 3 Datacenter Core, 4 Datacenter.
            IndexImage  = 1
            Ordre       = 2
            Coeurs      = 2
            # Server Core : 512 Mo et 32 Go minimum
            # (https://learn.microsoft.com/windows-server/get-started/hardware-requirements).
            MemoireMo   = 2048
            DisqueGo    = 32
            Ip          = '10.77.10.10'
        }
        @{
            Nom         = 'lab-win11'
            NomMachine  = 'PC-WIN11'
            VmId        = 103
            Role        = 'poste-windows'
            Iso         = 'Windows11Entreprise'
            # Image unique « Windows 11 Enterprise Evaluation » (EnterpriseEval), relevée le 22/11/2026.
            IndexImage  = 1
            Ordre       = 3
            Coeurs      = 2
            # Windows 11 exige 4 Go, 64 Go, TPM 2.0 et démarrage sécurisé à l'installation
            # (https://learn.microsoft.com/windows/whats-new/windows-11-requirements). Proxmox fournit
            # un TPM 2.0 virtuel et l'UEFI avec démarrage sécurisé : aucun contournement. La mémoire
            # redescend ensuite à 2,5 Go ; les 64 Go sont en allocation fine.
            MemoireInstallationMo = 4096
            MemoireMo   = 2560
            DisqueGo    = 64
            Ip          = '10.77.10.20'
        }
        @{
            Nom         = 'lab-ubuntu'
            NomMachine  = 'srv-ubuntu'
            VmId        = 104
            Role        = 'poste-ubuntu'
            Iso         = 'UbuntuServer'
            Ordre       = 3
            Coeurs      = 1
            # L'installeur « live » se charge en mémoire : 2 Go pendant l'installation, 1 Go ensuite.
            MemoireInstallationMo = 2048
            MemoireMo   = 1024
            DisqueGo    = 10
            Ip          = '10.77.10.30'
            # Secondes entre le démarrage et la saisie de la ligne de commande GRUB.
            DelaiGrubSecondes = 15
        }
    )

    PointDeControle = 'propre'

    # Renouvellement des évaluations : réinstallation quand il reste moins de SeuilJours.
    Renouvellement = @{
        SeuilJours = 7
    }
}
