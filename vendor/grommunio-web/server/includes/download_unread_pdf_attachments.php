<?php

// required to handle php errors
require_once __DIR__ . '/exceptions/class.ZarafaErrorException.php';
require_once __DIR__ . '/download_base.php';

/**
 * Downloads PDF attachments from unread messages in a folder as a ZIP archive.
 */
class DownloadUnreadPdfAttachments extends DownloadBase {
	/**
	 * Entryid of the MAPIFolder that should be scanned.
	 */
	private $folderId;

	/**
	 * Resource of the MAPIFolder that should be scanned.
	 */
	private $folder;

	/**
	 * Name of the ZIP file sent to the client.
	 */
	private $zipFileName;

	/**
	 * Constructor.
	 */
	public function __construct() {
		$this->folderId = false;
		$this->folder = false;
		$this->zipFileName = _('Unread PDF attachments') . '.zip';

		parent::__construct();
	}

	/**
	 * Initializes and sanitizes request data.
	 *
	 * @param array $data parameters received with the request
	 */
	public function init($data) {
		if (isset($data['store'])) {
			$this->storeId = sanitizeValue($data['store'], '', ID_REGEX);
		}
		elseif (isset($data['storeid'])) {
			$this->storeId = sanitizeValue($data['storeid'], '', ID_REGEX);
		}

		if (isset($data['entryid'])) {
			$this->folderId = sanitizeValue($data['entryid'], '', ID_REGEX);
		}

		if (!$this->storeId || !$this->folderId) {
			throw new ZarafaException(_('No mail folder selected.'));
		}

		$this->store = $GLOBALS['mapisession']->openMessageStore(hex2bin((string) $this->storeId));
		$this->folder = mapi_msgstore_openentry($this->store, hex2bin((string) $this->folderId));

		if (!$this->folder) {
			throw new ZarafaException(_('Folder not found.'));
		}
	}

	/**
	 * Creates and sends a ZIP containing PDF attachments from unread messages.
	 */
	public function download() {
		$randomZipName = tempnam(sys_get_temp_dir(), 'unread_pdf_');
		$zip = new ZipArchive();

		if ($randomZipName === false) {
			throw new ZarafaException(_('Cannot create ZIP archive.'));
		}

		if ($zip->open($randomZipName, ZipArchive::OVERWRITE) !== true) {
			unlink($randomZipName);
			throw new ZarafaException(_('Cannot create ZIP archive.'));
		}

		$attachmentState = new AttachmentState();
		$attachmentState->open();
		$messagesToMarkRead = [];

		try {
			try {
				$messages = $this->getUnreadMessagesWithAttachments();
				foreach ($messages as $messageRow) {
					$message = mapi_msgstore_openentry($this->store, $messageRow[PR_ENTRYID]);
					if (!$message) {
						continue;
					}

					$pdfCount = $this->addPdfAttachmentsToZipArchive($message, $attachmentState, $zip);
					if ($pdfCount > 0) {
						$messagesToMarkRead[] = $message;
					}
				}
			}
			catch (Exception $e) {
				$zip->close();
				if (file_exists($randomZipName)) {
					unlink($randomZipName);
				}

				throw $e;
			}
		}
		finally {
			$attachmentState->close();
		}

		if (count($messagesToMarkRead) === 0) {
			$zip->close();
			unlink($randomZipName);
			throw new ZarafaException(_('No PDF attachments found in unread messages.'));
		}

		if (!$zip->close()) {
			unlink($randomZipName);
			throw new ZarafaException(_('Cannot create ZIP archive.'));
		}

		foreach ($messagesToMarkRead as $message) {
			mapi_message_setreadflag($message, SUPPRESS_RECEIPT | MAPI_DEFERRED_ERRORS);
		}

		$this->sendZipResponse($randomZipName);
	}

	/**
	 * Returns unread messages that have attachments in the selected folder.
	 *
	 * @return array unread message rows
	 */
	private function getUnreadMessagesWithAttachments() {
		$table = mapi_folder_getcontentstable($this->folder, MAPI_DEFERRED_ERRORS);
		$restriction = [
			RES_AND,
			[
				[
					RES_BITMASK,
					[
						ULTYPE => BMR_EQZ,
						ULPROPTAG => PR_MESSAGE_FLAGS,
						ULMASK => MSGFLAG_READ,
					],
				],
				[
					RES_PROPERTY,
					[
						RELOP => RELOP_EQ,
						ULPROPTAG => PR_HASATTACH,
						VALUE => [PR_HASATTACH => true],
					],
				],
			],
		];

		$messages = mapi_table_queryallrows($table, [PR_ENTRYID], $restriction);

		return is_array($messages) ? $messages : [];
	}

