package dev.sieluna.auth.mixin;

import dev.sieluna.auth.AuthMod;
import net.minecraft.network.Connection;
import net.minecraft.network.protocol.Packet;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.network.CommonListenerCookie;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(ServerGamePacketListenerImpl.class)
public abstract class GameConnectionMixin {
    @Inject(method = "<init>", at = @At("RETURN"))
    private void auth$attach(MinecraftServer server, Connection connection, ServerPlayer player, CommonListenerCookie cookie, CallbackInfo ci) {
        AuthMod auth = AuthMod.get();
        if (auth != null) auth.attach((ServerGamePacketListenerImpl) (Object) this, player, connection);
    }

    @Inject(method = "shouldHandleMessage", at = @At("HEAD"), cancellable = true)
    private void auth$filter(Packet<?> packet, CallbackInfoReturnable<Boolean> cir) {
        AuthMod auth = AuthMod.get();
        if (auth != null && !auth.allow((ServerGamePacketListenerImpl) (Object) this, packet)) cir.setReturnValue(false);
    }
}
