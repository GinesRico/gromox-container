<?php

require_once '/usr/share/grommunio-web/init.php';
require_once BASE_PATH . 'server/includes/bootstrap.php';
require_once BASE_PATH . 'server/includes/modules/class.module.php';
require_once BASE_PATH . 'server/includes/modules/class.rulesmodule.php';

$owner = getenv('GROMMUNIO_USER') ?: '';
$password = getenv('GROMMUNIO_PASS') ?: '';
$rulesPath = getenv('RULES_JSON') ?: '/tmp/thunderbird_filter_worker_rules.json';
$onlyOwner = getenv('RULE_OWNER') ?: $owner;
$dryRun = getenv('DRY_RUN');
$limit = (int) (getenv('LIMIT') ?: '0');

if ($dryRun === false) {
    $dryRun = '1';
}

if ($owner === '' || $password === '') {
    fwrite(STDERR, "Uso: GROMMUNIO_USER=buzon@dominio GROMMUNIO_PASS=... RULE_OWNER=buzon@dominio php import_native_rules_from_thunderbird.php\n");
    exit(2);
}

if (!is_file($rulesPath)) {
    fwrite(STDERR, "No encuentro reglas JSON: {$rulesPath}\n");
    exit(2);
}

$GLOBALS['mapisession'] = new MAPISession();
$result = $GLOBALS['mapisession']->logon($owner, $password);
if ($result !== NOERROR) {
    fwrite(STDERR, "Logon MAPI failed for {$owner}: " . get_mapi_error_name($result) . " ({$result})\n");
    exit(1);
}

$GLOBALS['properties'] = new Properties();

function smtpSearchKeyHex(string $email): string {
    return strtoupper(bin2hex('SMTP:' . strtoupper($email) . "\0"));
}

function textSearchKeyHex(string $text): string {
    return strtoupper(bin2hex(strtoupper($text)));
}

function exactSenderCondition(string $email): array {
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
                '0x0001001E' => $email . ' <' . $email . '>',
                'PR_DISPLAY_TYPE' => 0,
            ],
        ],
    ];
}

function containsSenderCondition(string $needle): array {
    return [
        3,
        [
            '6' => 'PR_SENDER_SEARCH_KEY',
            '2' => 1,
            '0' => [
                'PR_SENDER_SEARCH_KEY' => textSearchKeyHex($needle),
            ],
        ],
    ];
}

function combineConditions(array $conditions, string $joiner): array {
    if (count($conditions) === 1) {
        return $conditions[0];
    }
    return [strtoupper($joiner) === 'AND' ? 1 : 0, $conditions];
}

function parseThunderbirdCondition(string $condition): array {
    $joiner = str_starts_with(trim($condition), 'AND ') ? 'AND' : 'OR';
    preg_match_all('/\((from|to|cc|subject),(is|contains|ends with|begins with),([^)]+)\)/i', $condition, $matches, PREG_SET_ORDER);
    $parsed = [];
    foreach ($matches as $match) {
        $parsed[] = [
            'field' => strtolower(trim($match[1])),
            'operator' => strtolower(trim($match[2])),
            'value' => trim($match[3]),
        ];
    }
    return [$joiner, $parsed];
}

function nativeFromCondition(array $condition) {
    $value = trim($condition['value']);
    if ($value === '') {
        return false;
    }

    if ($condition['operator'] === 'is' && str_contains($value, '@') && !str_starts_with($value, '@')) {
        return exactSenderCondition($value);
    }

    if (in_array($condition['operator'], ['is', 'contains', 'ends with'], true)) {
        return containsSenderCondition($value);
    }

    return false;
}

function publicFolderNameFromPath(string $path): string {
    $parts = array_values(array_filter(explode('/', trim($path, '/')), fn($part) => $part !== ''));
    return end($parts) ?: '';
}

function publicFolderPathAliases(string $path): array {
    $path = trim($path);
    if ($path === '') {
        return [];
    }

    $aliases = [$path];
    $folderName = publicFolderNameFromPath($path);
    if (preg_match('/^(.+)[0-9a-fA-F]{8}$/', $folderName, $matches)) {
        $cleanName = rtrim($matches[1]);
        $aliases[] = preg_replace('/\/' . preg_quote($folderName, '/') . '$/', '/' . $cleanName, $path);
    }

    return array_values(array_unique($aliases));
}

function publicFolderPathKey(string $path): string {
    $path = '/' . trim(preg_replace('#/+#', '/', $path), '/');
    return strtolower($path);
}

