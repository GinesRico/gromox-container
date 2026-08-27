<?php

require_once '/usr/share/grommunio-web/init.php';
require_once BASE_PATH . 'server/includes/bootstrap.php';
require_once BASE_PATH . 'server/includes/modules/class.module.php';
require_once BASE_PATH . 'server/includes/modules/class.rulesmodule.php';

$username = getenv('GROMMUNIO_USER') ?: ($argv[1] ?? '');
$password = getenv('GROMMUNIO_PASS') ?: ($argv[2] ?? '');

if ($username === '' || $password === '') {
    fwrite(STDERR, "Uso: GROMMUNIO_USER=admin@arvera.es GROMMUNIO_PASS=... php probe_mapi_rules.php\n");
    exit(2);
}

$GLOBALS['mapisession'] = new MAPISession();
$result = $GLOBALS['mapisession']->logon($username, $password);
if ($result !== NOERROR) {
    fwrite(STDERR, "Logon MAPI failed: " . get_mapi_error_name($result) . " ($result)\n");
    exit(1);
}

$GLOBALS['properties'] = new Properties();

$store = $GLOBALS['mapisession']->getDefaultMessageStore();
$storeProps = mapi_getprops($store, [PR_ENTRYID, PR_DISPLAY_NAME, PR_MAILBOX_OWNER_NAME, PR_MAILBOX_OWNER_ENTRYID]);

echo "LOGON OK: {$username}\n";
echo "STORE_ENTRYID=" . bin2hex($storeProps[PR_ENTRYID]) . "\n";
echo "STORE_DISPLAY=" . ($storeProps[PR_DISPLAY_NAME] ?? '') . "\n";
echo "MAILBOX_OWNER=" . ($storeProps[PR_MAILBOX_OWNER_NAME] ?? '') . "\n";

$module = new RulesModule(1, []);
$rules = $module->getRules($store);

echo "RULES_JSON_BEGIN\n";
echo json_encode($rules, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE) . "\n";
echo "RULES_JSON_END\n";
