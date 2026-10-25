package dev.sieluna.auth.mixin;

import dev.sieluna.auth.AuthMod;
import com.mojang.authlib.GameProfile;
import net.minecraft.core.UUIDUtil;
import net.minecraft.network.Connection;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.login.ServerboundHelloPacket;
import net.minecraft.network.protocol.login.ServerboundKeyPacket;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.network.ServerLoginPacketListenerImpl;
import net.minecraft.util.Crypt;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.gen.Invoker;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.ModifyArg;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(ServerLoginPacketListenerImpl.class)
public abstract class LoginEncryptionMixin {
    @Shadow @Final private MinecraftServer server;
    @Shadow @Final private Connection connection;
    @Shadow @Final private byte[] challenge;
    @Shadow private String requestedUsername;
    @Shadow public abstract void disconnect(Component reason);
    @Invoker("startClientVerification") protected abstract void auth$verify(GameProfile profile);
    @Unique private boolean auth$hello;
    @Unique private boolean auth$waitingForKey;

    @Inject(method = "handleHello", at = @At("HEAD"), cancellable = true)
    private void auth$admit(ServerboundHelloPacket packet, CallbackInfo ci) {
        if (server.isDedicatedServer() && !server.usesAuthentication() && !AuthMod.active()) {
            disconnect(Component.literal("Authentication is not ready. Reconnect shortly."));
            ci.cancel(); return;
        }
        if (!AuthMod.active()) return;
        if (auth$hello) { disconnect(Component.literal("Unexpected login packet.")); ci.cancel(); return; }
        auth$hello = true;
        String rejection = AuthMod.get().admit(connection, packet.name());
        if (rejection != null) { disconnect(Component.literal(rejection)); ci.cancel(); }
    }

    @Redirect(method = "handleHello", at = @At(value = "INVOKE", target = "Lnet/minecraft/server/MinecraftServer;usesAuthentication()Z"))
    private boolean auth$requestEncryption(MinecraftServer server) {
        if (AuthMod.active() && !connection.isMemoryConnection()) {
            auth$waitingForKey = true;
            return true;
        }
        return server.usesAuthentication();
    }

    @ModifyArg(method = "handleHello", at = @At(value = "INVOKE", target = "Lnet/minecraft/network/protocol/login/ClientboundHelloPacket;<init>(Ljava/lang/String;[B[BZ)V"), index = 3)
    private boolean auth$skipMojangSession(boolean original) {
        return AuthMod.active() ? false : original;
    }

    @Inject(method = "handleKey", at = @At("HEAD"), cancellable = true)
    private void auth$enableEncryption(ServerboundKeyPacket packet, CallbackInfo ci) {
        if (!AuthMod.active()) return;
        ci.cancel();
        if (!auth$waitingForKey) { disconnect(Component.literal("Unexpected encryption response.")); return; }
        auth$waitingForKey = false;
        try {
            var privateKey = server.getKeyPair().getPrivate();
            if (!packet.isChallengeValid(challenge, privateKey)) {
                disconnect(Component.literal("Invalid encryption challenge.")); return;
            }
            var secret = packet.getSecretKey(privateKey);
            connection.setEncryptionKey(Crypt.getCipher(2, secret), Crypt.getCipher(1, secret));
            auth$verify(UUIDUtil.createOfflineProfile(requestedUsername));
        } catch (Exception invalid) { disconnect(Component.literal("Could not establish an encrypted connection.")); }
    }
}
