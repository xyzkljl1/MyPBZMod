using UnrealBuildTool;
using System.IO;
public class MCUExample5Editor : ModuleRules {
    public MCUExample5Editor(ReadOnlyTargetRules Target) : base(Target) {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PrivateDependencyModuleNames.AddRange(new string[] {
            "Core", "CoreUObject", "Engine", "UnrealEd", "BlueprintGraph", "KismetCompiler", "InputCore"
        });
        PrivateIncludePaths.Add(Path.GetFullPath(Path.Combine(ModuleDirectory,
            "../../../ModConfigUI/Source/MCUBlueprintEditor")));
    }
}
