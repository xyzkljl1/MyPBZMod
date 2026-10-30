"""Build the editable example and reuse MCU's container build pipeline."""
from pathlib import Path
import runpy
import shutil
import sys

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        source = Path(__file__).resolve().parent
        sdk = source.parent / "ModConfigUI"
        root = source.parents[1] / "_temp/mcu-example5-build"
        assets = sdk / "Content/Mods/ModConfigUI/Blueprint"
        if not assets.is_dir():
            raise RuntimeError("Generate the MCU Blueprint SDK first")
        builder = runpy.run_path(str(sdk / "build.py"))
        # Reference copies keep this project editable. They are never packaged twice.
        shutil.copytree(assets, source / "Content/Mods/ModConfigUI/Blueprint", dirs_exist_ok=True,
                        copy_function=builder["copy_changed"])
        helper = root / "ModConfigUI/Source/MCUBlueprintEditor"
        helper.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sdk / "Source/MCUBlueprintEditor/BlueprintBuildUtils.h", helper)
        main = builder["main"]
        main.__globals__.update(source=source, build_root=root, mod_name="MCUExample5",
                                module_name="MCUExample5Editor", create_commandlet="MCUExampleBuild")
        sys.exit(main())
    except Exception as error:
        print(f"MCUExample5 build failed: {error}", file=sys.stderr)
        sys.exit(1)
