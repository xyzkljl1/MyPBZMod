#pragma once
#include "Commandlets/Commandlet.h"
#include "MCUBlueprintAPIBuildCommandlet.generated.h"
UCLASS()
class UMCUBlueprintAPIBuildCommandlet : public UCommandlet {
    GENERATED_BODY()
public:
    virtual int32 Main(const FString& Params) override;
};
