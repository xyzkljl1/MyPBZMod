# ModConfigUI Blueprint project

Use Unreal Engine **5.7.4** and its supported C++ toolchain. Set `UE_ROOT` if the engine is not installed at `E:/UE_5.7`.

From this directory, compile the editor module:

```powershell
python -B build.py editor-build
```

Then open `ModConfigUI.uproject` in this directory. The editable bridges are `Content/Mods/ModConfigUI/W_TextInputBridge` (text commit/color preview) and `W_KeyCapture` (single-key capture). The source project uses the normal engine plugins so the Content Browser and Blueprint editor remain available.

The Blueprint configuration SDK is under `Content/Mods/ModConfigUI/Blueprint/`: `BP_MCUConfigComponent`, `ST_MCUFieldV1` and `ST_MCUOptionV1`. Migrate these assets together into a Blueprint Mod authoring project, preserving their `/Game/Mods/ModConfigUI/Blueprint/` paths. They are runtime dependencies supplied by MCU; exclude their copies from the other Mod's release package. See `../MCUExample5/` for a complete typed configuration example.

Build caches and command-line logs stay in the repository's `_temp/mcu-blueprint-build/`. The compiled editor module is copied to this project's ignored `Binaries/` directory. Close this project's editor before rebuilding its module; the script does not close it for you.

## Build the existing Blueprint

Save any Blueprint edits in the source project, then run each stage in order. Stop if a stage fails.

```powershell
python -B build.py cook
python -B build.py iostore
python -B build.py pak
python -B build.py verify
python -B build.py publish
```

These stages use the existing source assets. They do not regenerate or overwrite them. `publish` copies only the three runtime containers into the Mod release directory; it does not install them into the game. The game mount and installation path still use `ProjectPBZ`, independently of this project's name.

## Regenerate the Blueprint from C++

**Regeneration replaces `W_TextInputBridge.uasset` and `W_KeyCapture.uasset` and discards manual graph edits.** Commit or preserve your edits first. If a manual change should survive regeneration, update the generator in `Source/MCUBlueprintEditor/MCUBridgeBuildCommandlet.cpp` as well.

After compiling the updated generator with `editor-build`, explicitly opt in:

```powershell
python -B build.py create --overwrite-assets
```

Run regeneration with this project's editor closed to avoid overwriting an asset that is still open in memory. Inspect the generated asset before rebuilding the runtime containers. The normal build workflow never calls this stage automatically.

`ST_MCUFieldV1` and `ST_MCUOptionV1` are frozen SDK assets. Build stages verify their hashes against `sdk-v1.sha256.json` and reject changes; do not regenerate them or update the baseline to bypass a failure. `create-api --overwrite-assets` is blocked after V1 is frozen. Use the saved assets for builds and introduce new versioned structs if structural changes are needed. The component remains `BP_MCUConfigComponent`; its existing `Fields` type and public API stay compatible.

`python -B build.py update-api --overwrite-assets` updates only the component's lifecycle wiring to `MCU_Config_Init` and `MCU_Config_Release`. It replaces manual edits to `InitFromFile` and `Release`, preserves the SDK structs and other assets, and does not require regenerating dependent examples. Rebuild the editor module first. Lua registers these named events once; the public Blueprint calls remain unchanged.
