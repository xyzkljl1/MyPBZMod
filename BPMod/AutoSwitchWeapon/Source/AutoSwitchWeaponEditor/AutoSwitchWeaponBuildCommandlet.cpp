#include "AutoSwitchWeaponBuildCommandlet.h"
#include "Modules/ModuleManager.h"
#include "BasicAttributeSet.h"
#include "CharacterWeaponsComponent.h"
#include "ActorStateComponent.h"
#include "AbilitySystemComponent.h"
#include "AbilitySystemBlueprintLibrary.h"
#include "Abilities/Async/AbilityAsync_WaitAttributeChanged.h"
#include "Abilities/Async/AbilityAsync_WaitGameplayTag.h"
#include "BlueprintGameplayTagLibrary.h"
#include "InputAction.h"
#include "InputModifiers.h"
#include "InputTriggers.h"
#include "Kismet/GameplayStatics.h"
#include "Kismet/KismetMathLibrary.h"
#include "Kismet/KismetSystemLibrary.h"
#include "Kismet/KismetArrayLibrary.h"
#include "GameFramework/PlayerController.h"
#include "Engine/Blueprint.h"
#include "Engine/World.h"
#include "Engine/Engine.h"
#include "Engine/LocalPlayer.h"
#include "Engine/GameInstance.h"
#include "Subsystems/SubsystemBlueprintLibrary.h"
#include "TimerManager.h"
#include "GameplayTagsManager.h"
#include "EdGraphSchema_K2.h"
#include "K2Node_CallFunction.h"
#include "K2Node_CallArrayFunction.h"
#include "K2Node_MacroInstance.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_VariableGet.h"
#include "K2Node_VariableSet.h"
#include "K2Node_IfThenElse.h"
#include "K2Node_AddDelegate.h"
#include "K2Node_RemoveDelegate.h"
#include "K2Node_CreateDelegate.h"
#include "K2Node_Self.h"
#include "K2Node_Event.h"
#include "K2Node_DynamicCast.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "KismetCompiler.h"
#include "Misc/PackageName.h"
#include "Misc/ScopeExit.h"
#include "UObject/SavePackage.h"
#include "UObject/UnrealType.h"

IMPLEMENT_MODULE(FDefaultModuleImpl, AutoSwitchWeaponEditor)

