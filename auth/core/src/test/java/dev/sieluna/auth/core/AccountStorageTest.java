package dev.sieluna.auth.core;

import static org.junit.jupiter.api.Assertions.*;
import java.io.ByteArrayInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

final class AccountStorageTest {
    @TempDir Path directory;

    private static PasswordHasher.Hash hash(int marker) {
        byte[] salt = new byte[16], hash = new byte[32];
        Arrays.fill(salt, (byte) marker); Arrays.fill(hash, (byte) (marker + 1));
        return new PasswordHasher.Hash(Base64.getEncoder().encodeToString(salt), Base64.getEncoder().encodeToString(hash), 600_000);
    }

    @Test void lookupDoesNotReadUnrelatedAccountsAndDetectsTargetCorruption() throws Exception {
        try (var store = new AccountStore(directory)) {
            var password = hash(1);
            for (int i = 0; i < 1000; i++) assertTrue(store.create("Player" + i, password));
        }
        Path file = directory.resolve("accounts.db");
        assertEquals(AccountStore.FILE_SIZE, Files.size(file));
        byte[] seed = readSeed(file);
        String untouched = "Player0";
        for (int i = 0; bucket(untouched, seed) == bucket("Player999", seed); i++) untouched = "Player" + i;
        try (var output = FileChannel.open(file, StandardOpenOption.READ, StandardOpenOption.WRITE)) {
            long position = AccountStore.RECORDS_START + 999L * AccountStore.SLOT_SIZE + 40;
            ByteBuffer one = ByteBuffer.allocate(1); output.read(one, position); one.flip();
            one.put(0, (byte) (one.get(0) ^ 1)); output.write(one, position); output.force(true);
        }
        // Opening and reading a different bucket succeed: neither path scans the account table.
        try (var store = new AccountStore(directory)) {
            assertEquals(untouched, store.find(untouched.toUpperCase(Locale.ROOT)).orElseThrow().name());
            assertThrows(IOException.class, () -> store.find("Player999"));
            assertThrows(IOException.class, () -> store.create("Player999", hash(2)));
        }
    }

    @Test void collisionChainsSurviveHeadAndMiddleDeletionAndReuseFreedSlots() throws Exception {
        List<String> names;
        try (var ignored = new AccountStore(directory)) { }
        byte[] seed = readSeed(directory.resolve("accounts.db"));
        names = collisionNames(seed, 4);
        try (var store = new AccountStore(directory)) {
            var password = hash(1);
            for (int i = 0; i < 3; i++) assertTrue(store.create(names.get(i), password));
            assertTrue(store.remove(names.get(1))); // Middle of a real collision chain.
            assertTrue(store.find(names.get(0)).isPresent());
            assertTrue(store.find(names.get(2)).isPresent());
            assertTrue(store.create(names.get(3), password)); // Reuses the on-disk free list.
            assertTrue(store.remove(names.get(3))); // Head of the same chain.
            assertTrue(store.find(names.get(0)).isPresent());
            assertTrue(store.find(names.get(2)).isPresent());
            assertTrue(store.find(names.get(1)).isEmpty());
        }
        try (var store = new AccountStore(directory)) {
            assertTrue(store.find(names.get(0)).isPresent());
            assertTrue(store.find(names.get(2)).isPresent());
        }
    }

    @ParameterizedTest @EnumSource(AccountStore.CommitStage.class)
    void durableJournalRecoversEveryInterruptedCommitPhase(AccountStore.CommitStage failAt) throws Exception {
        try (var store = new AccountStore(directory)) { assertTrue(store.create("PlayerOne", hash(1))); }
        try (var store = new AccountStore(directory, stage -> { if (stage == failAt) throw new IOException("Injected crash"); })) {
            var old = store.find("PlayerOne").orElseThrow();
            assertThrows(IOException.class, () -> store.replace(old, hash(2), () -> true));
            assertThrows(IOException.class, () -> store.find("PlayerOne"));
        }
        assertTrue(Files.exists(directory.resolve("accounts.journal")));
        try (var store = new AccountStore(directory)) { assertEquals(hash(2), store.find("PlayerOne").orElseThrow().password()); }
        assertFalse(Files.exists(directory.resolve("accounts.journal")));
        try (var store = new AccountStore(directory)) { assertEquals(hash(2), store.find("PlayerOne").orElseThrow().password()); }
    }

