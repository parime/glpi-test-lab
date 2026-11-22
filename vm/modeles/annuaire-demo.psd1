# Annuaire de démonstration du domaine lab.local (données fictives).
# Sert aux revues d'accès de GRC et à la synchronisation LDAP de GLPI. Chargé par
# vm\invite\annuaire-demo.ps1 sur le contrôleur de domaine ; relançable sans doublon.
#
# Cas utiles aux revues d'accès, volontairement présents :
# - comptes désactivés encore membres de groupes (f.chevalier, g.mercier) ;
# - compte à privilèges oublié, mot de passe sans expiration (admin.ancien) ;
# - compte à privilèges séparé du compte de tous les jours (adm.jfournier) ;
# - compte expiré (h.garnier, stagiaire) ;
# - comptes de service, dont un avec SPN (svc-sql) et un opérateur de sauvegarde.
# Numéros de téléphone : tranche 01 99 00 réservée par l'ARCEP aux œuvres de fiction.
#
# Groupes intégrés désignés par un alias résolu par SID : @AdminsDuDomaine (RID 512),
# @OperateursSauvegarde (S-1-5-32-551).
@{
    UniteRacine = 'Lab'
    Unites      = @(
        'Utilisateurs'
        'Utilisateurs/Direction'
        'Utilisateurs/Securite'
        'Utilisateurs/Informatique'
        'Utilisateurs/RH'
        'Utilisateurs/Finance'
        'Utilisateurs/Commercial'
        'Groupes'
        'Comptes de service'
        'Comptes a privileges'
        'Ordinateurs'
        'Ordinateurs/Postes'
        'Ordinateurs/Serveurs'
        'Desactives'
    )

    Groupes = @(
        @{ Nom = 'GG-Direction'; Description = 'Comité de direction' }
        @{ Nom = 'GG-Comite-Securite'; Description = 'Comité sécurité (direction, RSSI, DPO)' }
        @{ Nom = 'GG-RSSI'; Description = 'Responsable de la sécurité des systèmes d''information' }
        @{ Nom = 'GG-DPO'; Description = 'Délégué à la protection des données' }
        @{ Nom = 'GG-Securite-Analystes'; Description = 'Analystes sécurité' }
        @{ Nom = 'GG-Techniciens'; Description = 'Techniciens informatiques' }
        @{ Nom = 'GG-Support-N1'; Description = 'Support de niveau 1' }
        @{ Nom = 'GG-Admins-Serveurs'; Description = 'Administrateurs des serveurs' }
        @{ Nom = 'GG-RH'; Description = 'Ressources humaines' }
        @{ Nom = 'GG-Finance'; Description = 'Finance et comptabilité' }
        @{ Nom = 'GG-Commercial'; Description = 'Équipe commerciale' }
        @{ Nom = 'GG-Supervision'; Description = 'Comptes de supervision' }
        @{ Nom = 'GG-GLPI-Admins'; Description = 'Profil Super-Admin de GLPI' }
        @{ Nom = 'GG-GLPI-Techniciens'; Description = 'Profil Technicien de GLPI' }
        @{ Nom = 'GG-GLPI-Utilisateurs'; Description = 'Profil Self-Service de GLPI'; Membres = @('GG-Direction', 'GG-RH', 'GG-Finance', 'GG-Commercial', 'GG-Securite-Analystes') }
    )

    Utilisateurs = @(
        @{ Sam = 'a.martin'; Prenom = 'Alice'; Nom = 'Martin'; Unite = 'Utilisateurs/Direction'; Titre = 'Directrice générale'; Service = 'Direction'; Telephone = '01 99 00 00 01'; Groupes = @('GG-Direction', 'GG-Comite-Securite') }
        @{ Sam = 's.bernard'; Prenom = 'Sophie'; Nom = 'Bernard'; Unite = 'Utilisateurs/Securite'; Titre = 'RSSI'; Service = 'Sécurité'; Responsable = 'a.martin'; Telephone = '01 99 00 00 02'; Groupes = @('GG-RSSI', 'GG-Comite-Securite', 'GG-GLPI-Admins') }
        @{ Sam = 't.dubois'; Prenom = 'Thomas'; Nom = 'Dubois'; Unite = 'Utilisateurs/Direction'; Titre = 'Délégué à la protection des données'; Service = 'Juridique'; Responsable = 'a.martin'; Telephone = '01 99 00 00 03'; Groupes = @('GG-DPO', 'GG-Comite-Securite') }
        @{ Sam = 'l.petit'; Prenom = 'Léa'; Nom = 'Petit'; Unite = 'Utilisateurs/Securite'; Titre = 'Analyste sécurité'; Service = 'Sécurité'; Responsable = 's.bernard'; Telephone = '01 99 00 00 04'; Groupes = @('GG-Securite-Analystes') }
        @{ Sam = 'j.fournier'; Prenom = 'Julien'; Nom = 'Fournier'; Unite = 'Utilisateurs/Informatique'; Titre = 'Administrateur systèmes'; Service = 'Informatique'; Responsable = 'a.martin'; Telephone = '01 99 00 00 05'; Groupes = @('GG-Techniciens', 'GG-Admins-Serveurs', 'GG-GLPI-Techniciens') }
        @{ Sam = 'm.roux'; Prenom = 'Marc'; Nom = 'Roux'; Unite = 'Utilisateurs/Informatique'; Titre = 'Technicien support N1'; Service = 'Informatique'; Responsable = 'j.fournier'; Telephone = '01 99 00 00 06'; Groupes = @('GG-Techniciens', 'GG-Support-N1', 'GG-GLPI-Techniciens') }
        @{ Sam = 'c.moreau'; Prenom = 'Camille'; Nom = 'Moreau'; Unite = 'Utilisateurs/Informatique'; Titre = 'Technicienne support N2'; Service = 'Informatique'; Responsable = 'j.fournier'; Telephone = '01 99 00 00 07'; Groupes = @('GG-Techniciens', 'GG-GLPI-Techniciens') }
        @{ Sam = 'h.garnier'; Prenom = 'Hugo'; Nom = 'Garnier'; Unite = 'Utilisateurs/Informatique'; Titre = 'Stagiaire'; Service = 'Informatique'; Responsable = 'j.fournier'; Telephone = '01 99 00 00 08'; Groupes = @('GG-Techniciens', 'GG-Support-N1'); ExpireIlYaJours = 30 }
        @{ Sam = 'n.girard'; Prenom = 'Nathalie'; Nom = 'Girard'; Unite = 'Utilisateurs/RH'; Titre = 'Directrice des ressources humaines'; Service = 'Ressources humaines'; Responsable = 'a.martin'; Telephone = '01 99 00 00 09'; Groupes = @('GG-RH', 'GG-Direction') }
        @{ Sam = 'p.lambert'; Prenom = 'Pierre'; Nom = 'Lambert'; Unite = 'Utilisateurs/Finance'; Titre = 'Comptable'; Service = 'Finance'; Responsable = 'a.martin'; Telephone = '01 99 00 00 10'; Groupes = @('GG-Finance') }
        @{ Sam = 'e.bonnet'; Prenom = 'Emma'; Nom = 'Bonnet'; Unite = 'Utilisateurs/Commercial'; Titre = 'Chargée d''affaires'; Service = 'Commercial'; Responsable = 'a.martin'; Telephone = '01 99 00 00 11'; Groupes = @('GG-Commercial') }
        # Comptes à privilèges.
        @{ Sam = 'adm.jfournier'; Prenom = 'Julien'; Nom = 'Fournier (admin)'; Unite = 'Comptes a privileges'; Titre = 'Compte d''administration de Julien Fournier'; Service = 'Informatique'; Responsable = 'j.fournier'; Groupes = @('@AdminsDuDomaine') }
        @{ Sam = 'admin.ancien'; Prenom = 'Prestataire'; Nom = 'Ancien'; Unite = 'Comptes a privileges'; Titre = 'Ancien prestataire infogérance'; Service = 'Externe'; Groupes = @('@AdminsDuDomaine', 'GG-Admins-Serveurs'); MotDePasseNExpireJamais = $true; Description = 'Compte d''un prestataire parti, jamais revu' }
        # Comptes désactivés (départs), encore membres de groupes.
        @{ Sam = 'f.chevalier'; Prenom = 'François'; Nom = 'Chevalier'; Unite = 'Desactives'; Titre = 'Ancien contrôleur de gestion'; Service = 'Finance'; Groupes = @('GG-Finance'); Desactive = $true; Description = 'Départ, compte désactivé' }
        @{ Sam = 'g.mercier'; Prenom = 'Gilles'; Nom = 'Mercier'; Unite = 'Desactives'; Titre = 'Ancien administrateur réseau'; Service = 'Informatique'; Groupes = @('GG-Admins-Serveurs', 'GG-Techniciens'); Desactive = $true; Description = 'Départ, compte désactivé, droits non retirés' }
    )

    ComptesService = @(
        # Compte de liaison LDAP de GLPI (lecture seule) : son mot de passe est CompteLdapGlpi dans secrets.json.
        @{ Sam = 'svc-glpi-ldap'; Description = 'Lecture de l''annuaire par GLPI (liaison LDAP)'; MotDePasse = 'CompteLdapGlpi' }
        @{ Sam = 'svc-sauvegarde'; Description = 'Logiciel de sauvegarde'; Groupes = @('@OperateursSauvegarde') }
        @{ Sam = 'svc-sql'; Description = 'Service SQL Server de démonstration'; Spn = @('MSSQLSvc/srv-sql.lab.local:1433') }
        @{ Sam = 'svc-supervision'; Description = 'Supervision (Zabbix)'; Groupes = @('GG-Supervision') }
    )
}
