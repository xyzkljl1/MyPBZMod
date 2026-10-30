#include "MCUBlueprintAPIBuildCommandlet.h"
#include "BlueprintBuildUtils.h"
#include "Components/ActorComponent.h"
#include "K2Node_CustomEvent.h"
#include "Misc/Parse.h"
using namespace MCUBuilder;
namespace {
bool SetFlag(UBlueprint* BP, FName FunctionName, FName Flag, FName Notification) {
    const auto Graphs = BP->FunctionGraphs;
    for (UEdGraph* Graph : Graphs) {
        if (Graph->GetFName() == FunctionName) FBlueprintEditorUtils::RemoveGraph(BP, Graph);
    }
    auto* Entry = Function(BP, FunctionName);
    if (!Entry) return false;
    auto* SetNode = Set(Entry->GetGraph(), Flag);
    auto* Value = SetNode->FindPin(Flag);
    if (!Value) return false;
    Value->DefaultValue = "true";
    auto* Call = Node<UK2Node_CallFunction>(Entry->GetGraph());
    Call->FunctionReference.SetSelfMember(Notification); Call->AllocateDefaultPins();
    return Link(Entry->FindPin(UEdGraphSchema_K2::PN_Then), SetNode->FindPin(UEdGraphSchema_K2::PN_Execute))
        && Link(SetNode->FindPin(UEdGraphSchema_K2::PN_Then), Call->FindPin(UEdGraphSchema_K2::PN_Execute));
}
bool Lifecycle(UBlueprint* BP) {
    UEdGraph* Graph = BP->UbergraphPages[0];
    for (FName Name : {FName("MCU_Config_Init"), FName("MCU_Config_Release")}) {
        bool Found = false;
        for (UEdGraphNode* N : Graph->Nodes) {
            auto* Event = Cast<UK2Node_CustomEvent>(N);
            if (Event && Event->CustomFunctionName == Name) { Found = true; break; }
        }
        if (!Found) {
            auto* Event = Node<UK2Node_CustomEvent>(Graph);
            Event->CustomFunctionName = Name; Event->AllocateDefaultPins();
        }
    }
    // Compile event signatures before creating calls to them.
    return Compile(BP)
        && SetFlag(BP, "InitFromFile", "Requested", "MCU_Config_Init")
        && SetFlag(BP, "Release", "Ending", "MCU_Config_Release") && Compile(BP);
}
bool EventCalls(UBlueprint* BP, FName EventName, FName FunctionName) {
    UEdGraph* Graph = BP->UbergraphPages[0];
    auto* Event = Node<UK2Node_Event>(Graph);
    Event->EventReference.SetExternalMember(EventName, UActorComponent::StaticClass());
    Event->bOverrideFunction = true; Event->AllocateDefaultPins();
    auto* Call = Node<UK2Node_CallFunction>(Graph);
    Call->FunctionReference.SetSelfMember(FunctionName); Call->AllocateDefaultPins();
    return Link(Event->FindPin(UEdGraphSchema_K2::PN_Then), Call->FindPin(UEdGraphSchema_K2::PN_Execute));
}
}
int32 UMCUBlueprintAPIBuildCommandlet::Main(const FString& Params) {
    if (!FParse::Param(*Params, TEXT("OverwriteGeneratedAssets"))) {
        UE_LOG(LogTemp, Error, TEXT("Regeneration overwrites the Blueprint SDK; pass -OverwriteGeneratedAssets explicitly.")); return 1;
    }
    const FString Root = "/Game/Mods/ModConfigUI/Blueprint/";
    if (FParse::Param(*Params, TEXT("VersionStructs"))) {
        auto* BP = LoadObject<UBlueprint>(nullptr, *(Root + "BP_MCUConfigComponent.BP_MCUConfigComponent"));
        auto* Option = LoadObject<UUserDefinedStruct>(nullptr, *(Root + "ST_MCUOption.ST_MCUOption"));
        auto* Description = LoadObject<UUserDefinedStruct>(nullptr, *(Root + "ST_MCUField.ST_MCUField"));
        if (!BP || !Option || !Description) return 12;
        for (auto* Struct : {Option, Description}) {
            const FString Name = Struct->GetName() + "V1";
            const FString Package = Root + Name;
            if (FPackageName::DoesPackageExist(Package)) return 13;
            if (!Struct->Rename(*Name, CreatePackage(*Package), REN_DontCreateRedirectors | REN_NonTransactional)) return 14;
        }
        // Move the existing objects; member GUIDs and loaded references stay intact.
        if (!Compile(BP) || !Save(Option) || !Save(Description) || !Save(BP)) return 15;
        UE_LOG(LogTemp, Display, TEXT("MCU_STRUCTS_VERSIONED: existing structs moved to V1 without regeneration"));
        return 0;
    }
    if (FParse::Param(*Params, TEXT("UpdateLifecycleOnly"))) {
        auto* BP = LoadObject<UBlueprint>(nullptr, *(Root + "BP_MCUConfigComponent.BP_MCUConfigComponent"));
        if (!BP || !Lifecycle(BP) || !Save(BP)) return 11;
        UE_LOG(LogTemp, Display, TEXT("MCU_BLUEPRINT_LIFECYCLE_UPDATED: name-based events; schema structs unchanged"));
        return 0;
    }
    if (FPackageName::DoesPackageExist(Root + "ST_MCUFieldV1")
        || FPackageName::DoesPackageExist(Root + "ST_MCUOptionV1")) {
        UE_LOG(LogTemp, Error, TEXT("V1 SDK structs are frozen. Use saved assets; create a new version for structural changes."));
        return 16;
    }
    const auto String = Type(UEdGraphSchema_K2::PC_String);
    const auto Bool = Type(UEdGraphSchema_K2::PC_Boolean);
    const auto Int = Type(UEdGraphSchema_K2::PC_Int);
    const auto Double = Type(UEdGraphSchema_K2::PC_Real, UEdGraphSchema_K2::PC_Double);
    auto* Option = NewStruct(Root + "ST_MCUOptionV1", "ST_MCUOptionV1");
    if (!Option || !Field(Option, "Label", String) || !Field(Option, "IntValue", Int)
        || !Field(Option, "FloatValue", Double) || !Field(Option, "TextValue", String)) return 2;
    auto* Description = NewStruct(Root + "ST_MCUFieldV1", "ST_MCUFieldV1");
    if (!Description) return 3;
    for (const FString Name : {"Key", "Type", "Label", "Description", "Pattern"})
        if (!Field(Description, Name, String)) return 4;
    if (!Field(Description, "UseMin", Bool) || !Field(Description, "Min", Double)
        || !Field(Description, "UseMax", Bool) || !Field(Description, "Max", Double)
        || !Field(Description, "Step", Double, "1")
        || !Field(Description, "MinLength", Int, "-1") || !Field(Description, "MaxLength", Int, "-1")
        || !Field(Description, "Options", StructType(Option, true))) return 5;
    auto* BP = FKismetEditorUtilities::CreateBlueprint(UActorComponent::StaticClass(),
        CreatePackage(*(Root + "BP_MCUConfigComponent")), "BP_MCUConfigComponent", BPTYPE_Normal);
    if (!BP) return 6;
    FBlueprintEditorUtils::AddMemberVariable(BP, "Fields", StructType(Description, true));
    FBlueprintEditorUtils::SetBlueprintOnlyEditableFlag(BP, "Fields", false);
    for (FName Flag : {FName("Requested"), FName("Ending"), FName("IsReady")})
        FBlueprintEditorUtils::AddMemberVariable(BP, Flag, Bool);
    FBlueprintEditorUtils::AddMemberVariable(BP, "Error", String);
    auto* Print = Function(BP, "PrintMessage");
    if (!Print) return 7;
    Print->CreateUserDefinedPin("Message", String, EGPD_Output);
    if (!Lifecycle(BP)) return 7;
    if (!EventCalls(BP, "ReceiveBeginPlay", "InitFromFile") || !EventCalls(BP, "ReceiveEndPlay", "Release") || !Compile(BP)) return 8;
    auto* CDO = Cast<UActorComponent>(BP->GeneratedClass->GetDefaultObject());
    if (!CDO) return 9;
    CDO->PrimaryComponentTick.bCanEverTick = false;
    if (!Save(Option) || !Save(Description) || !Save(BP)) return 10;
    UE_LOG(LogTemp, Display, TEXT("MCU_BLUEPRINT_API_CREATED: typed schema metadata and lifecycle component, no runtime native module"));
    return 0;
}
