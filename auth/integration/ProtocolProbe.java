import java.io.*;
import java.net.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.spec.X509EncodedKeySpec;
import java.time.Duration;
import java.util.*;
import java.util.zip.*;
import javax.crypto.*;
import javax.crypto.spec.*;

/** End-to-end protocol tests for a disposable, localhost-only Minecraft 26.3 server. */
public final class ProtocolProbe {
    private static final String PLAYER = "AuthProbe", PERSIST = "AuthPersist";
    private static final String PASSWORD = "probe-first-537!", CHANGED = "probe-changed-891!", SAVED = "probe-persist-734!";
    private static final String OBJECTIVE = "auth_probe";
    private static final int PROTOCOL = 777;

    public static void main(String[] args) throws Exception {
        if (args.length < 4) throw new IllegalArgumentException("Usage: ProtocolProbe.java exercise|persist|rcon MC_PORT RCON_PORT RCON_PASSWORD [COMMAND]");
        int gamePort = Integer.parseInt(args[1]), rconPort = Integer.parseInt(args[2]);
        try (Rcon console = new Rcon(rconPort, args[3])) {
            if (args[0].equals("rcon")) {
                require(args.length == 5, "rcon mode requires one command argument");
                System.out.println(console.command(args[4])); return;
            }
            require(args[0].equals("exercise") || args[0].equals("persist"), "Unknown probe mode");
            console.command("scoreboard objectives add " + OBJECTIVE + " dummy");
            if (args[0].equals("exercise")) exercise(gamePort, console);
            else persistence(gamePort, console);
        }
        System.out.println("PASS: " + args[0] + " encrypted login and authentication protocol checks");
    }

    private static void exercise(int port, Rcon console) throws Exception {
        reset(console, PLAYER); reset(console, PERSIST);
        try (Client client = new Client(port, PLAYER)) {
            client.await("Log in:", 15);
            console.command("op " + PLAYER);
            blocked(client, console, PLAYER);
            double health = health(console, PLAYER);
            console.command("damage " + PLAYER + " 2 minecraft:generic");
            require(Math.abs(health(console, PLAYER) - health) < 0.01, "Unauthenticated player took damage");
            try (Client duplicate = new Client(port, PLAYER, false)) {
                duplicate.awaitDisconnect("already connected", 8);
            }
            client.pump(300);
            require(client.disconnect == null, "Duplicate login evicted the incumbent player");
            client.command("register " + PASSWORD + " " + PASSWORD);
            client.await("Authentication successful.", 15);
            allowed(client, console);
            System.out.println("PASS: encrypted registration, duplicate-session protection, pending OP/movement/damage restrictions and authenticated commands");
        }
        waitGone(console, PLAYER);
        try (Client client = new Client(port, PLAYER)) {
            client.await("Log in:", 15);
            blocked(client, console, PLAYER);
            client.command("login incorrect-password"); client.await("Incorrect password.", 15);
            client.command("login " + PASSWORD); client.await("Authentication successful.", 15);
            client.command("changepassword " + PASSWORD + " " + CHANGED + " " + CHANGED);
            client.await("Password changed.", 15);
        }
        waitGone(console, PLAYER);
        try (Client client = new Client(port, PLAYER)) {
            client.await("Log in:", 15);
            client.command("login " + PASSWORD); client.await("Incorrect password.", 15);
            client.command("login " + CHANGED); client.await("Authentication successful.", 15);
            reset(console, PLAYER);
            client.awaitDisconnect("reset", 8);
        }
        waitGone(console, PLAYER);
        try (Client client = new Client(port, PLAYER)) {
            client.await("Log in:", 15);
            client.command("login " + CHANGED); client.await("not registered", 15);
            client.command("register " + PASSWORD + " " + PASSWORD); client.await("Authentication successful.", 15);
        }
        waitGone(console, PLAYER);
        reset(console, PLAYER);
        console.command("deop " + PLAYER);
        try (Client client = new Client(port, PERSIST)) {
            client.await("Log in:", 15);
            client.command("register " + SAVED + " " + SAVED); client.await("Authentication successful.", 15);
            console.command("op " + PERSIST);
        }
        waitGone(console, PERSIST);
        System.out.println("PASS: reconnect requires login, wrong/changed passwords, console reset and account re-registration");
    }

