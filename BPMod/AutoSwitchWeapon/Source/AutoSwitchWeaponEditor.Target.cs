using UnrealBuildTool;
public class AutoSwitchWeaponEditorTarget : TargetRules
{
    public AutoSwitchWeaponEditorTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Editor;
        DefaultBuildSettings = BuildSettingsVersion.V6;
        IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_7;
        ExtraModuleNames.AddRange(new[] { "CharacterBasics", "SGameCombatSystem", "SGameActorState", "AutoSwitchWeaponEditor" });
    }
}
