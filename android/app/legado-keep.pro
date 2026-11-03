# 小说文库 release (R8) keep rules — FINAL package slimming.
#
# The Legado engine is reflection-heavy by design: Gson (de)serializes the
# book-source/rule/entity model, kotlinx-serialization mirrors it, and the
# QuickJS bindings expose Java objects whose methods are invoked BY NAME
# from source JavaScript. Renaming or stripping any of that surface only
# fails at runtime on a real device, so the engine surface is kept whole.
# Deliberately conservative: correctness over a few extra hundred KB.

# --- Vendored Legado engine (libs/*.aar) -------------------------------
-keep class io.legado.** { *; }
-keep interface io.legado.** { *; }
-keep enum io.legado.** { *; }

# --- QuickJS JNI bindings (com.script, quickjs.aar / js-api.aar) -------
-keep class com.script.** { *; }
-keep interface com.script.** { *; }

# --- Vendored jsoup port inside data.aar (rule parsing is reflective) --
-keep class org.jsoup.** { *; }
-keep interface org.jsoup.** { *; }

# --- JNI entry points anywhere ------------------------------------------
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- Gson ----------------------------------------------------------------
-keepattributes Signature
-keepattributes *Annotation*
-keep class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-keep class * {
    @com.google.gson.annotations.Expose <fields>;
}

# --- kotlinx-serialization -------------------------------------------------
-keep class **$$serializer { *; }
-keep class * implements kotlinx.serialization.internal.GeneratedSerializer { *; }
-keepclassmembers class * {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep class * {
    @kotlinx.serialization.Serializable <fields>;
    static **$Companion Companion;
}

# --- Parcelable / Serializable scaffolding ----------------------------------
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    !static !transient <fields>;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# --- Enum value lookup by name (rules/configs persist enum names) -----------
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# --- Libraries that ship without consumer rules in this dependency set ------
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn com.gemalto.jp2.**
-dontwarn javax.annotation.**
-dontwarn kotlin.**
-dontwarn org.mozilla.**
-dontwarn com.sun.**
-dontwarn org.openjsse.**
