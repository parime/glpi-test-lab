<?php

/**
 * Connexions des briques du labo dans une instance GLPI (plugin Inventaire Docker).
 *
 * Lancé par `./lab connect <instance>` dans le conteneur GLPI (utilisateur www-data, dossier
 * /var/www/glpi). Entrée standard : une connexion par ligne, en JSON, écrite par le crochet
 * « connect » de chaque brique (stack/<brique>/hook.sh) :
 *   {"name": "Labo - Portainer", "type": "portainer", "url": "http://portainer:9000", ...}
 *
 * - crée la connexion, ou la met à jour si une connexion du même nom existe (le nom « Labo - … »
 *   sert de clé) ; les secrets passent par Connection::add/update, qui les chiffre (GLPIKey) ;
 * - autorise les contextes HTTP du plugin vers les réseaux privés (GLPI 12 les refuse par défaut),
 *   dans /var/glpi/config/local_define.php : fichier du volume de l'instance, inclus par
 *   /var/www/glpi/config/local_define.php (config Swarm de stack/glpi.yml).
 *
 * Ne touche qu'aux connexions dont le nom commence par « Labo - ». Rejouable.
 */

declare(strict_types=1);

require '/var/www/glpi/vendor/autoload.php';

$kernel = new \Glpi\Kernel\Kernel();
$kernel->boot();
// Session de ligne de commande, entité racine : les connexions du labo couvrent tout (récursives).
\Session::start();
$_SESSION['glpiactive_entity'] = 0;
$_SESSION['glpiactive_entity_recursive'] = 1;
$_SESSION['glpiactiveentities'] = [0];

const LAB_PREFIX = 'Labo - ';
const LAB_LOCAL_DEFINE = '/var/glpi/config/local_define.php';
const LAB_BEGIN = '// >>> glpi-test-lab (lab connect)';
const LAB_END = '// <<< glpi-test-lab';

function lab_say(string $msg): void
{
    fwrite(STDERR, 'lab connect : ' . $msg . PHP_EOL);
}

if (!\Plugin::isPluginActive('dockerinventory')) {
    lab_say("plugin Inventaire Docker (dockerinventory) absent ou inactif : le déployer d'abord, par exemple"
        . ' G12=<instance> sh /f/Dev/glpi-test-env/deploy-g12.sh dockerinventory');
    exit(2);
}

// Contextes du plugin autorisés vers les réseaux privés (docs/administrateur.md du plugin).
$contexts = [
    'Agent', // défaut de GLPI
    'Auth',  // défaut de GLPI
    'GlpiPlugin\\Dockerinventory\\Portainer\\PortainerContext',
    'GlpiPlugin\\Dockerinventory\\Wud\\WudContext',
    'GlpiPlugin\\Dockerinventory\\Registry\\RegistryContext',
    'GlpiPlugin\\Dockerinventory\\Kubernetes\\KubernetesContext',
    'GlpiPlugin\\Dockerinventory\\Lifecycle\\LifecycleContext',
    'GlpiPlugin\\Dockerinventory\\Traefik\\TraefikContext',
];
$block = LAB_BEGIN . " (contextes autorisés vers les réseaux privés ; retirer ce bloc pour revenir au défaut)\n"
    . "if (!defined('GLPI_SERVERSIDE_URL_ALLOWED_PRIVATE_NETWORKS_CONTEXTS')) {\n"
    . "    define('GLPI_SERVERSIDE_URL_ALLOWED_PRIVATE_NETWORKS_CONTEXTS', [\n"
    . implode('', array_map(static fn(string $c): string => '        ' . var_export($c, true) . ",\n", $contexts))
    . "    ]);\n}\n" . LAB_END . "\n";
$current = is_file(LAB_LOCAL_DEFINE) ? (string) file_get_contents(LAB_LOCAL_DEFINE) : '';
if ($current === '') {
    $current = "<?php\n";
}
$begin = strpos($current, LAB_BEGIN);
$end = strpos($current, LAB_END);
if ($begin !== false && $end !== false) {
    $new = substr($current, 0, $begin) . $block . substr($current, $end + strlen(LAB_END) + 1);
} elseif (str_contains($current, 'GLPI_SERVERSIDE_URL_ALLOWED_PRIVATE_NETWORKS_CONTEXTS')) {
    lab_say(LAB_LOCAL_DEFINE . ' définit déjà les contextes des réseaux privés : laissé tel quel');
    $new = $current;
} else {
    $new = rtrim($current, "\n") . "\n\n" . $block;
}
if ($new !== $current || !is_file(LAB_LOCAL_DEFINE)) {
    file_put_contents(LAB_LOCAL_DEFINE, $new);
    lab_say('contextes Inventaire Docker autorisés vers les réseaux privés (' . LAB_LOCAL_DEFINE . ')');
}

// Instance déployée avant que stack/glpi.yml ne monte l'inclusion : copie provisoire dans le
// conteneur (perdue si Swarm relance la tâche ; `./lab up <instance>` monte la version durable).
$stub = '/var/www/glpi/config/local_define.php';
if (!is_file($stub)) {
    file_put_contents($stub, "<?php
// glpi-test-lab : inclusion provisoire (voir stack/glpi/local_define.php)
"
        . "if (is_file('" . LAB_LOCAL_DEFINE . "')) {
    require_once '" . LAB_LOCAL_DEFINE . "';
}
");
    lab_say("inclusion provisoire écrite dans $stub (./lab up <instance> pour la rendre durable)");
}

$allowed = ['name', 'type', 'url', 'allow_http', 'username', 'api_key', 'registry_host', 'ca_certificate', 'comment'];
$count = 0;
$errors = 0;
while (($line = fgets(STDIN)) !== false) {
    $line = trim($line);
    if ($line === '') {
        continue;
    }
    $spec = json_decode($line, true);
    if (!is_array($spec) || !isset($spec['name'], $spec['type']) || !str_starts_with((string) $spec['name'], LAB_PREFIX)) {
        lab_say('ligne ignorée (JSON invalide ou nom sans « ' . LAB_PREFIX . ' ») : ' . substr($line, 0, 80));
        $errors++;
        continue;
    }
    $input = array_intersect_key($spec, array_flip($allowed));
    $input += ['entities_id' => 0, 'is_recursive' => 1, 'is_active' => 1];

    $conn = new \GlpiPlugin\Dockerinventory\Connection();
    if ($conn->getFromDBByCrit(['name' => $input['name']])) {
        unset($input['type']); // fixé à la création
        $input['id'] = $conn->getID();
        $ok = $conn->update($input);
        $verb = 'mise à jour';
    } else {
        $ok = $conn->add($input) !== false;
        $verb = 'créée';
    }
    // Messages d'erreur du plugin (adresse refusée, champ invalide…), sans les secrets.
    foreach ($_SESSION['MESSAGE_AFTER_REDIRECT'] ?? [] as $messages) {
        foreach ($messages as $m) {
            lab_say('  ' . html_entity_decode(strip_tags((string) $m)));
        }
    }
    $_SESSION['MESSAGE_AFTER_REDIRECT'] = [];
    if ($ok) {
        lab_say(sprintf('%s : %s (%s)', $input['name'], $verb, $spec['url'] ?? ''));
        $count++;
    } else {
        lab_say(sprintf('%s : échec', $input['name']));
        $errors++;
    }
}
lab_say(sprintf('%d connexion(s) à jour, %d erreur(s)', $count, $errors));
exit($errors > 0 ? 1 : 0);