    @Test void journalRepairsPartialRecordWritesButRejectsCorruptAndStaleReplay() throws Exception {
        try (var store = new AccountStore(directory)) { assertTrue(store.create("PlayerOne", hash(1))); }
        try (var store = new AccountStore(directory, stage -> { if (stage == AccountStore.CommitStage.JOURNAL_DURABLE) throw new IOException("Injected crash"); })) {
            var old = store.find("PlayerOne").orElseThrow();
            assertThrows(IOException.class, () -> store.replace(old, hash(2), () -> true));
        }
        Path journal = directory.resolve("accounts.journal"), file = directory.resolve("accounts.db");
        byte[] transaction = Files.readAllBytes(journal);
        byte[] corrupt = transaction.clone(); corrupt[12] ^= 1; Files.write(journal, corrupt);
        assertThrows(IOException.class, () -> new AccountStore(directory));
        Files.write(journal, transaction);
        // Simulate a real interrupted write: only half the new record reached the data file.
        try (var input = new DataInputStream(new ByteArrayInputStream(transaction));
             var output = FileChannel.open(file, StandardOpenOption.WRITE)) {
            input.skipNBytes(16);
            for (int i = 0; i < 2; i++) {
                long offset = input.readLong(); int length = input.readInt();
                input.skipNBytes(length); byte[] after = input.readNBytes(length);
                if (i == 1) output.write(ByteBuffer.wrap(after, 0, length / 2), offset);
            }
            output.force(true);
        }
        try (var store = new AccountStore(directory)) {
            assertEquals(hash(2), store.find("PlayerOne").orElseThrow().password());
            assertTrue(store.remove("PlayerOne"));
            assertTrue(store.create("PlayerOne", hash(3)));
        }
        Files.write(journal, transaction); // An older valid transaction must never resurrect old credentials.
        assertThrows(IOException.class, () -> new AccountStore(directory));
        Files.delete(journal);
        try (var store = new AccountStore(directory)) { assertEquals(hash(3), store.find("PlayerOne").orElseThrow().password()); }
    }

    @Test void concurrentCaseAliasesCreateOnlyOneAccount() throws Exception {
        try (var store = new AccountStore(directory); var workers = Executors.newFixedThreadPool(4)) {
            var calls = new ArrayList<java.util.concurrent.Future<Boolean>>();
            for (int i = 0; i < 24; i++) {
                String name = i % 2 == 0 ? "PlayerOne" : "playerone";
                calls.add(workers.submit(() -> store.create(name, hash(1))));
            }
            int created = 0;
            for (var call : calls) if (call.get(5, TimeUnit.SECONDS)) created++;
            assertEquals(1, created);
            assertEquals(hash(1), store.find("PLAYERONE").orElseThrow().password());
        }
    }

    @Test void changedLiveHeaderRejectsMutationBeforeJournalOrDataWrite() throws Exception {
        Path file = directory.resolve("accounts.db");
        try (var store = new AccountStore(directory)) {
            assertTrue(store.create("PlayerOne", hash(1)));
            byte[] original = Files.readAllBytes(file);
            for (boolean validChecksum : new boolean[]{false, true}) {
                byte[] changed = original.clone();
                changed[43] ^= 2; // Change the live transaction generation.
                if (validChecksum) {
                    byte[] checksum = MessageDigest.getInstance("SHA-256").digest(Arrays.copyOf(changed, AccountStore.HEADER_SIZE - 32));
                    System.arraycopy(checksum, 0, changed, AccountStore.HEADER_SIZE - 32, checksum.length);
                }
                try (var output = FileChannel.open(file, StandardOpenOption.WRITE)) {
                    output.write(ByteBuffer.wrap(changed, 0, AccountStore.HEADER_SIZE), 0);
                    output.force(true);
                }
                assertThrows(IOException.class, () -> store.create("PlayerTwo", hash(2)));
                assertArrayEquals(changed, Files.readAllBytes(file));
                assertFalse(Files.exists(directory.resolve("accounts.journal")));
                assertFalse(Files.exists(directory.resolve("accounts.journal.tmp")));
            }
            try (var output = FileChannel.open(file, StandardOpenOption.WRITE)) {
                output.write(ByteBuffer.wrap(original, 0, AccountStore.HEADER_SIZE), 0);
                output.force(true);
            }
            assertTrue(store.find("PlayerTwo").isEmpty());
            assertEquals(hash(1), store.find("PlayerOne").orElseThrow().password());
        }
    }

    private static byte[] readSeed(Path file) throws IOException {
        byte[] seed = new byte[32];
        try (var input = FileChannel.open(file, StandardOpenOption.READ)) {
            ByteBuffer buffer = ByteBuffer.wrap(seed);
            while (buffer.hasRemaining()) assertTrue(input.read(buffer, 60 + buffer.position()) > 0);
        }
        return seed;
    }

    private static int bucket(String name, byte[] seed) throws Exception {
        byte[] text = name.toLowerCase(Locale.ROOT).getBytes(StandardCharsets.US_ASCII);
        byte[] data = Arrays.copyOf(seed, seed.length + text.length);
        System.arraycopy(text, 0, data, seed.length, text.length);
        return ByteBuffer.wrap(MessageDigest.getInstance("SHA-256").digest(data)).getInt() & (AccountStore.BUCKETS - 1);
    }

    private static List<String> collisionNames(byte[] seed, int count) throws Exception {
        var names = new ArrayList<String>(); String first = "Collision0";
        int target = bucket(first, seed); names.add(first);
        for (int i = 1; names.size() < count && i < 1_000_000; i++) {
            String candidate = "Collision" + i;
            if (bucket(candidate, seed) == target) names.add(candidate);
        }
        assertEquals(count, names.size());
        return names;
    }
}
