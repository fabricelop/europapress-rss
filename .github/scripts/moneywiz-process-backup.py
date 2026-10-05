from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import tempfile
import urllib.request
import zipfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

CORE_DATA_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
MAX_ZIP_BYTES = 180 * 1024 * 1024
MAX_DB_BYTES = 220 * 1024 * 1024
EXPECTED_DB = "MoneyWiz_iCloud.sqlite"


def core_date(value):
    if value is None:
        return None
    return (CORE_DATA_EPOCH + timedelta(seconds=float(value))).date().isoformat()


def tx_kind(ent: int) -> str:
    return {38: "INCOME", 46: "TRANSFER_IN", 47: "TRANSFER_OUT", 48: "EXPENSE"}.get(ent, "OTHER")


def money(value) -> float:
    return round(float(value or 0.0), 2)


def safe_name(value: str) -> str:
    return Path(str(value or "")).name[:220]


def download(url: str, path: Path) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "money-control-moneywiz-processor/1"})
    digest = hashlib.sha256()
    total = 0
    with urllib.request.urlopen(req, timeout=120) as response, path.open("wb") as target:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_ZIP_BYTES:
                raise RuntimeError("backup_too_large")
            digest.update(chunk)
            target.write(chunk)
    return digest.hexdigest()


def materialize_backup(url: str, work: Path, label: str) -> tuple[Path, str]:
    zip_path = work / f"{label}.zip"
    digest = download(url, zip_path)
    out = work / label
    out.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path) as archive:
        members = {Path(info.filename).name: info for info in archive.infolist() if not info.is_dir()}
        if EXPECTED_DB not in members:
            raise RuntimeError("missing_moneywiz_sqlite")

        for name in [EXPECTED_DB, EXPECTED_DB + "-wal", EXPECTED_DB + "-shm"]:
            info = members.get(name)
            if not info:
                if name == EXPECTED_DB:
                    raise RuntimeError("missing_moneywiz_sqlite")
                continue
            if info.file_size > MAX_DB_BYTES:
                raise RuntimeError("sqlite_member_too_large")
            target = out / name
            with archive.open(info) as source, target.open("wb") as dest:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    dest.write(chunk)

    return out / EXPECTED_DB, digest


def open_ro(db_path: Path) -> sqlite3.Connection:
    con = sqlite3.connect(f"file:{db_path.as_posix()}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA query_only=ON")
    if con.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise RuntimeError("sqlite_integrity_failed")
    return con


