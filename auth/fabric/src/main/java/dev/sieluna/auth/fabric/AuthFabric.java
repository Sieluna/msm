package dev.sieluna.auth.fabric;

import dev.sieluna.auth.AuthMod;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.command.v2.CommandRegistrationCallback;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
import net.fabricmc.fabric.api.networking.v1.ServerPlayConnectionEvents;

public final class AuthFabric implements ModInitializer {
    @Override public void onInitialize() {
        ServerLifecycleEvents.SERVER_STARTING.register(AuthMod::start);
        ServerLifecycleEvents.SERVER_STOPPED.register(server -> AuthMod.stop());
        ServerTickEvents.END_SERVER_TICK.register(server -> {
            AuthMod auth = AuthMod.get();
            if (auth != null) auth.tick();
        });
        ServerPlayConnectionEvents.JOIN.register((handler, sender, server) -> {
            AuthMod auth = AuthMod.get();
            if (auth != null) auth.joined(handler.player);
        });
        ServerPlayConnectionEvents.DISCONNECT.register((handler, server) -> {
            AuthMod auth = AuthMod.get();
            if (auth != null) auth.disconnected(handler.player);
        });
        CommandRegistrationCallback.EVENT.register((dispatcher, context, selection) -> AuthMod.registerCommands(dispatcher));
    }
}
