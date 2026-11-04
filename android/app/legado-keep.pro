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

# --- Host bridge package (FIX9) ----------------------------------------
# The host's Legado bridge classes live outside io.legado.**: anything in
# here that JavaScript reaches BY NAME (JS bindings resolve methods
# reflectively at runtime) or that reflection looks up must keep its
# names. FIX8's lesson: host-only JS-visible methods added to the
# AnalyzeRule/AnalyzeUrl subclasses were renamed/stripped by R8 and the
# device kept failing with "TypeError: not a function" while every debug
# build passed. JS-visible APIs belong in the engine (kept above); this
# rule is defense in depth for the rest of the bridge surface.
-keep class org.mewx.wenku8_flutter.legado.** { *; }
-keep interface org.mewx.wenku8_flutter.legado.** { *; }
-keep enum org.mewx.wenku8_flutter.legado.** { *; }

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

# --- Missing-class tolerance --------------------------------------------------
# R8 (full mode) fails the build on references to classes that do not exist
# on Android at all: hutool's desktop utilities (java.awt / javax.tools /
# java.beans / JMX) and the Play Core split-install classes Flutter's
# deferred-components manager references optionally. None of these code
# paths can execute on a phone (the engine only uses hutool-crypto).
-dontwarn com.google.android.play.core.**
-dontwarn java.awt.**
-dontwarn javax.swing.**
-dontwarn javax.tools.**
-dontwarn javax.imageio.**
-dontwarn java.beans.**
-dontwarn java.lang.management.**
-dontwarn cn.hutool.core.swing.**
-dontwarn cn.hutool.core.compiler.**
-dontwarn cn.hutool.core.img.**

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