namespace
{
using Pin = UEdGraphPin*;
using Schema = UEdGraphSchema_K2;
FEdGraphPinType Type(FName Category, UObject* Object = nullptr, FName Subcategory = NAME_None)
{
    FEdGraphPinType T;
    T.PinCategory = Category; T.PinSubCategoryObject = Object; T.PinSubCategory = Subcategory;
    return T;
}
FEdGraphPinType ObjectType(UClass* C) { return Type(Schema::PC_Object, C); }
FEdGraphPinType StructType(UScriptStruct* S) { return Type(Schema::PC_Struct, S); }
template<class T> T* Node(UEdGraph* G)
{
    auto* N = NewObject<T>(G); G->AddNode(N, false, false); N->CreateNewGuid();
    N->NodePosX = (G->Nodes.Num() % 6) * 320; N->NodePosY = (G->Nodes.Num() / 6) * 240;
    return N;
}
void Link(Pin A, Pin B)
{
    check(A && B);
    if (!GetDefault<Schema>()->TryCreateConnection(A, B))
        UE_LOG(LogTemp, Fatal, TEXT("Link failed: %s.%s -> %s.%s"),
            *A->GetOwningNode()->GetNodeTitle(ENodeTitleType::FullTitle).ToString(), *A->PinName.ToString(),
            *B->GetOwningNode()->GetNodeTitle(ENodeTitleType::FullTitle).ToString(), *B->PinName.ToString());
}
void Value(Pin P, const FString& V) { check(P); GetDefault<Schema>()->TrySetDefaultValue(*P, V); }
void Var(UBlueprint* BP, FName Name, const FEdGraphPinType& T, const FString& Default = {})
{
    check(FBlueprintEditorUtils::AddMemberVariable(BP, Name, T, Default));
}
UK2Node_FunctionEntry* Function(UBlueprint* BP, FName Name, UFunction* Signature = nullptr)
{
    auto* G = FBlueprintEditorUtils::CreateNewGraph(BP, Name, UEdGraph::StaticClass(), Schema::StaticClass());
    FBlueprintEditorUtils::AddFunctionGraph(BP, G, true, Signature);
    for (auto N : G->Nodes) if (auto* E = Cast<UK2Node_FunctionEntry>(N)) return E;
    checkNoEntry(); return nullptr;
}
struct Graph
{
    UK2Node_FunctionEntry* Entry;
    UEdGraph* G;
    Pin Exec;
    explicit Graph(UK2Node_FunctionEntry* E) : Entry(E), G(E->GetGraph()), Exec(E->FindPinChecked(Schema::PN_Then))
    { Exec->BreakAllPinLinks(); }
    Pin Self() { auto* N = Node<UK2Node_Self>(G); N->AllocateDefaultPins(); return N->FindPinChecked(Schema::PN_Self); }
    Pin Get(FName Name)
    {
        auto* N = Node<UK2Node_VariableGet>(G); N->VariableReference.SetSelfMember(Name);
        N->AllocateDefaultPins(); return N->FindPinChecked(Name);
    }
    UK2Node_CallFunction* Call(UClass* C, FName Name, Pin Target = nullptr)
    {
        auto* F = C->FindFunctionByName(Name); checkf(F, TEXT("Missing function %s:%s"), *C->GetName(), *Name.ToString());
        auto* N = C == UKismetArrayLibrary::StaticClass() ? static_cast<UK2Node_CallFunction*>(Node<UK2Node_CallArrayFunction>(G))
            : Node<UK2Node_CallFunction>(G);
        N->SetFromFunction(F); N->AllocateDefaultPins();
        if (Target) Link(Target, N->FindPinChecked(Schema::PN_Self));
        return N;
    }
    UK2Node_CallFunction* Local(FName Name)
    {
        auto* N = Node<UK2Node_CallFunction>(G); N->FunctionReference.SetSelfMember(Name); N->AllocateDefaultPins();
        return N;
    }
    void Run(UK2Node_CallFunction* N)
    {
        if (N->IsNodePure()) return;
        Link(Exec, N->FindPinChecked(Schema::PN_Execute)); Exec = N->FindPinChecked(Schema::PN_Then);
    }
    void Set(FName Name, Pin Source = nullptr, const FString& Literal = {})
    {
        auto* N = Node<UK2Node_VariableSet>(G); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins();
        if (Source) Link(Source, N->FindPinChecked(Name)); else if (!Literal.IsEmpty()) Value(N->FindPinChecked(Name), Literal);
        Link(Exec, N->FindPinChecked(Schema::PN_Execute)); Exec = N->FindPinChecked(Schema::PN_Then);
    }
    UK2Node_IfThenElse* Branch(Pin Condition)
    {
        auto* N = Node<UK2Node_IfThenElse>(G); N->AllocateDefaultPins();
        Link(Condition, N->GetConditionPin()); Link(Exec, N->GetExecPin()); Exec = N->GetThenPin(); return N;
    }
    void Guard(Pin Condition, bool Expected = true)
    { auto* N = Branch(Condition); Exec = Expected ? N->GetThenPin() : N->GetElsePin(); }
    Pin Valid(Pin Object)
    { auto* N = Call(UKismetSystemLibrary::StaticClass(), "IsValid"); Link(Object, N->FindPinChecked(FName("Object"))); return N->GetReturnValuePin(); }
    Pin Math(FName Name, Pin A, Pin B = nullptr, const FString& LiteralB = {})
    {
        auto* N = Call(UKismetMathLibrary::StaticClass(), Name); Link(A, N->FindPinChecked(FName("A")));
        if (B) Link(B, N->FindPinChecked(FName("B"))); else if (!LiteralB.IsEmpty()) Value(N->FindPinChecked(FName("B")), LiteralB);
        return N->GetReturnValuePin();
    }
    void Timer(FName FunctionName, Pin Seconds = nullptr, const FString& Literal = {})
    {
        auto* N = Call(UKismetSystemLibrary::StaticClass(), "K2_SetTimer");
        Link(Self(), N->FindPinChecked(FName("Object"))); Value(N->FindPinChecked(FName("FunctionName")), FunctionName.ToString());
        Value(N->FindPinChecked(FName("bLooping")), "false");
        if (Seconds) Link(Seconds, N->FindPinChecked(FName("Time"))); else Value(N->FindPinChecked(FName("Time")), Literal);
        Run(N);
    }
    void ClearTimer(FName FunctionName)
    {
        auto* N = Call(UKismetSystemLibrary::StaticClass(), "K2_ClearTimer");
        Link(Self(), N->FindPinChecked(FName("Object"))); Value(N->FindPinChecked(FName("FunctionName")), FunctionName.ToString()); Run(N);
    }
    void Delegate(UClass* C, FName PropertyName, Pin Target, FName Callback, bool Add)
    {
        auto* Property = FindFProperty<FMulticastDelegateProperty>(C, PropertyName); check(Property);
        UK2Node_BaseMCDelegate* N = Add ? static_cast<UK2Node_BaseMCDelegate*>(Node<UK2Node_AddDelegate>(G))
            : static_cast<UK2Node_BaseMCDelegate*>(Node<UK2Node_RemoveDelegate>(G));
        N->SetFromProperty(Property, false, C); N->AllocateDefaultPins();
        auto* D = Node<UK2Node_CreateDelegate>(G); D->AllocateDefaultPins(); D->SetFunction(Callback);
        Link(D->GetDelegateOutPin(), N->GetDelegatePin()); Link(Target, N->FindPinChecked(Schema::PN_Self));
        Link(Exec, N->FindPinChecked(Schema::PN_Execute)); Exec = N->FindPinChecked(Schema::PN_Then);
    }
    UK2Node_CallFunction* Attribute(FName Name)
    {
        auto* N = Call(UAbilitySystemBlueprintLibrary::StaticClass(), "GetFloatAttribute");
        Link(Get("PlayerPawn"), N->FindPinChecked(FName("Actor"))); Link(Get(Name), N->FindPinChecked(FName("Attribute"))); return N;
    }
    Pin Cooldown()
    {
        auto* N = Call(UCharacterWeaponsComponent::StaticClass(), "GetCurrentChangeWeaponCooldown", Get("Weapons"));
        Link(Get("MainSlot"), N->FindPinChecked(FName("SlotTag"))); return N->GetReturnValuePin();
    }
    Pin CastObject(Pin Object, UClass* Class)
    {
        auto* N = Node<UK2Node_DynamicCast>(G); N->TargetType = Class; N->SetPurity(true); N->AllocateDefaultPins();
        Link(Object, N->GetCastSourcePin()); return N->GetCastResultPin();
    }
    Pin OwnedTags()
    {
        auto* ASC = Call(UAbilitySystemBlueprintLibrary::StaticClass(), "GetAbilitySystemComponent");
        Link(Get("PlayerPawn"), ASC->FindPinChecked(FName("Actor")));
        auto* Tags = Call(UBlueprintGameplayTagLibrary::StaticClass(), "GetOwnedGameplayTags");
        Link(ASC->GetReturnValuePin(), Tags->FindPinChecked(FName("TagContainerInterface")));
        return Tags->GetReturnValuePin();
    }
    Pin TagArray(FName Name)
    {
        auto* N = Call(UBlueprintGameplayTagLibrary::StaticClass(), "BreakGameplayTagContainer");
        Link(Get(Name), N->FindPinChecked(FName("GameplayTagContainer")));
        return N->FindPinChecked(FName("GameplayTags"));
    }
    void ForEach(Pin Array, FName Callback, FName Parameter)
    {
        auto* Library = LoadObject<UBlueprint>(nullptr, TEXT("/Engine/EditorBlueprintResources/StandardMacros.StandardMacros"));
        check(Library);
        UEdGraph* Macro = nullptr;
        for (auto Candidate : Library->MacroGraphs) if (Candidate->GetFName() == "ForEachLoop") Macro = Candidate.Get();
        check(Macro);
        auto* N = Node<UK2Node_MacroInstance>(G); N->SetMacroGraph(Macro); N->AllocateDefaultPins();
        Link(Array, N->FindPinChecked(FName("Array"))); Link(Exec, N->FindPinChecked(FName("Exec")));
        auto* Body = Local(Callback); Link(N->FindPinChecked(FName("Array Element")), Body->FindPinChecked(Parameter));
        Exec = N->FindPinChecked(FName("LoopBody")); Run(Body); Exec = N->FindPinChecked(FName("Completed"));
    }
};

void BuildGraphs(UBlueprint* BP)
{
    Var(BP, "Enabled", Type(Schema::PC_Boolean), "true");
    Var(BP, "ThresholdPercent", Type(Schema::PC_Real, nullptr, Schema::PC_Double), "30.0");
    for (auto Name : {"Ready", "Queued", "InputInFlight", "Started", "ResolveQueued"}) Var(BP, Name, Type(Schema::PC_Boolean));
    for (auto Name : {"EvaluationCount", "RequestCount", "ResolveCount"}) Var(BP, Name, Type(Schema::PC_Int));
    Var(BP, "BootstrapGameInstance", ObjectType(UGameInstance::StaticClass()));
    Var(BP, "ObservedPawn", ObjectType(APawn::StaticClass()));
    Var(BP, "PlayerPawn", ObjectType(APawn::StaticClass()));
    Var(BP, "Controller", ObjectType(APlayerController::StaticClass()));
    Var(BP, "Weapons", ObjectType(UCharacterWeaponsComponent::StaticClass()));
    Var(BP, "States", ObjectType(UActorStateComponent::StaticClass()));
    Var(BP, "InputSubsystem", ObjectType(UEnhancedInputLocalPlayerSubsystem::StaticClass()));
    Var(BP, "SwitchAction", ObjectType(UInputAction::StaticClass()));
    for (auto Name : {"ShachiWatcher", "MaxWatcher"}) Var(BP, Name, ObjectType(UAbilityAsync_WaitAttributeChanged::StaticClass()));
    auto Watchers = ObjectType(UAbilityAsync_WaitGameplayTagRemoved::StaticClass()); Watchers.ContainerType = EPinContainerType::Array;
    Var(BP, "AttackWatchers", Watchers);
    Var(BP, "AttackRoots", StructType(FGameplayTagContainer::StaticStruct()),
        TEXT("(GameplayTags=((TagName=\"Ability.Action.Hun.Heavy\"),(TagName=\"Ability.Action.Hun.Light\")))"));
    for (auto Name : {"ProtectedAttacks", "CandidateAttacks", "OtherAttacks"}) Var(BP, Name, StructType(FGameplayTagContainer::StaticStruct()));
    for (auto Pair : {TPair<FName, FName>("ShachiAttribute", "Shachi"), {"MaxAttribute", "Shachi_Max"}, {"HealthAttribute", "Health"}})
    {
        FGameplayAttribute Attribute(FindFProperty<FProperty>(UBasicAttributeSet::StaticClass(), Pair.Value));
        FString Text; FGameplayAttribute::StaticStruct()->ExportText(Text, &Attribute, nullptr, nullptr, PPF_None, nullptr);
        Var(BP, Pair.Key, StructType(FGameplayAttribute::StaticStruct()), Text);
    }
    Var(BP, "MainSlot", StructType(FGameplayTag::StaticStruct()), TEXT("(TagName=\"Weapon.Slot.Main\")"));
    auto Modifiers = ObjectType(UInputModifier::StaticClass()); Modifiers.ContainerType = EPinContainerType::Array;
    auto Triggers = ObjectType(UInputTrigger::StaticClass()); Triggers.ContainerType = EPinContainerType::Array;
    Var(BP, "EmptyModifiers", Modifiers); Var(BP, "EmptyTriggers", Triggers);

    TMap<FName, UK2Node_FunctionEntry*> Functions;
    for (auto Name : {"Initialize", "Shutdown", "StopWatcher", "UnbindState", "QueueEvaluate", "Evaluate", "FinishInput",
        "PostBeginPlay", "PreBeginPlay", "StopMod", "UnbindGameInstance", "UnbindPawn", "QueueResolve", "ResolvePlayer",
        "CapturePaidAttacks", "CaptureAttackTag", "RebuildProtection", "AddAttackWatcher", "StopAttackWatchers"})
        Functions.Add(Name, Function(BP, Name));
    for (auto Name : {"CaptureAttackTag", "AddAttackWatcher"})
        Functions[Name]->CreateUserDefinedPin("Tag", StructType(FGameplayTag::StaticStruct()), EGPD_Output);
    auto* Initialize = Functions["Initialize"];
    for (auto Pair : {TPair<FName, UClass*>("Pawn", APawn::StaticClass()), {"PlayerController", APlayerController::StaticClass()},
        {"WeaponComponent", UCharacterWeaponsComponent::StaticClass()}, {"StateComponent", UActorStateComponent::StaticClass()},
        {"Subsystem", UEnhancedInputLocalPlayerSubsystem::StaticClass()}, {"Action", UInputAction::StaticClass()}})
        Initialize->CreateUserDefinedPin(Pair.Key, ObjectType(Pair.Value), EGPD_Output);
    Functions["StopWatcher"]->CreateUserDefinedPin("Watcher", ObjectType(UAbilityAsync::StaticClass()), EGPD_Output);
    auto* Changed = FindFProperty<FMulticastDelegateProperty>(UAbilityAsync_WaitAttributeChanged::StaticClass(), "Changed");
    auto* Ended = FindFProperty<FMulticastDelegateProperty>(UActorStateComponent::StaticClass(), "OnStateEnd");
    Functions.Add("ResourceChanged", Function(BP, "ResourceChanged", Changed->SignatureFunction));
    Functions.Add("StateEnded", Function(BP, "StateEnded", Ended->SignatureFunction));
    auto* Possession = FindFProperty<FMulticastDelegateProperty>(UGameInstance::StaticClass(), "OnPawnControllerChangedDelegates");
    auto* Restart = FindFProperty<FMulticastDelegateProperty>(APawn::StaticClass(), "ReceiveRestartedDelegate");
    Functions.Add("PawnControllerChanged", Function(BP, "PawnControllerChanged", Possession->SignatureFunction));
    Functions.Add("PawnRestarted", Function(BP, "PawnRestarted", Restart->SignatureFunction));
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);

