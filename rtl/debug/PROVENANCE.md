# Debug blocks — provenance

| File | From | Notes |
|---|---|---|
| `issp_probe.sv` | `Arcade-Seta_MiSTer rtl/debug/` at `f4be27d` | In-System Sources and Probes wrapper; read by `scripts/read_issp.py` |
| `debug_counter.sv` | same | saturating, no reset port |
| `debug_tracer.sv` | same | trace ring read out through the video output |
| `pause_control.sv` | `Arcade-Fuuki_MiSTer rtl/` at `5a81012` | Pause from the OSD, the hiscore module and the fake Pause button, as one clock-enable gate |

All four are this core family's own (GPL-3.0-or-later), copied **untouched**. The headers say
what each does and why it has the shape it has; `docs/WORKFLOW.md` sections 5 and 6 are the
rationale.

## Local changes

None.