function collectPublicFolderEntryIds($folder, string $basePath, array &$out, $publicStore): void {
    $table = mapi_folder_gethierarchytable($folder);
    $rows = mapi_table_queryallrows($table, [PR_ENTRYID, PR_DISPLAY_NAME]);
    foreach ($rows as $row) {
        $name = $row[PR_DISPLAY_NAME] ?? '';
        if ($name === '' || !isset($row[PR_ENTRYID])) {
            continue;
        }

        $path = ($basePath === '/IPM_SUBTREE' && $name === 'IPM_SUBTREE')
            ? '/IPM_SUBTREE'
            : $basePath . '/' . $name;
        $out[publicFolderPathKey($path)] = strtolower(bin2hex($row[PR_ENTRYID]));

        $child = mapi_msgstore_openentry($publicStore, $row[PR_ENTRYID]);
        if ($child) {
            collectPublicFolderEntryIds($child, $path, $out, $publicStore);
        }
    }
}

function findPublicFolderEntryId(array $publicFolders, string $path): string {
    foreach (publicFolderPathAliases($path) as $candidatePath) {
        $key = publicFolderPathKey($candidatePath);
        if (isset($publicFolders[$key])) {
            return $publicFolders[$key];
        }
    }
    return '';
}

function publicFolderFidHex(string $path, string $domain): string {
    $cmd = 'gromox-export -u ' . escapeshellarg('@' . $domain) . ' -t -r ' . escapeshellarg($path) . ' 2>&1 | head -c 8192';
    $output = shell_exec($cmd);
    if (!is_string($output) || !preg_match('/Folder\s+([0-9a-fA-F]+)h/', $output, $matches)) {
        return '';
    }
    return strtolower($matches[1]);
}

function findPublicMoveFolderEntryIdTemplate(array $rules, string $publicStoreEntryIdHex): string {
    foreach ($rules as $rule) {
        foreach (($rule['props']['rule_actions'] ?? []) as $action) {
            if (($action['action'] ?? null) !== 1) {
                continue;
            }
            if (strtolower($action['storeentryid'] ?? '') !== strtolower($publicStoreEntryIdHex)) {
                continue;
            }
            $folderEntryId = $action['folderentryid'] ?? '';
            if (is_string($folderEntryId) && preg_match('/^[0-9a-fA-F]+$/', $folderEntryId) && strlen($folderEntryId) >= 10) {
                return strtolower($folderEntryId);
            }
        }
    }
    return '';
}

function folderEntryIdFromTemplate(string $templateHex, string $fidHex): string {
    $fidHex = strtolower(rtrim($fidHex, 'h'));
    if ($fidHex === '' || $templateHex === '') {
        return '';
    }
    // grommunio-web stores public folder rule destinations as a short entryid.
    // The last bytes encode the folder id as seen in gromox-export, plus padding.
    $suffix = $fidHex . '0000';
    return substr($templateHex, 0, -strlen($suffix)) . $suffix;
}

function shortRuleName(array $rule): string {
    $folder = publicFolderNameFromPath($rule['public_folder'] ?? '');
    $base = $folder !== '' ? $folder : ($rule['name'] ?? 'Thunderbird');
    $base = preg_replace('/\s+/', ' ', trim($base));
    $base = function_exists('mb_substr') ? mb_substr($base, 0, 48) : substr($base, 0, 48);
    return 'TB-' . ($rule['id'] ?? '0') . ' ' . $base;
}

$allRules = json_decode(file_get_contents($rulesPath), true);
if (!is_array($allRules)) {
    fwrite(STDERR, "JSON invalido en {$rulesPath}\n");
    exit(2);
}

$store = $GLOBALS['mapisession']->getDefaultMessageStore();
$storeProps = mapi_getprops($store, [PR_ENTRYID]);
$storeEntryIdHex = bin2hex($storeProps[PR_ENTRYID]);

$publicStore = $GLOBALS['mapisession']->getPublicMessageStore();
$publicStoreProps = mapi_getprops($publicStore, [PR_ENTRYID]);
$publicStoreEntryIdHex = bin2hex($publicStoreProps[PR_ENTRYID]);
$publicRoot = mapi_msgstore_openentry($publicStore);
$publicFolders = [];
if ($publicRoot) {
    collectPublicFolderEntryIds($publicRoot, '/IPM_SUBTREE', $publicFolders, $publicStore);
}

$module = new RulesModule(1, []);
$existing = $module->getRules($store)['item'] ?? [];
$existingNames = [];
$maxSequence = 0;
foreach ($existing as $rule) {
    $name = $rule['props']['rule_name'] ?? '';
    if ($name !== '') {
        $existingNames[$name] = true;
    }
    $maxSequence = max($maxSequence, (int) ($rule['props']['rule_sequence'] ?? 0));
}

