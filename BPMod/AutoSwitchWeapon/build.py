"""UE 5.7.4 authoring and IoStore build.

Before opening AutoSwitchWeapon.uproject, run: python build.py editor-build-source
Build from editable assets: editor-build, cook, iostore, pak, verify, publish.
To replace the editable Blueprint from code: create --overwrite-blueprint.
All build intermediates stay in _temp; editor-build-source installs the compiled
editor modules in the ignored Binaries folder beside the editable project.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source = Path(__file__).resolve().parent
project = source.parents[1]
work = project / "_temp/AutoSwitchWeapon"
engine = Path("E:/UE_5.7/Engine")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("editor-build-source", "editor-build", "create", "cook", "iostore", "pak", "verify", "publish"))
    parser.add_argument("--overwrite-blueprint", action="store_true",
                        help="Explicitly replace the editable Blueprint, losing manual graph edits")
    options = parser.parse_args()
    stage = options.stage
    editable = source / "Content/Mods/AutoSwitchWeapon/ModActor.uasset"
    if stage == "create" and editable.exists() and not options.overwrite_blueprint:
        raise RuntimeError("create replaces the editable Blueprint and manual graph edits; explicitly pass --overwrite-blueprint")
    work.mkdir(parents=True, exist_ok=True)
    for name in ("Source", "Config", "Content"):
        shutil.copytree(source / name, work / name, dirs_exist_ok=True)
    descriptor = json.loads((source / "AutoSwitchWeapon.uproject").read_text(encoding="utf-8"))
    if stage not in ("editor-build", "editor-build-source"):
        descriptor["DisableEnginePluginsByDefault"] = True
    (work / "AutoSwitchWeapon.uproject").write_text(json.dumps(descriptor, indent=2) + "\n", encoding="utf-8")
    env = os.environ.copy()
    for name, directory in (("TEMP", "Temp"), ("TMP", "Temp"),
                            ("UE-LocalDataCachePath", "DerivedDataCache"),
                            ("LOCALAPPDATA", "BuildUser/Local"), ("APPDATA", "BuildUser/Roaming"),
                            ("DOTNET_CLI_HOME", "BuildUser/DotNet"), ("NUGET_PACKAGES", "BuildUser/NuGet")):
        path = work / directory
        path.mkdir(parents=True, exist_ok=True)
        env[name] = str(path)
    env.update(PYTHONDONTWRITEBYTECODE="1", DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1")
    env["UE-SharedDataCachePath"] = "None"
    for name in ("Logs", "Config", "Settings", "Shaders", "Content", "IoStore"):
        (work / name).mkdir(exist_ok=True)
    (work / "Config/DefaultEngine.ini").write_text(f'''[ASWDDC]
Root=(Type=KeyLength,Length=120,Inner=AsyncPut)
AsyncPut=(Type=AsyncPut,Inner=Local)
Local=(Type=FileSystem,Path="{(work / 'DerivedDataCache').as_posix()}",DeleteUnused=false)

[/Script/EngineSettings.GameMapsSettings]
EditorStartupMap=
GameDefaultMap=
ServerDefaultMap=

[/Script/UnrealEd.ProjectPackagingSettings]
bUseIoStore=True
bShareMaterialShaderCode=False

[/Script/Engine.RendererSettings]
r.RayTracing=False

[Zen.AutoLaunch]
DataPath={(work / 'Zen').as_posix()}
''', encoding="utf-8")
    common = ["-unattended", "-nop4", "-nosplash", "-nullrhi", "-nosound", "-NoLiveCoding",
              "-NoEpicPortal", "-NoCrashDialog", "-NoZenAutoLaunch", "-notraceserver", "-ddc=ASWDDC",
              "-stdout", "-FullStdOutLogOutput", f"-userdir={work.as_posix()}",
              f"-ShaderWorkingDir={(work / 'Shaders').as_posix()}",
              f"-abslog={(work / 'Logs' / (stage + '.log')).as_posix()}",
              f"-abscrashreportclientlog={(work / 'Logs' / (stage + '-crashclient.log')).as_posix()}"]
    for name in ("EditorSettings", "EditorKeyBindings", "EditorLayout"):
        common.append(f"-{name}INI={(work / 'Settings' / (name + '.ini')).as_posix()}")
    editor = str(engine / "Binaries/Win64/UnrealEditor-Cmd.exe")
    pak = str(engine / "Binaries/Win64/UnrealPak.exe")
    uproject = str(work / "AutoSwitchWeapon.uproject")
    if stage in ("editor-build", "editor-build-source"):
        args = [str(engine / "Binaries/ThirdParty/DotNet/8.0.412/win-x64/dotnet.exe"),
                str(engine / "Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.dll"),
                "AutoSwitchWeaponEditor", "Win64", "Development", f"-Project={uproject}",
                "-NoHotReloadFromIDE", "-NoEngineChanges", "-NoUBA", "-NoUBALocal", "-NoXGE", "-NoFASTBuild",
                f"-Log={work / 'Logs/editor-build-ubt.log'}"]
    elif stage == "create":
        # Rebuild from the graph generator, not a partially loaded previous package.
        (work / "Content/Mods/AutoSwitchWeapon/ModActor.uasset").unlink(missing_ok=True)
        args = [editor, uproject, "-run=AutoSwitchWeaponBuild"] + common
    elif stage == "cook":
        args = [editor, uproject, "-run=cook", "-TargetPlatform=Windows", "-CookSinglePackageNoRefs",
                "-CookSkipRequests", "-NoDefaultMaps", "-NoGameAlwaysCookPackages", "-Unversioned",
                "-NoShaderCompile", "-PACKAGE=/Game/Mods/AutoSwitchWeapon/ModActor"] + common
    elif stage == "iostore":
        cooked = work / "Saved/Cooked/Windows"
        metadata = cooked / "AutoSwitchWeapon/Metadata"
        asset = cooked / "AutoSwitchWeapon/Content/Mods/AutoSwitchWeapon/ModActor.uasset"
        if not asset.is_file():
            raise RuntimeError("Cooked ModActor missing")
        response = work / "iostore-files.txt"
        response.write_text(f'"{asset.as_posix()}" "../../../ProjectPBZ/Content/Mods/AutoSwitchWeapon/ModActor.uasset"\n', encoding="utf-8")
        commands = work / "iostore-commands.txt"
        commands.write_text(f'-Output="{(work / "IoStore/AutoSwitchWeapon.utoc").as_posix()}" -ContainerName=AutoSwitchWeapon -ResponseFile="{response.as_posix()}"\n', encoding="utf-8")
        args = [pak, "IoStore", f"-CreateGlobalContainer={(work / 'IoStore/global.utoc').as_posix()}",
                f"-CookedDirectory={cooked.as_posix()}", f"-PackageStoreManifest={(metadata / 'packagestore.manifest').as_posix()}",
                f"-ScriptObjects={(metadata / 'scriptobjects.bin').as_posix()}",
                f"-Commands={commands.as_posix()}", "-TargetPlatform=Windows"] + common
    elif stage == "pak":
        response = work / "pak-files.txt"
        response.write_text("", encoding="utf-8")
        args = [pak, str(work / "IoStore/AutoSwitchWeapon.pak"), f"-Create={response.as_posix()}"] + common
    elif stage == "verify":
        args = [pak, "IoStore", f"-List={(work / 'IoStore/AutoSwitchWeapon.utoc').as_posix()}",
                f"-CSV={(work / 'Logs/iostore-list.csv').as_posix()}"] + common
    elif stage == "publish":
        destination = project / "AutoSwitchWeapon/ProjectPBZ/Content/Paks/LogicMods"
        destination.mkdir(parents=True, exist_ok=True)
        for extension in ("pak", "utoc", "ucas"):
            artifact = work / f"IoStore/AutoSwitchWeapon.{extension}"
            if not artifact.is_file() or artifact.stat().st_size == 0:
                raise RuntimeError(f"Missing container: {artifact}")
            shutil.copy2(artifact, destination / artifact.name)
        print("Published only AutoSwitchWeapon.pak/.utoc/.ucas; global containers and authoring DLLs excluded.")
        return 0
    else:
        raise ValueError("Stage: editor-build, create, cook, iostore, pak, verify, publish")
    log = work / "Logs" / f"{stage}-stdout.log"
    print(f"Running {stage}; output: {log}", flush=True)
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(args, cwd=work, env=env, stdout=output, stderr=subprocess.STDOUT)
    print(log.read_text(encoding="utf-8", errors="replace")[-6000:])
    print("Exit code:", result.returncode)
    if stage == "editor-build-source" and result.returncode == 0:
        built = work / "Binaries/Win64"
        manifest = json.loads((built / "UnrealEditor.modules").read_text(encoding="utf-8"))
        engine_manifest = json.loads((engine / "Binaries/Win64/UnrealEditor.modules").read_text(encoding="utf-8"))
        expected = {module["Name"] for module in descriptor["Modules"]}
        if manifest["BuildId"] != engine_manifest["BuildId"] or set(manifest["Modules"]) != expected:
            raise RuntimeError("Compiled editor module manifest does not match this project/engine")
        files = ["UnrealEditor.modules", "AutoSwitchWeaponEditor.target"]
        for module in manifest["Modules"].values():
            files.extend((module, str(Path(module).with_suffix(".pdb"))))
        for name in files:
            if not (built / name).is_file():
                raise RuntimeError(f"Missing compiled editor file: {name}")
        destination = source / "Binaries/Win64"
        destination.mkdir(parents=True, exist_ok=True)
        for name in files:
            shutil.copy2(built / name, destination / name)
        print(f"Installed {len(expected)} editor modules for UE BuildId {manifest['BuildId']} in {destination}")
        print(f"Ready to open: {source / 'AutoSwitchWeapon.uproject'}")
    if stage == "create" and result.returncode == 0:
        editable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(work / "Content/Mods/AutoSwitchWeapon/ModActor.uasset", editable)
        print("Updated editable Blueprint from generator (manual graph edits replaced).")
    return result.returncode


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.exit(main())
    except Exception as exc:
        print(f"AutoSwitchWeapon build failed: {exc}", file=sys.stderr)
        sys.exit(1)
