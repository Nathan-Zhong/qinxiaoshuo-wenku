package org.mewx.wenku8_flutter

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import io.legado.engine.LegadoEngineFacade

/**
 * Bridge to the Legado engine AARs vendored under `android/app/libs/`
 * (built in the legado-engine-src repo with the fork's own toolchain).
 *
 * Spike stage: only `ping` and a placeholder `init` are implemented.
 * `ping` answers straight from [LegadoEngineFacade], which doubles as the
 * host-toolchain compatibility probe — compiling this file forces the host
 * Kotlin compiler to read the engine's Kotlin 2.3 metadata and class-file
 * version 65. Every other contract method returns notImplemented until the
 * engine wiring lands.
 */
class LegadoEnginePlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/legado_engine").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ping" -> result.success(
                        mapOf(
                            "engineVersion" to LegadoEngineFacade.engineVersion(),
                            "includedModules" to LegadoEngineFacade.includedModules(),
                            "upstreamCommit" to LegadoEngineFacade.upstreamCommit(),
                        ),
                    )

                    // Placeholder: no database or provider registration yet.
                    // Returns the contract shape the Dart client expects.
                    "init" -> result.success(
                        mapOf(
                            "ok" to true,
                            "engineVersion" to LegadoEngineFacade.engineVersion(),
                            "sourceCount" to 0,
                        ),
                    )

                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