    {
        Graph G(Functions["StopWatcher"]);
        auto* P = G.Entry->FindPinChecked(FName("Watcher")); G.Guard(G.Valid(P));
        G.Run(G.Call(UAbilityAsync::StaticClass(), "EndAction", P));
    }
    {
        Graph G(Functions["UnbindState"]); G.Guard(G.Valid(G.Get("States")));
        G.Delegate(UActorStateComponent::StaticClass(), "OnStateEnd", G.Get("States"), "StateEnded", false);
    }
    {
        Graph G(Functions["Shutdown"]);
        G.Set("Ready", nullptr, "false"); G.ClearTimer("Evaluate"); G.ClearTimer("FinishInput");
        for (auto Name : {"ShachiWatcher", "MaxWatcher"})
        { auto* N = G.Local("StopWatcher"); Link(G.Get(Name), N->FindPinChecked(FName("Watcher"))); G.Run(N); G.Set(Name); }
        G.Run(G.Local("StopAttackWatchers")); G.Set("ProtectedAttacks"); G.Set("CandidateAttacks"); G.Set("OtherAttacks");
        G.Run(G.Local("UnbindState"));
        for (auto Name : {"PlayerPawn", "Controller", "Weapons", "States", "InputSubsystem", "SwitchAction"}) G.Set(Name);
        G.Set("Queued", nullptr, "false"); G.Set("InputInFlight", nullptr, "false");
    }
    {
        Graph G(Functions["Initialize"]); G.Run(G.Local("Shutdown"));
        for (auto Pair : {TPair<FName, FName>("PlayerPawn", "Pawn"), {"Controller", "PlayerController"}, {"Weapons", "WeaponComponent"},
            {"States", "StateComponent"}, {"InputSubsystem", "Subsystem"}, {"SwitchAction", "Action"}})
        { G.Set(Pair.Key, G.Entry->FindPinChecked(Pair.Value)); G.Guard(G.Valid(G.Get(Pair.Key))); }
        auto* Maximum = G.Attribute("MaxAttribute"); G.Guard(Maximum->FindPinChecked(FName("bSuccessfullyFoundAttribute")));
        for (auto Pair : {TPair<FName, FName>("ShachiWatcher", "ShachiAttribute"), {"MaxWatcher", "MaxAttribute"}})
        {
            auto* N = G.Call(UAbilityAsync_WaitAttributeChanged::StaticClass(), "WaitForAttributeChanged");
            Link(G.Get("PlayerPawn"), N->FindPinChecked(FName("TargetActor"))); Link(G.Get(Pair.Value), N->FindPinChecked(FName("Attribute")));
            Value(N->FindPinChecked(FName("OnlyTriggerOnce")), "false"); G.Run(N); G.Set(Pair.Key, N->GetReturnValuePin());
            G.Delegate(UAbilityAsync_WaitAttributeChanged::StaticClass(), "Changed", G.Get(Pair.Key), "ResourceChanged", true);
            G.Run(G.Call(UBlueprintAsyncActionBase::StaticClass(), "Activate", G.Get(Pair.Key)));
        }
        G.Delegate(UActorStateComponent::StaticClass(), "OnStateEnd", G.Get("States"), "StateEnded", true);
        G.Set("Ready", nullptr, "true"); G.Run(G.Local("QueueEvaluate"));
    }
    { Graph G(Functions["StateEnded"]); G.Run(G.Local("QueueEvaluate")); }
    {
        Graph G(Functions["ResourceChanged"]); G.Run(G.Local("QueueEvaluate")); G.Guard(G.Get("Ready"));
        auto* IsShachi = G.Call(UAbilitySystemBlueprintLibrary::StaticClass(), "EqualEqual_GameplayAttributeGameplayAttribute");
        Link(G.Entry->FindPinChecked(FName("Attribute")), IsShachi->FindPinChecked(FName("AttributeA")));
        Link(G.Get("ShachiAttribute"), IsShachi->FindPinChecked(FName("AttributeB"))); G.Guard(IsShachi->GetReturnValuePin());
        G.Guard(G.Math("Less_DoubleDouble", G.Entry->FindPinChecked(FName("NewValue")), G.Entry->FindPinChecked(FName("OldValue"))));
        G.Run(G.Local("CapturePaidAttacks"));
    }
    {
        Graph G(Functions["CapturePaidAttacks"]);
        auto* Filter = G.Call(UBlueprintGameplayTagLibrary::StaticClass(), "Filter");
        Link(G.OwnedTags(), Filter->FindPinChecked(FName("TagContainer")));
        Link(G.Get("AttackRoots"), Filter->FindPinChecked(FName("OtherContainer")));
        Value(Filter->FindPinChecked(FName("bExactMatch")), "false"); G.Set("CandidateAttacks", Filter->GetReturnValuePin());
        G.ForEach(G.TagArray("CandidateAttacks"), "CaptureAttackTag", "Tag"); G.Run(G.Local("RebuildProtection"));
    }
    {
        // Keep concrete attack tags, not their shared Heavy/Light ancestors. Otherwise
        // an overlapping free follow-up would inherit protection from the paid attack.
        Graph G(Functions["CaptureAttackTag"]); auto Tag = G.Entry->FindPinChecked(FName("Tag"));
        G.Set("OtherAttacks", G.Get("CandidateAttacks"));
        auto* Remove = G.Call(UBlueprintGameplayTagLibrary::StaticClass(), "RemoveGameplayTag");
        Link(G.Get("OtherAttacks"), Remove->FindPinChecked(FName("TagContainer"))); Link(Tag, Remove->FindPinChecked(FName("Tag"))); G.Run(Remove);
        auto* HasChild = G.Call(UBlueprintGameplayTagLibrary::StaticClass(), "HasTag");
        Link(G.Get("OtherAttacks"), HasChild->FindPinChecked(FName("TagContainer"))); Link(Tag, HasChild->FindPinChecked(FName("Tag")));
        Value(HasChild->FindPinChecked(FName("bExactMatch")), "false"); G.Guard(HasChild->GetReturnValuePin(), false);
        auto* Add = G.Call(UBlueprintGameplayTagLibrary::StaticClass(), "AddGameplayTag");
        Link(G.Get("ProtectedAttacks"), Add->FindPinChecked(FName("TagContainer"))); Link(Tag, Add->FindPinChecked(FName("Tag"))); G.Run(Add);
    }
    {
        Graph G(Functions["StopAttackWatchers"]); G.ForEach(G.Get("AttackWatchers"), "StopWatcher", "Watcher");
        auto* Clear = G.Call(UKismetArrayLibrary::StaticClass(), "Array_Clear"); Link(G.Get("AttackWatchers"), Clear->FindPinChecked(FName("TargetArray"))); G.Run(Clear);
    }
    {
        // This callback runs synchronously on tag removal, before a later attack can
        // re-add the same tag. Rebuild only on events; ended listeners never accumulate.
        Graph G(Functions["RebuildProtection"]); G.Guard(G.Get("Ready")); G.Run(G.Local("StopAttackWatchers"));
        auto* Filter = G.Call(UBlueprintGameplayTagLibrary::StaticClass(), "Filter");
        Link(G.Get("ProtectedAttacks"), Filter->FindPinChecked(FName("TagContainer")));
        Link(G.OwnedTags(), Filter->FindPinChecked(FName("OtherContainer")));
        Value(Filter->FindPinChecked(FName("bExactMatch")), "true"); G.Set("ProtectedAttacks", Filter->GetReturnValuePin());
        G.ForEach(G.TagArray("ProtectedAttacks"), "AddAttackWatcher", "Tag"); G.Run(G.Local("QueueEvaluate"));
    }
    {
        Graph G(Functions["AddAttackWatcher"]);
        auto* N = G.Call(UAbilityAsync_WaitGameplayTagRemoved::StaticClass(), "WaitGameplayTagRemoveFromActor");
        Link(G.Get("PlayerPawn"), N->FindPinChecked(FName("TargetActor"))); Link(G.Entry->FindPinChecked(FName("Tag")), N->FindPinChecked(FName("Tag")));
        Value(N->FindPinChecked(FName("OnlyTriggerOnce")), "true"); G.Run(N);
        auto* Add = G.Call(UKismetArrayLibrary::StaticClass(), "Array_Add"); Link(G.Get("AttackWatchers"), Add->FindPinChecked(FName("TargetArray")));
        Link(N->GetReturnValuePin(), Add->FindPinChecked(FName("NewItem"))); G.Run(Add);
        G.Delegate(UAbilityAsync_WaitGameplayTagRemoved::StaticClass(), "Removed", N->GetReturnValuePin(), "RebuildProtection", true);
        G.Run(G.Call(UBlueprintAsyncActionBase::StaticClass(), "Activate", N->GetReturnValuePin()));
    }
    {
        Graph G(Functions["QueueEvaluate"]); G.Guard(G.Get("Ready")); G.Guard(G.Get("Enabled")); G.Guard(G.Get("Queued"), false);
        G.Set("Queued", nullptr, "true"); G.Timer("Evaluate", nullptr, "0.001");
    }
    {
        Graph G(Functions["Evaluate"]); G.Set("Queued", nullptr, "false");
        G.Set("EvaluationCount", G.Math("Add_IntInt", G.Get("EvaluationCount"), nullptr, "1"));
        G.Guard(G.Get("Ready")); G.Guard(G.Get("Enabled")); G.Guard(G.Get("InputInFlight"), false);
        for (auto Name : {"PlayerPawn", "Controller", "Weapons", "States", "InputSubsystem", "SwitchAction"}) G.Guard(G.Valid(G.Get(Name)));
        auto* Pawn = G.Call(AController::StaticClass(), "K2_GetPawn", G.Get("Controller"));
        G.Guard(G.Math("EqualEqual_ObjectObject", Pawn->GetReturnValuePin(), G.Get("PlayerPawn")));
        auto* Paused = G.Call(UGameplayStatics::StaticClass(), "IsGamePaused"); Link(G.Self(), Paused->FindPinChecked(FName("WorldContextObject")));
        G.Guard(Paused->GetReturnValuePin(), false);
        auto* Ignored = G.Call(AController::StaticClass(), "IsMoveInputIgnored", G.Get("Controller")); G.Guard(Ignored->GetReturnValuePin(), false);
        auto* ASC = G.Call(UAbilitySystemBlueprintLibrary::StaticClass(), "GetAbilitySystemComponent");
        Link(G.Get("PlayerPawn"), ASC->FindPinChecked(FName("Actor"))); G.Guard(G.Valid(ASC->GetReturnValuePin()));
        // Only attacks observed consuming Shachi block input, including cooldown wakeups.
        auto* ProtectedCount = G.Call(UBlueprintGameplayTagLibrary::StaticClass(), "GetNumGameplayTagsInContainer");
        Link(G.Get("ProtectedAttacks"), ProtectedCount->FindPinChecked(FName("TagContainer")));
        G.Guard(G.Math("EqualEqual_IntInt", ProtectedCount->GetReturnValuePin(), nullptr, "0"));
        auto* Health = G.Attribute("HealthAttribute"); G.Guard(Health->FindPinChecked(FName("bSuccessfullyFoundAttribute")));
        G.Guard(G.Math("Greater_DoubleDouble", Health->GetReturnValuePin(), nullptr, "0.0"));
        auto* Maximum = G.Attribute("MaxAttribute"); G.Guard(Maximum->FindPinChecked(FName("bSuccessfullyFoundAttribute")));
        G.Guard(G.Math("Greater_DoubleDouble", Maximum->GetReturnValuePin(), nullptr, "0.0"));
        auto* Current = G.Attribute("ShachiAttribute"); G.Guard(Current->FindPinChecked(FName("bSuccessfullyFoundAttribute")));
        G.Guard(G.Math("Less_DoubleDouble", G.Math("Multiply_DoubleDouble", Current->GetReturnValuePin(), nullptr, "100.0"),
            G.Math("Multiply_DoubleDouble", Maximum->GetReturnValuePin(), G.Get("ThresholdPercent"))));
        auto* Count = G.Call(UCharacterWeaponsComponent::StaticClass(), "GetSlotWeapons", G.Get("Weapons"));
        Link(G.Get("MainSlot"), Count->FindPinChecked(FName("SlotTag")));
        G.Guard(G.Math("Greater_IntInt", Count->GetReturnValuePin(), nullptr, "1"));
        Pin Cooldown = G.Cooldown();
        auto* Wait = G.Branch(G.Math("Greater_DoubleDouble", Cooldown, nullptr, "0.0"));
        // A single wake-up for the actual remaining cooldown, never a loop.
        G.Timer("Evaluate", G.Math("Add_DoubleDouble", Cooldown, nullptr, "0.025"));
        G.Exec = Wait->GetElsePin();
        auto* Transition = G.Call(UCharacterWeaponsComponent::StaticClass(), "IsInWeaponTransition", G.Get("Weapons"));
        G.Guard(Transition->GetReturnValuePin(), false);
        G.Set("InputInFlight", nullptr, "true");
        G.Set("RequestCount", G.Math("Add_IntInt", G.Get("RequestCount"), nullptr, "1"));
        auto* Inject = G.Call(UEnhancedInputSubsystemInterface::StaticClass(), "InjectInputVectorForAction", G.Get("InputSubsystem"));
        Link(G.Get("SwitchAction"), Inject->FindPinChecked(FName("Action"))); Value(Inject->FindPinChecked(FName("Value")), "1.0,0.0,0.0");
        Link(G.Get("EmptyModifiers"), Inject->FindPinChecked(FName("Modifiers"))); Link(G.Get("EmptyTriggers"), Inject->FindPinChecked(FName("Triggers")));
        G.Run(Inject);
        // Input injection lasts one input frame; this only releases our in-flight guard.
        G.Timer("FinishInput", nullptr, "0.1");
    }
    {
        Graph G(Functions["FinishInput"]); G.Set("InputInFlight", nullptr, "false");
        G.Guard(G.Get("Ready")); G.Guard(G.Valid(G.Get("Weapons")));
        // Do not create a retry loop if the game's action system rejected the input.
        G.Guard(G.Math("Greater_DoubleDouble", G.Cooldown(), nullptr, "0.0")); G.Run(G.Local("QueueEvaluate"));
    }
    {
        Graph G(Functions["UnbindPawn"]); G.Guard(G.Valid(G.Get("ObservedPawn")));
        G.Delegate(APawn::StaticClass(), "ReceiveRestartedDelegate", G.Get("ObservedPawn"), "PawnRestarted", false);
        G.Set("ObservedPawn");
    }
    {
        Graph G(Functions["UnbindGameInstance"]); G.Guard(G.Valid(G.Get("BootstrapGameInstance")));
        G.Delegate(UGameInstance::StaticClass(), "OnPawnControllerChangedDelegates", G.Get("BootstrapGameInstance"), "PawnControllerChanged", false);
        G.Set("BootstrapGameInstance");
    }
    {
        Graph G(Functions["StopMod"]); G.Set("Started", nullptr, "false"); G.ClearTimer("ResolvePlayer");
        G.Set("ResolveQueued", nullptr, "false"); G.Run(G.Local("Shutdown"));
        G.Run(G.Local("UnbindPawn")); G.Run(G.Local("UnbindGameInstance"));
    }
    {
        Graph G(Functions["PostBeginPlay"]); G.Guard(G.Get("Started"), false);
        // BPModLoader can spawn again on Insert/reload. Keep only the first live instance.
        auto* Class = G.Call(UGameplayStatics::StaticClass(), "GetObjectClass"); Link(G.Self(), Class->FindPinChecked(FName("Object")));
        auto* First = G.Call(UGameplayStatics::StaticClass(), "GetActorOfClass");
        Link(G.Self(), First->FindPinChecked(FName("WorldContextObject"))); Link(Class->GetReturnValuePin(), First->FindPinChecked(FName("ActorClass"))); G.Run(First);
        auto* Unique = G.Branch(G.Math("EqualEqual_ObjectObject", First->GetReturnValuePin(), G.Self()));
        G.Exec = Unique->GetElsePin(); G.Run(G.Call(AActor::StaticClass(), "K2_DestroyActor", G.Self()));
        G.Exec = Unique->GetThenPin();
        auto* Instance = G.Call(UGameplayStatics::StaticClass(), "GetGameInstance"); Link(G.Self(), Instance->FindPinChecked(FName("WorldContextObject")));
        G.Set("BootstrapGameInstance", Instance->GetReturnValuePin()); G.Guard(G.Valid(G.Get("BootstrapGameInstance")));
        G.Set("Started", nullptr, "true");
        G.Delegate(UGameInstance::StaticClass(), "OnPawnControllerChangedDelegates", G.Get("BootstrapGameInstance"), "PawnControllerChanged", true);
        G.Run(G.Local("QueueResolve"));
    }
    { Graph G(Functions["PreBeginPlay"]); G.Run(G.Local("PostBeginPlay")); }
    {
        Graph G(Functions["PawnControllerChanged"]);
        auto* Pawn = G.Entry->FindPinChecked(FName("Pawn")); G.Guard(G.Valid(Pawn));
        // Pawn.IsPlayerControlled depends on PlayerState, which may not exist yet during possession.
        Pin PlayerController = G.CastObject(G.Entry->FindPinChecked(FName("Controller")), APlayerController::StaticClass());
        G.Guard(G.Math("BooleanOR", G.Valid(PlayerController), G.Math("EqualEqual_ObjectObject", Pawn, G.Get("ObservedPawn"))));
        G.Run(G.Local("QueueResolve"));
    }
    { Graph G(Functions["PawnRestarted"]); G.Run(G.Local("QueueResolve")); }
    {
        Graph G(Functions["QueueResolve"]); G.Guard(G.Get("Started")); G.Guard(G.Get("ResolveQueued"), false);
        G.Set("ResolveQueued", nullptr, "true");
        // Defer once past possession/restart dispatch, after game components have initialized.
        G.Timer("ResolvePlayer", nullptr, "0.001");
    }
    {
        Graph G(Functions["ResolvePlayer"]); G.Set("ResolveQueued", nullptr, "false"); G.Guard(G.Get("Started"));
        G.Set("ResolveCount", G.Math("Add_IntInt", G.Get("ResolveCount"), nullptr, "1"));
        G.Run(G.Local("Shutdown")); G.Run(G.Local("UnbindPawn"));
        auto* PC = G.Call(UGameplayStatics::StaticClass(), "GetPlayerController"); Link(G.Self(), PC->FindPinChecked(FName("WorldContextObject")));
        auto Controller = PC->GetReturnValuePin(); G.Guard(G.Valid(Controller));
        G.Guard(G.Call(APlayerController::StaticClass(), "IsLocalPlayerController", Controller)->GetReturnValuePin());
        auto* PawnNode = G.Call(AController::StaticClass(), "K2_GetPawn", Controller); auto Pawn = PawnNode->GetReturnValuePin();
        G.Set("ObservedPawn", Pawn); G.Guard(G.Valid(G.Get("ObservedPawn")));
        G.Delegate(APawn::StaticClass(), "ReceiveRestartedDelegate", G.Get("ObservedPawn"), "PawnRestarted", true);
        auto Component = [&](UClass* C)
        {
            auto* N = G.Call(AActor::StaticClass(), "GetComponentByClass", Pawn);
            GetDefault<Schema>()->TrySetDefaultObject(*N->FindPinChecked(FName("ComponentClass")), C);
            G.Run(N); return G.CastObject(N->GetReturnValuePin(), C);
        };
        Pin Weapons = Component(UCharacterWeaponsComponent::StaticClass()); G.Guard(G.Valid(Weapons));
        Pin States = Component(UActorStateComponent::StaticClass()); G.Guard(G.Valid(States));
        auto* Subsystem = G.Call(USubsystemBlueprintLibrary::StaticClass(), "GetLocalPlayerSubSystemFromPlayerController");
        Link(Controller, Subsystem->FindPinChecked(FName("PlayerController")));
        GetDefault<Schema>()->TrySetDefaultObject(*Subsystem->FindPinChecked(FName("Class")), UEnhancedInputLocalPlayerSubsystem::StaticClass());
        Pin Input = G.CastObject(Subsystem->GetReturnValuePin(), UEnhancedInputLocalPlayerSubsystem::StaticClass()); G.Guard(G.Valid(Input));
        auto* Path = G.Call(UKismetSystemLibrary::StaticClass(), "MakeSoftObjectPath");
        Value(Path->FindPinChecked(FName("PathString")), "/SGameCombatSystem/Weapon/Input/IA_ChangeWeapon.IA_ChangeWeapon");
        auto* Reference = G.Call(UKismetSystemLibrary::StaticClass(), "Conv_SoftObjPathToSoftObjRef");
        Link(Path->GetReturnValuePin(), Reference->FindPinChecked(FName("SoftObjectPath")));
        auto* Load = G.Call(UKismetSystemLibrary::StaticClass(), "LoadAsset_Blocking");
        Link(Reference->GetReturnValuePin(), Load->FindPinChecked(FName("Asset"))); G.Run(Load);
        Pin Action = G.CastObject(Load->GetReturnValuePin(), UInputAction::StaticClass()); G.Guard(G.Valid(Action));
        auto* Init = G.Local("Initialize");
        Link(Pawn, Init->FindPinChecked(FName("Pawn"))); Link(Controller, Init->FindPinChecked(FName("PlayerController")));
        Link(Weapons, Init->FindPinChecked(FName("WeaponComponent"))); Link(States, Init->FindPinChecked(FName("StateComponent")));
        Link(Input, Init->FindPinChecked(FName("Subsystem"))); Link(Action, Init->FindPinChecked(FName("Action"))); G.Run(Init);
    }
    auto* Events = FBlueprintEditorUtils::CreateNewGraph(BP, "Lifecycle", UEdGraph::StaticClass(), Schema::StaticClass());
    FBlueprintEditorUtils::AddUbergraphPage(BP, Events);
    auto* EndPlay = Node<UK2Node_Event>(Events);
    EndPlay->EventReference.SetExternalMember("ReceiveEndPlay", AActor::StaticClass());
    EndPlay->bOverrideFunction = true; EndPlay->AllocateDefaultPins();
    auto* Stop = Node<UK2Node_CallFunction>(Events);
    Stop->FunctionReference.SetSelfMember("StopMod"); Stop->AllocateDefaultPins();
    Link(EndPlay->FindPinChecked(Schema::PN_Then), Stop->FindPinChecked(Schema::PN_Execute));
}

