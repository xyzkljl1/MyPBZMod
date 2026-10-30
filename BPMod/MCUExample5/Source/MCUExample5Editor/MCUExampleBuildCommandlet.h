#pragma once
#include "Commandlets/Commandlet.h"
#include "MCUExampleBuildCommandlet.generated.h"
UCLASS()
class UMCUExampleBuildCommandlet : public UCommandlet {
    GENERATED_BODY()
public:
    virtual int32 Main(const FString& Params) override;
};
