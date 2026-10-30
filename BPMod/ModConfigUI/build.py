"""Build the editable ModConfigUI project with UE 5.7.4.

editor-build: compile the editor module and install it beside ModConfigUI.uproject.
cook/iostore/pak/verify/publish: build existing Content assets; never regenerate them.
create --overwrite-assets: explicitly discard manual edits and regenerate the bridge.
create-controls --overwrite-assets: generate only the internal W_ControlEvents asset.
Use UE_ROOT to override E:/UE_5.7. A supported C++ toolchain is required.
"""
import argparse
import filecmp
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source = Path(__file__).resolve().parent
project = source.parents[1]
build_root = project / "_temp/mcu-blueprint-build"
engine = Path(os.environ.get("UE_ROOT", "E:/UE_5.7")) / "Engine"
asset_name = "W_TextInputBridge"
mod_name = "ModConfigUI"
module_name = "MCUBlueprintEditor"
create_commandlet = "MCUBridgeBuild"


def copy_changed(src, dst):
    # An open editor may lock an identical module; no replacement is needed then.
    target = Path(dst) / Path(src).name if Path(dst).is_dir() else Path(dst)
    if not target.is_file() or not filecmp.cmp(src, target, shallow=False):
        shutil.copy2(src, target)
    return str(target)


frozen_manifest = source / "sdk-v1.sha256.json"
sdk_source = source


