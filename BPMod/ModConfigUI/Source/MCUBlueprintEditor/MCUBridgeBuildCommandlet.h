#pragma once
#include "Commandlets/Commandlet.h"
#include "MCUBridgeBuildCommandlet.generated.h"

UCLASS()
class UMCUBridgeBuildCommandlet : public UCommandlet
{
    GENERATED_BODY()
public:
    virtual int32 Main(const FString& Params) override;
};
