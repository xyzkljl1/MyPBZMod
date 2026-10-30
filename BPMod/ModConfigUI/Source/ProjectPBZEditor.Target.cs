using UnrealBuildTool;
using System.Collections.Generic;
public class ProjectPBZEditorTarget : TargetRules
{
    public ProjectPBZEditorTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Editor;
        DefaultBuildSettings = BuildSettingsVersion.V6;
        IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_7;
        ExtraModuleNames.Add("MCUBlueprintEditor");
    }
}