$ownerDomain = substr(strrchr($onlyOwner, '@') ?: '@arvera.es', 1);
$publicFolderEntryIdTemplate = findPublicMoveFolderEntryIdTemplate($existing, $publicStoreEntryIdHex);

$toAdd = [];
$stats = [
    'owner' => $onlyOwner,
    'existing' => count($existing),
    'candidate' => 0,
    'added' => 0,
    'skipped_existing' => 0,
    'skipped_owner' => 0,
    'skipped_unsupported' => 0,
    'skipped_missing_folder' => 0,
    'public_folders_seen' => count($publicFolders),
    'public_template_found' => $publicFolderEntryIdTemplate !== '',
];

foreach ($allRules as $rule) {
    if (($rule['source_mailbox'] ?? '') !== $onlyOwner) {
        $stats['skipped_owner']++;
        continue;
    }
    $stats['candidate']++;

    [$joiner, $conditions] = parseThunderbirdCondition($rule['condition'] ?? '');
    if (!$conditions) {
        $stats['skipped_unsupported']++;
        continue;
    }

    $nativeConditions = [];
    $unsupported = false;
    foreach ($conditions as $condition) {
        if ($condition['field'] !== 'from') {
            $unsupported = true;
            break;
        }
        $native = nativeFromCondition($condition);
        if ($native === false) {
            $unsupported = true;
            break;
        }
        $nativeConditions[] = $native;
    }

    if ($unsupported) {
        $stats['skipped_unsupported']++;
        continue;
    }

    $publicFolderPath = $rule['public_folder'] ?? '';
    $folderEntryIdHex = findPublicFolderEntryId($publicFolders, $publicFolderPath);
    $resolvedPublicFolderPath = $folderEntryIdHex !== '' ? $publicFolderPath : '';
    $folderName = publicFolderNameFromPath($resolvedPublicFolderPath !== '' ? $resolvedPublicFolderPath : $publicFolderPath);

    if ($folderEntryIdHex === '' && $publicFolderEntryIdTemplate !== '') {
        $folderFidHex = '';
        foreach (publicFolderPathAliases($publicFolderPath) as $candidatePath) {
            $folderFidHex = publicFolderFidHex($candidatePath, $ownerDomain);
            if ($folderFidHex !== '') {
                $resolvedPublicFolderPath = $candidatePath;
                break;
            }
        }
        $folderEntryIdHex = folderEntryIdFromTemplate($publicFolderEntryIdTemplate, $folderFidHex);
    }

    if ($folderEntryIdHex === '') {
        $stats['skipped_missing_folder']++;
        fwrite(STDERR, "WARN carpeta publica no encontrada: {$folderName} ({$publicFolderPath}) para regla " . ($rule['id'] ?? '?') . "\n");
        continue;
    }

    $ruleName = shortRuleName($rule);
    if (isset($existingNames[$ruleName])) {
        $stats['skipped_existing']++;
        continue;
    }

    $maxSequence++;
    $toAdd[] = [
        'rule_id' => '',
        'message_action' => [
            'store_entryid' => $storeEntryIdHex,
        ],
        'timezone_iana' => 'Europe/Madrid',
        'props' => [
            'rule_name' => $ruleName,
            'rule_provider' => 'RuleOrganizer',
            'rule_level' => 0,
            'rule_sequence' => $maxSequence,
            'rule_state' => 1,
            'rule_condition' => combineConditions($nativeConditions, $joiner),
            'rule_actions' => [
                [
                    'action' => 1,
                    'flags' => 0,
                    'flavor' => 0,
                    'storeentryid' => $publicStoreEntryIdHex,
                    'folderentryid' => $folderEntryIdHex,
                ],
            ],
        ],
    ];
    $existingNames[$ruleName] = true;
    $stats['added']++;

    if ($limit > 0 && $stats['added'] >= $limit) {
        break;
    }
}

$rulesToSave = array_merge($existing, $toAdd);

echo json_encode($stats, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE) . "\n";

if ($dryRun === '1') {
    echo "DRY_RUN=1: no guardo cambios. Reglas totales si se aplica: " . count($rulesToSave) . "\n";
    if ($toAdd) {
        echo "Primera regla nueva:\n";
        echo json_encode($toAdd[0], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE) . "\n";
    }
    exit(0);
}

if (!$toAdd) {
    echo "No hay reglas nuevas que guardar.\n";
    exit(0);
}

$module->deleteRules($store);
$module->saveRules($store, $rulesToSave);
$module->deleteOLClientRules($store);

echo "Guardadas " . count($toAdd) . " reglas nuevas. Total reglas: " . count($rulesToSave) . "\n";
