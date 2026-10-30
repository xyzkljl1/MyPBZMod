#pragma once
// Editor-only helpers shared with the example generator; no runtime C++ dependency.
#include "Engine/Blueprint.h"
#include "EdGraphSchema_K2.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_VariableGet.h"
#include "K2Node_VariableSet.h"
#include "K2Node_CallFunction.h"
#include "K2Node_Event.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "Kismet2/StructureEditorUtils.h"
#include "UserDefinedStructure/UserDefinedStructEditorData.h"
#include "KismetCompiler.h"
#include "Misc/PackageName.h"
#include "UObject/SavePackage.h"
#include "UObject/UnrealType.h"

namespace MCUBuilder {
inline FEdGraphPinType Type(FName Category, FName Sub = NAME_None) {
    FEdGraphPinType T; T.PinCategory = Category; T.PinSubCategory = Sub; return T;
}
inline FEdGraphPinType StructType(UScriptStruct* Struct, bool Array = false) {
    auto T = Type(UEdGraphSchema_K2::PC_Struct); T.PinSubCategoryObject = Struct;
    if (Array) T.ContainerType = EPinContainerType::Array;
    return T;
}
template<class T> T* Node(UEdGraph* G) {
    auto* N = NewObject<T>(G); G->AddNode(N, false, false); N->CreateNewGuid(); return N;
}
inline bool Link(UEdGraphPin* A, UEdGraphPin* B) {
    return A && B && GetDefault<UEdGraphSchema_K2>()->TryCreateConnection(A, B);
}
inline UK2Node_FunctionEntry* Function(UBlueprint* BP, FName Name) {
    auto* G = FBlueprintEditorUtils::CreateNewGraph(BP, Name, UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
    FBlueprintEditorUtils::AddFunctionGraph(BP, G, true, static_cast<UFunction*>(nullptr));
    for (UEdGraphNode* N : G->Nodes) if (auto* E = Cast<UK2Node_FunctionEntry>(N)) {
        E->FindPin(UEdGraphSchema_K2::PN_Then)->BreakAllPinLinks(); return E;
    }
    return nullptr;
}
inline UK2Node_VariableSet* Set(UEdGraph* G, FName Name) {
    auto* N = Node<UK2Node_VariableSet>(G); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins(); return N;
}
inline UK2Node_VariableGet* Get(UEdGraph* G, FName Name) {
    auto* N = Node<UK2Node_VariableGet>(G); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins(); return N;
}
inline bool Compile(UBlueprint* BP) {
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    FCompilerResultsLog Results;
    FKismetEditorUtilities::CompileBlueprint(BP, EBlueprintCompileOptions::None, &Results);
    return Results.NumErrors == 0;
}
inline bool Save(UObject* Asset) {
    FSavePackageArgs Args; Args.TopLevelFlags = RF_Public | RF_Standalone; Args.SaveFlags = SAVE_NoError;
    return UPackage::SavePackage(Asset->GetOutermost(), Asset,
        *FPackageName::LongPackageNameToFilename(Asset->GetOutermost()->GetName(), ".uasset"), Args);
}
inline bool Field(UUserDefinedStruct* Struct, const FString& Name, const FEdGraphPinType& T, const FString& Default = "") {
    const auto& Existing = FStructureEditorUtils::GetVarDesc(Struct);
    if (Existing.Num() == 1 && Existing[0].FriendlyName.StartsWith("MemberVar")) {
        if (Existing[0].ToPinType() != T && !FStructureEditorUtils::ChangeVariableType(Struct, Existing[0].VarGuid, T)) return false;
    } else if (!FStructureEditorUtils::AddVariable(Struct, T)) return false;
    const FGuid Id = FStructureEditorUtils::GetVarDesc(Struct).Last().VarGuid;
    if (!FStructureEditorUtils::RenameVariable(Struct, Id, Name)) return false;
    return Default.IsEmpty() || FStructureEditorUtils::ChangeVariableDefaultValue(Struct, Id, Default);
}
inline UUserDefinedStruct* NewStruct(const FString& Package, FName Name) {
    auto* S = FStructureEditorUtils::CreateUserDefinedStruct(CreatePackage(*Package), Name, RF_Public | RF_Standalone);
    return S;
}
}
