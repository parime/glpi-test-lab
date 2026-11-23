<?php

/**
 * Essai de bout en bout de la brique vaultwarden avec GRC (Comptes privilégiés, issue #859 de
 * parime/glpi-iso27001-management), côté GLPI. Lancé par stack/vaultwarden/grc/essai.sh dans le
 * conteneur GLPI (utilisateur www-data, dossier /var/www/glpi) :
 *   php essai.php comptes   comptes GLPI des membres factices (David Moreau désactivé : parti)
 *   php essai.php verifier  écarts calculés par GRC après l'import, comparés aux écarts attendus
 *   php essai.php purger    retire ces comptes GLPI (les imports sont effacés par l'interface)
 * Ne touche qu'aux comptes dont le commentaire porte LAB_MARK. Données factices seulement.
 */

declare(strict_types=1);

require '/var/www/glpi/vendor/autoload.php';

$kernel = new \Glpi\Kernel\Kernel();
$kernel->boot();
\Session::start();
$_SESSION['glpiactive_entity'] = 0;
$_SESSION['glpiactive_entity_recursive'] = 1;
$_SESSION['glpiactiveentities'] = [0];

use GlpiPlugin\Grcmanager\PrivilegedVault;

const LAB_MARK = 'glpi-test-lab : essai Vaultwarden (factice)';

/** Comptes GLPI : identifiant => [prénom, nom, actif]. Le prestataire n'en a pas (inconnu de GLPI). */
const LAB_USERS = [
    'claire.martin'    => ['Claire', 'Martin', true],
    'bruno.lefevre'    => ['Bruno', 'Lefèvre', true],
    'david.moreau'     => ['David', 'Moreau', false],
    'emma.petit'       => ['Emma', 'Petit', true],
];

/** Écarts attendus des membres (adresse => écarts) et des éléments (nom => écarts), délai de 12 mois. */
const LAB_MEMBERS = [
    'claire.martin@labo-grc.example'  => [],
    'bruno.lefevre@labo-grc.example'  => ['admin_no_2fa'],
    'david.moreau@labo-grc.example'   => ['departed'],
    'emma.petit@labo-grc.example'     => [],
    'prestataire@infogerance.example' => ['unknown'],
    'ancien.stagiaire@labo-grc.example' => [],
];
const LAB_ENTRIES = [
    'Routeur cœur de réseau'       => ['stale', 'departed_holder'],
    'Pare-feu périmétrique'        => ['departed_holder'],
    'Base de données RH'           => ['stale'],
    'iLO srv-app01'                => [],
    // Mot de passe jamais changé depuis la création : Bitwarden laisse passwordRevisionDate vide,
    // la date du dernier changement est celle de la création (colonne creationDate de l'export).
    "Console d'hébergement"        => [],
    'Compte de service sauvegarde' => [],
];

/**
 * Écarts connus de GRC (issue ouverte) : résultat actuel accepté sans faire échouer l'essai, signalé
 * « CONNU » ; dès que GRC donne l'attendu, la ligne repasse « OK ».
 */
const LAB_KNOWN = [
    // parime/glpi-iso27001-management#1145 : creationDate ignorée quand passwordRevisionDate est vide.
    "Console d'hébergement" => [['no_date'], 'parime/glpi-iso27001-management#1145'],
];

function lab_say(string $msg): void
{
    fwrite(STDERR, 'essai vaultwarden : ' . $msg . PHP_EOL);
}

if (!\Plugin::isPluginActive('grcmanager') || !class_exists(PrivilegedVault::class)) {
    lab_say('plugin GRC (grcmanager) absent, inactif ou sans la page Comptes privilégiés (#859)');
    exit(2);
}

/** @return array<string, int> identifiant => id des comptes de l'essai */
function lab_users(): array
{
    global $DB;
    $ids = [];
    foreach ($DB->request(['FROM' => 'glpi_users', 'WHERE' => ['comment' => LAB_MARK]]) as $row) {
        $ids[(string) $row['name']] = (int) $row['id'];
    }

    return $ids;
}

function lab_comptes(): void
{
    $existing = lab_users();
    foreach (LAB_USERS as $login => [$first, $last, $active]) {
        $user = new \User();
        $input = [
            'name'      => $login,
            'firstname' => $first,
            'realname'  => $last,
            'is_active' => $active ? 1 : 0,
            'comment'   => LAB_MARK,
        ];
        if (isset($existing[$login])) {
            $user->update(['id' => $existing[$login]] + $input);
        } else {
            $input['_useremails'] = [-1 => $login . '@labo-grc.example'];
            if ($user->add($input) === false) {
                lab_say("compte $login non créé");
                exit(1);
            }
            lab_say("compte GLPI $login créé" . ($active ? '' : ' (désactivé : personne partie)'));
        }
    }
}

/**
 * @param array<string, list<string>> $expected
 * @param array<string, list<string>> $actual
 */
function lab_compare(string $what, array $expected, array $actual): int
{
    $bad = 0;
    foreach ($expected as $key => $gaps) {
        if (!array_key_exists($key, $actual)) {
            printf("ÉCHEC  %-12s %-36s absent de GRC\n", $what, $key);
            $bad++;
            continue;
        }
        $got = $actual[$key];
        sort($gaps);
        sort($got);
        $ok = $gaps === $got;
        $known = !$ok && isset(LAB_KNOWN[$key]) && LAB_KNOWN[$key][0] === $got;
        printf(
            "%-6s %-12s %-36s attendu [%s], GRC [%s]%s\n",
            $ok ? 'OK' : ($known ? 'CONNU' : 'ÉCHEC'),
            $what,
            $key,
            implode(', ', $gaps),
            implode(', ', $got),
            $known ? ' (écart connu : ' . LAB_KNOWN[$key][1] . ')' : ''
        );
        $bad += $ok || $known ? 0 : 1;
    }
    foreach (array_diff_key($actual, $expected) as $key => $got) {
        printf("ÉCHEC  %-12s %-36s inattendu [%s]\n", $what, $key, implode(', ', $got));
        $bad++;
    }

    return $bad;
}

function lab_verifier(): int
{
    $members = PrivilegedVault::members([0]);
    $entries = PrivilegedVault::entries([0], $members);
    $m = [];
    foreach ($members as $member) {
        $m[(string) $member['email']] = array_values($member['gaps']);
    }
    $e = [];
    foreach ($entries as $entry) {
        $e[(string) $entry['name']] = array_values($entry['gaps']);
    }
    $bad = lab_compare('membre', LAB_MEMBERS, $m) + lab_compare('élément', LAB_ENTRIES, $e);
    echo $bad === 0 ? "Tous les écarts attendus sont trouvés.\n" : "$bad résultat(s) différent(s) de l'attendu.\n";

    return $bad === 0 ? 0 : 1;
}

function lab_purger(): void
{
    foreach (lab_users() as $login => $id) {
        (new \User())->delete(['id' => $id], true);
        lab_say("compte GLPI $login supprimé");
    }
}

switch ($argv[1] ?? '') {
    case 'comptes':
        lab_comptes();
        break;
    case 'verifier':
        exit(lab_verifier());
    case 'purger':
        lab_purger();
        break;
    default:
        lab_say('action attendue : comptes, verifier ou purger');
        exit(2);
}
