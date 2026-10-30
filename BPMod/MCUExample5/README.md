# MCUExample5

Editable **UE 5.7.4** Blueprint example for MCU schema configuration. It contains no Lua script. Its only application behavior is printing configuration values to the UE4SS console and `UE4SS.log` through `PrintToModLoader`, provided by the enabled `BPML_GenericFunctions` Mod.

Run `python -B build.py editor-build`, then open `MCUExample5.uproject`. The build entry copies the MCU SDK reference assets from `../ModConfigUI/Content/Mods/ModConfigUI/Blueprint/` and installs the editor module beside this project. Those SDK copies are ignored by Git and are excluded from the example's runtime package.

Open `Content/Mods/MCUExample5/ModActor`:

- `Config` uses `ST_ExampleConfig`; read it with a typed **Break ST_ExampleConfig** node.
- Select the `MCUConfig` component to edit its ordered `Fields` array: names, descriptions, bounds, slider steps and options.
- `OnConfigReady` and `OnButtonClicked(Key)` print the typed values. `OnConfigChanged(Key: String)` uses **Switch on String** to print only the changed field, once per changed field in declaration order, after the full `Config` has been updated. These are Blueprint functions called by MCU, not per-frame events.
- Configuration defaults are defined in the actor's **Class Defaults → Config**. Metadata does not duplicate them.
- The example covers the Blueprint-compatible schema controls: Boolean, integer/float boxes, integer/float sliders, text, color preview, single-key binding (Key/FKey), integer/float/text selections, separator and button. LuaKey is demonstrated by MCUExample2.

## Build and install

Save source asset edits and run each stage in order, stopping on any failure:

```powershell
python -B build.py cook
python -B build.py iostore
python -B build.py pak
python -B build.py verify
python -B build.py publish
```

This publishes only this Mod's three containers to the root `MCUExample5/` release folder. Install that folder's contents into the PBZ game root alongside the current MCU release. With the installed PBZ loader, add `MCUExample5` to `platform/steam/ue4ss/Mods/BPModLoaderMod/load_order.txt` without replacing existing entries. The loader creates `/Game/Mods/MCUExample5/ModActor.ModActor_C` in each game world.

The component loads or creates `Mods/MCUExample5/MCUExample5.schemaconfig.json`. Open the MOD settings tab, edit a field and check the corresponding Ready/Changed/Button output in `UE4SS.log`. Invalid commits and unchanged values must not produce a Changed notification. Reloading a world must load the saved values and issue Ready for the new actor.

## Regenerate

**`python -B build.py create --overwrite-assets` replaces the example's source assets and discards manual Blueprint edits.** Update `Source/MCUExample5Editor/MCUExampleBuildCommandlet.cpp` before regeneration if those edits should survive. Rebuild the editor module first. Close this project's editor before regenerating. Normal Cook/package stages never regenerate assets.

Caches, generation logs and checks remain under `_temp/mcu-example5-build/`. Do not distribute the editor module or copied SDK assets with the Mod.
