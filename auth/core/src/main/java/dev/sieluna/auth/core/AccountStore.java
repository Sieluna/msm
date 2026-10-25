package dev.sieluna.auth.core;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.UUID;
import java.util.function.BooleanSupplier;

/** A fixed-size disk hash index. Only the header and the current collision chain are read. */
public final class AccountStore implements AutoCloseable {
    public record Account(String name, PasswordHasher.Hash password, String revision) {}
    static final int CAPACITY = 8192;
    static final int BUCKETS = 8192;
    static final int HEADER_SIZE = 256;
    static final int BUCKET_SIZE = 64;
    static final int SLOT_SIZE = 128;
    static final long RECORDS_START = HEADER_SIZE + (long) BUCKETS * BUCKET_SIZE;
    static final long FILE_SIZE = RECORDS_START + (long) CAPACITY * SLOT_SIZE;
    private static final long MAGIC = 0x4155544844423031L; // AUTHDB01
    private static final long JOURNAL_MAGIC = 0x4155544854583031L; // AUTHTX01
    private static final int FREE = 0, ACTIVE = 1;

    enum CommitStage { JOURNAL_DURABLE, DATA_DURABLE, HEADER_DURABLE }
    @FunctionalInterface interface CommitHook { void reached(CommitStage stage) throws IOException; }
    private record Header(int count, int freeHead, long generation, UUID id, byte[] seed) {}
    private record Entry(int status, int next, Account account) {}
    private record Located(int bucket, int previous, int index, Entry entry) {}
    private record Change(long offset, byte[] before, byte[] after) {}

    private final Path directory, journal;
    private final FileChannel lockChannel, database;
    private final FileLock lock;
    private final CommitHook hook;
    private Header header;
    private boolean closed, poisoned;

    public AccountStore(Path directory) throws IOException { this(directory, stage -> { }); }

