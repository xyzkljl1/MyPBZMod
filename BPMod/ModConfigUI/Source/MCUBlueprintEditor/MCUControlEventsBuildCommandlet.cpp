#include "MCUControlEventsBuildCommandlet.h"
#include "BlueprintBuildUtils.h"
#include "Blueprint/UserWidget.h"
#include "Blueprint/WidgetTree.h"
#include "CommonButtonBase.h"
#include "CommonActivatableWidget.h"
#include "Components/Overlay.h"
#include "Components/Slider.h"
#include "WidgetBlueprint.h"
#include "WidgetBlueprintFactory.h"
#include "K2Node_CustomEvent.h"
#include "K2Node_AddDelegate.h"
#include "K2Node_RemoveDelegate.h"
#include "K2Node_CreateDelegate.h"
#include "K2Node_IfThenElse.h"
#include "Misc/Parse.h"
#include "UObject/StrongObjectPtr.h"
using namespace MCUBuilder;

namespace {
struct FBinding { FName Delegate; FName Handler; };
const TArray<FBinding> SliderBindings = {
    {"OnValueChanged", "SliderChanged"},
    {"OnMouseCaptureBegin", "CaptureBegin"}, {"OnMouseCaptureEnd", "CaptureEnd"},
    {"OnControllerCaptureBegin", "CaptureBegin"}, {"OnControllerCaptureEnd", "CaptureEnd"},
};
const TArray<FBinding> ButtonBindings = {{"OnButtonBaseClicked", "Clicked"}};
const TArray<FBinding> HostBindings = {
    {"BP_OnWidgetActivated", "HostActivated"}, {"BP_OnWidgetDeactivated", "HostDeactivated"},
};

bool Emit(UBlueprint* BP, UEdGraph* Graph, UEdGraphPin* Exec, FName Kind, FName Signal = "MCU_ControlEvent") {
    auto* Store = Set(Graph, "EventKind");
    Store->FindPinChecked(FName("EventKind"))->DefaultValue = Kind.ToString();
    auto* Call = Node<UK2Node_CallFunction>(Graph);
    Call->FunctionReference.SetSelfMember(Signal); Call->AllocateDefaultPins();
    return Link(Exec, Store->FindPin(UEdGraphSchema_K2::PN_Execute))
        && Link(Store->FindPin(UEdGraphSchema_K2::PN_Then), Call->FindPin(UEdGraphSchema_K2::PN_Execute));
}

bool Handler(UBlueprint* BP, FName Name, UFunction* Signature) {
    auto* Graph = FBlueprintEditorUtils::CreateNewGraph(BP, Name, UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
    FBlueprintEditorUtils::AddFunctionGraph(BP, Graph, true, Signature);
    for (UEdGraphNode* N : Graph->Nodes) if (auto* Entry = Cast<UK2Node_FunctionEntry>(N)) {
        Entry->FindPinChecked(UEdGraphSchema_K2::PN_Then)->BreakAllPinLinks();
        return Emit(BP, Graph, Entry->FindPin(UEdGraphSchema_K2::PN_Then), Name);
    }
    return false;
}

bool Bindings(UBlueprint* BP, FName Name, FName Member, UClass* Class,
    const TArray<FBinding>& Items, bool Add) {
    auto* Entry = Function(BP, Name);
    auto* Graph = Entry->GetGraph();
    auto* Exec = Entry->FindPin(UEdGraphSchema_K2::PN_Then);
    UEdGraphPin* Input;
    if (Add) {
        auto InputType = Type(UEdGraphSchema_K2::PC_Object); InputType.PinSubCategoryObject = Class;
        Input = Entry->CreateUserDefinedPin("Input", InputType, EGPD_Output);
        auto* Store = Set(Graph, Member);
        if (!Link(Input, Store->FindPin(Member)) || !Link(Exec, Store->FindPin(UEdGraphSchema_K2::PN_Execute))) return false;
        Exec = Store->FindPin(UEdGraphSchema_K2::PN_Then);
    } else Input = Get(Graph, Member)->FindPin(Member);
    for (const auto& Item : Items) {
        auto* Property = FindFProperty<FMulticastDelegateProperty>(Class, Item.Delegate);
        if (!Property) return false;
        UK2Node_BaseMCDelegate* Bind = Add
            ? static_cast<UK2Node_BaseMCDelegate*>(Node<UK2Node_AddDelegate>(Graph))
            : static_cast<UK2Node_BaseMCDelegate*>(Node<UK2Node_RemoveDelegate>(Graph));
        Bind->SetFromProperty(Property, false, Class); Bind->AllocateDefaultPins();
        auto* Delegate = Node<UK2Node_CreateDelegate>(Graph);
        Delegate->AllocateDefaultPins(); Delegate->SetFunction(Item.Handler);
        if (!Link(Delegate->GetDelegateOutPin(), Bind->GetDelegatePin())
            || !Link(Input, Bind->FindPin(UEdGraphSchema_K2::PN_Self))
            || !Link(Exec, Bind->FindPin(UEdGraphSchema_K2::PN_Execute))) return false;
        Exec = Bind->FindPin(UEdGraphSchema_K2::PN_Then);
    }
    if (!Add && !Link(Exec, Set(Graph, Member)->FindPin(UEdGraphSchema_K2::PN_Execute))) return false;
    return true;
}

bool SelfTest(UBlueprint* BP) {
    auto* Receiver = NewObject<UUserWidget>(GetTransientPackage(), BP->GeneratedClass);
    // Compiling the temporary button Blueprint below runs garbage collection.
    TStrongObjectPtr<UUserWidget> KeepReceiver(Receiver);
    auto* Slider = NewObject<USlider>();
    auto* Other = NewObject<USlider>();
    auto* Kind = FindFProperty<FNameProperty>(BP->GeneratedClass, "EventKind");
    auto Expect = [&](FName Name) { return Kind->GetPropertyValue_InContainer(Receiver) == Name; };
    auto Clear = [&]() { Kind->SetPropertyValue_InContainer(Receiver, NAME_None); };
    struct { USlider* Input; } Args{Slider};
    Receiver->ProcessEvent(Receiver->FindFunctionChecked("BindSlider"), &Args);
    Slider->OnValueChanged.Broadcast(.3f); if (!Expect("SliderChanged")) return false;
    Slider->OnMouseCaptureBegin.Broadcast(); if (!Expect("CaptureBegin")) return false;
    Slider->OnMouseCaptureEnd.Broadcast(); if (!Expect("CaptureEnd")) return false;
    Slider->OnControllerCaptureBegin.Broadcast(); if (!Expect("CaptureBegin")) return false;
    Slider->OnControllerCaptureEnd.Broadcast(); if (!Expect("CaptureEnd")) return false;
    Clear(); Other->OnValueChanged.Broadcast(.9f); if (!Expect(NAME_None)) return false;
    Receiver->ProcessEvent(Receiver->FindFunctionChecked("UnbindSlider"), nullptr);
    Slider->OnValueChanged.Broadcast(.7f); if (!Expect(NAME_None)) return false;
    // The actual button base is abstract; use a transient Blueprint subclass.
    auto* ButtonFactory = NewObject<UWidgetBlueprintFactory>();
    ButtonFactory->ParentClass = UCommonButtonBase::StaticClass();
    auto* ButtonBP = CastChecked<UWidgetBlueprint>(ButtonFactory->FactoryCreateNew(UWidgetBlueprint::StaticClass(),
        GetTransientPackage(), "MCUTestButton", RF_Transient, nullptr, GWarn));
    if (!Compile(ButtonBP)) return false;
    auto* Button = NewObject<UCommonButtonBase>(GetTransientPackage(), ButtonBP->GeneratedClass);
    struct { UCommonButtonBase* Input; } ButtonArgs{Button};
    Receiver->ProcessEvent(Receiver->FindFunctionChecked("BindButton"), &ButtonArgs);
    auto* Click = FindFProperty<FMulticastDelegateProperty>(UCommonButtonBase::StaticClass(), "OnButtonBaseClicked");
    // Broadcast the reflected instance delegate, without Slate or a viewport.
    struct { UCommonButtonBase* Button; } ClickArgs{Button};
    const auto* ClickDelegate = Click->GetMulticastDelegate(Click->ContainerPtrToValuePtr<void>(Button));
    if (!ClickDelegate || !ClickDelegate->IsBound()) return false;
    ClickDelegate->ProcessMulticastDelegate<UObject>(&ClickArgs);
    if (!Expect("Clicked")) return false;
    Receiver->ProcessEvent(Receiver->FindFunctionChecked("UnbindButton"), nullptr);
    Clear();
    Click->GetMulticastDelegate(Click->ContainerPtrToValuePtr<void>(Button))->ProcessMulticastDelegate<UObject>(&ClickArgs);
    if (!Expect(NAME_None)) return false;
    auto* Host = NewObject<UCommonActivatableWidget>();
    auto* OtherHost = NewObject<UCommonActivatableWidget>();
    struct { UCommonActivatableWidget* Input; } HostArgs{Host};
    Receiver->ProcessEvent(Receiver->FindFunctionChecked("BindHost"), &HostArgs);
    // Exercise the real activation path, including deactivate/reopen and isolation.
    Host->ActivateWidget(); if (!Expect("HostActivated")) return false;
    Host->DeactivateWidget(); if (!Expect("HostDeactivated")) return false;
    Clear(); OtherHost->ActivateWidget(); OtherHost->DeactivateWidget();
    if (!Expect(NAME_None)) return false;
    Host->ActivateWidget(); if (!Expect("HostActivated")) return false;
    Receiver->ProcessEvent(Receiver->FindFunctionChecked("UnbindHost"), nullptr);
    Clear(); Host->DeactivateWidget(); if (!Expect(NAME_None)) return false;
    // Exercise Slate teardown, not a manually invoked Destruct event. A collapsed
    // observer remains a child of the root, just like the runtime menu observer.
    auto* Parent = NewObject<UUserWidget>(GetTransientPackage(), BP->GeneratedClass);
    TStrongObjectPtr<UUserWidget> KeepParent(Parent);
    Parent->Initialize();
    Receiver->Initialize();
    Receiver->SetVisibility(ESlateVisibility::Collapsed);
    auto* Notify = FindFProperty<FBoolProperty>(BP->GeneratedClass, "NotifyDestruct");
    Notify->SetPropertyValue_InContainer(Receiver, true);
    CastChecked<UOverlay>(Parent->GetRootWidget())->AddChild(Receiver);
    TSharedPtr<SWidget> SlateParent = Parent->TakeWidget();
    Clear(); SlateParent.Reset();
    if (!Expect("Destruct")) return false;
    if (Kind->GetPropertyValue_InContainer(Parent) != NAME_None) return false;
    Clear(); SlateParent = Parent->TakeWidget(); SlateParent.Reset();
    if (!Expect("Destruct")) return false;
    UE_LOG(LogTemp, Display, TEXT("MCU_DESTRUCT_TEST_PASS: collapsed child receives Slate teardown and rebuild/teardown; ordinary parent emits no notification"));
    return true;
}
}

int32 UMCUControlEventsBuildCommandlet::Main(const FString& Params) {
    if (!FParse::Param(*Params, TEXT("OverwriteGeneratedAssets"))) return 1;
    const FString Path = "/Game/Mods/ModConfigUI/W_ControlEvents";
    auto* Factory = NewObject<UWidgetBlueprintFactory>(); Factory->ParentClass = UUserWidget::StaticClass();
    auto* BP = CastChecked<UWidgetBlueprint>(Factory->FactoryCreateNew(UWidgetBlueprint::StaticClass(),
        CreatePackage(*Path), "W_ControlEvents", RF_Public | RF_Standalone, nullptr, GWarn));
    auto* Content = BP->WidgetTree->ConstructWidget<UOverlay>(UOverlay::StaticClass(), "ContentRoot");
    Content->bIsVariable = true; Content->SetVisibility(ESlateVisibility::Visible);
    BP->WidgetTree->RootWidget = Content;
    FBlueprintEditorUtils::AddMemberVariable(BP, "EventKind", Type(UEdGraphSchema_K2::PC_Name));
    FBlueprintEditorUtils::AddMemberVariable(BP, "NotifyDestruct", Type(UEdGraphSchema_K2::PC_Boolean));
    for (const auto& Pair : {TPair<FName, UClass*>("BoundSlider", USlider::StaticClass()),
        TPair<FName, UClass*>("BoundButton", UCommonButtonBase::StaticClass()),
        TPair<FName, UClass*>("BoundHost", UCommonActivatableWidget::StaticClass())}) {
        auto T = Type(UEdGraphSchema_K2::PC_Object); T.PinSubCategoryObject = Pair.Value;
        FBlueprintEditorUtils::AddMemberVariable(BP, Pair.Key, T);
    }
    auto* Event = Node<UK2Node_CustomEvent>(BP->UbergraphPages[0]);
    Event->CustomFunctionName = "MCU_ControlEvent"; Event->AllocateDefaultPins();
    auto* DestroySignal = Node<UK2Node_CustomEvent>(BP->UbergraphPages[0]);
    DestroySignal->CustomFunctionName = "MCU_MenuDestruct"; DestroySignal->AllocateDefaultPins();
    if (!Compile(BP)) return 2;
    auto* Destroy = Node<UK2Node_Event>(BP->UbergraphPages[0]);
    Destroy->EventReference.SetExternalMember("Destruct", UUserWidget::StaticClass());
    Destroy->bOverrideFunction = true; Destroy->AllocateDefaultPins();
    auto* Gate = Node<UK2Node_IfThenElse>(Destroy->GetGraph()); Gate->AllocateDefaultPins();
    if (!Link(Destroy->FindPin(UEdGraphSchema_K2::PN_Then), Gate->GetExecPin())
        || !Link(Get(Destroy->GetGraph(), "NotifyDestruct")->FindPin(FName("NotifyDestruct")), Gate->GetConditionPin())
        || !Emit(BP, Destroy->GetGraph(), Gate->GetThenPin(), "Destruct", "MCU_MenuDestruct")) return 4;
    TSet<FName> Added;
    for (const auto& Item : SliderBindings) if (!Added.Contains(Item.Handler)) {
        if (!Handler(BP, Item.Handler, FindFProperty<FMulticastDelegateProperty>(USlider::StaticClass(), Item.Delegate)->SignatureFunction)) return 3;
        Added.Add(Item.Handler);
    }
    if (!Handler(BP, "Clicked", FindFProperty<FMulticastDelegateProperty>(UCommonButtonBase::StaticClass(), "OnButtonBaseClicked")->SignatureFunction)) return 3;
    for (const auto& Item : HostBindings)
        if (!Handler(BP, Item.Handler, FindFProperty<FMulticastDelegateProperty>(UCommonActivatableWidget::StaticClass(), Item.Delegate)->SignatureFunction)) return 3;
    // The wrapper participates in the entire hit/focus path, including blank row space.
    for (FName Name : {FName("OnMouseEnter"), FName("OnMouseLeave"),
        FName("OnAddedToFocusPath"), FName("OnRemovedFromFocusPath")}) {
        auto* NodeEvent = Node<UK2Node_Event>(BP->UbergraphPages[0]);
        NodeEvent->EventReference.SetExternalMember(Name, UUserWidget::StaticClass());
        NodeEvent->bOverrideFunction = true; NodeEvent->AllocateDefaultPins();
        if (!Emit(BP, NodeEvent->GetGraph(), NodeEvent->FindPin(UEdGraphSchema_K2::PN_Then), Name)) return 4;
    }
    if (!Compile(BP)
        || !Bindings(BP, "BindSlider", "BoundSlider", USlider::StaticClass(), SliderBindings, true)
        || !Bindings(BP, "UnbindSlider", "BoundSlider", USlider::StaticClass(), SliderBindings, false)
        || !Bindings(BP, "BindButton", "BoundButton", UCommonButtonBase::StaticClass(), ButtonBindings, true)
        || !Bindings(BP, "UnbindButton", "BoundButton", UCommonButtonBase::StaticClass(), ButtonBindings, false)
        || !Bindings(BP, "BindHost", "BoundHost", UCommonActivatableWidget::StaticClass(), HostBindings, true)
        || !Bindings(BP, "UnbindHost", "BoundHost", UCommonActivatableWidget::StaticClass(), HostBindings, false)
        || !Compile(BP) || !SelfTest(BP)) return 5;
    auto* CDO = CastChecked<UUserWidget>(BP->GeneratedClass->GetDefaultObject());
    CDO->SetIsFocusable(false);
    auto* Tick = FindFProperty<FEnumProperty>(BP->GeneratedClass, "TickFrequency");
    Tick->GetUnderlyingProperty()->SetIntPropertyValue(Tick->ContainerPtrToValuePtr<void>(CDO), int64(0));
    if (!Save(BP)) return 6;
    UE_LOG(LogTemp, Display, TEXT("MCU_CONTROL_EVENTS_PASS: slider, button, host activate/deactivate/reopen, instance isolation, delegate cleanup; no runtime C++"));
    return 0;
}
