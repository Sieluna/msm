package dev.sieluna.auth;

import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import dev.sieluna.auth.core.AccountStore;
import dev.sieluna.auth.core.AttemptLimiter;
import dev.sieluna.auth.core.AuthService;
import dev.sieluna.auth.core.CommandPolicy;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.Arrays;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.Connection;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.common.ServerboundClientInformationPacket;
import net.minecraft.network.protocol.common.ServerboundKeepAlivePacket;
import net.minecraft.network.protocol.common.ServerboundPongPacket;
import net.minecraft.network.protocol.common.ServerboundResourcePackPacket;
import net.minecraft.network.protocol.game.ServerboundAcceptTeleportationPacket;
import net.minecraft.network.protocol.game.ServerboundChatCommandPacket;
import net.minecraft.network.protocol.game.ServerboundChatCommandSignedPacket;
import net.minecraft.network.protocol.game.ServerboundChatAckPacket;
import net.minecraft.network.protocol.game.ServerboundChatSessionUpdatePacket;
import net.minecraft.network.protocol.game.ServerboundChunkBatchReceivedPacket;
import net.minecraft.network.protocol.game.ServerboundPlayerLoadedPacket;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import net.minecraft.server.permissions.Permissions;
import net.minecraft.world.phys.Vec3;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class AuthMod implements AutoCloseable {
    private static final Logger LOGGER = LoggerFactory.getLogger("auth");
    private static volatile AuthMod instance;
    private final MinecraftServer server;
    private final boolean enabled;
    private final AuthConfig config;
    private final AccountStore store;
    private final AuthService service;
    private final Map<ServerGamePacketListenerImpl, Session> sessions = new ConcurrentHashMap<>();
    private final Map<String, Connection> reservations = new ConcurrentHashMap<>();
    private final java.util.Set<String> resetting = ConcurrentHashMap.newKeySet();
    private final AttemptLimiter names = new AttemptLimiter(TimeUnit.MINUTES.toNanos(1), 10);
    private final AttemptLimiter addresses = new AttemptLimiter(TimeUnit.MINUTES.toNanos(1), 30);
    private long lastTick;
    private volatile boolean closed;

    private static final class Session {
        final ServerPlayer player;
        final String name;
        final Connection connection;
        final long deadline;
        volatile boolean authenticated;
        boolean busy;
        int failures;
        double x, y, z;
        float yaw, pitch;
        volatile boolean joined;
        Session(ServerPlayer player, Connection connection, int timeout) {
            this.player = player;
            this.name = player.getGameProfile().name();
            this.connection = connection;
            this.deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeout);
        }
    }

    private AuthMod(MinecraftServer server) throws IOException {
        this.server = server;
        enabled = server.isDedicatedServer() && !server.usesAuthentication();
        if (enabled) {
            var directory = server.getServerDirectory().resolve("config/auth");
            config = AuthConfig.load(directory);
            store = new AccountStore(directory);
            service = new AuthService(store, 600_000, config.minimumPasswordLength(), failure -> LOGGER.error("Authentication storage operation failed", failure));
        } else { config = null; store = null; service = null; }
    }

    public static synchronized void start(MinecraftServer server) {
        if (instance != null) throw new IllegalStateException("Auth is already running");
        try { instance = new AuthMod(server); }
        catch (IOException failure) { throw new IllegalStateException("Auth cannot load its data; startup aborted", failure); }
        LOGGER.info("Auth 0.1.0: {}", instance.enabled ? "offline authentication enabled; encrypted login required" : "password authentication inactive (online or integrated server)");
    }

    public static AuthMod get() { return instance; }
    public static boolean active() { var auth = instance; return auth != null && auth.enabled && !auth.closed; }
    public static void stop() {
        AuthMod auth = instance;
        if (auth != null) auth.close();
        instance = null;
    }

    public String admit(Connection connection, String name) {
        try { AccountStore.key(name); }
        catch (IllegalArgumentException invalid) { return "Use a player name with 3-16 ASCII letters, digits or underscores."; }
        String key = AccountStore.key(name);
        if (resetting.contains(key)) return "This account is being reset. Reconnect shortly.";
        Connection previous = reservations.putIfAbsent(key, connection);
        if (previous != null && previous != connection) {
            if (!previous.isConnected() && reservations.replace(key, previous, connection)) return null;
            return "This player name is already connected.";
        }
        return null;
    }

    public void attach(ServerGamePacketListenerImpl listener, ServerPlayer player, Connection connection) {
        if (!enabled) return;
        sessions.put(listener, new Session(player, connection, config.loginTimeoutSeconds()));
    }

    public void joined(ServerPlayer player) {
        if (!enabled) return;
        Session session = sessions.get(player.connection);
        if (session == null) { player.connection.disconnect(text("Authentication state is unavailable. Reconnect.")); return; }
        session.x = player.getX(); session.y = player.getY(); session.z = player.getZ();
        session.yaw = player.getYRot(); session.pitch = player.getXRot(); session.joined = true;
        prompt(session);
    }

    public void disconnected(ServerPlayer player) {
        Session removed = sessions.remove(player.connection);
        if (removed != null) reservations.remove(AccountStore.key(removed.name), removed.connection);
    }

    public boolean pending(ServerPlayer player) {
        if (!enabled) return false;
        Session session = sessions.get(player.connection);
        return session == null || !session.authenticated;
    }

    public boolean allow(ServerGamePacketListenerImpl listener, Packet<?> packet) {
        if (!enabled) return true;
        Session session = sessions.get(listener);
        if (session != null && session.authenticated) return true;
        if (packet instanceof ServerboundChatCommandPacket command) return CommandPolicy.isAuthentication(command.command());
        if (packet instanceof ServerboundChatCommandSignedPacket command) return CommandPolicy.isAuthentication(command.command());
        // Since 26.3 a teleport acknowledgement also carries a player-supplied position.
        if (packet instanceof ServerboundAcceptTeleportationPacket acknowledgement) {
            return session != null && session.joined
                    && Math.abs(acknowledgement.x() - session.x) < 0.001
                    && Math.abs(acknowledgement.y() - session.y) < 0.001
                    && Math.abs(acknowledgement.z() - session.z) < 0.001
                    && Float.isFinite(acknowledgement.yRot()) && Float.isFinite(acknowledgement.xRot());
        }
        return packet instanceof ServerboundKeepAlivePacket || packet instanceof ServerboundPongPacket
                || packet instanceof ServerboundClientInformationPacket || packet instanceof ServerboundResourcePackPacket
                || packet instanceof ServerboundPlayerLoadedPacket
                || packet instanceof ServerboundChatSessionUpdatePacket || packet instanceof ServerboundChatAckPacket
                || packet instanceof ServerboundChunkBatchReceivedPacket;
    }

    public void tick() {
        if (!enabled || closed) return;
        long now = System.nanoTime();
        if (now - lastTick < TimeUnit.SECONDS.toNanos(1)) return;
        lastTick = now;
        reservations.entrySet().removeIf(entry -> !entry.getValue().isConnected());
        for (Session session : sessions.values()) {
            if (session.authenticated || !session.joined) continue;
            if (now >= session.deadline) { session.player.connection.disconnect(text("Authentication timed out.")); continue; }
            session.player.setDeltaMovement(Vec3.ZERO);
            session.player.connection.teleport(session.x, session.y, session.z, session.yaw, session.pitch);
        }
    }

    private void prompt(Session session) {
        session.player.sendSystemMessage(text("Log in: /login <password>. New player: /register <password> <repeat>. Minimum "
                + config.minimumPasswordLength() + " characters; no spaces."));
    }

    public static void registerCommands(CommandDispatcher<CommandSourceStack> dispatcher) {
        for (String name : new String[]{"register", "login", "changepassword"}) {
            dispatcher.register(Commands.literal(name)
                    .requires(source -> source.getPlayer() != null)
                    .executes(context -> invoke(context.getSource(), name, ""))
                    .then(Commands.argument("credentials", StringArgumentType.greedyString())
                            .executes(context -> invoke(context.getSource(), name, StringArgumentType.getString(context, "credentials")))));
        }
        dispatcher.register(Commands.literal("auth")
                .requires(source -> source.getEntity() == null && source.permissions().hasPermission(Permissions.COMMANDS_OWNER))
                .then(Commands.literal("reset").then(Commands.argument("name", StringArgumentType.word())
                        .executes(context -> reset(context.getSource(), StringArgumentType.getString(context, "name"))))));
    }

    private static int invoke(CommandSourceStack source, String command, String arguments) {
        AuthMod auth = instance;
        if (auth == null || !auth.enabled || auth.closed) {
            source.sendFailure(text("Password authentication is inactive.")); return 0;
        }
        return auth.command(source.getPlayer(), command, arguments);
    }

    private int command(ServerPlayer player, String command, String arguments) {
        Session session = sessions.get(player.connection);
        if (session == null || !session.joined || session.busy) return 0;
        if (!session.authenticated && System.nanoTime() >= session.deadline) {
            player.connection.disconnect(text("Authentication timed out.")); return 0;
        }
        if (session.authenticated && !command.equals("changepassword")) {
            player.sendSystemMessage(text("You are already authenticated.")); return 0;
        }
        if (!session.authenticated && command.equals("changepassword")) { prompt(session); return 0; }
        String[] parts = arguments.split(" ", -1);
        int expected = command.equals("login") ? 1 : command.equals("register") ? 2 : 3;
        if (arguments.length() > 400 || parts.length != expected || Arrays.stream(parts).anyMatch(part -> part.isEmpty() || part.length() > 128)) {
            player.sendSystemMessage(text("Usage: /" + command + (expected == 1 ? " <password>" : expected == 2 ? " <password> <repeat>" : " <old> <new> <repeat>")));
            return 0;
        }
        if (expected > 1 && !parts[expected - 1].equals(parts[expected - 2])) {
            player.sendSystemMessage(text("Passwords do not match.")); return 0;
        }
        long now = System.nanoTime();
        String address = session.connection.getRemoteAddress() instanceof InetSocketAddress socket
                ? socket.getAddress().getHostAddress() : "local";
        if (!names.acquire(AccountStore.key(session.name), now) || !addresses.acquire(address, now)) {
            player.connection.disconnect(text("Too many authentication requests. Wait one minute.")); return 0;
        }
        session.busy = true;
        ServerGamePacketListenerImpl listener = player.connection;
        java.util.function.BooleanSupplier valid = () -> !closed && sessions.get(listener) == session && session.connection.isConnected();
        CompletableFuture<AuthService.Result> result = switch (command) {
            case "register" -> service.register(session.name, parts[0].toCharArray(), valid);
            case "login" -> service.login(session.name, parts[0].toCharArray());
            default -> service.changePassword(session.name, parts[0].toCharArray(), parts[1].toCharArray(), valid);
        };
        result.thenAccept(outcome -> server.execute(() -> complete(listener, session, command, outcome)));
        return 1;
    }

    private void complete(ServerGamePacketListenerImpl listener, Session session, String command, AuthService.Result result) {
        if (closed || sessions.get(listener) != session || !session.connection.isConnected()) return;
        session.busy = false;
        if (!session.authenticated && System.nanoTime() >= session.deadline) {
            listener.disconnect(text("Authentication timed out.")); return;
        }
        if (result == AuthService.Result.SUCCESS) {
            session.authenticated = true;
            session.player.sendSystemMessage(text(command.equals("changepassword") ? "Password changed." : "Authentication successful."));
            return;
        }
        String message = switch (result) {
            case WRONG_PASSWORD -> "Incorrect password.";
            case WRONG_NAME_CASE -> "Use the exact capitalization of your registered player name.";
            case NOT_REGISTERED -> "This name is not registered. Use /register <password> <repeat>.";
            case ALREADY_REGISTERED -> "This name is registered. Use /login <password>.";
            case INVALID_PASSWORD -> "Password must contain " + config.minimumPasswordLength() + "-128 characters without whitespace or control characters.";
            case BUSY, CANCELLED -> "Authentication is busy. Try again shortly.";
            case ACCOUNT_CHANGED -> "Account changed. Reconnect.";
            default -> "Authentication storage failed. Contact the server operator.";
        };
        if (result == AuthService.Result.STORAGE_ERROR) LOGGER.error("Authentication storage operation failed for {}", session.name);
        session.player.sendSystemMessage(text(message));
        if (result == AuthService.Result.WRONG_PASSWORD && ++session.failures >= config.maximumAttempts()) {
            listener.disconnect(text("Too many incorrect passwords."));
        }
    }

    private static int reset(CommandSourceStack source, String name) {
        AuthMod auth = instance;
        if (auth == null || !auth.enabled || auth.closed) { source.sendFailure(text("Password authentication is inactive.")); return 0; }
        try {
            String key = AccountStore.key(name);
            if (!auth.resetting.add(key)) { source.sendFailure(text("An account reset is already pending.")); return 0; }
            // Invalidate callbacks before changing the account, including pending registrations.
            for (var entry : auth.sessions.entrySet()) {
                if (entry.getValue().name.equalsIgnoreCase(name)) {
                    auth.sessions.remove(entry.getKey(), entry.getValue());
                    entry.getKey().disconnect(text("Your account was reset by the server operator."));
                }
            }
            auth.service.reset(name).thenAccept(result -> auth.server.execute(() -> {
                auth.resetting.remove(key);
                if (result == AuthService.Result.SUCCESS || result == AuthService.Result.NOT_REGISTERED) {
                    source.sendSuccess(() -> text(result == AuthService.Result.SUCCESS ? "Account reset: " + name : "No registered account: " + name), false);
                } else { source.sendFailure(text("Account reset failed. Try again and check the server log.")); }
            }));
            return 1;
        } catch (IllegalArgumentException failure) {
            source.sendFailure(text("Account reset failed. Check the player name and server log."));
            LOGGER.error("Could not reset authentication account", failure); return 0;
        }
    }

    private static Component text(String message) { return Component.literal("[Auth] " + message); }

    @Override public void close() {
        closed = true;
        sessions.clear(); reservations.clear();
        if (service != null) service.close();
        if (store != null) try { store.close(); } catch (IOException failure) { LOGGER.error("Could not close authentication storage", failure); }
    }
}