def check_frozen_sdk():
    if not frozen_manifest.is_file():
        # Only the one-time pre-V1 migration may lack a baseline.
        if (sdk_source / "Content/Mods/ModConfigUI/Blueprint/ST_MCUFieldV1.uasset").exists():
            raise RuntimeError("Frozen SDK baseline is missing")
        return
    for relative, expected in json.loads(frozen_manifest.read_text(encoding="utf-8")).items():
        path = sdk_source / relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Frozen SDK asset changed: {relative}; do not regenerate or update the baseline")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("editor-build", "create", "create-controls", "create-api", "update-api", "version-api", "cook", "iostore", "pak", "verify", "publish"))
    parser.add_argument("--overwrite-assets", action="store_true",
                        help="allow create to overwrite the source Blueprint and discard manual edits")
    options = parser.parse_args()
    stage = options.stage
    if stage in ("create", "create-controls", "create-api", "update-api", "version-api") and not options.overwrite_assets:
        parser.error("Regeneration discards manual edits to the requested assets; explicitly pass --overwrite-assets")
    if options.overwrite_assets and stage not in ("create", "create-controls", "create-api", "update-api", "version-api"):
        parser.error("--overwrite-assets is only valid with an asset generation stage")
    if stage in ("create", "create-controls", "create-api", "update-api", "version-api"):
        print("WARNING: Regeneration will overwrite the source Blueprint, including manual edits.", flush=True)
    check_frozen_sdk()
    if stage == "create-api" and frozen_manifest.is_file():
        parser.error("V1 SDK structs are frozen; use saved assets or introduce a new version")
    if stage == "version-api" and frozen_manifest.is_file():
        parser.error("V1 migration has already completed")
    work = build_root / ("editor" if stage == "editor-build" else "headless")
    work.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source / "Source", work / "Source", dirs_exist_ok=True)
    descriptor = json.loads((source / f"{mod_name}.uproject").read_text(encoding="utf-8"))
    if stage != "editor-build":
        # Pruning is confined to the command-line build copy, never the source project.
        descriptor["DisableEnginePluginsByDefault"] = True
        descriptor["Plugins"] = [{"Name": "CommonUI", "Enabled": True}]
    (work / f"{mod_name}.uproject").write_text(json.dumps(descriptor, indent=4) + "\n", encoding="utf-8")
    if (source / "Config").is_dir():
        shutil.copytree(source / "Config", work / "Config", dirs_exist_ok=True)
    if stage in ("cook", "create", "create-controls", "create-api", "update-api", "version-api"):
        binaries = source / "Binaries/Win64"
        if not (binaries / f"UnrealEditor-{module_name}.dll").is_file():
            raise RuntimeError("Run editor-build first to compile the source project's editor module")
        shutil.copytree(binaries, work / "Binaries/Win64", dirs_exist_ok=True)
    if stage in ("cook", "create", "create-controls", "create-api", "update-api", "version-api") and (source / "Content").is_dir():
        # The committed, editable assets are the input, including any saved manual edits.
        shutil.copytree(source / "Content", work / "Content", dirs_exist_ok=True)
    if stage in ("create", "create-controls", "create-api"):
        # Regenerate only the requested assets in the build copy. An existing
        # on-disk package otherwise makes SavePackage reject a newly created object.
        names = (["W_ControlEvents"] if stage == "create-controls" else ["Blueprint/BP_MCUConfigComponent"]
                 if stage == "create-api" else [asset_name, "W_KeyCapture"] if mod_name == "ModConfigUI"
                 else ["ST_ExampleConfig", "ModActor"])
        for name in names:
            generated = (work / f"Content/Mods/{mod_name}/{name}.uasset").resolve()
            if not generated.is_relative_to(work.resolve()):
                raise RuntimeError("Generated asset escaped the build directory")
            generated.unlink(missing_ok=True)
    env = os.environ.copy()
    for name, folder in (("TEMP", "Temp"), ("TMP", "Temp"),
                         ("UE-LocalDataCachePath", "DerivedDataCache"),
                         ("LOCALAPPDATA", "BuildUser/Local"), ("APPDATA", "BuildUser/Roaming"),
                         ("DOTNET_CLI_HOME", "BuildUser/DotNet"), ("NUGET_PACKAGES", "BuildUser/NuGet")):
        path = work / folder
        path.mkdir(parents=True, exist_ok=True)
        env[name] = str(path)
    env.update(PYTHONDONTWRITEBYTECODE="1", DOTNET_CLI_TELEMETRY_OPTOUT="1",
               DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1")
    env["UE-SharedDataCachePath"] = "None"
    for folder in ("Logs", "Settings", "Shaders", "Content", "Config", "IoStore"):
        (work / folder).mkdir(exist_ok=True)
    base_config = source / "Config/DefaultEngine.ini"
    config_text = base_config.read_text(encoding="utf-8") if base_config.is_file() else ""
    (work / "Config/DefaultEngine.ini").write_text(config_text + f'''\n[MCUBuildDDC]
Root=(Type=KeyLength,Length=120,Inner=AsyncPut)
AsyncPut=(Type=AsyncPut,Inner=Local)
Local=(Type=FileSystem,Path="{(work / 'DerivedDataCache').as_posix()}",DeleteUnused=false)

[/Script/EngineSettings.GameMapsSettings]
EditorStartupMap=
GameDefaultMap=
ServerDefaultMap=

[/Script/Engine.RendererSettings]
r.RayTracing=False

[Zen.AutoLaunch]
DataPath={(work / 'Zen').as_posix()}
''', encoding="utf-8")
    common = ["-unattended", "-nop4", "-nosplash", "-nullrhi", "-nosound",
              "-NoLiveCoding", "-NoEpicPortal", "-NoCrashDialog", "-NoZenAutoLaunch", "-notraceserver",
              "-ddc=MCUBuildDDC", "-stdout", "-FullStdOutLogOutput", f"-userdir={work.as_posix()}",
              f"-ShaderWorkingDir={(work / 'Shaders').as_posix()}",
              f"-abslog={(work / 'Logs' / (stage + '.log')).as_posix()}",
              f"-abscrashreportclientlog={(work / 'Logs' / (stage + '-crashclient.log')).as_posix()}"]
    for name in ("EditorSettings", "EditorKeyBindings", "EditorLayout"):
        common.append(f"-{name}INI={(work / 'Settings' / (name + '.ini')).as_posix()}")
    editor = str(engine / "Binaries/Win64/UnrealEditor-Cmd.exe")
    pak = str(engine / "Binaries/Win64/UnrealPak.exe")
    uproject = str(work / f"{mod_name}.uproject")
    if stage == "editor-build":
        args = [str(engine / "Binaries/ThirdParty/DotNet/8.0.412/win-x64/dotnet.exe"),
                str(engine / "Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.dll"),
                f"{mod_name}Editor", "Win64", "Development", f"-Project={uproject}",
                "-WaitMutex", "-NoHotReloadFromIDE", "-NoEngineChanges", "-NoUBA", "-NoUBALocal", "-NoXGE", "-NoFASTBuild",
                f"-Log={work / 'Logs/editor-build-ubt.log'}"]
    elif stage in ("create", "create-controls", "create-api", "update-api", "version-api"):
        commandlet = "MCUControlEventsBuild" if stage == "create-controls" else create_commandlet if stage == "create" else "MCUBlueprintAPIBuild"
        args = [editor, uproject, f"-run={commandlet}", "-OverwriteGeneratedAssets"] + common
        if stage == "update-api":
            args.append("-UpdateLifecycleOnly")
        elif stage == "version-api":
            args.append("-VersionStructs")
    elif stage == "cook":
        args = [editor, uproject, "-run=cook", "-TargetPlatform=Windows",
                "-CookSkipRequests", "-NoDefaultMaps", "-NoGameAlwaysCookPackages", "-Unversioned",
                "-NoShaderCompile", f"-CookDir={work / f'Content/Mods/{mod_name}'}"] + common
    elif stage == "iostore":
        cooked = work / "Saved/Cooked/Windows"
        metadata = cooked / f"{mod_name}/Metadata"
        cooked_content = cooked / f"{mod_name}/Content"
        assets = sorted((cooked_content / f"Mods/{mod_name}").rglob("*.uasset"))
        if not assets:
            raise RuntimeError("No cooked MCU assets; run cook first")
        response = work / "iostore-files.txt"
        response.write_text("".join(f'"{p.as_posix()}" "../../../ProjectPBZ/Content/{p.relative_to(cooked_content).as_posix()}"\n' for p in assets), encoding="utf-8")
        commands = work / "iostore-commands.txt"
        commands.write_text(f'-Output="{(work / f"IoStore/{mod_name}.utoc").as_posix()}" -ContainerName={mod_name} -ResponseFile="{response.as_posix()}"\n', encoding="utf-8")
        args = [pak, "IoStore", f"-CreateGlobalContainer={(work / 'IoStore/global.utoc').as_posix()}",
                f"-CookedDirectory={cooked.as_posix()}",
                f"-PackageStoreManifest={(metadata / 'packagestore.manifest').as_posix()}",
                f"-ScriptObjects={(metadata / 'scriptobjects.bin').as_posix()}",
                f"-Commands={commands.as_posix()}", "-TargetPlatform=Windows"] + common
    elif stage == "pak":
        response = work / "pak-files.txt"
        response.write_text("", encoding="utf-8")
        output = work / f"IoStore/{mod_name}.pak"
        output.unlink(missing_ok=True)
        args = [pak, str(output), f"-Create={response.as_posix()}"] + common
    elif stage == "verify":
        args = [pak, "IoStore", f"-List={(work / f'IoStore/{mod_name}.utoc').as_posix()}",
                f"-CSV={(work / 'Logs/iostore-list.csv').as_posix()}"] + common
    elif stage == "publish":
        files = [work / f"IoStore/{mod_name}.{ext}" for ext in ("pak", "utoc", "ucas")]
        if any(not path.is_file() or not path.stat().st_size for path in files):
            raise RuntimeError("Build the three containers before publishing")
        destination = project / f"{mod_name}/ProjectPBZ/Content/Paks/LogicMods"
        destination.mkdir(parents=True, exist_ok=True)
        for path in files:
            shutil.copy2(path, destination / path.name)
        print("Published MCU containers only; editable source assets were not modified.")
        return 0
    else:
        raise ValueError("Stage: editor-build, create, cook, iostore, pak, verify, publish")
    log = work / "Logs" / f"{stage}-stdout.log"
    print(f"Running {stage}; log: {log}", flush=True)
    with log.open("w", encoding="utf-8") as stream:
        result = subprocess.run(args, cwd=work, env=env, stdout=stream, stderr=subprocess.STDOUT)
    print(log.read_text(encoding="utf-8", errors="replace")[-2600:])
    if result.returncode == 0 and stage == "editor-build":
        # Build caches remain in _temp; only persistent editor binaries go beside the source project.
        shutil.copytree(work / "Binaries/Win64", source / "Binaries/Win64", dirs_exist_ok=True, copy_function=copy_changed)
        print(f"Editor module ready. Open: {source / f'{mod_name}.uproject'}")
    elif result.returncode == 0 and stage in ("create", "create-controls", "create-api", "update-api", "version-api"):
        if stage == "version-api":
            folder = Path("Content/Mods/ModConfigUI/Blueprint")
            for name in ("ST_MCUOptionV1", "ST_MCUFieldV1", "BP_MCUConfigComponent"):
                shutil.copy2(work / folder / (name + ".uasset"), source / folder / (name + ".uasset"))
            for name in ("ST_MCUOption", "ST_MCUField"):
                for base in (source, work):
                    (base / folder / (name + ".uasset")).unlink(missing_ok=True)
        elif stage == "create-controls":
            relative = "Content/Mods/ModConfigUI/W_ControlEvents.uasset"
            shutil.copy2(work / relative, source / relative)
        elif stage == "update-api":
            relative = "Content/Mods/ModConfigUI/Blueprint/BP_MCUConfigComponent.uasset"
            shutil.copy2(work / relative, source / relative)
        elif stage == "create-api":
            shutil.copytree(work / "Content/Mods/ModConfigUI/Blueprint", source / "Content/Mods/ModConfigUI/Blueprint", dirs_exist_ok=True)
        elif mod_name != "ModConfigUI":
            shutil.copytree(work / f"Content/Mods/{mod_name}", source / f"Content/Mods/{mod_name}", dirs_exist_ok=True)
        else:
            for name in (asset_name, "W_KeyCapture"):
                editable = source / f"Content/Mods/ModConfigUI/{name}.uasset"
                editable.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(work / f"Content/Mods/ModConfigUI/{name}.uasset", editable)
        print("Replaced the source Blueprint as explicitly requested; inspect and commit its changes.")
    if stage != "version-api":
        check_frozen_sdk()
    return result.returncode


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        sys.exit(main())
    except Exception as error:
        print(f"MCU build failed: {error}", file=sys.stderr)
        sys.exit(1)
