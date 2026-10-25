package dev.sieluna.auth.mixin;

import dev.sieluna.auth.AuthMod;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.damagesource.DamageSource;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(ServerPlayer.class)
public abstract class PendingPlayerMixin {
    private boolean auth$pending() {
        AuthMod auth = AuthMod.get();
        return auth != null && auth.pending((ServerPlayer) (Object) this);
    }

    @Inject(method = "doTick", at = @At("HEAD"), cancellable = true)
    private void auth$freezeSimulation(CallbackInfo ci) {
        if (auth$pending()) ci.cancel();
    }

    @Inject(method = "tick", at = @At("HEAD"), cancellable = true)
    private void auth$freezePlayer(CallbackInfo ci) {
        if (auth$pending()) {
            ((ServerPlayer) (Object) this).connection.tickClientLoadTimeout();
            ci.cancel();
        }
    }

    @Inject(method = "hurtServer", at = @At("HEAD"), cancellable = true)
    private void auth$protect(ServerLevel level, DamageSource damage, float amount, CallbackInfoReturnable<Boolean> cir) {
        if (auth$pending()) cir.setReturnValue(false);
    }
}
