package dev.sieluna.auth.core;

import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

public final class PasswordHasher {
    public static final int MIN_ITERATIONS = 600_000;
    public static final int MAX_ITERATIONS = 2_000_000;
    private final SecureRandom random = new SecureRandom();
    private final int iterations;

    public record Hash(String salt, String value, int iterations) {
        public Hash {
            if (iterations < MIN_ITERATIONS || iterations > MAX_ITERATIONS
                    || Base64.getDecoder().decode(salt).length != 16
                    || Base64.getDecoder().decode(value).length != 32) {
                throw new IllegalArgumentException("Invalid password hash parameters");
            }
        }
    }

    public PasswordHasher(int iterations) {
        if (iterations < MIN_ITERATIONS || iterations > MAX_ITERATIONS) {
            throw new IllegalArgumentException("PBKDF2 iterations out of range");
        }
        this.iterations = iterations;
    }

    public static boolean validPassword(char[] password, int minimum) {
        if (password.length < minimum || password.length > 128) return false;
        for (char character : password) {
            if (Character.isISOControl(character) || Character.isWhitespace(character)) return false;
        }
        return true;
    }

    public Hash hash(char[] password) {
        byte[] salt = new byte[16];
        random.nextBytes(salt);
        byte[] value = derive(password, salt, iterations);
        try {
            return new Hash(Base64.getEncoder().encodeToString(salt),
                    Base64.getEncoder().encodeToString(value), iterations);
        } finally { Arrays.fill(value, (byte) 0); }
    }

    public boolean verify(char[] password, Hash stored) {
        if (password.length > 128) return false;
        byte[] actual = derive(password, Base64.getDecoder().decode(stored.salt()), stored.iterations());
        byte[] expected = Base64.getDecoder().decode(stored.value());
        try { return MessageDigest.isEqual(expected, actual); }
        finally { Arrays.fill(actual, (byte) 0); Arrays.fill(expected, (byte) 0); }
    }

    private static byte[] derive(char[] password, byte[] salt, int iterations) {
        PBEKeySpec spec = new PBEKeySpec(password, salt, iterations, 256);
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).getEncoded();
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("JVM PBKDF2-HMAC-SHA256 is unavailable", exception);
        } finally { spec.clearPassword(); }
    }
}
