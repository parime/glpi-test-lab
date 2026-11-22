# Configuration des VM Hyper-V du laboratoire (lot #5).
#
# Ce fichier est versionné : n'y mettez aucun secret. Les mots de passe sont générés au premier
# lancement dans <Racine>\secrets.json (hors dépôt).
# Pour adapter sans modifier ce fichier, créez vm\vms.local.psd1 (ignoré par git) avec seulement
# les clés à changer, par exemple : @{ Glpi = @{ UrlAgent = 'http://10.77.10.254:8102/' } }
#
# Mémoire : en Mo, multiples de 128 (recommandation Microsoft pour la mémoire dynamique :
# https://learn.microsoft.com/windows-server/virtualization/hyper-v/supported-ubuntu-virtual-machines-on-hyper-v).
@{
    # Tout ce qui est produit (disques, ISO, supports d'installation, secrets, état) va ici, jamais sur C:.
    Racine = 'F:\Dev\glpi-test-lab-data\vm'

    Reseau = @{
        # Commutateur interne avec NAT (WinNAT) : sortie Internet du WAN de pfSense.
        # Windows n'accepte qu'UN seul réseau NAT par hôte (doc Microsoft, « Set up a NAT network ») :
        # https://learn.microsoft.com/windows-server/virtualization/hyper-v/setup-nat-network
        Nat     = @{
            Commutateur = 'lab-nat'
            NomNat      = 'lab-nat'
            Prefixe     = '10.77.0.0/24'
            IpHote      = '10.77.0.1'
            IpWanPfSense = '10.77.0.2'
        }
        # Commutateur interne : réseau local du labo (LAN de pfSense, AD, postes).
        # L'hôte y a une adresse pour joindre l'AD en LDAP et pour que les agents joignent GLPI.
        Interne = @{
            Commutateur = 'lab-interne'
            Prefixe     = '10.77.10.0/24'
            IpHote      = '10.77.10.254'
            Passerelle  = '10.77.10.1'      # pfSense (LAN)
        }
        # Ports GLPI du labo ouverts aux VM dans le pare-feu de l'hôte (voir instances.txt du socle).
        PortsGlpi = '8100-8199'
    }

    Domaine = @{
        Nom     = 'lab.local'
        NetBios = 'LAB'
        BaseDn  = 'DC=lab,DC=local'
    }

    # Instance GLPI qui reçoit les inventaires des agents. 10.77.10.254 est l'hôte vu depuis le LAN
    # du labo ; 8101 est glpi12-a dans instances.txt.
    Glpi = @{
        UrlAgent = 'http://10.77.10.254:8101/'
        Tag      = 'labo-vm'
    }

    # GLPI Agent, version officielle épinglée : https://github.com/glpi-project/glpi-agent/releases/tag/1.21
    # Les sommes viennent du fichier officiel glpi-agent-1.21.sha256 de la publication ; le script de
    # téléchargement vérifie aussi ce fichier.
    GlpiAgent = @{
        Version          = '1.21'
        Msi              = 'GLPI-Agent-1.21-x64.msi'
        MsiSha256        = '152bd777abc5a6d0e8a1f163af25c6b8c166f47895d115076b480863a5f0de6c'
        Linux            = 'glpi-agent-1.21-linux-installer.pl'
        LinuxSha256      = 'bde7235d77ca54766903ba4eda4a637e17e05e5ed489019c69e9b33bbef69395'
        # Options documentées : https://glpi-agent.readthedocs.io/en/latest/installation/windows-command-line.html
        # feat_NETINV prépare l'inventaire réseau (issue #8).
        AddLocalWindows  = 'feat_AGENT,feat_NETINV'
        # Options listées par « perl glpi-agent-1.21-linux-installer.pl --help ».
        TypeLinux        = 'typical'
    }

    # Langue : ISO Windows en anglais (noms des comptes et groupes intégrés prévisibles :
    # Administrator, Administrators), avec réglages régionaux et clavier français.
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
        # Centre d'évaluation Microsoft : https://www.microsoft.com/evalcenter/download-windows-server-2025
        # Lien direct « ISO downloads, English (United States) » de cette page. Microsoft ne publie pas
        # de somme de contrôle pour les ISO d'évaluation : la somme est relevée au premier
        # téléchargement (iso\SHA256SUMS.lab) puis vérifiée ensuite. Renseignez Sha256 pour l'imposer.
        WindowsServer2025 = @{
            Fichier         = 'WindowsServer2025-evaluation-en-us.iso'
            Url             = 'https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us'
            Page            = 'https://www.microsoft.com/evalcenter/download-windows-server-2025'
            Sha256          = ''
            EvaluationJours = 180
        }
        # https://www.microsoft.com/evalcenter/download-windows-11-enterprise (ISO Enterprise, en-US, 64 bits)
        Windows11Entreprise = @{
            Fichier         = 'Windows11-Entreprise-evaluation-en-us.iso'
            Url             = 'https://go.microsoft.com/fwlink/?LinkId=2382600&clcid=0x409&culture=en-us&country=us'
            Page            = 'https://www.microsoft.com/evalcenter/download-windows-11-enterprise'
            Sha256          = ''
            EvaluationJours = 90
        }
        # https://releases.ubuntu.com/24.04/ : le script prend la dernière version ponctuelle
        # « live-server » listée dans SHA256SUMS et vérifie sa somme.
        UbuntuServer = @{
            Base  = 'https://releases.ubuntu.com/24.04/'
            Motif = '^ubuntu-24\.04(\.\d+)*-live-server-amd64\.iso$'
        }
        # pfSense CE : depuis la 2.7.2, les nouvelles versions s'installent par le « Netgate Installer »
        # (en ligne, téléchargé depuis la boutique Netgate : https://www.pfsense.org/download/).
        # Le miroir officiel garde l'installeur hors ligne 2.7.2 avec sa somme SHA-256 : c'est lui qui
        # est téléchargé automatiquement ; une mise à jour depuis l'interface web est possible ensuite.
        PfSense = @{
            Fichier   = 'pfSense-CE-2.7.2-RELEASE-amd64.iso'
            UrlGz     = 'https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz'
            UrlSha256 = 'https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz.sha256'
            Page      = 'https://www.pfsense.org/download/'
        }
    }

    # Ordre de démarrage : pfSense (passerelle), AD (DNS, annuaire), puis les postes.
    Vm = @(
        @{
            Nom           = 'lab-pfsense'
            Role          = 'pare-feu'
            Iso           = 'PfSense'
            Ordre         = 1
            Processeurs   = 1
            # FreeBSD : mémoire fixe (la doc Netgate prévoit 1 Go, sans mémoire dynamique) :
            # https://docs.netgate.com/pfsense/en/latest/recipes/virtualize-hyper-v.html
            MemoireDemarrageMo = 1024
            MemoireDynamique   = $false
            DisqueGo      = 16
            SecureBoot    = 'Off'
            # Première carte = WAN (hn0), seconde = LAN (hn1), comme dans la doc Netgate.
            Cartes        = @('lab-nat', 'lab-interne')
            Ip            = '10.77.10.1'
        }
        @{
            Nom           = 'lab-ad'
            NomMachine    = 'DC01'
            Role          = 'ad'
            Iso           = 'WindowsServer2025'
            # Index de l'image dans sources\install.wim, relevé le 22/11/2026 dans l'ISO 26100.32230 :
            # 1 Standard Core, 2 Standard (expérience de bureau), 3 Datacenter Core, 4 Datacenter.
            # Vérifiable avec : dism /Get-WimInfo /WimFile:<lecteur>:\sources\install.wim
            IndexImage    = 2
            Ordre         = 2
            Processeurs   = 2
            MemoireDemarrageMo = 2048
            MemoireMinMo  = 2048
            MemoireMaxMo  = 4096
            MemoireDynamique   = $true
            DisqueGo      = 60
            SecureBoot    = 'MicrosoftWindows'
            Cartes        = @('lab-interne')
            Ip            = '10.77.10.10'
        }
        @{
            Nom           = 'lab-win11'
            NomMachine    = 'PC-WIN11'
            Role          = 'poste-windows'
            Iso           = 'Windows11Entreprise'
            # Image unique « Windows 11 Enterprise Evaluation » (EnterpriseEval), relevée le 22/11/2026.
            IndexImage    = 1
            Ordre         = 3
            Processeurs   = 2
            # Windows 11 exige 4 Go au démarrage de l'installation.
            MemoireDemarrageMo = 4096
            MemoireMinMo  = 2048
            MemoireMaxMo  = 4096
            MemoireDynamique   = $true
            DisqueGo      = 64
            SecureBoot    = 'MicrosoftWindows'
            Tpm           = $true
            Cartes        = @('lab-interne')
            Ip            = '10.77.10.20'
        }
        @{
            Nom           = 'lab-ubuntu'
            NomMachine    = 'srv-ubuntu'
            Role          = 'poste-ubuntu'
            Iso           = 'UbuntuServer'
            Ordre         = 3
            Processeurs   = 2
            MemoireDemarrageMo = 2048
            MemoireMinMo  = 1024
            MemoireMaxMo  = 2048
            MemoireDynamique   = $true
            DisqueGo      = 25
            SecureBoot    = 'MicrosoftUEFICertificateAuthority'
            Cartes        = @('lab-interne')
            Ip            = '10.77.10.30'
            # Secondes entre le démarrage et la saisie de la ligne de commande GRUB (voir docs/vm.md).
            DelaiGrubSecondes = 12
        }
    )

    PointDeControle = 'propre'

    # Renouvellement des évaluations : réinstallation quand il reste moins de SeuilJours.
    Renouvellement = @{
        SeuilJours = 7
    }
}
