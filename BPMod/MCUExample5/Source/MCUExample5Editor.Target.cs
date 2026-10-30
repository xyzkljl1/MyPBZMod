using UnrealBuildTool;
public class MCUExample5EditorTarget : TargetRules {
    public MCUExample5EditorTarget(TargetInfo Target) : base(Target) {
        Type = TargetType.Editor;
        DefaultBuildSettings = BuildSettingsVersion.V6;
        IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_7;
        ExtraModuleNames.Add("MCUExample5Editor");
    }
}
