<?php

class RunRulesNowModule extends Module {
	private const ST_ENABLED = 1;
	private const OP_MOVE = 1;

	#[Override]
	public function execute() {
		foreach ($this->data as $actionType => $actionData) {
			try {
				match ($actionType) {
					'run' => $this->run($actionData),
					default => $this->handleUnknownActionType($actionType),
				};
			}
			catch (Throwable $e) {
				$this->sendFeedback(false, [
					'type' => ERROR_GENERAL,
					'info' => [
						'display_message' => $e->getMessage(),
					],
				]);
			}
		}
	}

	private function run(array $data): void {
		$storeEntryId = $data['store_entryid'] ?? $GLOBALS['mapisession']->getDefaultMessageStoreEntryId();
		$since = $this->parseSince($data['since_date'] ?? '2026-01-01');
		$move = ($data['move'] ?? true) !== false;

		if (ENABLE_SHARED_RULES !== true && !$GLOBALS['entryid']->compareEntryIds($storeEntryId, $GLOBALS['mapisession']->getDefaultMessageStoreEntryId())) {
			throw new RuntimeException(_('Running rules on shared stores is not allowed by configuration.'));
		}

		$store = $GLOBALS['mapisession']->openMessageStore(hex2bin((string) $storeEntryId));
		$inbox = mapi_msgstore_getreceivefolder($store);
		$inboxProps = mapi_getprops($inbox, [PR_ENTRYID]);
		$rules = $this->loadRules($inbox);

		$table = mapi_folder_getcontentstable($inbox);
		$rows = mapi_table_queryallrows($table, [
			PR_ENTRYID,
			PR_SUBJECT,
			PR_SENDER_EMAIL_ADDRESS,
			PR_SENDER_SMTP_ADDRESS,
			PR_SENDER_NAME,
			PR_SENDER_SEARCH_KEY,
			PR_SENT_REPRESENTING_EMAIL_ADDRESS,
			PR_SENT_REPRESENTING_SMTP_ADDRESS,
			PR_TRANSPORT_MESSAGE_HEADERS,
			PR_MESSAGE_DELIVERY_TIME,
		]);

		$stats = [
			'scanned' => 0,
			'matched' => 0,
			'moved' => 0,
			'skipped_rules' => 0,
			'errors' => 0,
		];

		foreach ($rows as $row) {
			if (!$this->isSince($row[PR_MESSAGE_DELIVERY_TIME] ?? null, $since)) {
				continue;
			}

			$stats['scanned']++;
			foreach ($rules as $rule) {
				$action = $this->firstMoveAction($rule);
				if ($action === null) {
					$stats['skipped_rules']++;
					continue;
				}
				if (!$this->messageMatchesRule($row, $rule)) {
					continue;
				}

				$stats['matched']++;
				try {
					$destStore = $GLOBALS['mapisession']->openMessageStore(hex2bin((string) $action['storeentryid']));
					$destFolder = mapi_msgstore_openentry($destStore, hex2bin((string) $action['folderentryid']));
					mapi_folder_copymessages($inbox, [$row[PR_ENTRYID]], $destFolder, $move ? MESSAGE_MOVE : 0);
					$stats['moved']++;
				}
				catch (Throwable) {
					$stats['errors']++;
				}
				break;
			}
		}

		$stats['display_message'] = sprintf(
			_('Processed %d messages. Matched %d and moved %d. Skipped unsupported rules %d. Errors %d.'),
			$stats['scanned'],
			$stats['matched'],
			$stats['moved'],
			$stats['skipped_rules'],
			$stats['errors']
		);

		$this->addActionData('run', $stats);
		$GLOBALS['bus']->addData($this->getResponseData());
	}

	private function loadRules($inbox): array {
		$properties = $GLOBALS['properties']->getRulesProperties();
		$rulesTable = mapi_folder_getrulestable($inbox);
		mapi_table_restrict($rulesTable, [
			RES_CONTENT,
			[
				FUZZYLEVEL => FL_PREFIX | FL_IGNORECASE,
				ULPROPTAG => PR_RULE_PROVIDER,
				VALUE => [PR_RULE_PROVIDER => 'RuleOrganizer'],
			],
		], TBL_BATCH);
		mapi_table_sort($rulesTable, [PR_RULE_SEQUENCE => TABLE_SORT_ASCEND], TBL_BATCH);

		$rows = mapi_table_queryallrows($rulesTable, $properties);
		$rules = [];
		foreach ($rows as $row) {
			$rule = Conversion::mapMAPI2XML($properties, $row);
			if (((int) ($rule['props']['rule_state'] ?? 0) & self::ST_ENABLED) === self::ST_ENABLED) {
				$rules[] = $rule;
			}
		}
		return $rules;
	}

