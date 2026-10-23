# The engine bindings reach Rust through JNA, which finds classes, fields and
# native methods by name.
-dontwarn java.awt.**
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
-keep class ai.masko.player.engine.** { *; }
