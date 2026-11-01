setExtensionUnloadMode("tuningTelemetry_main", "manual")
extensions.load("tuningTelemetry_main")
extensions.core_input_categories.tuningTelemetry = { order = 99998, icon = "settings", title = "Tuning Telemetry", desc = "Telemetry recording for tuning" }