    private static void persistence(int port, Rcon console) throws Exception {
        try (Client client = new Client(port, PERSIST)) {
            client.await("Log in:", 15);
            console.command("op " + PERSIST);
            blocked(client, console, PERSIST);
            client.command("login " + SAVED); client.await("Authentication successful.", 15);
            allowed(client, console);
        }
        waitGone(console, PERSIST);
        System.out.println("PASS: account survives server restart while connection authentication does not");
    }

    private static void reset(Rcon console, String name) throws Exception {
        console.command("auth reset " + name);
        // Reset runs off the server thread; a second RCON round trip is not a completion barrier.
        Thread.sleep(250);
    }

    private static void blocked(Client client, Rcon console, String player) throws Exception {
        console.command("scoreboard players set AuthGate " + OBJECTIVE + " 0");
        client.command("scoreboard players set AuthGate " + OBJECTIVE + " 1");
        double[] before = position(console, player);
        client.move(before[0] + 3, before[1], before[2]);
        client.pump(1300);
        require(score(console) == 0, "Unauthenticated OP executed a gameplay command");
        double[] after = position(console, player);
        for (int i = 0; i < 3; i++) require(Math.abs(after[i] - before[i]) < 0.05, "Unauthenticated movement changed server position");
        client.forgeNextTeleport = true; client.forgedSent = false;
        long deadline = System.nanoTime() + Duration.ofSeconds(4).toNanos();
        while (!client.forgedSent && client.disconnect == null && System.nanoTime() < deadline) client.step();
        require(client.forgedSent, "No pending teleport was available for the forged ACK check");
        Thread.sleep(100);
        double[] afterForgedAck = position(console, player);
        for (int i = 0; i < 3; i++) require(Math.abs(afterForgedAck[i] - before[i]) < 0.05, "Forged teleport ACK moved an unauthenticated player");
    }

    private static void allowed(Client client, Rcon console) throws Exception {
        console.command("scoreboard players set AuthGate " + OBJECTIVE + " 0");
        client.command("scoreboard players set AuthGate " + OBJECTIVE + " 1");
        client.pump(400);
        require(score(console) == 1, "Authenticated OP could not execute a gameplay command");
    }

    private static int score(Rcon console) throws Exception {
        String result = console.command("scoreboard players get AuthGate " + OBJECTIVE);
        var matcher = java.util.regex.Pattern.compile("has (-?\\d+) ").matcher(result);
        require(matcher.find(), "Cannot parse scoreboard result: " + result);
        return Integer.parseInt(matcher.group(1));
    }

    private static double health(Rcon console, String player) throws Exception {
        String result = console.command("data get entity " + player + " Health");
        String value = result.substring(result.lastIndexOf(':') + 1).strip().replaceAll("[fFdD]$", "");
        return Double.parseDouble(value);
    }

    private static double[] position(Rcon console, String player) throws Exception {
        String result = console.command("data get entity " + player + " Pos");
        int start = result.indexOf('['), end = result.indexOf(']', start);
        require(start >= 0 && end > start, "Cannot parse player position: " + result);
        String[] values = result.substring(start + 1, end).split(",");
        require(values.length == 3, "Wrong player position size");
        return Arrays.stream(values).map(String::strip).map(value -> value.replaceAll("[dDfF]$", "")).mapToDouble(Double::parseDouble).toArray();
    }

