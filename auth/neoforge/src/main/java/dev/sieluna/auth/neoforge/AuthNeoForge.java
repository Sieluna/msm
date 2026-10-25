package dev.sieluna.auth.neoforge;

import dev.sieluna.auth.AuthMod;
import net.minecraft.server.level.ServerPlayer;
import net.neoforged.api.distmarker.Dist;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import net.neoforged.neoforge.event.RegisterCommandsEvent;
import net.neoforged.neoforge.event.entity.player.PlayerEvent;
import net.neoforged.neoforge.event.server.ServerStartingEvent;
import net.neoforged.neoforge.event.server.ServerStoppedEvent;
import net.neoforged.neoforge.event.tick.ServerTickEvent;

@Mod(value = "auth", dist = Dist.DEDICATED_SERVER)
public final class AuthNeoForge {
    public AuthNeoForge() {
        NeoForge.EVENT_BUS.addListener((ServerStartingEvent event) -> AuthMod.start(event.getServer()));
        NeoForge.EVENT_BUS.addListener((ServerStoppedEvent event) -> AuthMod.stop());
        NeoForge.EVENT_BUS.addListener((ServerTickEvent.Post event) -> {
            AuthMod auth = AuthMod.get();
            if (auth != null) auth.tick();
        });
        NeoForge.EVENT_BUS.addListener((PlayerEvent.PlayerLoggedInEvent event) -> {
            AuthMod auth = AuthMod.get();
            if (auth != null && event.getEntity() instanceof ServerPlayer player) auth.joined(player);
        });
        NeoForge.EVENT_BUS.addListener((PlayerEvent.PlayerLoggedOutEvent event) -> {
            AuthMod auth = AuthMod.get();
            if (auth != null && event.getEntity() instanceof ServerPlayer player) auth.disconnected(player);
        });
        NeoForge.EVENT_BUS.addListener((RegisterCommandsEvent event) -> AuthMod.registerCommands(event.getDispatcher()));
    }
}
