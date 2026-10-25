package dev.sieluna.auth;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import dev.sieluna.auth.core.AtomicFiles;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;

public record AuthConfig(int minimumPasswordLength, int loginTimeoutSeconds, int maximumAttempts) {
    public AuthConfig {
        if (minimumPasswordLength < 8 || minimumPasswordLength > 64
                || loginTimeoutSeconds < 15 || loginTimeoutSeconds > 300
                || maximumAttempts < 1 || maximumAttempts > 10) {
            throw new IllegalArgumentException("Invalid auth configuration limits");
        }
    }

    public static AuthConfig load(Path directory) throws IOException {
        AtomicFiles.privateDirectory(directory);
        Path file = directory.resolve("config.json");
        Gson json = new GsonBuilder().setPrettyPrinting().create();
        if (!Files.exists(file, LinkOption.NOFOLLOW_LINKS)) {
            AuthConfig defaults = new AuthConfig(10, 60, 5);
            AtomicFiles.write(file, (json.toJson(defaults) + "\n").getBytes(StandardCharsets.UTF_8));
            return defaults;
        }
        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) || Files.size(file) > 4096) {
            throw new IOException("Unsafe auth configuration");
        }
        try {
            AuthConfig config = json.fromJson(Files.readString(file, StandardCharsets.UTF_8), AuthConfig.class);
            if (config == null) throw new IllegalArgumentException("Empty configuration");
            return config;
        } catch (RuntimeException invalid) { throw new IOException("Invalid auth configuration", invalid); }
    }
}