bool TestBlueprint(UBlueprint* BP)
{
    TGuardValue<bool> ScriptExecution(GAllowActorScriptExecutionInEditor, true);
    auto Initialization = UWorld::InitializationValues().AllowAudioPlayback(false).CreatePhysicsScene(false)
        .CreateNavigation(false).CreateAISystem(false).ShouldSimulatePhysics(false).SetTransactional(false);
    UWorld* World = UWorld::CreateWorld(EWorldType::Game, false, "AutoSwitchWeaponTests", nullptr, true,
        ERHIFeatureLevel::Num, &Initialization);
    ON_SCOPE_EXIT { World->DestroyWorld(false); };
    auto* Pawn = World->SpawnActor<AAutoSwitchWeaponTestPawn>();
    auto* PC = World->SpawnActor<APlayerController>(); PC->Possess(Pawn);
    Pawn->ASC->InitAbilityActorInfo(Pawn, Pawn);
    auto* Attributes = NewObject<UBasicAttributeSet>(Pawn); Pawn->ASC->AddAttributeSetSubobject(Attributes);
    FGameplayAttribute Shachi(FindFProperty<FProperty>(UBasicAttributeSet::StaticClass(), "Shachi"));
    FGameplayAttribute Maximum(FindFProperty<FProperty>(UBasicAttributeSet::StaticClass(), "Shachi_Max"));
    FGameplayAttribute Health(FindFProperty<FProperty>(UBasicAttributeSet::StaticClass(), "Health"));
    Pawn->ASC->SetNumericAttributeBase(Health, 100); Pawn->ASC->SetNumericAttributeBase(Maximum, 100); Pawn->ASC->SetNumericAttributeBase(Shachi, 100);
    auto* Weapons = NewObject<UCharacterWeaponsComponent>(Pawn);
    auto* States = NewObject<UActorStateComponent>(Pawn);
    auto* LocalPlayer = NewObject<ULocalPlayer>(GEngine);
    auto* Input = NewObject<UAutoSwitchWeaponTestInput>(LocalPlayer);
    auto* Action = NewObject<UInputAction>(); Action->ValueType = EInputActionValueType::Boolean;
    auto* Actor = World->SpawnActor<AActor>(BP->GeneratedClass);
    struct FInitialize { APawn* Pawn; APlayerController* PlayerController; UCharacterWeaponsComponent* WeaponComponent;
        UActorStateComponent* StateComponent; UEnhancedInputLocalPlayerSubsystem* Subsystem; UInputAction* Action; } Init{Pawn, PC, Weapons, States, Input, Action};
    auto Invoke = [&](FName N) { Actor->ProcessEvent(Actor->FindFunctionChecked(N), nullptr); };
    auto Step = [&](float Seconds = 0.02f) { ++GFrameCounter; World->GetTimerManager().Tick(Seconds); };
    auto Drain = [&]() { for (int32 I=0; I<4; ++I) Step(); };
    auto Count = [&]() { return FindFProperty<FIntProperty>(Actor->GetClass(), "EvaluationCount")->GetPropertyValue_InContainer(Actor); };
    auto Check = [&](bool OK, const TCHAR* Description) { if (!OK) UE_LOG(LogTemp, Error, TEXT("ASW_TEST_FAILED: %s"), Description); return OK; };
    Actor->ProcessEvent(Actor->FindFunctionChecked("Initialize"), &Init); Drain();
    if (!Check(FindFProperty<FBoolProperty>(Actor->GetClass(), "Ready")->GetPropertyValue_InContainer(Actor)
        && Count() == 1, TEXT("Blueprint initialized and evaluated"))) return false;
    if (!Check(Input->Requests == 0, TEXT("initial full resource"))) return false;
    const int32 IdleCount = Count(); for (int32 I=0; I<200; ++I) Step();
    if (!Check(Count() == IdleCount && !Actor->PrimaryActorTick.bCanEverTick, TEXT("no idle polling or actor tick"))) return false;
    Pawn->ASC->SetNumericAttributeBase(Shachi, 30); Drain();
    if (!Check(Input->Requests == 0, TEXT("strictly below 30 percent"))) return false;
    const auto HeavyAttack = FGameplayTag::RequestGameplayTag("Ability.Action.Hun.Heavy.Atk01");
    const auto FreeHeavy = FGameplayTag::RequestGameplayTag("Ability.Action.Hun.Heavy.AirAtk01");
    const auto HeavyRoot = FGameplayTag::RequestGameplayTag("Ability.Action.Hun.Heavy");
    const auto LightAttack = FGameplayTag::RequestGameplayTag("Ability.Action.Hun.Light.A.Normal");
    auto ProtectedCount = [&]() { return FindFProperty<FStructProperty>(Actor->GetClass(), "ProtectedAttacks")
        ->ContainerPtrToValuePtr<FGameplayTagContainer>(Actor)->Num(); };
    auto WatcherCount = [&]() { auto* P = FindFProperty<FArrayProperty>(Actor->GetClass(), "AttackWatchers");
        return FScriptArrayHelper(P, P->ContainerPtrToValuePtr<void>(Actor)).Num(); };
    Pawn->ASC->AddLooseGameplayTag(HeavyRoot); Pawn->ASC->AddLooseGameplayTag(HeavyAttack);
    Pawn->ASC->SetNumericAttributeBase(Shachi, 29); Drain();
    if (!Check(Input->Requests == 0 && ProtectedCount() == 1 && WatcherCount() == 1,
        TEXT("actual spending protects concrete attack, excluding its ancestor"))) return false;
    States->OnStateEnd.Broadcast({}, {}); Drain();
    if (!Check(Input->Requests == 0, TEXT("intermediate state-end cannot interrupt paid attack"))) return false;
    const int32 AttackIdleCount = Count(); for (int32 I=0; I<100; ++I) Step();
    if (!Check(Count() == AttackIdleCount, TEXT("waiting for paid attack completion does not poll"))) return false;
    // The broad Heavy tag never disappears: only the old concrete attack ends.
    Pawn->ASC->AddLooseGameplayTag(FreeHeavy); Pawn->ASC->RemoveLooseGameplayTag(HeavyAttack); Drain();
    if (!Check(Input->Requests == 1 && ProtectedCount() == 0 && WatcherCount() == 0,
        TEXT("overlapping free heavy follow-up does not inherit protection"))) return false;
    Pawn->ASC->RemoveLooseGameplayTag(FreeHeavy); Pawn->ASC->RemoveLooseGameplayTag(HeavyRoot);
    for (int32 I=0; I<200; ++I) Step();
    if (!Check(Input->Requests == 1, TEXT("rejected input does not self-retry"))) return false;
    Pawn->ASC->AddLooseGameplayTag(LightAttack);
    Pawn->ASC->SetNumericAttributeBase(Shachi, 29); States->OnStateEnd.Broadcast({}, {}); Drain();
    if (!Check(Input->Requests == 2 && ProtectedCount() == 0,
        TEXT("zero-cost light attack allows switching"))) return false;
    Step(0.2f); Pawn->ASC->RemoveLooseGameplayTag(LightAttack); Drain();
    Weapons->TestCooldown=1; Pawn->ASC->SetNumericAttributeBase(Shachi, 28); Drain();
    if (!Check(Input->Requests == 2, TEXT("cooldown respected"))) return false;
    Pawn->ASC->AddLooseGameplayTag(HeavyAttack); Weapons->TestCooldown=0; Step(1.1f); Drain();
    if (!Check(Input->Requests == 3 && ProtectedCount() == 0,
        TEXT("cooldown expiry can switch during a heavy attack without spending"))) return false;
    Step(0.2f); Drain();
    Weapons->TestCooldown=1; Pawn->ASC->SetNumericAttributeBase(Shachi, 27); Drain();
    Weapons->TestCooldown=0; Step(1.1f); States->OnStateEnd.Broadcast({}, {}); Drain();
    if (!Check(Input->Requests == 3, TEXT("cooldown/state events cannot bypass actual cost protection"))) return false;
    Pawn->ASC->RemoveLooseGameplayTag(HeavyAttack); Drain();
    if (!Check(Input->Requests == 4, TEXT("paid attack end retries once"))) return false;
    Step(0.2f); Drain();
    Pawn->ASC->AddLooseGameplayTag(LightAttack); Pawn->ASC->SetNumericAttributeBase(Shachi, 26); Drain();
    if (!Check(Input->Requests == 4 && ProtectedCount() == 1, TEXT("light attack that actually spends is protected"))) return false;
    Pawn->ASC->SetNumericAttributeBase(Shachi, 100); Pawn->ASC->RemoveLooseGameplayTag(LightAttack); Drain();
    if (!Check(Input->Requests == 4 && WatcherCount() == 0, TEXT("recovered resource cancels need to switch after attack"))) return false;
    Pawn->ASC->SetNumericAttributeBase(Shachi, 30); Drain();
    Pawn->ASC->AddLooseGameplayTag(HeavyAttack); Pawn->ASC->SetNumericAttributeBase(Maximum, 200); Drain();
    if (!Check(Input->Requests == 5 && ProtectedCount() == 0, TEXT("maximum change is not attack spending"))) return false;
    Step(0.2f); Pawn->ASC->RemoveLooseGameplayTag(HeavyAttack); Pawn->ASC->SetNumericAttributeBase(Maximum, 100); Drain();
    Weapons->TestTransition=true; Pawn->ASC->SetNumericAttributeBase(Shachi, 10); Drain();
    if (!Check(Input->Requests == 5, TEXT("transition respected"))) return false;
    Pawn->ASC->AddLooseGameplayTag(LightAttack); Pawn->ASC->SetNumericAttributeBase(Shachi, 20); Drain();
    Weapons->TestTransition=false; States->OnStateEnd.Broadcast({}, {}); Drain();
    if (!Check(Input->Requests == 6 && ProtectedCount() == 0, TEXT("resource recovery during attack does not enable protection"))) return false;
    Step(0.2f); Drain();
    Pawn->ASC->SetNumericAttributeBase(Shachi, 19); Drain();
    if (!Check(Input->Requests == 6 && ProtectedCount() == 1, TEXT("a new actual cost protects current attack"))) return false;
    Pawn->ASC->RemoveLooseGameplayTag(LightAttack); Pawn->ASC->AddLooseGameplayTag(LightAttack); Drain();
    if (!Check(Input->Requests == 7 && ProtectedCount() == 0, TEXT("same-tag free follow-up does not retain stale protection"))) return false;
    Step(0.2f); Pawn->ASC->RemoveLooseGameplayTag(LightAttack); Drain();
    Pawn->ASC->AddLooseGameplayTag(HeavyAttack);
    for (float Value : {18.f, 17.f, 16.f}) Pawn->ASC->SetNumericAttributeBase(Shachi, Value);
    Drain();
    if (!Check(Input->Requests == 7 && ProtectedCount() == 1 && WatcherCount() == 1,
        TEXT("repeated costs do not duplicate or accumulate watchers"))) return false;
    Invoke("Shutdown"); Pawn->ASC->RemoveLooseGameplayTag(HeavyAttack);
    if (!Check(ProtectedCount() == 0 && WatcherCount() == 0, TEXT("shutdown clears attack protection"))) return false;
    Actor->ProcessEvent(Actor->FindFunctionChecked("Initialize"), &Init); Drain();
    if (!Check(Input->Requests == 8, TEXT("reinitialization binds once without stale protection"))) return false;
    Step(0.2f); Drain();
    Pawn->ASC->SetNumericAttributeBase(Health, 0); Pawn->ASC->SetNumericAttributeBase(Shachi, 10); Drain();
    if (!Check(Input->Requests == 8, TEXT("dead player ignored"))) return false;
    Pawn->ASC->SetNumericAttributeBase(Health, 100);
    Invoke("Shutdown"); Pawn->ASC->SetNumericAttributeBase(Shachi, 5); States->OnStateEnd.Broadcast({}, {});
    Pawn->ASC->AddLooseGameplayTag(HeavyAttack); Pawn->ASC->RemoveLooseGameplayTag(HeavyAttack);
    const int32 StoppedCount = Count(); for (int32 I=0; I<100; ++I) Step();
    if (!Check(Input->Requests == 8 && Count() == StoppedCount, TEXT("shutdown removes delegates and timers"))) return false;
    Actor->Destroy();
    UE_LOG(LogTemp, Display, TEXT("ASW_BLUEPRINT_TESTS_PASS: actual cost protection, free light/heavy attacks, overlapping/same-tag free follow-up, recovery, maximum, repeated costs, cooldown, threshold, idle, reinit, shutdown"));
    return true;
}