    private static void waitGone(Rcon console, String player) throws Exception {
        long deadline = System.nanoTime() + Duration.ofSeconds(8).toNanos();
        while (System.nanoTime() < deadline) {
            if (!console.command("list").matches("(?s).*\\b" + player + "\\b.*")) return;
            Thread.sleep(100);
        }
        throw new AssertionError("Player did not disconnect: " + player);
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    @FunctionalInterface private interface Writer { void write(DataOutputStream output) throws Exception; }
    private record Packet(int id, byte[] body) {
        DataInputStream input() { return new DataInputStream(new ByteArrayInputStream(body)); }
        String text() { return new String(body, StandardCharsets.UTF_8); }
    }

    private static final class Client implements AutoCloseable {
        final Socket socket;
        InputStream input;
        OutputStream output;
        final ArrayList<String> messages = new ArrayList<>();
        String state = "login", disconnect;
        int compression = -1;
        boolean encrypted, loaded, forgeNextTeleport, forgedSent;

        Client(int port, String name) throws Exception { this(port, name, true); }
        Client(int port, String name, boolean accepted) throws Exception {
            socket = new Socket();
            socket.connect(new InetSocketAddress("127.0.0.1", port), 5000);
            socket.setSoTimeout(1000);
            input = socket.getInputStream(); output = socket.getOutputStream();
            boolean initialized = false;
            try {
                send(0, data -> { varInt(data, PROTOCOL); string(data, "localhost"); data.writeShort(port); varInt(data, 2); });
                send(0, data -> { string(data, name); data.writeLong(0); data.writeLong(0); });
                if (accepted) {
                    long deadline = System.nanoTime() + Duration.ofSeconds(20).toNanos();
                    while (!state.equals("play") && disconnect == null && System.nanoTime() < deadline) step();
                    require(disconnect == null, "Login rejected: " + disconnect);
                    require(state.equals("play"), "Login did not enter game state");
                    require(encrypted, "Offline server did not negotiate native transport encryption");
                    socket.setSoTimeout(100);
                }
                initialized = true;
            } finally { if (!initialized) socket.close(); }
        }

        void command(String command) throws Exception { send(7, data -> string(data, command)); }
        void move(double x, double y, double z) throws Exception {
            send(30, data -> { data.writeDouble(x); data.writeDouble(y); data.writeDouble(z); data.writeByte(1); });
        }

        void await(String text, int timeout) throws Exception {
            long deadline = System.nanoTime() + Duration.ofSeconds(timeout).toNanos();
            while (System.nanoTime() < deadline && disconnect == null) {
                for (int i = 0; i < messages.size(); i++) {
                    if (messages.get(i).contains(text)) { messages.remove(i); return; }
                }
                step();
            }
            throw new AssertionError("Missing message '" + text + "'; disconnect=" + disconnect + "; received=" + messages);
        }

        void awaitDisconnect(String text, int timeout) throws Exception {
            long deadline = System.nanoTime() + Duration.ofSeconds(timeout).toNanos();
            while (disconnect == null && System.nanoTime() < deadline) step();
            require(disconnect != null && disconnect.contains(text), "Expected disconnect containing '" + text + "', got " + disconnect);
        }

        void pump(long milliseconds) throws Exception {
            long deadline = System.nanoTime() + Duration.ofMillis(milliseconds).toNanos();
            while (System.nanoTime() < deadline && disconnect == null) step();
            require(disconnect == null, "Unexpected disconnect: " + disconnect);
        }

        void step() throws Exception {
            Packet packet;
            try { packet = receive(); }
            catch (SocketTimeoutException timeout) { return; }
            catch (EOFException eof) { disconnect = "Connection closed"; return; }
            DataInputStream data = packet.input();
            if (Boolean.getBoolean("auth.probe.trace")) System.out.println(state + " packet " + packet.id + " (" + packet.body.length + " bytes)");
            if (state.equals("login")) {
                switch (packet.id) {
                    case 0 -> disconnect = packet.text();
                    case 1 -> {
                        require(!encrypted, "Repeated encryption request");
                        string(data); byte[] key = bytes(data), challenge = bytes(data);
                        require(!data.readBoolean(), "Offline encryption unexpectedly requires a Mojang session");
                        PublicKey publicKey = KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(key));
                        byte[] secret = new byte[16]; new SecureRandom().nextBytes(secret);
                        Cipher rsa = Cipher.getInstance("RSA/ECB/PKCS1Padding"); rsa.init(Cipher.ENCRYPT_MODE, publicKey);
                        byte[] sealedSecret = rsa.doFinal(secret), sealedChallenge = rsa.doFinal(challenge);
                        send(1, response -> { bytes(response, sealedSecret); bytes(response, sealedChallenge); });
                        Cipher decrypt = Cipher.getInstance("AES/CFB8/NoPadding"), encrypt = Cipher.getInstance("AES/CFB8/NoPadding");
                        var aes = new SecretKeySpec(secret, "AES"); var iv = new IvParameterSpec(secret);
                        decrypt.init(Cipher.DECRYPT_MODE, aes, iv); encrypt.init(Cipher.ENCRYPT_MODE, aes, iv);
                        input = new CipherInputStream(input, decrypt); output = new CipherOutputStream(output, encrypt);
                        Arrays.fill(secret, (byte) 0); encrypted = true;
                    }
                    case 2 -> { send(3, response -> { }); state = "configuration"; }
                    case 3 -> compression = varInt(data);
                    case 4 -> { int query = varInt(data); send(2, response -> { varInt(response, query); response.writeBoolean(false); }); }
                    default -> throw new IOException("Unexpected login packet: " + packet.id);
                }
            } else if (state.equals("configuration")) {
                switch (packet.id) {
                    case 2 -> disconnect = packet.text();
                    case 3 -> { send(3, response -> { }); state = "play"; }
                    case 4 -> { long id = data.readLong(); send(4, response -> response.writeLong(id)); }
                    case 5 -> { int id = data.readInt(); send(5, response -> response.writeInt(id)); }
                    case 15 -> send(7, response -> varInt(response, 0));
                    default -> { }
                }
            } else {
                switch (packet.id) {
                    case 11 -> send(11, response -> response.writeFloat(16.0f));
                    case 32 -> disconnect = packet.text();
                    case 45 -> { long id = data.readLong(); send(28, response -> response.writeLong(id)); }
                    case 62 -> { int id = data.readInt(); send(45, response -> response.writeInt(id)); }
                    case 73 -> {
                        int id = varInt(data);
                        double x = data.readDouble(), y = data.readDouble(), z = data.readDouble();
                        data.readDouble(); data.readDouble(); data.readDouble();
                        float yaw = data.readFloat(), pitch = data.readFloat();
                        if (forgeNextTeleport) {
                            acknowledgeTeleport(id, x + 64, y, z, yaw, pitch);
                            forgeNextTeleport = false; forgedSent = true;
                        }
                        acknowledgeTeleport(id, x, y, z, yaw, pitch);
                        if (!loaded) { send(44, response -> { }); loaded = true; }
                    }
                    case 124 -> messages.add(packet.text());
                    default -> { }
                }
            }
        }

        private void acknowledgeTeleport(int id, double x, double y, double z, float yaw, float pitch) throws Exception {
            send(0, response -> {
                varInt(response, id); response.writeDouble(x); response.writeDouble(y); response.writeDouble(z);
                response.writeFloat(yaw); response.writeFloat(pitch);
            });
        }

        void send(int id, Writer body) throws Exception {
            var packet = new ByteArrayOutputStream();
            try (var data = new DataOutputStream(packet)) { varInt(data, id); body.write(data); }
            byte[] payload = packet.toByteArray();
            if (compression >= 0) {
                var framed = new ByteArrayOutputStream();
                try (var data = new DataOutputStream(framed)) {
                    if (payload.length >= compression) {
                        varInt(data, payload.length);
                        try (var compressed = new DeflaterOutputStream(data)) { compressed.write(payload); }
                    } else { varInt(data, 0); data.write(payload); }
                }
                payload = framed.toByteArray();
            }
            var stream = new DataOutputStream(output); varInt(stream, payload.length); stream.write(payload); stream.flush();
        }

        Packet receive() throws Exception {
            int length = varInt(input);
            if (Boolean.getBoolean("auth.probe.trace")) System.out.println("frame " + length + ", compression=" + compression);
            require(length > 0 && length <= 16 * 1024 * 1024, "Invalid frame length");
            byte[] payload = exactly(input, length);
            if (compression >= 0) {
                var compressed = new ByteArrayInputStream(payload);
                int uncompressed = varInt(compressed);
                require(uncompressed >= 0 && uncompressed <= 16 * 1024 * 1024, "Invalid decompressed length");
                if (uncompressed == 0) payload = compressed.readAllBytes();
                else {
                    try (var inflater = new InflaterInputStream(compressed)) { payload = inflater.readNBytes(uncompressed + 1); }
                    require(payload.length == uncompressed, "Compressed frame size mismatch");
                }
            }
            var packet = new ByteArrayInputStream(payload);
            return new Packet(varInt(packet), packet.readAllBytes());
        }

        @Override public void close() throws IOException {
            try {
                socket.shutdownOutput();
                socket.setSoTimeout(100);
                byte[] buffer = new byte[4096];
                long deadline = System.nanoTime() + Duration.ofSeconds(1).toNanos();
                while (System.nanoTime() < deadline && input.read(buffer) >= 0) { }
            } catch (IOException ignored) { }
            finally { socket.close(); }
        }
    }

