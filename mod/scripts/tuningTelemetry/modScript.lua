setExtensionUnloadMode("tuningTelemetry_main", "manual")
extensions.load("tuningTelemetry_main")
setExtensionUnloadMode("tuningTelemetry_graph", "manual")
extensions.load("tuningTelemetry_graph")
extensions.core_input_categories.tuningTelemetry = { order = 99998, icon = "settings", title = "Tuning Telemetry", desc = "Telemetry recording for tuning" }
