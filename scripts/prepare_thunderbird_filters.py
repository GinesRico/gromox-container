#!/usr/bin/env python3
import csv
import json
import re
import sys
from collections import Counter
from pathlib import Path


ACCOUNT_MAP = {
    "Mail/pop.serviciodecorreo.es": "grico@arvera.es",
    "Mail/pop.serviciodecorreo-1.es": "info@arvera.es",
    "Mail/mail.gira.net": "admin@arvera.es",
    "Mail/Local Folders": "local-folders",
}

SPECIAL_FOLDERS = {
    "Inbox",
    "INBOX",
    "Trash",
    "Drafts",
    "Sent",
    "Templates",
    "Junk",
}


def norm_public_path(target):
    target = (target or "").strip().replace("\\", "/")
    if not target:
        return ""
    if target.startswith("mailbox://"):
        target = target.rsplit("/", 1)[-1]
    if target.startswith("INBOX/"):
        target = target[6:]
    parts = [part.strip() for part in target.split("/") if part.strip()]
    parts = [re.sub(r'[\\/:*"<>|?\x00-\x1f]', "_", part) for part in parts]
    return "/IPM_SUBTREE/" + "/".join(parts) if parts else ""


def is_migrable(row):
    if row.get("enabled") != "yes":
        return False, "disabled"
    if row.get("action") != "Move to folder":
        return False, "non_move_action"
    target = row.get("target_folder", "").strip()
    if not target:
        return False, "missing_target"
    if target in SPECIAL_FOLDERS:
        return False, "special_target"
    fields = set(filter(None, row.get("fields", "").split(";")))
    operators = set(filter(None, row.get("operators", "").split(";")))
    if not fields <= {"from", "to", "cc", "subject"}:
        return False, "unsupported_field"
    if not operators <= {"is", "contains", "ends with", "begins with"}:
        return False, "unsupported_operator"
    return True, "ok"


def main():
    base = Path(__file__).resolve().parents[1]
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else base / "migration-analysis" / "thunderbird_filters.csv"
    outdir = Path(sys.argv[2]) if len(sys.argv) > 2 else base / "migration-analysis"
    outdir.mkdir(parents=True, exist_ok=True)

    rows = list(csv.DictReader(source.open(newline="", encoding="utf-8-sig")))
    migrable = []
    review = []
    target_counter = Counter()
    action_counter = Counter()
    account_counter = Counter()

    for index, row in enumerate(rows, start=1):
        row = dict(row)
        row["rule_id"] = str(index)
        row["source_mailbox"] = ACCOUNT_MAP.get(row.get("account_path", ""), row.get("account_path", ""))
        row["public_folder"] = norm_public_path(row.get("target_folder", ""))
        ok, reason = is_migrable(row)
        row["migration_status"] = "migrable" if ok else "review"
        row["review_reason"] = reason
        action_counter[row.get("action", "")] += 1
        account_counter[row.get("account_path", "")] += 1
        if row["public_folder"]:
            target_counter[row["public_folder"]] += 1
        if ok:
            migrable.append(row)
        else:
            review.append(row)

    fields = [
        "rule_id",
        "source_mailbox",
        "account_path",
        "name",
        "action",
        "target_folder",
        "public_folder",
        "condition",
        "conditions_count",
        "fields",
        "operators",
        "review_reason",
    ]

    def write_csv(path, data):
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(data)

    write_csv(outdir / "thunderbird_filters_migrable.csv", migrable)
    write_csv(outdir / "thunderbird_filters_review.csv", review)

    with (outdir / "thunderbird_filter_targets.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["count", "public_folder"])
        for folder, count in target_counter.most_common():
            writer.writerow([count, folder])

    worker_rules = [
        {
            "id": row["rule_id"],
            "source_mailbox": row["source_mailbox"],
            "condition": row["condition"],
            "action": "move",
            "public_folder": row["public_folder"],
            "name": row["name"],
        }
        for row in migrable
    ]
    (outdir / "thunderbird_filter_worker_rules.json").write_text(
        json.dumps(worker_rules, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    summary = {
        "total_rules": len(rows),
        "migrable_rules": len(migrable),
        "review_rules": len(review),
        "actions": dict(action_counter.most_common()),
        "accounts": dict(account_counter.most_common()),
        "top_targets": dict(target_counter.most_common(30)),
    }
    (outdir / "thunderbird_filters_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