def fingerprint(item: dict) -> str:
    keys = [
        "accountGid",
        "kind",
        "amount",
        "date",
        "description",
        "payee",
        "status",
        "counterpartGid",
        "categories",
    ]
    raw = json.dumps(
        {key: item.get(key) for key in keys},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def read_backup(db_path: Path) -> dict:
    con = open_ro(db_path)
    try:
        groups = {
            row["ZGROUPID3"]: row["ZNAME4"]
            for row in con.execute("SELECT ZGROUPID3,ZNAME4 FROM ZSYNCOBJECT WHERE Z_ENT=23")
        }
        payees = {
            row["Z_PK"]: row["ZNAME5"]
            for row in con.execute("SELECT Z_PK,ZNAME5 FROM ZSYNCOBJECT WHERE Z_ENT=29")
        }

        accounts_by_pk = {}
        accounts = []
        for row in con.execute(
            """
            SELECT Z_PK,ZGID,ZNAME,ZCURRENCYNAME,ZINCLUDEINNETWORTH,ZARCHIVED,ZGROUPID
            FROM ZSYNCOBJECT
            WHERE Z_ENT IN (11,12,13,14,15,16,17) AND ZGID IS NOT NULL
            """
        ):
            item = {
                "sourcePk": int(row["Z_PK"]),
                "gid": row["ZGID"],
                "name": row["ZNAME"] or f"Cuenta {row['Z_PK']}",
                "currency": row["ZCURRENCYNAME"] or "EUR",
                "archived": bool(row["ZARCHIVED"] or 0),
                "includeNetWorth": int(
                    row["ZINCLUDEINNETWORTH"] if row["ZINCLUDEINNETWORTH"] is not None else 1
                ),
                "sourceGroup": groups.get(row["ZGROUPID"]),
            }
            accounts_by_pk[item["sourcePk"]] = item
            accounts.append(item)

        category_rows = con.execute(
            """
            SELECT Z_PK,ZNAME2,ZPARENTCATEGORY
            FROM ZSYNCOBJECT
            WHERE Z_ENT=20 AND ZGID IS NOT NULL AND ZNAME2 IS NOT NULL
            """
        ).fetchall()
        categories = {
            int(row["Z_PK"]): {"name": row["ZNAME2"], "parentPk": row["ZPARENTCATEGORY"]}
            for row in category_rows
        }
        categories_by_tx = defaultdict(list)
        for row in con.execute(
            """
            SELECT ZTRANSACTION,ZCATEGORY,ZAMOUNT
            FROM ZCATEGORYASSIGMENT
            WHERE ZTRANSACTION IS NOT NULL AND ZCATEGORY IS NOT NULL
            """
        ):
            category = categories.get(int(row["ZCATEGORY"]))
            if not category:
                continue
            parent = (
                categories.get(int(category["parentPk"]))
                if category.get("parentPk") is not None
                else None
            )
            categories_by_tx[int(row["ZTRANSACTION"])].append(
                {
                    "name": category["name"],
                    "parent": parent["name"] if parent else None,
                    "amount": money(row["ZAMOUNT"]),
                }
            )

        raw_rows = con.execute(
            """
            SELECT Z_PK,Z_ENT,ZGID,ZACCOUNT2,ZPAYEE2,ZAMOUNT1,ZDATE1,ZDESC2,ZSTATUS1,
                   ZSENDERTRANSACTION,ZRECIPIENTTRANSACTION
            FROM ZSYNCOBJECT
            WHERE Z_ENT IN (38,46,47,48)
              AND ZACCOUNT2 IS NOT NULL
              AND ZGID IS NOT NULL
              AND COALESCE(ZVOIDCHEQUE,0)=0
            """
        ).fetchall()
        source_to_gid = {int(row["Z_PK"]): row["ZGID"] for row in raw_rows}

        transactions = {}
        last_by_account = {}
        max_date = None
        for row in raw_rows:
            account = accounts_by_pk.get(int(row["ZACCOUNT2"]))
            if not account:
                continue
            tx_date = core_date(row["ZDATE1"])
            if not tx_date:
                continue
            if max_date is None or tx_date > max_date:
                max_date = tx_date
            if tx_date > last_by_account.get(account["gid"], ""):
                last_by_account[account["gid"]] = tx_date

            counterpart_pk = (
                row["ZSENDERTRANSACTION"]
                if int(row["Z_ENT"]) == 46
                else (row["ZRECIPIENTTRANSACTION"] if int(row["Z_ENT"]) == 47 else None)
            )
            item = {
                "sourcePk": int(row["Z_PK"]),
                "gid": row["ZGID"],
                "accountGid": account["gid"],
                "accountName": account["name"],
                "kind": tx_kind(int(row["Z_ENT"])),
                "amount": money(row["ZAMOUNT1"]),
                "date": tx_date,
                "description": row["ZDESC2"] or "",
                "payee": payees.get(row["ZPAYEE2"]),
                "status": row["ZSTATUS1"],
                "counterpartGid": (
                    source_to_gid.get(int(counterpart_pk)) if counterpart_pk is not None else None
                ),
                "categories": categories_by_tx.get(int(row["Z_PK"]), []),
            }
            item["fingerprint"] = fingerprint(item)
            transactions[item["gid"]] = item

        for account in accounts:
            account["lastMovementDate"] = last_by_account.get(account["gid"])

        return {
            "accounts": accounts,
            "transactions": transactions,
            "snapshotDate": max_date,
        }
    finally:
        con.close()


def build_patch(
    current: dict,
    previous: dict,
    current_name: str,
    previous_name: str,
    current_sha: str,
    previous_sha: str,
) -> dict:
    current_txs = current["transactions"]
    previous_txs = previous["transactions"]

    upserts = []
    new_count = 0
    modified_count = 0

    for gid, item in current_txs.items():
        old = previous_txs.get(gid)
        if old is None:
            source_state = "NEW"
            new_count += 1
        elif old.get("fingerprint") != item.get("fingerprint"):
            source_state = "MODIFIED"
            modified_count += 1
        else:
            continue

        out = {key: value for key, value in item.items() if key != "fingerprint"}
        out.update(
            {
                "id": 1_000_000_000 + int(item["sourcePk"]),
                "sourceState": source_state,
                "reviewState": "UNREVIEWED",
            }
        )
        upserts.append(out)

    deleted = sorted(gid for gid in previous_txs if gid not in current_txs)

    return {
        "format": "moneywiz-auto-patch",
        "version": 1,
        "snapshotDate": current.get("snapshotDate"),
        "sourceImportedAt": datetime.now(timezone.utc).isoformat(),
        "backupFilename": safe_name(current_name),
        "previousBackupFilename": safe_name(previous_name),
        "backupSha256": current_sha,
        "previousBackupSha256": previous_sha,
        "accountsUpsert": current["accounts"],
        "transactionsUpsert": sorted(upserts, key=lambda item: (item["date"], item["sourcePk"])),
        "transactionDeletes": deleted,
        "stats": {
            "new": new_count,
            "modified": modified_count,
            "deleted": len(deleted),
            "unchanged": max(0, len(current_txs) - new_count - modified_count),
            "currentTransactions": len(current_txs),
            "previousTransactions": len(previous_txs),
            "accounts": len(current["accounts"]),
        },
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--current-url", required=True)
    parser.add_argument("--previous-url", required=True)
    parser.add_argument("--current-filename", required=True)
    parser.add_argument("--previous-filename", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        current_db, current_sha = materialize_backup(args.current_url, work, "current")
        previous_db, previous_sha = materialize_backup(args.previous_url, work, "previous")
        current = read_backup(current_db)
        previous = read_backup(previous_db)
        patch = build_patch(
            current,
            previous,
            args.current_filename,
            args.previous_filename,
            current_sha,
            previous_sha,
        )
        args.output.write_text(
            json.dumps(patch, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        print(
            json.dumps(
                {
                    "ok": True,
                    "snapshotDate": patch["snapshotDate"],
                    "stats": patch["stats"],
                    "outputBytes": args.output.stat().st_size,
                }
            )
        )


if __name__ == "__main__":
    main()
