# Account storage

Auth uses a purpose-built, versioned disk hash table. It has no database driver,
native library, SQL interpreter, background database service, or account-wide
in-memory cache.

## Files and limits

Files are kept in `config/auth/`, independently of the world:

- `accounts.db`: the account table and disk index, exactly 1,573,120 bytes.
- `accounts.lock`: an operating-system file lock held for the server lifetime.
- `accounts.journal`: one committed transaction awaiting completion or cleanup.

`accounts.init` and `accounts.journal.tmp` are temporary files used for atomic
publication. An unpublished journal never changes the account table. It is
discarded on the next successful open. An interrupted initial creation is
recreated before any account database is published.

The format has 8,192 buckets and 8,192 account slots. At most 8,192 accounts can
exist at once. Deleting an account returns its slot to an on-disk free list;
password changes and account churn do not grow the file. Capacity is fixed in
format version 1; there is no automatic resize or online compaction.

Only a 256-byte header remains in the `AccountStore` instance. A lookup reads
one 64-byte bucket, then the 128-byte records in that bucket's collision chain.
It does not scan other buckets, read the entire file, or load other accounts
into a collection. Temporary transaction data is bounded to a few KiB. The
filesystem may independently cache file pages.

## File format

All integers use big-endian byte order. The final 32 bytes of each header,
bucket, and account slot contain SHA-256 of the preceding bytes of that region.
Even unused buckets and free slots have checksums, so a zeroed region is not
mistaken for a missing account.

| Region | Offset | Size | Contents before its checksum |
| --- | --- | --- | --- |
| Header | 0 | 256 bytes | `AUTHDB01` magic, format version 1, bucket and slot dimensions, account count, free-list head, transaction generation, database UUID, random 32-byte index seed, zero padding |
| Buckets | 256 | 8,192 × 64 bytes | First account-slot index, or `-1`, followed by zero padding |
| Account slots | 524,544 | 8,192 × 128 bytes | State, next-slot index, name length, 16-byte name field, 16-byte salt, 32-byte password hash, PBKDF2 iteration count, 16-byte revision UUID |

Names contain 3–16 ASCII letters, digits, or underscores. The index key is the
name lowercased with `Locale.ROOT`; the original capitalization is stored in the
record. The bucket is the low 13 bits of the first big-endian integer in
`SHA-256(indexSeed || normalizedName)`.

An active slot's next index links accounts in the same bucket. A free slot's
next index links free slots, and its account fields are zero. Indexes are
range-checked, active records must belong to their indexed bucket, and chain
traversal is bounded by total capacity. Revision UUIDs make conditional password
updates fail after an account was reset and recreated, even with the same name
and password.

## Commit and recovery

One writer holds the Java synchronization lock during each mutation. A process
lock prevents two server instances from opening the same database concurrently.
All account operations run on Auth's bounded background executor.

1. Build the before and after images of the changed header, bucket and/or slots.
   A transaction changes at most three regions. The live header must have a
   valid checksum and exactly match the metadata held by the open store before
   a journal can be published; unexpected changes are rejected without repair.
2. Write the journal temporary file, force it to disk, atomically rename it to
   `accounts.journal`, and sync the directory where the platform supports it.
   Publication of this complete journal is the commit point.
3. Write and force the changed bucket/slots; then write and force the new header.
4. Delete the journal and sync the directory. Only then acknowledge success.

The journal has its own format marker and SHA-256 checksum. It contains the old
and new metadata, including the database UUID and consecutive transaction
generations. On open, recovery validates every journal region before writing
anything. Current bytes must match the old or new image, or be a torn mixture
of those two images with an invalid region checksum. Valid unrelated data, an
older journal, a different database UUID, malformed addresses, bad checksums or
unexpected file lengths cause an error. Recovery always reapplies the new
images, so replay after a crash is idempotent and cannot roll back a later
password reset.

If an I/O failure occurs during commit, the open store rejects further
operations until the server is restarted and recovery succeeds. A process can
fail after committing but before acknowledging the request; after restart,
the account operation may therefore already have completed.

Startup reads the header and any outstanding small journal. It does not scan
all account records. Record integrity is checked when a lookup or mutation
touches that record. A corrupt record is never silently deleted, reset, or
treated as an unregistered name. The operation fails instead. Checksums detect
accidental damage; they do not authenticate files against an attacker who can
write to the server's private directory.

## Operation and backups

Use a local filesystem supporting atomic file renames and normal file locking.
On POSIX filesystems Auth requests directory mode `0700` and file mode `0600`.
Windows uses inherited directory ACLs. File forcing is used on both platforms;
directory syncing is additionally used on POSIX filesystems.

Back up or restore the entire `config/auth/` directory only while Minecraft is
stopped. In particular, keep an outstanding `accounts.journal` with its matching
`accounts.db`; never restore one independently of the other. MSM's stopped-server
snapshots include this directory. A normal clean shutdown leaves only the
database, lock file and configuration file.

This is a single-process account store, not a general-purpose database or a
shared network backend. It has no live backup API, replication, query language,
automatic repair, capacity migration, or secure-erasure guarantee. Keep backups
for recovery from disk failure or file corruption.