    AccountStore(Path directory, CommitHook hook) throws IOException {
        AtomicFiles.privateDirectory(directory);
        this.directory = directory;
        this.journal = directory.resolve("accounts.journal");
        this.hook = hook;
        Path lockFile = directory.resolve("accounts.lock");
        safeFile(lockFile, false);
        lockChannel = FileChannel.open(lockFile, StandardOpenOption.CREATE, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
        FileLock acquired;
        try {
            acquired = lockChannel.tryLock();
            if (acquired == null) throw new IOException("Authentication database is already in use");
        } catch (IOException | RuntimeException failure) {
            lockChannel.close(); throw new IOException("Cannot lock authentication database", failure);
        }
        lock = acquired;
        FileChannel opened = null;
        try {
            Path file = directory.resolve("accounts.db");
            safeFile(file, false); safeFile(journal, false);
            if (!Files.exists(file, LinkOption.NOFOLLOW_LINKS)) {
                if (Files.exists(journal, LinkOption.NOFOLLOW_LINKS)) throw new IOException("Account database is missing but its journal exists");
                initialize(file);
            }
            opened = FileChannel.open(file, StandardOpenOption.READ, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
            if (opened.size() != FILE_SIZE) throw new IOException("Invalid authentication database length");
            if (Files.exists(journal, LinkOption.NOFOLLOW_LINKS)) recover(opened);
            header = decodeHeader(read(opened, 0, HEADER_SIZE));
            database = opened;
            privateFile(file); privateFile(lockFile);
            Path pending = directory.resolve("accounts.journal.tmp");
            safeFile(pending, false);
            if (Files.deleteIfExists(pending)) forceDirectory(); // Unpublished transactions never touched the database.
        } catch (IOException | RuntimeException failure) {
            if (opened != null) try { opened.close(); } catch (IOException ignored) { }
            lock.release(); lockChannel.close();
            throw new IOException("Cannot open authentication database; refusing to reset accounts", failure);
        }
    }

    public static String key(String name) {
        if (name == null || !name.matches("[A-Za-z0-9_]{3,16}")) {
            throw new IllegalArgumentException("Player names must contain 3-16 ASCII letters, digits or underscores");
        }
        return name.toLowerCase(Locale.ROOT);
    }

    public synchronized Optional<Account> find(String name) throws IOException {
        checkOpen();
        Located location = locate(key(name));
        return location.index() < 0 ? Optional.empty() : Optional.of(location.entry().account());
    }

    public boolean create(String name, PasswordHasher.Hash password) throws IOException { return create(name, password, () -> true); }

    public synchronized boolean create(String name, PasswordHasher.Hash password, BooleanSupplier valid) throws IOException {
        checkOpen();
        Located location = locate(key(name));
        if (location.index() >= 0 || !valid.getAsBoolean()) return false;
        if (header.count() == CAPACITY) throw new IOException("Authentication database capacity reached (8192 accounts)");
        int index = header.freeHead();
        Entry free = decodeEntry(read(database, slotOffset(index), SLOT_SIZE));
        if (free.status() != FREE) throw new IOException("Corrupt authentication free list");
        byte[] bucket = read(database, bucketOffset(location.bucket()), BUCKET_SIZE);
        int head = decodeBucket(bucket);
        Account account = new Account(name, password, UUID.randomUUID().toString());
        Header updated = updatedHeader(header.count() + 1, free.next());
        commit(List.of(
                headerChange(updated),
                new Change(bucketOffset(location.bucket()), bucket, encodeBucket(index)),
                changeSlot(index, new Entry(ACTIVE, head, account))), updated);
        return true;
    }

    public synchronized boolean replace(Account expected, PasswordHasher.Hash password, BooleanSupplier valid) throws IOException {
        checkOpen();
        Located location = locate(key(expected.name()));
        if (location.index() < 0 || !expected.equals(location.entry().account()) || !valid.getAsBoolean()) return false;
        Account account = new Account(expected.name(), password, UUID.randomUUID().toString());
        Header updated = updatedHeader(header.count(), header.freeHead());
        commit(List.of(headerChange(updated), changeSlot(location.index(), new Entry(ACTIVE, location.entry().next(), account))), updated);
        return true;
    }

    public synchronized boolean remove(String name) throws IOException {
        checkOpen();
        Located location = locate(key(name));
        if (location.index() < 0) return false;
        Header updated = updatedHeader(header.count() - 1, location.index());
        List<Change> changes = new ArrayList<>(3);
        changes.add(headerChange(updated));
        if (location.previous() < 0) {
            long offset = bucketOffset(location.bucket());
            changes.add(new Change(offset, read(database, offset, BUCKET_SIZE), encodeBucket(location.entry().next())));
        } else {
            Entry previous = decodeEntry(read(database, slotOffset(location.previous()), SLOT_SIZE));
            changes.add(changeSlot(location.previous(), new Entry(ACTIVE, location.entry().next(), previous.account())));
        }
        changes.add(changeSlot(location.index(), new Entry(FREE, header.freeHead(), null)));
        commit(changes, updated);
        return true;
    }

    private Located locate(String key) throws IOException {
        int bucket = bucket(key, header.seed());
        int index = decodeBucket(read(database, bucketOffset(bucket), BUCKET_SIZE)), previous = -1;
        for (int visited = 0; index >= 0; visited++) {
            if (visited >= CAPACITY) throw new IOException("Cyclic authentication index");
            Entry entry = decodeEntry(read(database, slotOffset(index), SLOT_SIZE));
            if (entry.status() != ACTIVE || bucket(key(entry.account().name()), header.seed()) != bucket) {
                throw new IOException("Corrupt authentication bucket chain");
            }
            if (key(entry.account().name()).equals(key)) return new Located(bucket, previous, index, entry);
            previous = index; index = entry.next();
        }
        return new Located(bucket, previous, -1, null);
    }

    private Header updatedHeader(int count, int freeHead) throws IOException {
        if (header.generation() == Long.MAX_VALUE) throw new IOException("Authentication transaction counter exhausted");
        return new Header(count, freeHead, header.generation() + 1, header.id(), header.seed());
    }

    private Change headerChange(Header after) throws IOException {
        byte[] before = read(database, 0, HEADER_SIZE);
        decodeHeader(before);
        if (!Arrays.equals(before, encodeHeader(header))) {
            throw new IOException("Authentication metadata changed while the database was open");
        }
        return new Change(0, before, encodeHeader(after));
    }

    private Change changeSlot(int index, Entry after) throws IOException {
        long offset = slotOffset(index);
        return new Change(offset, read(database, offset, SLOT_SIZE), encodeEntry(after));
    }

    private void commit(List<Change> changes, Header updated) throws IOException {
        try {
            for (Change change : changes) {
                validateRegion(change.offset(), change.before());
                validateRegion(change.offset(), change.after());
            }
            publishJournal(encodeJournal(changes));
            hook.reached(CommitStage.JOURNAL_DURABLE);
            for (int i = 1; i < changes.size(); i++) write(database, changes.get(i).offset(), changes.get(i).after());
            database.force(true);
            hook.reached(CommitStage.DATA_DURABLE);
            write(database, 0, changes.getFirst().after()); database.force(true);
            hook.reached(CommitStage.HEADER_DURABLE);
            Files.delete(journal); forceDirectory();
            header = updated;
        } catch (IOException | RuntimeException failure) {
            poisoned = true;
            throw new IOException("Authentication write failed; restart required for journal recovery", failure);
        }
    }

    private void publishJournal(byte[] content) throws IOException {
        Path temporary = directory.resolve("accounts.journal.tmp");
        safeFile(temporary, false); safeFile(journal, false);
        if (Files.exists(journal, LinkOption.NOFOLLOW_LINKS)) throw new IOException("An unexpected authentication journal requires recovery");
        try (FileChannel output = FileChannel.open(temporary, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
            privateFile(temporary); write(output, 0, content); output.force(true);
        }
        Files.move(temporary, journal, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        forceDirectory();
    }

    private void recover(FileChannel channel) throws IOException {
        long size = Files.size(journal);
        if (size < 64 || size > 4096) throw new IOException("Invalid authentication journal size");
        byte[] bytes;
        try (FileChannel input = FileChannel.open(journal, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            bytes = read(input, 0, (int) size);
        }
        List<Change> changes = decodeJournal(bytes);
        Change metadata = changes.getFirst();
        Header before = decodeHeader(metadata.before()), after = decodeHeader(metadata.after());
        if (!before.id().equals(after.id()) || !Arrays.equals(before.seed(), after.seed())
                || before.generation() == Long.MAX_VALUE || after.generation() != before.generation() + 1
                || Math.abs(after.count() - before.count()) > 1) throw new IOException("Invalid authentication journal transaction");
        for (Change change : changes) {
            byte[] actual = read(channel, change.offset(), change.before().length);
            if (Arrays.equals(actual, change.before()) || Arrays.equals(actual, change.after())) continue;
            boolean valid;
            try { validateRegion(change.offset(), actual); valid = true; }
            catch (IOException corrupt) { valid = false; }
            // A valid but different generation is stale, never a transaction to roll back.
            if (valid || !isTornWrite(actual, change.before(), change.after())) {
                throw new IOException("Stale authentication journal or unrelated database corruption");
            }
        }
        for (int i = 1; i < changes.size(); i++) write(channel, changes.get(i).offset(), changes.get(i).after());
        channel.force(true);
        write(channel, 0, metadata.after()); channel.force(true);
        Files.delete(journal); forceDirectory();
    }

    private static boolean isTornWrite(byte[] actual, byte[] before, byte[] after) {
        for (int i = 0; i < actual.length; i++) if (actual[i] != before[i] && actual[i] != after[i]) return false;
        return true;
    }

    private static byte[] encodeJournal(List<Change> changes) throws IOException {
        var bytes = new ByteArrayOutputStream(1536);
        try (var output = new DataOutputStream(bytes)) {
            output.writeLong(JOURNAL_MAGIC); output.writeInt(1); output.writeInt(changes.size());
            for (Change change : changes) {
                output.writeLong(change.offset()); output.writeInt(change.before().length);
                output.write(change.before()); output.write(change.after());
            }
        }
        byte[] body = bytes.toByteArray(), result = Arrays.copyOf(body, body.length + 32);
        System.arraycopy(digest(body), 0, result, body.length, 32);
        return result;
    }

    private static List<Change> decodeJournal(byte[] content) throws IOException {
        int bodyLength = content.length - 32;
        if (!MessageDigest.isEqual(digest(Arrays.copyOf(content, bodyLength)), Arrays.copyOfRange(content, bodyLength, content.length))) {
            throw new IOException("Authentication journal checksum mismatch");
        }
        try (var input = new DataInputStream(new ByteArrayInputStream(content, 0, bodyLength))) {
            if (input.readLong() != JOURNAL_MAGIC || input.readInt() != 1) throw new IOException("Unsupported authentication journal format");
            int count = input.readInt();
            if (count < 2 || count > 3) throw new IOException("Invalid authentication transaction length");
            List<Change> changes = new ArrayList<>(count);
            for (int i = 0; i < count; i++) {
                long offset = input.readLong(); int length = input.readInt();
                if ((i == 0 && (offset != 0 || length != HEADER_SIZE))
                        || (i > 0 && offset == 0) || regionLength(offset) != length) throw new IOException("Invalid authentication journal address");
                for (Change previous : changes) if (previous.offset() == offset) throw new IOException("Duplicate journal address");
                byte[] before = input.readNBytes(length), after = input.readNBytes(length);
                if (before.length != length || after.length != length) throw new IOException("Truncated authentication journal");
                validateRegion(offset, before); validateRegion(offset, after);
                changes.add(new Change(offset, before, after));
            }
            if (input.available() != 0) throw new IOException("Trailing authentication journal data");
            return changes;
        }
    }

    private void initialize(Path file) throws IOException {
        Path temporary = directory.resolve("accounts.init");
        safeFile(temporary, false);
        byte[] seed = new byte[32]; new SecureRandom().nextBytes(seed);
        Header initial = new Header(0, 0, 0, UUID.randomUUID(), seed);
        try (FileChannel output = FileChannel.open(temporary, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
            privateFile(temporary);
            write(output, 0, encodeHeader(initial));
            byte[] empty = encodeBucket(-1);
            for (int i = 0; i < BUCKETS; i++) write(output, bucketOffset(i), empty);
            for (int i = 0; i < CAPACITY; i++) write(output, slotOffset(i), encodeEntry(new Entry(FREE, i + 1 == CAPACITY ? -1 : i + 1, null)));
            output.force(true);
        }
        Files.move(temporary, file, StandardCopyOption.ATOMIC_MOVE);
        forceDirectory();
    }

    private static byte[] encodeHeader(Header value) {
        ByteBuffer data = ByteBuffer.allocate(HEADER_SIZE);
        data.putLong(MAGIC).putInt(1).putInt(BUCKETS).putInt(CAPACITY).putInt(SLOT_SIZE).putInt(BUCKET_SIZE)
                .putInt(value.count()).putInt(value.freeHead()).putLong(value.generation())
                .putLong(value.id().getMostSignificantBits()).putLong(value.id().getLeastSignificantBits()).put(value.seed());
        return seal(data.array());
    }

    private static Header decodeHeader(byte[] bytes) throws IOException {
        verify(bytes);
        ByteBuffer data = ByteBuffer.wrap(bytes);
        if (data.getLong() != MAGIC || data.getInt() != 1 || data.getInt() != BUCKETS || data.getInt() != CAPACITY
                || data.getInt() != SLOT_SIZE || data.getInt() != BUCKET_SIZE) throw new IOException("Unsupported authentication database format");
        int count = data.getInt(), freeHead = data.getInt(); long generation = data.getLong();
        UUID id = new UUID(data.getLong(), data.getLong()); byte[] seed = new byte[32]; data.get(seed);
        if (count < 0 || count > CAPACITY || !validIndex(freeHead) || generation < 0
                || (count == CAPACITY) != (freeHead == -1)) throw new IOException("Invalid authentication database metadata");
        while (data.position() < HEADER_SIZE - 32) if (data.get() != 0) throw new IOException("Invalid authentication metadata padding");
        return new Header(count, freeHead, generation, id, seed);
    }

    private static byte[] encodeBucket(int index) { return seal(ByteBuffer.allocate(BUCKET_SIZE).putInt(index).array()); }

    private static int decodeBucket(byte[] bytes) throws IOException {
        verify(bytes);
        ByteBuffer data = ByteBuffer.wrap(bytes); int index = data.getInt();
        if (!validIndex(index)) throw new IOException("Invalid authentication bucket address");
        while (data.position() < BUCKET_SIZE - 32) if (data.get() != 0) throw new IOException("Invalid authentication bucket padding");
        return index;
    }

    private static byte[] encodeEntry(Entry value) {
        ByteBuffer data = ByteBuffer.allocate(SLOT_SIZE).putInt(value.status()).putInt(value.next());
        if (value.status() == ACTIVE) {
            byte[] name = value.account().name().getBytes(StandardCharsets.US_ASCII);
            data.putInt(name.length).put(name); data.position(28);
            data.put(Base64.getDecoder().decode(value.account().password().salt()));
            data.put(Base64.getDecoder().decode(value.account().password().value())).putInt(value.account().password().iterations());
            UUID revision = UUID.fromString(value.account().revision());
            data.putLong(revision.getMostSignificantBits()).putLong(revision.getLeastSignificantBits());
        }
        return seal(data.array());
    }

    private static Entry decodeEntry(byte[] bytes) throws IOException {
        verify(bytes);
        ByteBuffer data = ByteBuffer.wrap(bytes);
        int status = data.getInt(), next = data.getInt();
        if (!validIndex(next)) throw new IOException("Invalid authentication record address");
        if (status == FREE) {
            while (data.position() < SLOT_SIZE - 32) if (data.get() != 0) throw new IOException("Invalid free authentication record");
            return new Entry(FREE, next, null);
        }
        if (status != ACTIVE) throw new IOException("Invalid authentication record state");
        int length = data.getInt();
        if (length < 3 || length > 16) throw new IOException("Invalid authentication player name length");
        byte[] nameBytes = new byte[length]; data.get(nameBytes);
        while (data.position() < 28) if (data.get() != 0) throw new IOException("Invalid authentication player name padding");
        String name = new String(nameBytes, StandardCharsets.US_ASCII);
        byte[] salt = new byte[16], hash = new byte[32]; data.get(salt); data.get(hash); int iterations = data.getInt();
        UUID revision = new UUID(data.getLong(), data.getLong());
        try {
            key(name);
            PasswordHasher.Hash password = new PasswordHasher.Hash(Base64.getEncoder().encodeToString(salt), Base64.getEncoder().encodeToString(hash), iterations);
            return new Entry(ACTIVE, next, new Account(name, password, revision.toString()));
        } catch (IllegalArgumentException invalid) { throw new IOException("Invalid authentication record", invalid); }
    }

    private static int bucket(String name, byte[] seed) {
        byte[] key = name.getBytes(StandardCharsets.US_ASCII), value = Arrays.copyOf(seed, seed.length + key.length);
        System.arraycopy(key, 0, value, seed.length, key.length);
        return ByteBuffer.wrap(digest(value)).getInt() & (BUCKETS - 1);
    }

    private static long bucketOffset(int bucket) { return HEADER_SIZE + (long) bucket * BUCKET_SIZE; }
    private static long slotOffset(int index) { return RECORDS_START + (long) index * SLOT_SIZE; }
    private static boolean validIndex(int index) { return index >= -1 && index < CAPACITY; }

    private static int regionLength(long offset) throws IOException {
        if (offset == 0) return HEADER_SIZE;
        if (offset >= HEADER_SIZE && offset < RECORDS_START && (offset - HEADER_SIZE) % BUCKET_SIZE == 0) return BUCKET_SIZE;
        if (offset >= RECORDS_START && offset < FILE_SIZE && (offset - RECORDS_START) % SLOT_SIZE == 0) return SLOT_SIZE;
        throw new IOException("Invalid authentication database address");
    }

    private static void validateRegion(long offset, byte[] content) throws IOException {
        if (regionLength(offset) != content.length) throw new IOException("Invalid authentication region length");
        if (offset == 0) decodeHeader(content);
        else if (offset < RECORDS_START) decodeBucket(content);
        else decodeEntry(content);
    }

    private static byte[] seal(byte[] data) {
        System.arraycopy(digest(Arrays.copyOf(data, data.length - 32)), 0, data, data.length - 32, 32);
        return data;
    }

    private static void verify(byte[] data) throws IOException {
        if (!MessageDigest.isEqual(digest(Arrays.copyOf(data, data.length - 32)), Arrays.copyOfRange(data, data.length - 32, data.length))) {
            throw new IOException("Authentication database checksum mismatch");
        }
    }

    private static byte[] digest(byte[] data) {
        try { return MessageDigest.getInstance("SHA-256").digest(data); }
        catch (NoSuchAlgorithmException unavailable) { throw new IllegalStateException(unavailable); }
    }

    private static byte[] read(FileChannel input, long position, int length) throws IOException {
        ByteBuffer buffer = ByteBuffer.allocate(length);
        while (buffer.hasRemaining()) {
            int read = input.read(buffer, position + buffer.position());
            if (read < 0) throw new IOException("Truncated authentication database");
            if (read == 0) throw new IOException("Authentication read made no progress");
        }
        return buffer.array();
    }

    private static void write(FileChannel output, long position, byte[] content) throws IOException {
        ByteBuffer buffer = ByteBuffer.wrap(content);
        while (buffer.hasRemaining()) {
            if (output.write(buffer, position + buffer.position()) == 0) throw new IOException("Authentication write made no progress");
        }
    }

    private static void safeFile(Path file, boolean required) throws IOException {
        if (!Files.exists(file, LinkOption.NOFOLLOW_LINKS)) {
            if (required) throw new IOException("Missing authentication file");
            return;
        }
        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) throw new IOException("Authentication path is not a regular file");
        try { if (((Number) Files.getAttribute(file, "unix:nlink", LinkOption.NOFOLLOW_LINKS)).longValue() != 1) throw new IOException("Authentication file has multiple links"); }
        catch (UnsupportedOperationException ignored) { }
    }

    private static void privateFile(Path file) throws IOException {
        try { Files.setPosixFilePermissions(file, PosixFilePermissions.fromString("rw-------")); }
        catch (UnsupportedOperationException ignored) { }
    }

    private void forceDirectory() throws IOException {
        if (Files.getFileStore(directory).supportsFileAttributeView("posix")) {
            try (FileChannel channel = FileChannel.open(directory, StandardOpenOption.READ)) { channel.force(true); }
        }
    }

    private void checkOpen() throws IOException {
        if (closed) throw new IOException("Authentication database is closed");
        if (poisoned) throw new IOException("Authentication database requires journal recovery; restart the server");
    }

    @Override public synchronized void close() throws IOException {
        if (closed) return;
        closed = true;
        try { database.close(); }
        finally { try { lock.release(); } finally { lockChannel.close(); } }
    }
}
