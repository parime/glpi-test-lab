<?php

// glpi-test-lab : GLPI lit config/local_define.php dans son dossier d'installation, qui n'est pas
// un volume (perdu quand Swarm relance la tâche). Ce fichier, monté par stack/glpi.yml, inclut
// celui du volume /var/glpi/config, où `./lab connect` écrit les réglages de l'instance.
if (is_file('/var/glpi/config/local_define.php')) {
    require_once '/var/glpi/config/local_define.php';
}
