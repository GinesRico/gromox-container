<?php

require_once '/usr/share/grommunio-web/init.php';
require_once BASE_PATH . 'server/includes/bootstrap.php';
require_once BASE_PATH . 'server/includes/modules/class.module.php';
require_once BASE_PATH . 'server/includes/modules/class.rulesmodule.php';

$username = getenv('GROMMUNIO_USER') ?: '';
$password = getenv('GROMMUNIO_PASS') ?: '';

if ($username === '' || $password === '') {
    fwrite(STDERR, "Uso: GROMMUNIO_USER=usuario@dominio GROMMUNIO_PASS=... php export_native_rules_for_runner.php\n");
    exit(2);
}

$GLOBALS['mapisession'] = new MAPISession();
$result = $GLOBALS['mapisession']->logon($username, $password);
if ($result !== NOERROR) {
    fwrite(STDERR, "Logon MAPI failed: " . get_mapi_error_name($result) . " ($result)\n");
    exit(1);
}

$GLOBALS['properties'] = new Properties();

function hexToStringValue(string $hex): string {
    $raw = @hex2bin($hex);
    if ($raw === false) {
        return '';
    }
    return strtolower(rtrim($raw, "\0"));
}

function collectPublicFolders($folder, string $basePath, array &$out): void {
    $table = mapi_folder_gethierarchytable($folder);
    $rows = mapi_table_queryallrows($table, [PR_ENTRYID, PR_DISPLAY_NAME]);
    foreach ($rows as $row) {
        $name = $row[PR_DISPLAY_NAME] ?? '';
        if ($name === '') {
            continue;
        }
        $entryId = $row[PR_ENTRYID];
        $path = ($basePath === '/IPM_SUBTREE' && $name === 'IPM_SUBTREE') ? '/IPM_SUBTREE' : $basePath . '/' . $name;
        $out[strtolower(bin2hex($entryId))] = $path;
        $child = mapi_msgstore_openentry($GLOBALS['publicStore'], $entryId);
        if ($child) {
            collectPublicFolders($child, $path, $out);
        }
    }
}

function parseCondition($condition): array {
    $conditions = [];

    if (!is_array($condition) || count($condition) < 2) {
        return $conditions;
    }

    $type = $condition[0];
    $payload = $condition[1];

    // OR wrapper used by grommunio web for multiple sender tests.
    if ($type === 0 && is_array($payload)) {
        foreach ($payload as $child) {
            foreach (parseCondition($child) as $parsed) {
                $conditions[] = $parsed;
            }
        }
        return $conditions;
    }

    // Exact sender search key: SMTP:USER@DOMAIN\0
    if ($type === 10 && is_array($payload)) {
        $hex = $payload['9']['PR_EMS_TEMPLATE_BLOB'] ?? $payload['10'][1]['0']['PR_EMS_TEMPLATE_BLOB'] ?? '';
        $value = hexToStringValue($hex);
        if (str_starts_with($value, 'smtp:')) {
            $conditions[] = ['field' => 'from', 'operator' => 'is', 'value' => substr($value, 5)];
        }
        return $conditions;
    }

    // Contains sender search key, normally @DOMAIN.
    if ($type === 3 && is_array($payload)) {
        $prop = $payload['6'] ?? '';
        $hex = $payload['0']['PR_SENDER_SEARCH_KEY'] ?? '';
        $value = hexToStringValue($hex);
        if ($prop === 'PR_SENDER_SEARCH_KEY' && $value !== '') {
            $conditions[] = ['field' => 'from', 'operator' => 'contains', 'value' => $value];
        }
        return $conditions;
    }

    return $conditions;
}

$store = $GLOBALS['mapisession']->getDefaultMessageStore();
$module = new RulesModule(1, []);
$rules = $module->getRules($store)['item'] ?? [];

$GLOBALS['publicStore'] = $GLOBALS['mapisession']->getPublicMessageStore();
$publicRoot = mapi_msgstore_openentry($GLOBALS['publicStore']);
$publicFolders = [];
collectPublicFolders($publicRoot, '/IPM_SUBTREE', $publicFolders);

$exported = [];
foreach ($rules as $rule) {
    $props = $rule['props'] ?? [];
    if (($props['rule_state'] ?? 0) != 1) {
        continue;
    }
    $actions = $props['rule_actions'] ?? [];
    if (!$actions) {
        continue;
    }
    $action = $actions[0];
    if (($action['action'] ?? null) !== 1) {
        continue;
    }

    $folderEntryId = strtolower($action['folderentryid'] ?? '');
    $publicPath = $publicFolders[$folderEntryId] ?? null;
    if ($publicPath === null) {
        continue;
    }

    $conditions = parseCondition($props['rule_condition'] ?? null);
    if (!$conditions) {
        continue;
    }

    $exported[] = [
        'id' => (string)($rule['rule_id'] ?? ''),
        'name' => $props['rule_name'] ?? '',
        'source_mailbox' => $username,
        'conditions' => $conditions,
        'public_folder' => $publicPath,
    ];
}

echo json_encode($exported, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE) . "\n";
