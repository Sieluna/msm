package dev.sieluna.auth.core;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;

public final class AtomicFiles {
    private AtomicFiles() {}

    public static void privateDirectory(Path directory) throws IOException {
        if (Files.isSymbolicLink(directory)) throw new IOException("Authentication directory is a symlink");
        Files.createDirectories(directory);
        try { Files.setPosixFilePermissions(directory, PosixFilePermissions.fromString("rwx------")); }
        catch (UnsupportedOperationException ignored) { /* Windows inherits the operator's directory ACL. */ }
    }

    public static void write(Path destination, byte[] data) throws IOException {
        if (Files.isSymbolicLink(destination)) throw new IOException("Authentication file is a symlink");
        Path temporary = Files.createTempFile(destination.getParent(), ".auth-", ".tmp");
        try {
            try { Files.setPosixFilePermissions(temporary, PosixFilePermissions.fromString("rw-------")); }
            catch (UnsupportedOperationException ignored) { }
            try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.WRITE)) {
                ByteBuffer buffer = ByteBuffer.wrap(data);
                while (buffer.hasRemaining()) channel.write(buffer);
                channel.force(true);
            }
            Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            try (FileChannel directory = FileChannel.open(destination.getParent(), StandardOpenOption.READ)) {
                directory.force(true);
            } catch (IOException | UnsupportedOperationException ignored) { /* Directory fsync is not exposed on Windows. */ }
        } finally { Files.deleteIfExists(temporary); }
    }
}
