package dev.sieluna.auth.core;

public final class CommandPolicy {
    private CommandPolicy() {}

    public static String root(String command) {
        int space = command.indexOf(' ');
        return space < 0 ? command : command.substring(0, space);
    }

    public static boolean isAuthentication(String command) {
        if (command.length() > 400) return false;
        return switch (root(command)) {
            case "register", "login", "changepassword" -> true;
            default -> false;
        };
    }
}
