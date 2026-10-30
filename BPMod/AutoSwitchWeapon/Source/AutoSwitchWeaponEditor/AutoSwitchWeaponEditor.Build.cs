using UnrealBuildTool;
public class AutoSwitchWeaponEditor : ModuleRules
{
    public AutoSwitchWeaponEditor(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PrivateDependencyModuleNames.AddRange(new[] {
            "Core", "CoreUObject", "Engine", "UnrealEd", "BlueprintGraph", "KismetCompiler",
            "GameplayAbilities", "GameplayTags", "GameplayTasks", "EnhancedInput", "InputCore",
            "CharacterBasics", "SGameCombatSystem", "SGameActorState", "ProjectPBZ",
            "UMG", "CommonUI", "Json", "JsonUtilities", "JsonBlueprintUtilities"
        });
    }
}