bool TestLifecycle(UBlueprint* BP)
{
    TGuardValue<bool> ScriptExecution(GAllowActorScriptExecutionInEditor, true);
    auto Initialization = UWorld::InitializationValues().AllowAudioPlayback(false).CreatePhysicsScene(false)
        .CreateNavigation(false).CreateAISystem(false).ShouldSimulatePhysics(false).SetTransactional(false);
    UWorld* World = UWorld::CreateWorld(EWorldType::Game, false, "AutoSwitchWeaponLifecycle", nullptr, true,
        ERHIFeatureLevel::Num, &Initialization);
    auto* Instance = NewObject<UGameInstance>(GEngine); World->SetGameInstance(Instance);
    auto* LocalPlayer = NewObject<ULocalPlayer>(GEngine);
    auto* PC = World->SpawnActor<APlayerController>();
    World->AddController(PC); // This headless world has not run actor initialization.
    LocalPlayer->PlayerController = PC; PC->Player = LocalPlayer;
    Instance->AddLocalPlayer(LocalPlayer, FPlatformUserId::CreateFromInternalId(0));
    ON_SCOPE_EXIT { LocalPlayer->PlayerRemoved(); World->DestroyWorld(false); };
    auto* ActionPackage = CreatePackage(TEXT("/SGameCombatSystem/Weapon/Input/IA_ChangeWeapon"));
    auto* Action = NewObject<UInputAction>(ActionPackage, "IA_ChangeWeapon", RF_Public | RF_Standalone);
    Action->ValueType = EInputActionValueType::Boolean;
    auto MakePawn = [&]()
    {
        auto* Pawn = World->SpawnActor<AAutoSwitchWeaponTestPawn>();
        Pawn->ASC->InitAbilityActorInfo(Pawn, Pawn);
        Pawn->ASC->AddAttributeSetSubobject(NewObject<UBasicAttributeSet>(Pawn));
        for (auto Name : {"Health", "Shachi", "Shachi_Max"})
            Pawn->ASC->SetNumericAttributeBase(FGameplayAttribute(FindFProperty<FProperty>(UBasicAttributeSet::StaticClass(), Name)), 100);
        auto* Weapons = NewObject<UCharacterWeaponsComponent>(Pawn); Pawn->AddInstanceComponent(Weapons); Weapons->RegisterComponent();
        auto* States = NewObject<UActorStateComponent>(Pawn); Pawn->AddInstanceComponent(States); States->RegisterComponent();
        return Pawn;
    };
    auto* Actor = World->SpawnActor<AActor>(BP->GeneratedClass);
    auto Invoke = [&](FName Name) { Actor->ProcessEvent(Actor->FindFunctionChecked(Name), nullptr); };
    auto Count = [&](FName Name) { return FindFProperty<FIntProperty>(Actor->GetClass(), Name)->GetPropertyValue_InContainer(Actor); };
    auto Ready = [&]() { return FindFProperty<FBoolProperty>(Actor->GetClass(), "Ready")->GetPropertyValue_InContainer(Actor); };
    auto BoundPawn = [&]() { return FindFProperty<FObjectPropertyBase>(Actor->GetClass(), "PlayerPawn")->GetObjectPropertyValue_InContainer(Actor); };
    auto Step = [&](int32 Frames = 5) { for(int32 I=0; I<Frames; ++I) { ++GFrameCounter; World->GetTimerManager().Tick(0.02f); } };
    auto Check = [&](bool OK, const TCHAR* Description)
    {
        if (!OK)
        {
            UE_LOG(LogTemp, Error, TEXT("ASW_LIFECYCLE_FAILED: %s; ready=%d resolves=%d local=%d pc=%s pawn=%s subsystem=%s"),
                Description, Ready(), Count("ResolveCount"), PC->IsLocalPlayerController(),
                *GetNameSafe(UGameplayStatics::GetPlayerController(Actor, 0)), *GetNameSafe(PC->GetPawn()),
                *GetNameSafe(LocalPlayer->GetSubsystem<UEnhancedInputLocalPlayerSubsystem>()));
            for (auto Name : {"ObservedPawn", "PlayerPawn", "Weapons", "States", "InputSubsystem", "SwitchAction"})
                UE_LOG(LogTemp, Display, TEXT("ASW_TEST_STATE %hs=%s"), Name,
                    *GetNameSafe(FindFProperty<FObjectPropertyBase>(Actor->GetClass(), Name)->GetObjectPropertyValue_InContainer(Actor)));
        }
        return OK;
    };
    Invoke("PostBeginPlay"); Invoke("PreBeginPlay"); Step();
    if (!Check(!Ready() && Count("ResolveCount") == 1, TEXT("start before pawn exists; duplicate startup coalesced"))) return false;
    const int32 Waiting = Count("ResolveCount"); Step(200);
    if (!Check(Count("ResolveCount") == Waiting, TEXT("waiting for pawn does not poll"))) return false;
    auto* FirstPawn = MakePawn(); PC->Possess(FirstPawn);
    Instance->GetOnPawnControllerChanged().Broadcast(FirstPawn, PC); Step();
    if (!Check(Ready() && BoundPawn() == FirstPawn, TEXT("game-instance event discovers and initializes local pawn"))) return false;
    const int32 BeforeRestart = Count("ResolveCount");
    FirstPawn->ReceiveRestartedDelegate.Broadcast(FirstPawn); Step();
    if (!Check(Ready() && Count("ResolveCount") == BeforeRestart + 1, TEXT("sparse pawn restart delegate rebinds once"))) return false;
    auto* SecondPawn = MakePawn(); PC->Possess(SecondPawn);
    Instance->GetOnPawnControllerChanged().Broadcast(SecondPawn, PC); Step();
    if (!Check(Ready() && BoundPawn() == SecondPawn, TEXT("respawn switches subscriptions"))) return false;
    const int32 AfterRespawn = Count("ResolveCount"); FirstPawn->ReceiveRestartedDelegate.Broadcast(FirstPawn); Step();
    if (!Check(Count("ResolveCount") == AfterRespawn, TEXT("old pawn restart is unbound"))) return false;
    auto* Duplicate = World->SpawnActor<AActor>(BP->GeneratedClass);
    Duplicate->ProcessEvent(Duplicate->FindFunctionChecked("PostBeginPlay"), nullptr);
    if (!Check(Duplicate->IsActorBeingDestroyed(), TEXT("duplicate loader instance is discarded"))) return false;
    Invoke("StopMod");
    Instance->GetOnPawnControllerChanged().Broadcast(SecondPawn, PC); SecondPawn->ReceiveRestartedDelegate.Broadcast(SecondPawn); Step(200);
    if (!Check(!Ready() && Count("ResolveCount") == AfterRespawn, TEXT("full shutdown removes lifecycle listeners"))) return false;
    Actor->Destroy();
    UE_LOG(LogTemp, Display, TEXT("ASW_LIFECYCLE_TESTS_PASS: no Lua initialization, late pawn, restart, respawn, duplicate rejection, no polling, shutdown"));
    return true;
}
}

