package dev.sieluna.auth.core;

import static org.junit.jupiter.api.Assertions.*;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

final class AuthCoreTest {
    @TempDir Path directory;
    private static char[] password() { return "correct-horse-42!".toCharArray(); }
    private static PasswordHasher.Hash hash() { return new PasswordHasher(600_000).hash(password()); }

    @Test void saltedHashesRejectWrongPasswordsAndUnsafeParameters() {
        var hasher = new PasswordHasher(600_000);
        var first = hasher.hash(password());
        var second = hasher.hash(password());
        assertNotEquals(first.salt(), second.salt());
        assertNotEquals(first.value(), second.value());
        assertTrue(hasher.verify(password(), first));
        assertFalse(hasher.verify("wrong-password".toCharArray(), first));
        assertFalse(PasswordHasher.validPassword("space password".toCharArray(), 10));
        assertThrows(IllegalArgumentException.class, () -> new PasswordHasher.Hash(first.salt(), first.value(), 1));
    }

    @Test void credentialsSurviveReopenAndNeverPersistPlaintext() throws Exception {
        char[] secret = password();
        try (var store = new AccountStore(directory); var service = new AuthService(store, 600_000, 10)) {
            assertEquals(AuthService.Result.SUCCESS, service.register("TestPlayer", secret).get(10, TimeUnit.SECONDS));
            assertArrayEquals(new char[secret.length], secret);
            assertEquals(AuthService.Result.WRONG_NAME_CASE, service.login("testplayer", password()).get(10, TimeUnit.SECONDS));
            assertEquals(AuthService.Result.WRONG_PASSWORD, service.login("TestPlayer", "wrong-password".toCharArray()).get(10, TimeUnit.SECONDS));
            assertEquals(AuthService.Result.SUCCESS, service.changePassword("TestPlayer", password(), "new-password-87".toCharArray()).get(10, TimeUnit.SECONDS));
        }
        try (var store = new AccountStore(directory); var service = new AuthService(store, 600_000, 10)) {
            assertEquals(AuthService.Result.WRONG_PASSWORD, service.login("TestPlayer", password()).get(10, TimeUnit.SECONDS));
            assertEquals(AuthService.Result.SUCCESS, service.login("TestPlayer", "new-password-87".toCharArray()).get(10, TimeUnit.SECONDS));
        }
        byte[] bytes = Files.readAllBytes(directory.resolve("accounts.db"));
        String content = new String(bytes, java.nio.charset.StandardCharsets.ISO_8859_1);
        assertFalse(content.contains("correct-horse-42!"));
        assertFalse(content.contains("new-password-87"));
    }

    @Test void corruptDatabaseAndConcurrentServerFailClosed() throws Exception {
        try (var store = new AccountStore(directory)) {
            assertThrows(IOException.class, () -> new AccountStore(directory));
            assertTrue(store.create("PlayerOne", hash()));
        }
        Files.writeString(directory.resolve("accounts.db"), "corrupt database");
        assertThrows(IOException.class, () -> new AccountStore(directory));
        assertThrows(IOException.class, () -> new AccountStore(directory));
        assertEquals("corrupt database", Files.readString(directory.resolve("accounts.db")));
    }

    @Test void resetAndDisconnectedRequestsCannotOverwriteNewAccounts() throws Exception {
        var hash = hash();
        try (var store = new AccountStore(directory)) {
            assertTrue(store.create("PlayerOne", hash));
            var old = store.find("PlayerOne").orElseThrow();
            assertFalse(store.create("playerone", hash));
            assertTrue(store.remove("PlayerOne"));
            assertTrue(store.create("PlayerOne", hash));
            assertFalse(store.replace(old, hash, () -> true));
            assertFalse(store.create("PlayerTwo", hash, () -> false));
            assertTrue(store.find("PlayerTwo").isEmpty());
        }
    }

    @Test void boundedQueueRejectsFloodAndWipesCancelledSecrets() throws Exception {
        try (var store = new AccountStore(directory); var service = new AuthService(store, 600_000, 10)) {
            var entered = new CountDownLatch(2);
            var release = new CountDownLatch(1);
            var valid = new AtomicBoolean(true);
            java.util.function.BooleanSupplier blocked = () -> {
                entered.countDown();
                try { release.await(5, TimeUnit.SECONDS); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return false; }
                return valid.get();
            };
            var first = service.register("PlayerOne", password(), blocked);
            var second = service.register("PlayerTwo", password(), blocked);
            try {
                assertTrue(entered.await(3, TimeUnit.SECONDS));
                var queued = new ArrayList<java.util.concurrent.CompletableFuture<AuthService.Result>>();
                var secrets = new ArrayList<char[]>();
                for (int i = 0; i < 16; i++) {
                    char[] secret = password(); secrets.add(secret);
                    queued.add(service.register("Queued" + i, secret));
                }
                char[] rejected = password();
                assertEquals(AuthService.Result.BUSY, service.register("Overflow", rejected).get(1, TimeUnit.SECONDS));
                assertArrayEquals(new char[rejected.length], rejected);
                valid.set(false); service.close();
                for (var result : queued) assertEquals(AuthService.Result.CANCELLED, result.get(1, TimeUnit.SECONDS));
                for (char[] secret : secrets) assertArrayEquals(new char[secret.length], secret);
            } finally { valid.set(false); release.countDown(); }
            assertEquals(AuthService.Result.CANCELLED, first.get(3, TimeUnit.SECONDS));
            assertEquals(AuthService.Result.CANCELLED, second.get(3, TimeUnit.SECONDS));
            assertTrue(store.find("PlayerOne").isEmpty());
        }
    }

    @Test void commandGateAndReconnectLimitsRejectBypassForms() {
        for (String command : new String[]{"op TestPlayer", "execute run login a", "loginx a", "minecraft:login a", " login a", "Login a", "login\ta"}) {
            assertFalse(CommandPolicy.isAuthentication(command), command);
        }
        assertTrue(CommandPolicy.isAuthentication("login password"));
        var limiter = new AttemptLimiter(60, 2);
        assertTrue(limiter.acquire("player", 1));
        assertTrue(limiter.acquire("player", 2));
        assertFalse(limiter.acquire("player", 3));
        assertTrue(limiter.acquire("player", 61));
    }
}
