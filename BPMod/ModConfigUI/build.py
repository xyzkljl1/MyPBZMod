"""Run stages: editor-build, create, cook, iostore, pak, verify, publish.

Requires UE 5.7.4 (UE_ROOT may override E:/UE_5.7) and its supported C++ toolchain.
The editor module generates a pure Blueprint; no native DLL is shipped.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

source = Path(__file__).resolve().parent
project = source.parents[1]
work = project / "_temp/mcu-blueprint-build"
engine = Path(os.environ.get("UE_ROOT", "E:/UE_5.7")) / "Engine"
asset_name = "W_TextInputBridge"
asset_path = f"/Game/Mods/ModConfigUI/{asset_name}"


def main():
    stage = sys.argv[1]
    work.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source / "Source", work / "Source", dirs_exist_ok=True)
    shutil.copy2(source / "ProjectPBZ.uproject", work / "ProjectPBZ.uproject")
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
    (work / "Config/DefaultEngine.ini").write_text(f'''[MCUBuildDDC]
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
    uproject = str(work / "ProjectPBZ.uproject")
    if stage == "editor-build":
        args = [str(engine / "Binaries/ThirdParty/DotNet/8.0.412/win-x64/dotnet.exe"),
                str(engine / "Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.dll"),
                "ProjectPBZEditor", "Win64", "Development", f"-Project={uproject}",
                "-WaitMutex", "-NoHotReloadFromIDE", "-NoEngineChanges", "-NoUBA", "-NoUBALocal", "-NoXGE", "-NoFASTBuild",
                f"-Log={work / 'Logs/editor-build-ubt.log'}"]
    elif stage == "create":
        args = [editor, uproject, "-run=MCUBridgeBuild"] + common
    elif stage == "cook":
        args = [editor, uproject, "-run=cook", "-TargetPlatform=Windows", "-CookSinglePackageNoRefs",
                "-CookSkipRequests", "-NoDefaultMaps", "-NoGameAlwaysCookPackages", "-Unversioned",
                "-NoShaderCompile", f"-PACKAGE={asset_path}"] + common
    elif stage == "iostore":
        cooked = work / "Saved/Cooked/Windows"
        metadata = cooked / "ProjectPBZ/Metadata"
        relative = f"ProjectPBZ/Content/Mods/ModConfigUI/{asset_name}.uasset"
        response = work / "iostore-files.txt"
        response.write_text(f'"{(cooked / relative).as_posix()}" "../../../{relative}"\n', encoding="utf-8")
        commands = work / "iostore-commands.txt"
        commands.write_text(f'-Output="{(work / "IoStore/ModConfigUI.utoc").as_posix()}" -ContainerName=ModConfigUI -ResponseFile="{response.as_posix()}"\n', encoding="utf-8")
        args = [pak, "IoStore", f"-CreateGlobalContainer={(work / 'IoStore/global.utoc').as_posix()}",
                f"-CookedDirectory={cooked.as_posix()}",
                f"-PackageStoreManifest={(metadata / 'packagestore.manifest').as_posix()}",
                f"-ScriptObjects={(metadata / 'scriptobjects.bin').as_posix()}",
                f"-Commands={commands.as_posix()}", "-TargetPlatform=Windows"] + common
    elif stage == "pak":
        response = work / "pak-files.txt"
        response.write_text("", encoding="utf-8")
        output = work / "IoStore/ModConfigUI.pak"
        output.unlink(missing_ok=True)
        args = [pak, str(output), f"-Create={response.as_posix()}"] + common
    elif stage == "verify":
        args = [pak, "IoStore", f"-List={(work / 'IoStore/ModConfigUI.utoc').as_posix()}",
                f"-CSV={(work / 'Logs/iostore-list.csv').as_posix()}"] + common
    elif stage == "publish":
        files = [work / f"IoStore/ModConfigUI.{ext}" for ext in ("pak", "utoc", "ucas")]
        if any(not path.is_file() or not path.stat().st_size for path in files):
            raise RuntimeError("Build the three containers before publishing")
        destination = project / "ModConfigUI/ProjectPBZ/Content/Paks/LogicMods"
        destination.mkdir(parents=True, exist_ok=True)
        for path in files:
            shutil.copy2(path, destination / path.name)
        editable = source / f"Content/Mods/ModConfigUI/{asset_name}.uasset"
        editable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(work / f"Content/Mods/ModConfigUI/{asset_name}.uasset", editable)
        print("Published MCU containers and editable source asset; no global container or editor DLL.")
        return 0
    else:
        raise ValueError("Stage: editor-build, create, cook, iostore, pak, verify, publish")
    log = work / "Logs" / f"{stage}-stdout.log"
    print(f"Running {stage}; log: {log}", flush=True)
    with log.open("w", encoding="utf-8") as stream:
        result = subprocess.run(args, cwd=work, env=env, stdout=stream, stderr=subprocess.STDOUT)
    print(log.read_text(encoding="utf-8", errors="replace")[-2600:])
    return result.returncode


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        sys.exit(main())
    except Exception as error:
        print(f"MCU build failed: {error}", file=sys.stderr)
        sys.exit(1)