AAutoSwitchWeaponTestPawn::AAutoSwitchWeaponTestPawn()
{ ASC = CreateDefaultSubobject<UAbilitySystemComponent>(TEXT("ASC")); }
void UAutoSwitchWeaponTestInput::InjectInputForAction(const UInputAction* Action, FInputActionValue RawValue,
    const TArray<UInputModifier*>& Modifiers, const TArray<UInputTrigger*>& Triggers)
{ check(Action && RawValue.Get<bool>() && Modifiers.Num()==0 && Triggers.Num()==0); ++Requests; }

int32 UAutoSwitchWeaponBuildCommandlet::Main(const FString& Params)
{
    check(FGameplayTag::RequestGameplayTag("Weapon.Slot.Main").IsValid());
    const FString PackageName = TEXT("/Game/Mods/AutoSwitchWeapon/ModActor");
    auto* Package = CreatePackage(*PackageName);
    auto* BP = FKismetEditorUtilities::CreateBlueprint(AActor::StaticClass(), Package, "ModActor", BPTYPE_Normal,
        UBlueprint::StaticClass(), UBlueprintGeneratedClass::StaticClass());
    BuildGraphs(BP);
    FCompilerResultsLog Results;
    FKismetEditorUtilities::CompileBlueprint(BP, EBlueprintCompileOptions::None, &Results);
    if (Results.NumErrors > 0) return 1;
    auto* CDO = CastChecked<AActor>(BP->GeneratedClass->GetDefaultObject());
    CDO->PrimaryActorTick.bCanEverTick = false; CDO->PrimaryActorTick.bStartWithTickEnabled = false;
    if (!TestBlueprint(BP)) return 2;
    if (!TestLifecycle(BP)) return 4;
    FSavePackageArgs Args; Args.TopLevelFlags = RF_Public | RF_Standalone;
    const FString Filename = FPackageName::LongPackageNameToFilename(PackageName, FPackageName::GetAssetPackageExtension());
    if (!UPackage::SavePackage(Package, BP, *Filename, Args)) return 3;
    UE_LOG(LogTemp, Display, TEXT("ASW_BLUEPRINT_CREATED %s"), *Filename);
    return 0;
}