    private static final class Rcon implements AutoCloseable {
        final Socket socket;
        final DataInputStream input;
        final OutputStream output;
        int sequence;
        Rcon(int port, String password) throws Exception {
            socket = new Socket(); socket.connect(new InetSocketAddress("127.0.0.1", port), 5000); socket.setSoTimeout(5000);
            input = new DataInputStream(socket.getInputStream()); output = socket.getOutputStream();
            send(3, password); Response auth = read();
            require(auth.id != -1, "RCON authentication failed");
        }
        String command(String command) throws Exception {
            int id = send(2, command); Response response = read();
            require(response.id == id, "RCON response did not match command");
            return response.body;
        }
        private int send(int type, String body) throws IOException {
            byte[] text = body.getBytes(StandardCharsets.UTF_8);
            int id = ++sequence;
            var packet = ByteBuffer.allocate(text.length + 14).order(ByteOrder.LITTLE_ENDIAN);
            packet.putInt(text.length + 10).putInt(id).putInt(type).put(text).put((byte) 0).put((byte) 0);
            output.write(packet.array()); output.flush(); return id;
        }
        private record Response(int id, int type, String body) { }
        private Response read() throws IOException {
            int length = Integer.reverseBytes(input.readInt());
            require(length >= 10 && length < 1024 * 1024, "Invalid RCON response size");
            byte[] bytes = input.readNBytes(length);
            if (bytes.length != length) throw new EOFException();
            var packet = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
            return new Response(packet.getInt(), packet.getInt(), new String(bytes, 8, length - 10, StandardCharsets.UTF_8));
        }
        @Override public void close() throws IOException { socket.close(); }
    }

