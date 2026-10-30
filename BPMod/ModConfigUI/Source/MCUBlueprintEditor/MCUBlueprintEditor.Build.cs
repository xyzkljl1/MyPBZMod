using UnrealBuildTool;
public class MCUBlueprintEditor : ModuleRules
{
    public MCUBlueprintEditor(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PrivateDependencyModuleNames.AddRange(new string[] {
            "Core", "CoreUObject", "Engine", "UnrealEd", "BlueprintGraph",
            "KismetCompiler", "UMG", "UMGEditor", "Slate", "SlateCore"
        });
    }
}
