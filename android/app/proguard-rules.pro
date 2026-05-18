# Flutter — reflection ve JNI bridge korunur
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Spotify App Remote SDK — R8 bu sınıfları silmemeli
-keep class com.spotify.** { *; }
-keep interface com.spotify.** { *; }

# Spotify Auth SDK
-keep class com.spotify.sdk.android.authentication.** { *; }

# Gson (spotify_sdk JSON serialization)
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# kotlin-events (spotify_sdk bağımlılığı)
-keep class de.halfbit.** { *; }
