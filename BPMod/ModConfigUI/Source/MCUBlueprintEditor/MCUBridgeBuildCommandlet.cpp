#include "MCUBridgeBuildCommandlet.h"
#include "Modules/ModuleManager.h"
#include "Blueprint/UserWidget.h"
#include "Blueprint/WidgetTree.h"
#include "Components/EditableText.h"
#include "Components/VerticalBox.h"
#include "WidgetBlueprint.h"
#include "WidgetBlueprintFactory.h"
#include "EdGraphSchema_K2.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_VariableGet.h"
#include "K2Node_VariableSet.h"
#include "K2Node_AddDelegate.h"
#include "K2Node_RemoveDelegate.h"
#include "K2Node_CreateDelegate.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "KismetCompiler.h"
#include "Misc/PackageName.h"
#include "UObject/SavePackage.h"
#include "UObject/UnrealType.h"

IMPLEMENT_MODULE(FDefaultModuleImpl, MCUBlueprintEditor)

namespace {
template<class T> T* Node(UEdGraph* Graph)
{
    T* Result = NewObject<T>(Graph);
    Graph->AddNode(Result, false, false);
    Result->CreateNewGuid();
    return Result;
}
void Link(UEdGraphPin* A, UEdGraphPin* B)
{
    check(A && B);
    check(GetDefault<UEdGraphSchema_K2>()->TryCreateConnection(A, B));
}
UK2Node_FunctionEntry* Function(UBlueprint* BP, const FName Name, UFunction* Signature = nullptr)
{
    UEdGraph* Graph = FBlueprintEditorUtils::CreateNewGraph(BP, Name, UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
    FBlueprintEditorUtils::AddFunctionGraph(BP, Graph, true, Signature);
    for (UEdGraphNode* N : Graph->Nodes)
        if (auto* Entry = Cast<UK2Node_FunctionEntry>(N)) return Entry;
    return nullptr;
}
void ClearDefaultExecution(UK2Node_FunctionEntry* Entry)
{
    Entry->FindPinChecked(UEdGraphSchema_K2::PN_Then)->BreakAllPinLinks();
}
UK2Node_VariableSet* Set(UEdGraph* Graph, const FName Name)
{
    auto* Result = Node<UK2Node_VariableSet>(Graph);
    Result->VariableReference.SetSelfMember(Name);
    Result->AllocateDefaultPins();
    return Result;
}
void DelegateGraph(UBlueprint* BP, const FName Name, bool Add, const FEdGraphPinType& InputType)
{
    auto* Entry = Function(BP, Name);
    auto* Graph = Entry->GetGraph();
    ClearDefaultExecution(Entry);
    UEdGraphPin* Input;
    UEdGraphPin* Exec = Entry->FindPinChecked(UEdGraphSchema_K2::PN_Then);
    if (Add)
    {
        Input = Entry->CreateUserDefinedPin("Input", InputType, EGPD_Output);
        auto* Store = Set(Graph, "BoundInput");
        Link(Exec, Store->FindPinChecked(UEdGraphSchema_K2::PN_Execute));
        Link(Input, Store->FindPinChecked(FName("BoundInput")));
        Exec = Store->FindPinChecked(UEdGraphSchema_K2::PN_Then);
    }
    else
    {
        auto* Get = Node<UK2Node_VariableGet>(Graph);
        Get->VariableReference.SetSelfMember("BoundInput");
        Get->AllocateDefaultPins();
        Input = Get->FindPinChecked(FName("BoundInput"));
    }
    UK2Node_BaseMCDelegate* Bind = Add
        ? static_cast<UK2Node_BaseMCDelegate*>(Node<UK2Node_AddDelegate>(Graph))
        : static_cast<UK2Node_BaseMCDelegate*>(Node<UK2Node_RemoveDelegate>(Graph));
    auto* Property = FindFProperty<FMulticastDelegateProperty>(UEditableText::StaticClass(), "OnTextCommitted");
    Bind->SetFromProperty(Property, false, UEditableText::StaticClass());
    Bind->AllocateDefaultPins();
    auto* Delegate = Node<UK2Node_CreateDelegate>(Graph);
    Delegate->AllocateDefaultPins();
    Delegate->SetFunction("MCUTextCommitted");
    Link(Delegate->GetDelegateOutPin(), Bind->GetDelegatePin());
    Link(Input, Bind->FindPinChecked(UEdGraphSchema_K2::PN_Self));
    Link(Exec, Bind->FindPinChecked(UEdGraphSchema_K2::PN_Execute));
    if (!Add)
    {
        auto* Clear = Set(Graph, "BoundInput");
        Link(Bind->FindPinChecked(UEdGraphSchema_K2::PN_Then), Clear->FindPinChecked(UEdGraphSchema_K2::PN_Execute));
    }
}
}

int32 UMCUBridgeBuildCommandlet::Main(const FString& Params)
{
    const FString PackageName = TEXT("/Game/Mods/ModConfigUI/W_TextInputBridge");
    UPackage* Package = CreatePackage(*PackageName);
    auto* Factory = NewObject<UWidgetBlueprintFactory>();
    Factory->ParentClass = UUserWidget::StaticClass();
    auto* BP = CastChecked<UWidgetBlueprint>(Factory->FactoryCreateNew(UWidgetBlueprint::StaticClass(),
        Package, "W_TextInputBridge", RF_Public | RF_Standalone, nullptr, GWarn));
    BP->WidgetTree->RootWidget = BP->WidgetTree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), "Rows");
    FEdGraphPinType InputType;
    InputType.PinCategory = UEdGraphSchema_K2::PC_Object;
    InputType.PinSubCategoryObject = UEditableText::StaticClass();
    FBlueprintEditorUtils::AddMemberVariable(BP, "BoundInput", InputType);
    FEdGraphPinType TextType;
    TextType.PinCategory = UEdGraphSchema_K2::PC_Text;
    FBlueprintEditorUtils::AddMemberVariable(BP, "LastCommittedText", TextType);
    auto* Property = FindFProperty<FMulticastDelegateProperty>(UEditableText::StaticClass(), "OnTextCommitted");
    auto* Entry = Function(BP, "MCUTextCommitted", Property->SignatureFunction);
    ClearDefaultExecution(Entry);
    auto* StoreText = Set(Entry->GetGraph(), "LastCommittedText");
    Link(Entry->FindPinChecked(UEdGraphSchema_K2::PN_Then), StoreText->FindPinChecked(UEdGraphSchema_K2::PN_Execute));
    Link(Entry->FindPinChecked(FName("Text")), StoreText->FindPinChecked(FName("LastCommittedText")));
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    DelegateGraph(BP, "BindInput", true, InputType);
    DelegateGraph(BP, "UnbindInput", false, InputType);
    FCompilerResultsLog Results;
    FKismetEditorUtilities::CompileBlueprint(BP, EBlueprintCompileOptions::None, &Results);
    if (Results.NumErrors > 0) return 1;

    // Check blueprint binding and cleanup before cooking the asset.
    auto* Receiver = NewObject<UUserWidget>(GetTransientPackage(), BP->GeneratedClass);
    auto* Input = NewObject<UEditableText>(Receiver);
    struct { UEditableText* Input; } BindParams{Input};
    auto* LastText = FindFProperty<FTextProperty>(BP->GeneratedClass, "LastCommittedText");
    Receiver->ProcessEvent(Receiver->FindFunctionChecked("BindInput"), &BindParams);
    Input->OnTextCommitted.Broadcast(FText::FromString("enter-check"), ETextCommit::OnEnter);
    if (LastText->GetPropertyValue_InContainer(Receiver).ToString() != "enter-check") return 2;
    Input->OnTextCommitted.Broadcast(FText::FromString("focus-check"), ETextCommit::OnUserMovedFocus);
    if (LastText->GetPropertyValue_InContainer(Receiver).ToString() != "focus-check") return 3;
    Receiver->ProcessEvent(Receiver->FindFunctionChecked("UnbindInput"), nullptr);
    Input->OnTextCommitted.Broadcast(FText::FromString("must-not-arrive"), ETextCommit::OnEnter);
    if (LastText->GetPropertyValue_InContainer(Receiver).ToString() != "focus-check") return 4;
    UE_LOG(LogTemp, Display, TEXT("MCU_BRIDGE_SELFTEST_PASS: Blueprint bind, Enter, focus loss, unbind"));

    const FString Filename = FPackageName::LongPackageNameToFilename(PackageName, FPackageName::GetAssetPackageExtension());
    FSavePackageArgs SaveArgs;
    SaveArgs.TopLevelFlags = RF_Public | RF_Standalone;
    if (!UPackage::SavePackage(Package, BP, *Filename, SaveArgs)) return 5;
    UE_LOG(LogTemp, Display, TEXT("MCU_BRIDGE_CREATED %s"), *Filename);
    return 0;
}
