package dev.sieluna.auth.core;

import java.util.LinkedHashMap;
import java.util.Map;

public final class AttemptLimiter {
    private record Bucket(long expires, int count) {}
    private final LinkedHashMap<String, Bucket> buckets = new LinkedHashMap<>();
    private final long windowNanos;
    private final int maximum;
    public AttemptLimiter(long windowNanos, int maximum) {
        this.windowNanos = windowNanos; this.maximum = maximum;
    }
    public synchronized boolean acquire(String key, long now) {
        Bucket old = buckets.get(key);
        if (old == null || old.expires() <= now) old = new Bucket(now + windowNanos, 0);
        if (old.count() >= maximum) return false;
        if (!buckets.containsKey(key) && buckets.size() >= 4096) {
            buckets.remove(buckets.keySet().iterator().next());
        }
        buckets.put(key, new Bucket(old.expires(), old.count() + 1));
        return true;
    }
}