	/**
	 * Adds visible PDF attachments from one message to the ZIP archive.
	 *
	 * @param MAPImessage     $message         message that should be scanned
	 * @param AttachmentState $attachmentState attachment state helper
	 * @param ZipArchive      $zip             ZIP archive
	 *
	 * @return int number of PDFs added
	 */
	private function addPdfAttachmentsToZipArchive($message, $attachmentState, $zip) {
		$pdfCount = 0;
		$attachmentTable = mapi_message_getattachmenttable($message);
		$attachments = mapi_table_queryallrows($attachmentTable, [
			PR_ATTACH_NUM,
			PR_ATTACH_METHOD,
			PR_ATTACH_LONG_FILENAME,
			PR_ATTACH_FILENAME,
			PR_DISPLAY_NAME,
			PR_ATTACHMENT_HIDDEN,
		]);

		if (!is_array($attachments)) {
			return $pdfCount;
		}

		foreach ($attachments as $attachmentRow) {
			if (($attachmentRow[PR_ATTACH_METHOD] ?? false) === ATTACH_EMBEDDED_MSG) {
				continue;
			}

			if (!empty($attachmentRow[PR_ATTACHMENT_HIDDEN])) {
				continue;
			}

			$filename = $this->getAttachmentFileName($attachmentRow);
			if (!$this->isPdfFileName($filename)) {
				continue;
			}

			$attachment = mapi_message_openattach($message, $attachmentRow[PR_ATTACH_NUM]);
			if (!$attachment || $attachmentState->isInlineAttachment($attachment) || $attachmentState->isContactPhoto($attachment)) {
				continue;
			}

			$dataString = $this->getAttachmentData($attachment);
			if ($dataString === false) {
				continue;
			}

			if ($zip->addFromString($this->handleDuplicateFileNames($filename), $dataString)) {
				++$pdfCount;
			}
		}

		return $pdfCount;
	}

	/**
	 * Gets a displayable attachment file name from available MAPI properties.
	 *
	 * @param array $attachmentRow attachment table row
	 *
	 * @return string attachment file name
	 */
	private function getAttachmentFileName($attachmentRow) {
		return $attachmentRow[PR_ATTACH_LONG_FILENAME] ??
			$attachmentRow[PR_ATTACH_FILENAME] ??
			$attachmentRow[PR_DISPLAY_NAME] ??
			'';
	}

	/**
	 * Checks for a PDF extension case-insensitively.
	 *
	 * @param string $filename attachment file name
	 *
	 * @return bool true when file name ends in .pdf
	 */
	private function isPdfFileName($filename) {
		return strcasecmp(pathinfo((string) $filename, PATHINFO_EXTENSION), 'pdf') === 0;
	}

	/**
	 * Reads attachment binary data.
	 *
	 * @param MAPIAttach $attachment attachment to read
	 *
	 * @return string|false attachment data or false when unavailable
	 */
	private function getAttachmentData($attachment) {
		try {
			$stream = mapi_openproperty($attachment, PR_ATTACH_DATA_BIN, IID_IStream, 0, 0);
			$stat = mapi_stream_stat($stream);
		}
		catch (MAPIException $e) {
			$e->setHandled();

			return false;
		}

		$dataString = '';
		for ($i = 0; $i < ($stat['cb'] ?? 0); $i += BLOCK_SIZE) {
			$dataString .= mapi_stream_read($stream, BLOCK_SIZE);
		}

		return $dataString;
	}

	/**
	 * Sends the ZIP archive to the client.
	 *
	 * @param string $zipPath path to generated ZIP file
	 */
	public function sendZipResponse($zipPath) {
		header('Pragma: public');
		header('Expires: 0');
		header('Cache-Control: must-revalidate, post-check=0, pre-check=0');
		header('Content-Disposition: attachment; filename="' . addslashes(browserDependingHTTPHeaderEncode($this->zipFileName)) . '"');
		header('Content-Transfer-Encoding: binary');
		header('Content-Type: application/zip');
		header('Content-Length: ' . filesize($zipPath));

		readfile($zipPath);
		unlink($zipPath);
	}
}

$downloadUnreadPdfAttachments = new DownloadUnreadPdfAttachments();

try {
	$downloadUnreadPdfAttachments->init($_GET);
	$downloadUnreadPdfAttachments->download();
}
catch (Exception $e) {
	$downloadUnreadPdfAttachments->handleSaveMessageException($e);
}