	private function firstMoveAction(array $rule): ?array {
		foreach (($rule['props']['rule_actions'] ?? []) as $action) {
			if ((int) ($action['action'] ?? -1) === self::OP_MOVE && !empty($action['storeentryid']) && !empty($action['folderentryid'])) {
				return $action;
			}
		}
		return null;
	}

	private function messageMatchesRule(array $row, array $rule): bool {
		$needles = $this->extractSenderNeedles($rule['props']['rule_condition'] ?? []);
		if (empty($needles)) {
			return false;
		}

		$haystack = strtolower(implode("\n", array_filter([
			(string) ($row[PR_SENDER_EMAIL_ADDRESS] ?? ''),
			(string) ($row[PR_SENDER_SMTP_ADDRESS] ?? ''),
			(string) ($row[PR_SENDER_NAME] ?? ''),
			$this->binaryToText($row[PR_SENDER_SEARCH_KEY] ?? ''),
			(string) ($row[PR_SENT_REPRESENTING_EMAIL_ADDRESS] ?? ''),
			(string) ($row[PR_SENT_REPRESENTING_SMTP_ADDRESS] ?? ''),
			$this->headersFromLine($row[PR_TRANSPORT_MESSAGE_HEADERS] ?? ''),
		], static fn($value) => $value !== '')));

		foreach ($needles as $needle) {
			$needle = strtolower($needle);
			if ($needle === '') {
				continue;
			}
			if (str_contains($haystack, $needle)) {
				return true;
			}
		}
		return false;
	}

	private function extractSenderNeedles(mixed $node): array {
		$needles = [];
		if (!is_array($node)) {
			return $needles;
		}

		foreach ($node as $key => $value) {
			if (($key === 'PR_EMS_TEMPLATE_BLOB' || $key === 'PR_SENDER_SEARCH_KEY') && is_string($value)) {
				$text = $this->hexToText($value);
				$text = preg_replace('/^SMTP:/i', '', $text);
				$text = trim($text, "\0 \t\r\n");
				if ($text !== '') {
					$needles[] = $text;
				}
			}
			if (($key === '0x0001001E' || $key === '0x0001001f') && is_string($value)) {
				foreach ($this->emailsFromText($value) as $email) {
					$needles[] = $email;
				}
			}
			if (is_array($value)) {
				array_push($needles, ...$this->extractSenderNeedles($value));
			}
		}
		return array_values(array_unique($needles));
	}

	private function headersFromLine(mixed $headers): string {
		if (!is_string($headers) || $headers === '') {
			return '';
		}
		if (preg_match('/^From:\s*(.+)$/im', $headers, $match) === 1) {
			return $match[1];
		}
		return '';
	}

	private function emailsFromText(string $text): array {
		preg_match_all('/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i', $text, $matches);
		return $matches[0] ?? [];
	}

	private function hexToText(string $value): string {
		if ($value !== '' && preg_match('/^[0-9a-fA-F]+$/', $value) === 1 && strlen($value) % 2 === 0) {
			return @hex2bin($value) ?: $value;
		}
		return $value;
	}

	private function binaryToText(mixed $value): string {
		if (!is_string($value)) {
			return '';
		}
		$text = $value;
		if (str_starts_with(strtoupper($text), 'SMTP:')) {
			return trim(substr($text, 5), "\0 \t\r\n");
		}
		return trim($text, "\0 \t\r\n");
	}

	private function parseSince(string $since): int {
		$ts = strtotime($since . ' 00:00:00');
		if ($ts === false) {
			throw new RuntimeException(_('Invalid date. Use YYYY-MM-DD.'));
		}
		return $ts;
	}

	private function isSince(mixed $value, int $since): bool {
		if ($value === null) {
			return true;
		}
		if (is_int($value)) {
			return $value >= $since;
		}
		if ($value instanceof DateTimeInterface) {
			return $value->getTimestamp() >= $since;
		}
		$ts = strtotime((string) $value);
		return $ts === false || $ts >= $since;
	}
}
