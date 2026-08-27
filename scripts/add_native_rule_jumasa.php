<?php

require_once '/usr/share/grommunio-web/init.php';
require_once BASE_PATH . 'server/includes/bootstrap.php';
require_once BASE_PATH . 'server/includes/modules/class.module.php';
require_once BASE_PATH . 'server/includes/modules/class.rulesmodule.php';

$username = getenv('GROMMUNIO_USER') ?: ($argv[1] ?? '');
$password = getenv('GROMMUNIO_PASS') ?: ($argv[2] ?? '');

if ($username === '' || $password === '') {
    fwrite(STDERR, "Uso: GROMMUNIO_USER=admin@arvera.es GROMMUNIO_PASS=... php add_native_rule_jumasa.php\n");
    exit(2);
}

$GLOBALS['mapisession'] = new MAPISession();
$result = $GLOBALS['mapisession']->logon($username, $password);
if ($result !== NOERROR) {
    fwrite(STDERR, "Logon MAPI failed: " . get_mapi_error_name($result) . " ($result)\n");
    exit(1);
}

$GLOBALS['properties'] = new Properties();

function smtpSearchKeyHex(string $email): string {
    return strtoupper(bin2hex('SMTP:' . strtoupper($email) . "\0"));
}

function domainSearchKeyHex(string $domain): string {
    return strtoupper(bin2hex(strtoupper($domain)));
}

function exactSenderCondition(string $email, string $display): array {
    $hex = smtpSearchKeyHex($email);
    return [
        10,
        [
            '10' => [
                4,
                [
                    '1' => 4,
                    '6' => 'PR_SENDER_SEARCH_KEY',
                    '0' => [
                        'PR_EMS_TEMPLATE_BLOB' => $hex,
                    ],
                ],
            ],
            '9' => [
                '0x60000003' => 1,
                'PR_EMS_TEMPLATE_BLOB' => $hex,
                '0x0001001E' => $display . ' <' . $email . '>',
                'PR_DISPLAY_TYPE' => 0,
            ],
        ],
    ];
}

function containsSenderCondition(string $domain): array {
    return [
        3,
        [
            '6' => 'PR_SENDER_SEARCH_KEY',
            '2' => 1,
            '0' => [
                'PR_SENDER_SEARCH_KEY' => domainSearchKeyHex($domain),
            ],
        ],
    ];
}

function orCondition(array $conditions): array {
    return [0, $conditions];
}

function findPublicFolderByName($store, string $name) {
    $root = mapi_msgstore_openentry($store);
    $table = mapi_folder_gethierarchytable($root, CONVENIENT_DEPTH);
    $rows = mapi_table_queryallrows($table, [PR_ENTRYID, PR_DISPLAY_NAME]);
    foreach ($rows as $row) {
        if (($row[PR_DISPLAY_NAME] ?? '') === $name) {
            return $row[PR_ENTRYID];
        }
    }
    return false;
}

$store = $GLOBALS['mapisession']->getDefaultMessageStore();
$storeProps = mapi_getprops($store, [PR_ENTRYID]);
$storeEntryIdHex = bin2hex($storeProps[PR_ENTRYID]);

$publicStore = $GLOBALS['mapisession']->getPublicMessageStore();
$publicStoreProps = mapi_getprops($publicStore, [PR_ENTRYID]);
$publicStoreEntryIdHex = bin2hex($publicStoreProps[PR_ENTRYID]);

$jumasaFolderEntryId = findPublicFolderByName($publicStore, 'JUMASA');
if ($jumasaFolderEntryId === false) {
    fwrite(STDERR, "No encuentro Public Folder JUMASA. Creala primero desde admin web.\n");
    exit(1);
}

$module = new RulesModule(1, []);
$existing = $module->getRules($store)['item'] ?? [];

foreach ($existing as $rule) {
    if (($rule['props']['rule_name'] ?? '') === 'JUMASA') {
        echo "La regla JUMASA ya existe. No hago cambios.\n";
        exit(0);
    }
}

$maxSequence = 0;
foreach ($existing as $rule) {
    $maxSequence = max($maxSequence, (int) ($rule['props']['rule_sequence'] ?? 0));
}

$newRule = [
    'rule_id' => '',
    'message_action' => [
        'store_entryid' => $storeEntryIdHex,
    ],
    'timezone_iana' => 'Europe/Madrid',
    'props' => [
        'rule_name' => 'JUMASA',
        'rule_provider' => 'RuleOrganizer',
        'rule_level' => 0,
        'rule_sequence' => $maxSequence + 1,
        'rule_state' => 1,
        'rule_condition' => orCondition([
            exactSenderCondition('facturacion@jumasa.es', 'facturacion@jumasa.es'),
            containsSenderCondition('@jumasa.es'),
        ]),
        'rule_actions' => [
            [
                'action' => 1,
                'flags' => 0,
                'flavor' => 0,
                'storeentryid' => $publicStoreEntryIdHex,
                'folderentryid' => bin2hex($jumasaFolderEntryId),
            ],
        ],
    ],
];

$rulesToSave = $existing;
$rulesToSave[] = $newRule;

$dryRun = getenv('DRY_RUN');
if ($dryRun === false) {
    $dryRun = '1';
}

if ($dryRun === '1') {
    echo "DRY_RUN: se guardarian " . count($rulesToSave) . " reglas. Nueva regla:\n";
    echo json_encode($newRule, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE) . "\n";
    exit(0);
}

$module->deleteRules($store);
$module->saveRules($store, $rulesToSave);
$module->deleteOLClientRules($store);

echo "Regla JUMASA guardada. Total reglas: " . count($rulesToSave) . "\n";
