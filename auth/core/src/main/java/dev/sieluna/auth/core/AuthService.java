package dev.sieluna.auth.core;

import java.io.IOException;
import java.util.Arrays;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;

public final class AuthService implements AutoCloseable {
    public enum Result { SUCCESS, WRONG_PASSWORD, WRONG_NAME_CASE, NOT_REGISTERED, ALREADY_REGISTERED, INVALID_PASSWORD, ACCOUNT_CHANGED, BUSY, STORAGE_ERROR, CANCELLED }
    @FunctionalInterface private interface Operation { Result get() throws IOException; }
    private final AccountStore store;
    private final PasswordHasher hasher;
    private final int minimumPasswordLength;
    private final ThreadPoolExecutor workers;
    private final java.util.function.Consumer<Exception> failures;

    public AuthService(AccountStore store, int iterations, int minimumPasswordLength) {
        this(store, iterations, minimumPasswordLength, ignored -> {});
    }

    public AuthService(AccountStore store, int iterations, int minimumPasswordLength, java.util.function.Consumer<Exception> failures) {
        this.store = store;
        this.failures = failures;
        this.hasher = new PasswordHasher(iterations);
        this.minimumPasswordLength = minimumPasswordLength;
        AtomicInteger ids = new AtomicInteger();
        workers = new ThreadPoolExecutor(2, 2, 0, TimeUnit.SECONDS, new ArrayBlockingQueue<>(16), task -> {
            Thread thread = new Thread(task, "auth-crypto-" + ids.incrementAndGet());
            thread.setDaemon(true);
            return thread;
        }, new ThreadPoolExecutor.AbortPolicy());
    }

    public CompletableFuture<Result> register(String name, char[] password) {
        return register(name, password, () -> true);
    }

    public CompletableFuture<Result> register(String name, char[] password, BooleanSupplier valid) {
        return submit(() -> {
            if (!valid.getAsBoolean()) return Result.CANCELLED;
            if (!PasswordHasher.validPassword(password, minimumPasswordLength)) return Result.INVALID_PASSWORD;
            if (store.find(name).isPresent()) return Result.ALREADY_REGISTERED;
            return store.create(name, hasher.hash(password), valid) ? Result.SUCCESS : Result.ACCOUNT_CHANGED;
        }, password);
    }

    public CompletableFuture<Result> login(String name, char[] password) {
        return submit(() -> {
            var account = store.find(name);
            if (account.isEmpty()) return Result.NOT_REGISTERED;
            AccountStore.Account snapshot = account.get();
            if (!snapshot.name().equals(name)) return Result.WRONG_NAME_CASE;
            if (!hasher.verify(password, snapshot.password())) return Result.WRONG_PASSWORD;
            return store.find(name).filter(snapshot::equals).isPresent() ? Result.SUCCESS : Result.ACCOUNT_CHANGED;
        }, password);
    }

    public CompletableFuture<Result> changePassword(String name, char[] oldPassword, char[] newPassword) {
        return changePassword(name, oldPassword, newPassword, () -> true);
    }

    public CompletableFuture<Result> changePassword(String name, char[] oldPassword, char[] newPassword, BooleanSupplier valid) {
        return submit(() -> {
            if (!valid.getAsBoolean()) return Result.CANCELLED;
            if (!PasswordHasher.validPassword(newPassword, minimumPasswordLength)) return Result.INVALID_PASSWORD;
            var account = store.find(name);
            if (account.isEmpty()) return Result.NOT_REGISTERED;
            if (!hasher.verify(oldPassword, account.get().password())) return Result.WRONG_PASSWORD;
            return store.replace(account.get(), hasher.hash(newPassword), valid) ? Result.SUCCESS : Result.ACCOUNT_CHANGED;
        }, oldPassword, newPassword);
    }

    public CompletableFuture<Result> reset(String name) {
        return submit(() -> store.remove(name) ? Result.SUCCESS : Result.NOT_REGISTERED);
    }

    private CompletableFuture<Result> submit(Operation operation, char[]... secrets) {
        var future = new CompletableFuture<Result>();
        Job job = new Job(operation, future, secrets);
        try { workers.execute(job); }
        catch (RejectedExecutionException failure) { job.finish(Result.BUSY); }
        return future;
    }

    private final class Job implements Runnable {
        final Operation operation;
        final CompletableFuture<Result> future;
        final char[][] secrets;
        Job(Operation operation, CompletableFuture<Result> future, char[][] secrets) {
            this.operation = operation; this.future = future; this.secrets = secrets;
        }
        void finish(Result result) {
            for (char[] secret : secrets) Arrays.fill(secret, '\0');
            future.complete(result);
        }
        @Override public void run() {
            Result result;
            try { result = operation.get(); }
            catch (IOException | RuntimeException failure) {
                result = Result.STORAGE_ERROR;
                try { failures.accept(failure); } catch (RuntimeException ignored) { }
            }
            finish(result);
        }
    }

    @Override public void close() {
        for (Runnable queued : workers.shutdownNow()) ((Job) queued).finish(Result.CANCELLED);
    }
}
