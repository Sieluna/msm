# Auth

Small, server-only password authentication for Minecraft **26.3**, Fabric and NeoForge. Clients need no mod. The source and tested server JARs are part of MSM.

## Build

Use JDK 25:

```sh
./auth/gradlew -p auth :core:test bundleAuth
```

`auth/dist/` contains `auth-fabric-26.3.jar`, `auth-neoforge-26.3.jar` and their SHA-512 manifest. Install only the JAR matching the server loader. Fabric also requires Fabric API. Do not install another authentication mod alongside Auth.

The Fabric and NeoForge MSM templates enable the bundled JAR with `"auth": true`. Set this to `false` to exclude it. Unsupported Minecraft versions fail during planning; Auth does not silently claim compatibility with a newer release. MSM's default `online-mode=true` remains unchanged. Password authentication activates only on dedicated servers configured with `online-mode=false`.

## Commands

```text
/register <password> <repeat>
/login <password>
/changepassword <old> <new> <repeat>
```

Passwords default to 10-128 characters, without whitespace or control characters. Login requires the exact capitalization used at registration, preserving the original offline UUID. Every new connection must authenticate; there is no IP-based automatic login or OP bypass.

The server console or trusted RCON operator can run:

```text
auth reset <player>
```

Reset disconnects that player's current session and removes their account. Resetting a name allows a new registration; control access to the server while assigning existing player identities.

## Behavior and storage

Before authentication, Auth rejects gameplay packets, chat, custom payloads and unrelated commands, freezes the player simulation and prevents incoming damage. Basic connection, encryption, resource-pack and teleport acknowledgments remain available. Normal lifecycle and command registration use the loader APIs; three shared, required Mixins cover the packet gate, pending-player simulation and native offline encryption handshake. A missing required injection aborts loading.

Passwords are stored as salted PBKDF2-HMAC-SHA256 hashes with 600,000 iterations. Two background workers perform storage access and hashing, with a bounded queue of 16 requests. The main game thread performs neither account lookup nor password hashing. Login defaults to a 60-second deadline and five failed password attempts, with additional per-name and per-address request limits.

Configuration and account data live under `config/auth/`, independently of the world. Auth uses its own bounded, indexed account database and only JDK APIs. See [STORAGE.md](STORAGE.md) for its format, recovery rules and limits. Back up this directory with the server stopped; MSM's stopped-server backup includes it. Invalid storage fails closed and is never silently replaced with an empty database.

The offline handshake requests Minecraft's native RSA/AES transport encryption without Mojang session authentication. This protects against passive observation; it does not authenticate the server's identity against an active intermediary. Other mods, proxies and client command history may observe command arguments. Use a unique server password. Mojang ownership, premium auto-login, proxy identity forwarding, two-factor authentication and password recovery are outside this mod's scope.

## Validation

Core tests cover password changes and persistence, indexed lookups, interrupted writes, corrupt storage, account reset races and bounded request queues. CI boots both full MSM mod templates with the matching packaged Auth JAR and uses `integration/ProtocolProbe.java` to exercise encrypted registration, reconnection, login, command and movement restrictions, duplicate-session protection, password changes, reset and persistence through MSM operations. Vanilla keeps its separate latest-release boot test.
