#pragma once
#include "Kismet/BlueprintFunctionLibrary.h"
#include "PBZBlueprintFunctionLibrary.generated.h"

// Authoring declarations for existing game functions; this module is never shipped.
UCLASS()
class PROJECTPBZ_API UPBZBlueprintFunctionLibrary : public UBlueprintFunctionLibrary
{
    GENERATED_BODY()
public:
    UFUNCTION(BlueprintCallable) static void BindLayerDisplayedWidgetChanged(UObject* Target, FName FunctionName);
    UFUNCTION(BlueprintCallable) static void UnbindLayerDisplayedWidgetChanged(UObject* Target, FName FunctionName);
};
