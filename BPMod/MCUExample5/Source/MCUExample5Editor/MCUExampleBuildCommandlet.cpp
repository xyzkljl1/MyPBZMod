#include "MCUExampleBuildCommandlet.h"
#include "BlueprintBuildUtils.h"
#include "Components/ActorComponent.h"
#include "Engine/SCS_Node.h"
#include "Engine/SimpleConstructionScript.h"
#include "GameFramework/Actor.h"
#include "K2Node_BreakStruct.h"
#include "K2Node_SwitchString.h"
#include "Kismet/KismetStringLibrary.h"
#include "Kismet/KismetSystemLibrary.h"
#include "Misc/Parse.h"
#include "InputCoreTypes.h"
#include "Kismet/KismetInputLibrary.h"
#include "Kismet/KismetTextLibrary.h"
#include "Modules/ModuleManager.h"
IMPLEMENT_MODULE(FDefaultModuleImpl, MCUExample5Editor)
using namespace MCUBuilder;
namespace {
struct Setting { const char* Key; const char* Type; const char* Label; const char* Description; const char* Default; };
const Setting Settings[] = {
    {"ColorOptionExample", "ColorBox", "Color preview", "Enter #RRGGBB. Valid colors preview immediately; commit to save.", "#FF8800"},
    {"KeyOptionExample", "BPKey", "Key binding", "Click and press one keyboard or mouse button. Esc cancels.", "F8"},
    {"BoolOptionExample", "BoolToggle", "Boolean toggle", "Enable or disable this example option.", "True"},
    {"IntOptionExample", "IntBox", "Integer input", "Enter an integer from 0 to 100.", "12"},
    {"FloatOptionExample", "FloatBox", "Floating-point input", "Enter a number from 0 to 10.", "0.3"},
    {"IntSliderExample", "IntSlider", "Integer slider", "Drag to select an integer from 0 to 100 in steps of 5.", "40"},
    {"FloatSliderExample", "FloatSlider", "Floating-point slider", "Drag to select a number from 0 to 1 in steps of 0.1.", "0.3"},
    {"TextOptionExample", "TextBox", "Text input", "Enter 1 to 40 characters. Press Enter or leave the input to commit.", "Hello MCU"},
    {"IntSelectExample", "IntSelect", "Integer choice", "The saved value is an integer, not the option's position.", "2"},
    {"FloatSelectExample", "FloatSelect", "Floating-point choice", "The saved value is a double, not the option's label.", "0.5"},
    {"TextSelectExample", "TextSelect", "Text choice", "The saved value is a string, independent of the displayed label.", "normal"},
};
FEdGraphPinType ValueType(const FString& Kind) {
    if (Kind == "BPKey") return StructType(TBaseStructure<FKey>::Get());
    if (Kind == "BoolToggle") return Type(UEdGraphSchema_K2::PC_Boolean);
    if (Kind.StartsWith("Int")) return Type(UEdGraphSchema_K2::PC_Int);
    if (Kind.StartsWith("Float")) return Type(UEdGraphSchema_K2::PC_Real, UEdGraphSchema_K2::PC_Double);
    return Type(UEdGraphSchema_K2::PC_String);
}
FProperty* Property(UScriptStruct* S, const FString& Key) {
    auto* User = Cast<UUserDefinedStruct>(S);
    if (!User) return nullptr;
    for (const auto& V : FStructureEditorUtils::GetVarDesc(User))
        if (V.FriendlyName == Key) return S->FindPropertyByName(V.VarName);
    return nullptr;
}
bool Put(UScriptStruct* S, void* Data, const FString& Key, const FString& Value) {
    auto* P = Property(S, Key);
    if (!P) return false;
    void* Address = P->ContainerPtrToValuePtr<void>(Data);
    const TCHAR* End = P->ImportText_Direct(*Value, Address, nullptr, PPF_None);
    if (!End || *End != '\0') return false;
    auto* Struct = CastField<FStructProperty>(P);
    return !Struct || Struct->Struct != TBaseStructure<FKey>::Get()
        || (static_cast<FKey*>(Address)->IsValid() && static_cast<FKey*>(Address)->GetFName() == FName(*Value));
}
UK2Node_CallFunction* Call(UEdGraph* G, UClass* C, FName Name) {
    auto* N = Node<UK2Node_CallFunction>(G); N->FunctionReference.SetExternalMember(Name, C); N->AllocateDefaultPins(); return N;
}
bool PrintValue(UEdGraph* G, UEdGraphPin*& Exec, UEdGraphPin* Value, const FString& Prefix, const FString& Kind) {
    if (Kind == "BPKey") {
        auto* Display = Call(G, UKismetInputLibrary::StaticClass(), "Key_GetDisplayName");
        if (!Link(Value, Display->FindPin(FName("Key")))) return false;
        auto* Convert = Call(G, UKismetTextLibrary::StaticClass(), "Conv_TextToString");
        if (!Link(Display->FindPin(UEdGraphSchema_K2::PN_ReturnValue), Convert->FindPin(FName("InText")))) return false;
        Value = Convert->FindPin(UEdGraphSchema_K2::PN_ReturnValue);
    } else if (Kind != "ColorBox" && !Kind.StartsWith("Text")) {
        const FName Convert = Kind == "BoolToggle" ? "Conv_BoolToString" : Kind.StartsWith("Int") ? "Conv_IntToString" : "Conv_DoubleToString";
        auto* ToString = Call(G, UKismetStringLibrary::StaticClass(), Convert);
        const FName Input = Kind == "BoolToggle" ? "InBool" : Kind.StartsWith("Int") ? "InInt" : "InDouble";
        if (!Link(Value, ToString->FindPin(Input))) return false;
        Value = ToString->FindPin(UEdGraphSchema_K2::PN_ReturnValue);
    }
    auto* Append = Call(G, UKismetStringLibrary::StaticClass(), "Concat_StrStr");
    auto* A = Append->FindPin(FName("A"));
    if (!A) return false;
    A->DefaultValue = Prefix;
    if (!Link(Value, Append->FindPin(FName("B")))) return false;
    auto* Print = Node<UK2Node_CallFunction>(G);
    Print->FunctionReference.SetSelfMember("PrintToModLoader");
    Print->AllocateDefaultPins();
    if (!Link(Exec, Print->FindPin(UEdGraphSchema_K2::PN_Execute))
        || !Link(Append->FindPin(UEdGraphSchema_K2::PN_ReturnValue), Print->FindPin(FName("Message")))) return false;
    Exec = Print->FindPin(UEdGraphSchema_K2::PN_Then);
    return true;
}
bool PrintFunction(UBlueprint* BP, UUserDefinedStruct* Config, FName Name, bool Changed, bool Button) {
    auto* Entry = Function(BP, Name);
    if (!Entry) return false;
    auto* G = Entry->GetGraph();
    UEdGraphPin* Exec = Entry->FindPin(UEdGraphSchema_K2::PN_Then);
    if (Button) {
        auto* Key = Entry->CreateUserDefinedPin("Key", Type(UEdGraphSchema_K2::PC_String), EGPD_Output);
        if (!PrintValue(G, Exec, Key, "Button: ", "TextBox")) return false;
    }
    UK2Node_SwitchString* Selection = nullptr;
    if (Changed) {
        auto* Key = Entry->CreateUserDefinedPin("Key", Type(UEdGraphSchema_K2::PC_String), EGPD_Output);
        Selection = Node<UK2Node_SwitchString>(G);
        for (const auto& S : Settings) Selection->PinNames.Add(FName(S.Key));
        Selection->AllocateDefaultPins();
        if (!Link(Exec, Selection->FindPin(UEdGraphSchema_K2::PN_Execute))
            || !Link(Key, Selection->FindPin(FName("Selection")))) return false;
    }
    auto* Current = Get(G, "Config");
    auto* Break = Node<UK2Node_BreakStruct>(G); Break->StructType = Config; Break->AllocateDefaultPins();
    if (!Link(Current->FindPin(FName("Config")), Break->FindPin(Config->GetFName()))) return false;
    for (const auto& S : Settings) {
        if (Selection) Exec = Selection->FindPin(FName(S.Key));
        if (!PrintValue(G, Exec, Break->FindPin(Property(Config, S.Key)->GetFName()),
            Name.ToString() + " " + S.Key + " = ", S.Type)) return false;
    }
    // Keep the graph readable when opened in the editor.
    int32 Index = 0;
    for (UEdGraphNode* N : G->Nodes) { N->NodePosX = (Index % 4) * 430; N->NodePosY = (Index / 4) * 220; ++Index; }
    return true;
}
bool SetFields(UActorComponent* Component) {
    auto* Array = FindFProperty<FArrayProperty>(Component->GetClass(), "Fields");
    auto* Inner = Array ? CastField<FStructProperty>(Array->Inner) : nullptr;
    if (!Inner) return false;
    FScriptArrayHelper List(Array, Array->ContainerPtrToValuePtr<void>(Component));
    List.EmptyValues();
    auto Add = [&](const char* Key, const char* Type, const char* Label, const char* Description) {
        void* Row = List.GetRawPtr(List.AddValue());
        Put(Inner->Struct, Row, "Key", Key); Put(Inner->Struct, Row, "Type", Type);
        Put(Inner->Struct, Row, "Label", Label); Put(Inner->Struct, Row, "Description", Description);
        Put(Inner->Struct, Row, "MinLength", "-1"); Put(Inner->Struct, Row, "MaxLength", "-1");
        return Row;
    };
    Add("Basics", "Separator", "Blueprint configuration", "");
    for (const auto& S : Settings) {
        void* Row = Add(S.Key, S.Type, S.Label, S.Description);
        const FString Kind = S.Type;
        if (Kind == "IntBox" || Kind == "FloatBox" || Kind.EndsWith("Slider")) {
            Put(Inner->Struct, Row, "UseMin", "True"); Put(Inner->Struct, Row, "Min", "0");
            Put(Inner->Struct, Row, "UseMax", "True");
            Put(Inner->Struct, Row, "Max", Kind.StartsWith("Int") ? "100" : Kind == "FloatBox" ? "10" : "1");
            Put(Inner->Struct, Row, "Step", Kind.StartsWith("Int") ? "5" : "0.1");
        } else if (Kind == "TextBox") {
            Put(Inner->Struct, Row, "MinLength", "1"); Put(Inner->Struct, Row, "MaxLength", "40");
        } else if (Kind.EndsWith("Select")) {
            auto* Options = CastField<FArrayProperty>(Property(Inner->Struct, "Options"));
            auto* Option = Options ? CastField<FStructProperty>(Options->Inner) : nullptr;
            if (!Option) return false;
            FScriptArrayHelper Items(Options, Options->ContainerPtrToValuePtr<void>(Row));
            for (int I = 0; I < 3; ++I) {
                void* Value = Items.GetRawPtr(Items.AddValue());
                Put(Option->Struct, Value, "Label", I == 0 ? "Low" : I == 1 ? "Normal" : "High");
                Put(Option->Struct, Value, "IntValue", FString::FromInt(I + 1));
                Put(Option->Struct, Value, "FloatValue", I == 0 ? "0.25" : I == 1 ? "0.5" : "1");
                Put(Option->Struct, Value, "TextValue", I == 0 ? "low" : I == 1 ? "normal" : "high");
            }
        }
    }
    Add("PrintConfig", "Button", "This is a button", "Print the typed Config values; this button does not save settings.");
    return List.Num() == UE_ARRAY_COUNT(Settings) + 2;
}
}
int32 UMCUExampleBuildCommandlet::Main(const FString& Params) {
    if (!FParse::Param(*Params, TEXT("OverwriteGeneratedAssets"))) return 1;
    auto* SDK = LoadObject<UBlueprint>(nullptr, TEXT("/Game/Mods/ModConfigUI/Blueprint/BP_MCUConfigComponent.BP_MCUConfigComponent"));
    if (!SDK || !SDK->GeneratedClass) return 2;
    const FString Root = "/Game/Mods/MCUExample5/";
    auto* Config = NewStruct(Root + "ST_ExampleConfig", "ST_ExampleConfig");
    if (!Config) return 3;
    for (const auto& S : Settings) if (!Field(Config, S.Key, ValueType(S.Type))) return 4;
    auto* BP = FKismetEditorUtilities::CreateBlueprint(AActor::StaticClass(), CreatePackage(*(Root + "ModActor")), "ModActor", BPTYPE_Normal);
    if (!BP) return 5;
    FBlueprintEditorUtils::AddMemberVariable(BP, "Config", StructType(Config));
    auto* ComponentNode = BP->SimpleConstructionScript->CreateNode(SDK->GeneratedClass, "MCUConfig");
    BP->SimpleConstructionScript->AddNode(ComponentNode);
    // BPML_GenericFunctions handles this named Blueprint function and adds the Mod prefix.
    auto* Print = Function(BP, "PrintToModLoader");
    if (!Print) return 6;
    Print->CreateUserDefinedPin("Message", Type(UEdGraphSchema_K2::PC_String), EGPD_Output);
    if (!Compile(BP)) return 6;
    if (!PrintFunction(BP, Config, "OnConfigReady", false, false)
        || !PrintFunction(BP, Config, "OnConfigChanged", true, false)
        || !PrintFunction(BP, Config, "OnButtonClicked", false, true)) return 6;
    if (!Compile(BP) || !SetFields(ComponentNode->ComponentTemplate)) return 7;
    auto* CDO = Cast<AActor>(BP->GeneratedClass->GetDefaultObject());
    CDO->PrimaryActorTick.bCanEverTick = false;
    auto* P = FindFProperty<FStructProperty>(BP->GeneratedClass, "Config");
    if (!P) return 8;
    void* Data = P->ContainerPtrToValuePtr<void>(CDO);
    for (const auto& S : Settings) if (!Put(Config, Data, S.Key, S.Default)) return 9;
    if (!Save(Config) || !Save(BP)) return 11;
    UE_LOG(LogTemp, Display, TEXT("MCUEXAMPLE5_CREATED: 11 typed values, separator, button, Ready/Changed/Button graphs"));
    return 0;
}