    private static int varInt(InputStream input) throws IOException {
        int value = 0;
        for (int shift = 0; shift < 35; shift += 7) {
            int next = input.read(); if (next < 0) throw new EOFException();
            value |= (next & 127) << shift;
            if ((next & 128) == 0) return value;
        }
        throw new IOException("Oversized VarInt");
    }
    private static void varInt(OutputStream output, int value) throws IOException {
        do { int next = value & 127; value >>>= 7; output.write(value == 0 ? next : next | 128); } while (value != 0);
    }
    private static void string(OutputStream output, String value) throws IOException { bytes(output, value.getBytes(StandardCharsets.UTF_8)); }
    private static String string(InputStream input) throws IOException { return new String(bytes(input), StandardCharsets.UTF_8); }
    private static void bytes(OutputStream output, byte[] value) throws IOException { varInt(output, value.length); output.write(value); }
    private static byte[] bytes(InputStream input) throws IOException {
        int length = varInt(input); require(length >= 0 && length < 65536, "Invalid length-prefixed field");
        return exactly(input, length);
    }
    private static byte[] exactly(InputStream input, int length) throws IOException {
        byte[] value = new byte[length];
        int offset = 0;
        while (offset < length) {
            int read = input.read(value, offset, length - offset);
            if (read < 0) throw new EOFException();
            offset += read;
        }
        return value;
    }
}
